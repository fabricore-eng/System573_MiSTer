// -----------------------------------------------------------------------------
// atapi.v - ATA/ATAPI task-file + PACKET command handshake (System 573 CD-ROM)
//
// The System 573 boots game data from an ATAPI CD-ROM on its IDE bus
// (0x1f480000, IRQ10, DMA channel 5). This module implements the device side of
// the ATA task-file register set and the ATAPI PACKET command protocol: the host
// issues PACKET (0xA0), the device requests a 12-byte SCSI command packet via
// DRQ, then runs either a non-data command (e.g. TEST UNIT READY) or a PIO
// data-in command (e.g. INQUIRY, READ CAPACITY), managing the status, interrupt-
// reason and byte-count registers and asserting INTRQ at phase boundaries.
//
// Register interface (bus mapping handled by s573_bus): addr 0..7 are the command
// block (data, error/features, interrupt-reason/sector-count, LBA/byte-count,
// device, status/command); addr 8 is the control block (alternate status read /
// device control write). Data-register accesses are 16-bit; the rest are 8-bit.
//
// This is a faithful subset of the ATA-4/ATAPI (SFF-8020) standard. The SCSI
// command set is intentionally small (enough to exercise the non-data and
// data-in PACKET paths); a real disc model / READ(10/12) streaming from the
// MiSTer DDR3 backing store is future work (see docs/ROADMAP.md).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module atapi #(
    parameter integer NSECT = 4          // disc sectors backed for simulation
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ide_rst,     // board IDE reset line (0x1f560000)

    input  wire        sel,         // command-block / control select
    input  wire [3:0]  addr,        // 0..7 command block, 8 = control block
    input  wire        we,
    input  wire        re,
    input  wire [15:0] din,
    output reg  [15:0] dout,

    output wire        intrq,       // interrupt request (IRQ10 on the 573)

    // ---- mounted-CD-image sector source (Feature B) ----
    // cd_attached=1 routes READ(10)/READ(12) data-in from the EXTERNAL sector buffer
    // (s573_cdimg, fed from a mounted CD image) instead of the SIM-only disc[] store.
    // sec_req pulses with sec_lba when a READ packet is dispatched; sbuf_q returns the
    // 2048-byte user-data word for sbuf_addr (word index, byte = addr*2 into the sector).
    input  wire        cd_attached, // 1 = external CD image present; 0 = legacy disc[] (sim)
    output reg         sec_req,     // 1-clk strobe: host BIOS asked to read sec_lba
    output reg  [31:0] sec_lba,     // requested raw sector LBA (READ(10/12) big-endian LBA)
    output wire [10:0] sbuf_addr,   // word index into the buffered sector (= ridx/2)
    input  wire [15:0] sbuf_q       // buffered sector word
);
    // status bits
    localparam [7:0] ST_BSY=8'h80, ST_DRDY=8'h40, ST_DF=8'h20, ST_DSC=8'h10,
                     ST_DRQ=8'h08, ST_ERR=8'h01;
    // interrupt reason (sector-count) bits: C/D=bit0, I/O=bit1
    localparam [7:0] IR_CD=8'h01, IR_IO=8'h02;

    localparam [1:0] S_IDLE=2'd0, S_PKT=2'd1, S_DATAIN=2'd2, S_DATAOUT=2'd3;

    reg [7:0] r_error, r_feat, r_ireason, r_lbalo, r_bclo, r_bchi, r_device, r_status, r_devctl;
    reg [1:0] state;

    reg [7:0]  pkt  [0:11];
    reg [7:0]  resp_cmd;      // active fixed data-in response (selects the resp_byte ROM)
    reg [6:0]  pkt_idx;       // bytes received (0..12)
    reg [12:0] ridx;          // data-in byte index
    reg [12:0] resp_len;
    reg        irq_pending;
    reg        irq_event;     // 1-clk strobe: a fresh interrupt event was raised this cycle
    reg        irq_out;       // edge-guaranteed INTRQ level (see assign intrq below)
    reg        datain_disc;   // data-in source: 1 = disc store, 0 = resp[]
    reg        datain_ident;  // data-in source: 1 = generated IDENTIFY block
    reg [12:0] disc_base;     // byte base into the disc store for READ commands

    // IDENTIFY PACKET DEVICE (0xA1) data: 256 words. The 573 BIOS drive check
    // only validates the handshake (DRQ set, byte count <= 0x800, ERR clear at
    // end) -- it does not check any identify field -- so a minimal block with a
    // valid ATAPI general-configuration word (0x85C0 = ATAPI, CD-ROM, removable,
    // 12-byte packet) and zeros elsewhere is sufficient.
    function [15:0] ident_word(input [12:0] bidx);
        case (bidx[8:1])             // word index 0..255
            8'd0:    ident_word = 16'h85C0;
            default: ident_word = 16'h0000;
        endcase
    endfunction

    // Fixed data-in responses as a combinational ROM (was a 64-byte resp[] register
    // array + per-command write muxing -- removing it nets the block SMALLER than the
    // register version while supporting more commands, which is what lets the CDR fix
    // fit). Byte 'k' of the response for command 'cmd'. The drive check validates only
    // the handshake + byte count (not content), except REQUEST SENSE key (resp[2]==0)
    // which is naturally 0 here.
    function [7:0] resp_byte(input [7:0] cmd, input [5:0] k);
        reg [7:0] b;
        begin
            b = 8'h00;
            case (cmd)
                8'h12: begin                       // INQUIRY (36 bytes)
                    case (k)
                        6'd0: b=8'h05; 6'd1: b=8'h80; 6'd3: b=8'h21; 6'd4: b=8'h1f;
                        6'd8: b=8'h4b; 6'd9: b=8'h4f; 6'd10:b=8'h4e;   // "KON"
                        6'd11:b=8'h41; 6'd12:b=8'h4d; 6'd13:b=8'h49;   // "AMI"
                        6'd16:b=8'h35; 6'd17:b=8'h37; 6'd18:b=8'h33;   // "573"
                        6'd32:b=8'h31; 6'd33:b=8'h2e; 6'd34:b=8'h30; 6'd35:b=8'h30; // "1.00"
                        default: if ((k>=6'd14 && k<=6'd15) || (k>=6'd19 && k<=6'd31)) b=8'h20; // spaces
                    endcase
                end
                8'h25: case (k)                    // READ CAPACITY (8 bytes): last-LBA, blklen 2048
                    6'd1:b=8'h01; 6'd2:b=8'h23; 6'd3:b=8'h44; 6'd6:b=8'h08; default:b=8'h00; endcase
                8'h03: case (k)                    // REQUEST SENSE (16/18): resp code 0x70, key 0
                    6'd0:b=8'h70; 6'd7:b=8'h0a; default:b=8'h00; endcase
                8'h43: case (k)                    // READ TOC (12): 1 data track, MSF 0
                    6'd1:b=8'h0a; 6'd2:b=8'h01; 6'd3:b=8'h01; 6'd5:b=8'h14; 6'd6:b=8'h01; default:b=8'h00; endcase
                8'h5A: case (k)                    // MODE SENSE(10) page 0x0E (24)
                    6'd1:b=8'h16; 6'd8:b=8'h0e; 6'd9:b=8'h0e; 6'd10:b=8'h04; 6'd15:b=8'h4b;
                    6'd16:b=8'h01; 6'd17:b=8'hff; 6'd18:b=8'h02; 6'd19:b=8'hff; default:b=8'h00; endcase
                default: b=8'h00;
            endcase
            resp_byte = b;
        end
    endfunction

    // small disc backing store (sim) with a deterministic per-byte pattern
    reg [7:0]  disc [0:NSECT*2048-1];
    integer    s;
    // synthesis translate_off
    // SIM-ONLY disc fill (deterministic per-byte pattern). Not synthesizable: the
    // NSECT*2048 loop exceeds Quartus's 5000-iteration unroll limit, and on real
    // hardware the disc store is DDR3-backed (Phase 7/8), not this array. For the
    // BIOS boot (gchgchmp, no CD) disc[] is never read, so leaving it uninitialized
    // in synthesis is functionally harmless.
    initial for (s = 0; s < NSECT*2048; s = s + 1) disc[s] = s[7:0];
    // synthesis translate_on

    // INTRQ edge guarantee. psx/rtl/irq.vhd latches I_STATUS bit10 on a RISING EDGE of
    // this line (irqIn AND NOT irqIn_1). When two consecutive ATAPI interrupt events
    // (e.g. PIO data-ready then completion) are raised without the host's INTRQ-clear
    // in between, irq_pending stays level-high and the controller MISSES the 2nd event,
    // hanging the BIOS's IRQ-driven IDENTIFY wait (0x803cb4b8). irq_out below forces a
    // fresh 0->1 per event: whenever irq_event pulses while irq_out is already high, it
    // is dropped for exactly one clk so the next assert is a clean rising edge.
    assign intrq = irq_out & ~r_devctl[1];       // nIEN = device control bit1

    // load the ATAPI device signature into the task-file
    task set_signature;
        begin
            r_ireason <= 8'h01; r_lbalo <= 8'h01;
            r_bclo <= 8'h14; r_bchi <= 8'hEB;    // 0xEB14 ATAPI signature
            r_device <= 8'h00; r_status <= 8'h00; r_error <= 8'h01;
        end
    endtask

    integer i;
    reg [6:0] n;

    always @(posedge clk) begin
        if (rst || ide_rst) begin
            state <= S_IDLE; pkt_idx <= 0; ridx <= 0; resp_len <= 0;
            irq_pending <= 1'b0; irq_event <= 1'b0; irq_out <= 1'b0;
            r_feat <= 0; r_devctl <= 0;
            datain_disc <= 1'b0; datain_ident <= 1'b0;
            sec_req <= 1'b0; sec_lba <= 32'd0;
            set_signature;
        end else begin
            irq_event <= 1'b0;                           // default; set by the 13 event sites
            sec_req   <= 1'b0;                           // default; pulsed on READ dispatch

            // Edge-guaranteed INTRQ. irq_out tracks irq_pending, except a fresh event
            // (irq_event) raised while irq_out is ALREADY high forces one low clk first
            // so psx irq.vhd sees a clean 0->1 for every event (data-ready, completion,
            // ...). The host's INTRQ-clear (reg7 read/command write -> irq_pending=0)
            // still deasserts it normally.
            if (!irq_pending)
                irq_out <= 1'b0;                         // host cleared -> deassert
            else if (irq_event && irq_out)
                irq_out <= 1'b0;                         // re-arm collision -> 1-clk gap
            else
                irq_out <= 1'b1;                         // assert / hold

            if (sel && we) begin
                case (addr)
                    4'd0: if (state == S_PKT) begin           // packet bytes (16-bit)
                              pkt[pkt_idx]   <= din[7:0];
                              pkt[pkt_idx+1] <= din[15:8];
                              pkt_idx <= pkt_idx + 7'd2;
                              if (pkt_idx == 7'd10) begin
                                  // ===== full 12-byte packet received: dispatch =====
                                  pkt_idx <= 0;
                                  case (pkt[0])
                                      8'h00: begin              // TEST UNIT READY (non-data)
                                          r_status  <= ST_DRDY | ST_DSC;
                                          r_ireason <= IR_CD | IR_IO;
                                          r_error   <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1;
                                          state <= S_IDLE;
                                      end
                                      // Fixed data-in commands: select the resp_byte ROM + set the
                                      // exact byte count the BIOS latches/checks. (Bytes live in the
                                      // resp_byte() combinational ROM, not a register array.)
                                      8'h12: begin n = 7'd36; resp_cmd <= 8'h12;        // INQUIRY
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ; r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN; end
                                      8'h25: begin n = 7'd8;  resp_cmd <= 8'h25;        // READ CAPACITY
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ; r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN; end
                                      8'h03: begin n = 7'd16; resp_cmd <= 8'h03;        // REQUEST SENSE (key 0 = ready)
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00; // BIOS checks bc==0x10 @0x803cbc0c
                                          ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ; r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN; end
                                      8'h43: begin n = 7'd12; resp_cmd <= 8'h43;        // READ TOC (bc==12 @0x803cbe04)
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ; r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN; end
                                      8'h5A: begin n = 7'd24; resp_cmd <= 8'h5A;        // MODE SENSE(10) (bc==0x18)
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ; r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN; end
                                      8'h28, 8'hA8: begin       // READ(10) / READ(12) (disc data-in)
                                          // LBA in pkt[2..5] (big-endian); one 2048-byte sector per request.
                                          // Feature B: capture the full 32-bit LBA and pulse sec_req so the
                                          // external CD-image reader (s573_cdimg) fetches THIS sector. The
                                          // disc_base index (low bits) still drives the legacy sim disc[]
                                          // store when no CD image is attached.
                                          sec_lba   <= {pkt[2], pkt[3], pkt[4], pkt[5]};
                                          sec_req   <= cd_attached;   // only when an image is mounted
                                          disc_base <= {pkt[5][$clog2(NSECT)-1:0], 11'd0};
                                          resp_len  <= 13'd2048;
                                          r_bclo <= 8'h00; r_bchi <= 8'h08; // 0x0800
                                          ridx <= 0; datain_disc <= 1'b1; datain_ident <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ;
                                          r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN;
                                      end
                                      8'h55: begin              // MODE SELECT(10) (data-OUT) -- accept + discard
                                          // Off the live drive-check path (insurance/faithfulness). Request
                                          // the 24-byte param list (BIOS checks byte-count==0x18 @0x803cc1a8),
                                          // accept the host word-writes, validate nothing.
                                          n = 7'd24;
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0;
                                          r_status <= ST_DRDY | ST_DRQ;
                                          r_ireason <= 8'h00;   // C/D=0, I/O=0 -> data-OUT phase
                                          r_error <= 8'h00;
                                          irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAOUT;
                                      end
                                      default: begin            // unsupported -> CHECK CONDITION
                                          r_status  <= ST_DRDY | ST_ERR;
                                          r_error   <= 8'h50;   // sense key 5 (illegal request)
                                          r_ireason <= IR_CD | IR_IO;
                                          irq_pending <= 1'b1; irq_event <= 1'b1;
                                          state <= S_IDLE;
                                      end
                                  endcase
                              end
                          end else if (state == S_DATAOUT) begin
                              // MODE SELECT data-OUT: accept + discard the host's param-list words
                              if (ridx + 13'd2 >= resp_len) begin   // last word -> complete
                                  r_status  <= ST_DRDY | ST_DSC;
                                  r_ireason <= IR_CD | IR_IO;
                                  r_error   <= 8'h00;
                                  irq_pending <= 1'b1; irq_event <= 1'b1;
                                  state <= S_IDLE;
                              end else
                                  ridx <= ridx + 13'd2;
                          end
                    4'd1: r_feat    <= din[7:0];
                    4'd2: r_ireason <= din[7:0];
                    4'd3: r_lbalo   <= din[7:0];
                    4'd4: r_bclo    <= din[7:0];
                    4'd5: r_bchi    <= din[7:0];
                    4'd6: r_device  <= din[7:0];
                    4'd7: begin                                  // command register
                        irq_pending <= 1'b0;
                        case (din[7:0])
                            8'hA0: begin                         // PACKET
                                r_status  <= ST_DRQ;             // request the packet
                                r_ireason <= IR_CD;              // command, to device
                                pkt_idx   <= 0;
                                state     <= S_PKT;
                            end
                            8'hA1: begin                         // IDENTIFY PACKET DEVICE (data-in, 512 bytes)
                                resp_len  <= 13'd512;
                                r_bclo <= 8'h00; r_bchi <= 8'h02; // byte count 0x0200
                                ridx <= 0; datain_disc <= 1'b0; datain_ident <= 1'b1;
                                r_status  <= ST_DRDY | ST_DRQ;
                                r_ireason <= IR_IO; r_error <= 8'h00;
                                irq_pending <= 1'b1; irq_event <= 1'b1; state <= S_DATAIN;
                            end
                            8'h08: begin set_signature; state <= S_IDLE; end  // DEVICE RESET
                            default: begin                       // unsupported command
                                r_status <= ST_DRDY | ST_ERR;
                                r_error  <= 8'h04;               // ABRT
                                irq_pending <= 1'b1; irq_event <= 1'b1;
                                state    <= S_IDLE;
                            end
                        endcase
                    end
                    4'd8: begin                                  // device control
                        if (r_devctl[2] && !din[2]) set_signature; // SRST 1->0
                        r_devctl <= din[7:0];
                    end
                    default: ;
                endcase
            end

            // reads with side effects
            if (sel && re) begin
                if (addr == 4'd7)                                // status read clears INTRQ
                    irq_pending <= 1'b0;
                if (addr == 4'd0 && state == S_DATAIN) begin     // data-in transfer
                    if (ridx + 13'd2 >= resp_len) begin          // last word -> complete
                        r_status  <= ST_DRDY | ST_DSC;
                        r_ireason <= IR_CD | IR_IO;
                        irq_pending <= 1'b1; irq_event <= 1'b1;
                        state <= S_IDLE;
                    end else
                        ridx <= ridx + 13'd2;
                end
            end
        end
    end

    // disc data-in word. Two sources:
    //  * cd_attached=1 (HW / CD-image sim): the EXTERNAL sector buffer sbuf_q (block
    //    RAM in s573_cdimg, fed from the mounted CD image). sbuf_addr is the word index
    //    ridx/2; the buffer holds the 2048 user bytes of the requested sector at word 0.
    //    sbuf_q is registered (1-clk), which is fine here -- the PIO host first polls
    //    STATUS for several cycles after dispatch, and reads successive words many clocks
    //    apart, so the addressed word is always settled before the host samples reg0.
    //  * cd_attached=0 (legacy unit sim): the SIM-only disc[] store (asynchronous read,
    //    translate_off'd so synthesis does not infer ~64 Kbit of LUT RAM).
    assign sbuf_addr = ridx[12:1];
    reg [15:0] disc_dout;
    always @(*) begin
        disc_dout = 16'h0000;
        // synthesis translate_off
        disc_dout = {disc[disc_base + ridx + 13'd1], disc[disc_base + ridx]};
        // synthesis translate_on
    end

    // read mux
    always @(*) begin
        case (addr)
            4'd0:    dout = (state != S_DATAIN) ? 16'h0000 :
                            datain_ident ? ident_word(ridx) :
                            datain_disc  ? (cd_attached ? sbuf_q : disc_dout)
                                         : {resp_byte(resp_cmd, ridx[5:0] + 6'd1),
                                            resp_byte(resp_cmd, ridx[5:0])};
            4'd1:    dout = {8'h00, r_error};
            4'd2:    dout = {8'h00, r_ireason};
            4'd3:    dout = {8'h00, r_lbalo};
            4'd4:    dout = {8'h00, r_bclo};
            4'd5:    dout = {8'h00, r_bchi};
            4'd6:    dout = {8'h00, r_device};
            4'd7:    dout = {8'h00, r_status};
            4'd8:    dout = {8'h00, r_status};   // alternate status (no INTRQ clear)
            default: dout = 16'h0000;
        endcase
    end
endmodule
