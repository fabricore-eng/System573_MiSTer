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
    parameter [15:0]  MFR_ID       = 16'h0004,   // Fujitsu
    parameter [15:0]  DEV_ID       = 16'h00AD,   // MBM29F016
    parameter [10:0]  ADDR1        = 11'h555,
    parameter [10:0]  ADDR2        = 11'h2AA,
    // BACKING_EXTERNAL=0 (default): the array lives in the local mem[] BRAM and is
    //   read/programmed/erased here, exactly as before -- the iverilog unit tests
    //   exercise this path unchanged.
    // BACKING_EXTERNAL=1: the command/ID FSM is identical, but the ARRAY itself
    //   lives outside this module (the s573_flash 16 MB SDRAM-backed line buffer).
    //   In that mode array reads return `ext_rd_data` (the parent's word for the
    //   current `addr`) and program/erase are dropped (real flash is read-only in
    //   HW for now). The autoselect MFR/DEV ID path is unaffected so POST still
    //   passes the flash-ID check.
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
    output wire        id_read
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
