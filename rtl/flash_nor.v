// -----------------------------------------------------------------------------
// flash_nor.v - AMD/Fujitsu-style NOR flash command engine (x16)
//
// The System 573's onboard flash and PCMCIA cards are AMD/Fujitsu-command-set
// NOR flash (e.g. Fujitsu MBM29F016). Unlike RAM, a word can only be programmed
// 1->0 (program ANDs the new data into the cell) and must be erased (back to
// 0xFFFF) a whole sector at a time, and all of this is driven by magic unlock
// command sequences rather than plain writes. This module models that command
// state machine so flash writes behave faithfully:
//
//   program:      AA->ADDR1, 55->ADDR2, A0->ADDR1, data->addr   (cell &= data)
//   sector erase: AA->ADDR1, 55->ADDR2, 80->ADDR1, AA->ADDR1, 55->ADDR2,
//                 30->sector-addr                                (sector = 0xFFFF)
//   chip erase:   ...80..., AA->ADDR1, 55->ADDR2, 10->ADDR1      (all = 0xFFFF)
//   autoselect:   AA->ADDR1, 55->ADDR2, 90->ADDR1 ; read 0=mfr id, 1=device id
//   reset:        F0 (or any out-of-sequence write) -> read mode
//
// The unlock addresses are parameterized (default 0x555/0x2AA word-mode); the
// command-set FSM is the same regardless. Reads return the array (or the ID
// words in autoselect mode).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module flash_nor #(
    parameter integer WORDS        = 2048,
    parameter integer SECTOR_WORDS = 512,
    // JEDEC autoselect IDs as driven on the (x16) data bus. For a single x16 die this
    // is the ID byte in the low lane (0x0004 / 0x00AD, high lane 0x00). A board that
    // builds each 16-bit word from TWO x8 chips (System 573: .31x low / .27x high)
    // drives the ID into BOTH lanes -- override to 0x0404 / 0xADAD (see s573_flash.v).
    parameter [15:0]  MFR_ID       = 16'h0004,   // Fujitsu (low lane)
    parameter [15:0]  DEV_ID       = 16'h00AD,   // MBM29F016A (low lane)
    parameter [10:0]  ADDR1        = 11'h555,
    parameter [10:0]  ADDR2        = 11'h2AA,
    // BACKING_EXTERNAL=0 (default): the array lives in the local mem[] BRAM and is
    //   read/programmed/erased here, exactly as before -- the iverilog unit tests
    //   exercise this path unchanged.
    // BACKING_EXTERNAL=1: the command/ID FSM is identical, but the ARRAY itself
    //   lives outside this module (the s573_flash 16 MB SDRAM-backed line buffer).
    //   In that mode array reads return `ext_rd_data` (the parent's word for the
    //   current `addr`); program and erase are executed by the PARENT, which
    //   watches the `prog_now` / `erase_now` strobes below (s573_flash commits
    //   programs word-by-word and runs erases as a background 0xFF walker over
    //   the SDRAM backing). The autoselect MFR/DEV ID path is unaffected so POST
    //   still passes the flash-ID check.
    parameter integer BACKING_EXTERNAL = 0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    input  wire        we,
    input  wire [15:0] addr,
    input  wire [15:0] din,
    output reg  [15:0] dout,
    // External-array read port (used only when BACKING_EXTERNAL=1):
    // ext_rd_data is the backing word the parent has fetched for `addr`.
    input  wire [15:0] ext_rd_data,
    // High when the current read returns an autoselect MFR/DEV ID word (not the
    // array). Lets an external-backing parent skip the SDRAM fill for ID reads so
    // POST's flash-ID check never stalls. Combinational; harmless when unused.
    output wire        id_read,
    // High on the program DATA cycle (state ST_PROG + a write strobe): the parent
    // (s573_flash, BACKING_EXTERNAL=1) uses this to write the programmed word back
    // to its external array. `din` is the program data and `addr` the (low) target
    // word; the NOR rule (cell &= data) is applied by the parent against the array
    // word it holds. Combinational; harmless (and ignored) in BACKING_EXTERNAL=0.
    output wire        prog_now,
    // High on the erase COMMAND cycle (state ST_ERCMD + a write strobe carrying a
    // valid erase opcode): chip erase (0x10 @ ADDR1) or sector erase (0x30, any
    // address -- JEDEC and MAME intelfsh both accept 0x30 anywhere; the sector is
    // named by the address). erase_chip distinguishes the two. This module's addr
    // port is only 16 bits, so a BACKING_EXTERNAL=1 parent captures the sector
    // index from its own full window address at this strobe (s573_flash uses
    // win_addr[20:16]). Combinational; ignored in BACKING_EXTERNAL=0, where the
    // local mem[] erase below still serves the sim path.
    output wire        erase_now,
    output wire        erase_chip
);
    localparam [2:0] ST_READ=3'd0, ST_UL1=3'd1, ST_UL2=3'd2, ST_AUTO=3'd3,
                     ST_PROG=3'd4, ST_ER1=3'd5, ST_ER2=3'd6, ST_ERCMD=3'd7;

    reg [15:0] mem [0:WORDS-1];
    reg [2:0]  state;

    wire hit1 = (addr[10:0] == ADDR1);
    wire hit2 = (addr[10:0] == ADDR2);

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'hFFFF;
        state = ST_READ;
    end

    integer base;
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_READ;
        end else if (ce && we) begin
            // a reset command drops back to read from anywhere
            if (din[7:0] == 8'hF0 && state != ST_PROG) begin
                state <= ST_READ;
            end else begin
                case (state)
                    ST_READ:  state <= (hit1 && din[7:0]==8'hAA) ? ST_UL1 : ST_READ;
                    ST_UL1:   state <= (hit2 && din[7:0]==8'h55) ? ST_UL2 : ST_READ;
                    ST_UL2: begin
                        if (hit1) case (din[7:0])
                            8'h90:   state <= ST_AUTO;
                            8'hA0:   state <= ST_PROG;
                            8'h80:   state <= ST_ER1;
                            default: state <= ST_READ;
                        endcase
                        else state <= ST_READ;
                    end
                    ST_PROG: begin
                        // synthesis translate_off
                        // SIM-ONLY: NOR program is a read-modify-write -- it reads the
                        // array combinationally to AND-in 1->0 bits. That async read on
                        // the write port blocks M10K inference; with the erase paths
                        // also guarded, mem has no synthesizable writes, so Quartus
                        // folds the four flash windows to a constant 0xFFFF instead of
                        // ~131k logic registers (which overflow the device). Flash is
                        // therefore READ-ONLY in hardware for now -- gchgchmp never
                        // writes flash; a sync-friendly (M10K, 2-cycle) program path
                        // plus an HPS flash-image load is future work. iverilog ignores
                        // the pragma, so the program/erase unit tests still pass.
                        mem[addr[10:0]] <= mem[addr[10:0]] & din;   // NOR: 1->0 only
                        // synthesis translate_on
                        state <= ST_READ;
                    end
                    ST_ER1:  state <= (hit1 && din[7:0]==8'hAA) ? ST_ER2 : ST_READ;
                    ST_ER2:  state <= (hit2 && din[7:0]==8'h55) ? ST_ERCMD : ST_READ;
                    ST_ERCMD: begin
                        // synthesis translate_off
                        // SIM-ONLY: JEDEC chip/sector erase is a clocked full-array
                        // write (2048 / 512 words set in one edge). Quartus-hostile
                        // (blocks BRAM inference, builds a wide parallel write-decode)
                        // and never issued at BIOS boot -- POST only reads/ID-checks
                        // flash; bulk erase happens during game/data flashing.
                        if (hit1 && din[7:0]==8'h10)                 // chip erase
                            for (i = 0; i < WORDS; i = i + 1) mem[i] <= 16'hFFFF;
                        else if (din[7:0]==8'h30) begin              // sector erase
                            base = (addr[10:0] / SECTOR_WORDS) * SECTOR_WORDS;
                            for (i = 0; i < SECTOR_WORDS; i = i + 1) mem[base+i] <= 16'hFFFF;
                        end
                        // synthesis translate_on
                        state <= ST_READ;
                    end
                    ST_AUTO:  state <= ST_AUTO;   // exits via the F0 reset above
                    default:  state <= ST_READ;
                endcase
            end
        end
    end

    // Array read source: the local BRAM (default) or the parent-supplied word
    // (BACKING_EXTERNAL=1). The command/ID FSM above is identical in both modes.
    wire [15:0] array_word = (BACKING_EXTERNAL != 0) ? ext_rd_data : mem[addr[10:0]];

    // An ID read is a read of MFR (addr 0x00) or DEV (0x01) while in autoselect.
    assign id_read = (ce && state == ST_AUTO && (addr[7:0] == 8'h00 || addr[7:0] == 8'h01));

    // The program data cycle: in ST_PROG, any write strobe is the data write that
    // ANDs `din` into the array word at `addr` (a reset F0 is NOT special here --
    // the FSM above only treats F0 as a reset when state != ST_PROG). One cycle.
    assign prog_now = (ce && we && state == ST_PROG);

    // The erase command cycle: in ST_ERCMD, 0x10 at ADDR1 = chip erase, 0x30 at
    // any address = sector erase. A 0xF0 in ST_ERCMD never reaches here (the FSM
    // treats it as the global reset above), and any other value aborts to ST_READ
    // with no strobe -- both per JEDEC.
    assign erase_chip = (hit1 && din[7:0] == 8'h10);
    assign erase_now  = (ce && we && state == ST_ERCMD &&
                         (erase_chip || din[7:0] == 8'h30));

    always @(*) begin
        if (ce && state == ST_AUTO)
            case (addr[7:0])
                8'h00:   dout = MFR_ID;
                8'h01:   dout = DEV_ID;
                default: dout = array_word;
            endcase
        else if (ce)
            dout = array_word;
        else
            dout = 16'hFFFF;
    end
endmodule
