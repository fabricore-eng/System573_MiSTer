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
// This is a faithful subset of the ATA-4/ATAPI (SFF-8020) standard. READ(10)/
// READ(12) honor the CDB transfer length (N per-sector data phases, then ONE
// completion phase) and can be drained either by PIO data-register reads or by
// the PSX DMA channel 5 (psx_patches/0023) through the dma_* port trio -- the
// Konami BIOS's only sector-read data path is ch5 DMA (mode byte = 2; there is
// no PIO sector fallback in the BIOS).
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
    output wire [10:0] sbuf_addr,   // word index into the buffered sector (prefetch pointer)
    input  wire [15:0] sbuf_q,      // buffered sector word (registered, 1-clk latency)
    input  wire        sec_ready,   // s573_cdimg: the requested sector is buffered + valid

    // ---- PSX DMA channel 5 drain (psx_patches/0023) ----
    // dma_req is the device's DRQ to the DMA engine: high through a disc data-in
    // phase. dma_rd is DMA_ATA_readEna (ce-qualified in dma.vhd): each cycle it is
    // high the DMA consumes ONE 16-bit halfword, which must be valid on dma_dout
    // THAT cycle (low half first, then high -- the SPU ch4 accumulate pattern).
    output wire        dma_req,     // disc data-phase active -> psx atapi_dmaRequest
    input  wire        dma_rd,      // ch5 halfword consume strobe <- DMA_ATA_readEna
    output wire [15:0] dma_dout     // ch5 read data -> DMA_ATA_read
);
    // status bits
    localparam [7:0] ST_BSY=8'h80, ST_DRDY=8'h40, ST_DF=8'h20, ST_DSC=8'h10,
                     ST_DRQ=8'h08, ST_ERR=8'h01;
    // interrupt reason (sector-count) bits: C/D=bit0, I/O=bit1
    localparam [7:0] IR_CD=8'h01, IR_IO=8'h02;

    localparam [2:0] S_IDLE=3'd0, S_PKT=3'd1, S_DATAIN=3'd2, S_DATAOUT=3'd3, S_FETCH=3'd4;

    // Data-ready gating + pacing (clk1x = 33.8688 MHz):
    //  * FETCH_SETTLE covers the sec_req -> s573_cdimg sec_ready-invalidate race (the
    //    reader clears the PREVIOUS sector's sec_ready one clk after our strobe), so
    //    a stale sec_ready can never arm a data phase on the OLD buffer.
    //  * PACE_CLKS is the inter-sector floor: sector N+1's data IRQ waits ~4096 clk1x
    //    after sector N is fully consumed, so the BIOS ISR's per-IRQ remaining-byte
    //    accounting always runs before the next DRQ/INTRQ.
    localparam [12:0] FETCH_SETTLE = 13'd4;
    localparam [12:0] PACE_CLKS    = 13'd4096;

    reg [7:0] r_error, r_feat, r_ireason, r_lbalo, r_bclo, r_bchi, r_device, r_status, r_devctl;
    reg [2:0] state;

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

    // multi-sector READ(10)/READ(12) bookkeeping (transfer length from the CDB)
    reg [15:0] nblk;          // sectors remaining INCLUDING the one in flight
    reg [31:0] cur_lba;       // LBA of the sector in flight
    reg [12:0] fetch_wait;    // S_FETCH settle / pacing down-counter
    reg [1:0]  pf_cnt;        // prefetch prime step
    reg [10:0] pf_addr;       // prefetch word pointer into the sector buffer
    // Prefetch over the 1-clk-latency, FREE-RUNNING sector BRAM (s573_cdimg
    // re-latches sbuf_q = sbuf[sbuf_addr] EVERY clk). dma_word holds the word
    // being served (w[i]). At full back-to-back rate w[i+1] arrives through
    // sbuf_q exactly in time; across an idle gap sbuf_q would be re-latched to
    // w[i+2] and clobber it, so the FIRST idle cycle of a data phase captures
    // w[i+1] into the skid register (classic valid-bit skid buffer).
    reg [15:0] dma_word;      // w[i]: the word currently served (PIO reg0 + dma_dout)
    reg [15:0] pf_skid;       // w[i+1] across idle gaps (valid when skid_valid)
    reg        skid_valid;

    // IDENTIFY PACKET DEVICE (0xA1) data: 256 words. The 573 BIOS drive check
    // only validates the handshake (DRQ set, byte count <= 0x800, ERR clear at
    // end) -- it does not check any identify field -- but the identity now
    // reports the drive the whole 573 library was tested against (Matsushita
    // CR-589): word0 0x85C0 (ATAPI, CD-ROM, removable, 12-byte packet), fw rev
    // words 23-26, model words 27-46 (ATA byte order: 1st char in the HIGH
    // byte), and word49 capabilities bit10 = DMA supported (ch5).
    function [15:0] ident_word(input [12:0] bidx);
        case (bidx[8:1])             // word index 0..255
            8'd0:    ident_word = 16'h85C0;
            8'd23:   ident_word = "1.";        // firmware revision "1.0b    "
            8'd24:   ident_word = "0b";
            8'd25:   ident_word = "  ";
            8'd26:   ident_word = "  ";
            8'd27:   ident_word = "MA";        // model "MATSHITA CR-589"
            8'd28:   ident_word = "TS";
            8'd29:   ident_word = "HI";
            8'd30:   ident_word = "TA";
            8'd31:   ident_word = " C";
            8'd32:   ident_word = "R-";
            8'd33:   ident_word = "58";
            8'd34:   ident_word = "9 ";
            8'd35, 8'd36, 8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd42,
            8'd43, 8'd44, 8'd45, 8'd46:
                     ident_word = "  ";        // model padding to 40 chars
            8'd49:   ident_word = 16'h0400;    // capabilities: DMA supported
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
                8'h12: begin                       // INQUIRY (36 bytes): Matsushita CR-589
                    case (k)
                        6'd0: b=8'h05; 6'd1: b=8'h80; 6'd3: b=8'h21; 6'd4: b=8'h1f;
                        6'd8: b="M"; 6'd9: b="A"; 6'd10:b="T"; 6'd11:b="S";  // vendor
                        6'd12:b="H"; 6'd13:b="I"; 6'd14:b="T"; 6'd15:b="A";  // "MATSHITA"
                        6'd16:b="C"; 6'd17:b="D"; 6'd18:b="-"; 6'd19:b="R";  // product
                        6'd20:b="O"; 6'd21:b="M"; 6'd23:b="C"; 6'd24:b="R";  // "CD-ROM CR-589"
                        6'd25:b="-"; 6'd26:b="5"; 6'd27:b="8"; 6'd28:b="9";
                        6'd32:b="1"; 6'd33:b="."; 6'd34:b="0"; 6'd35:b="b";  // rev "1.0b"
                        default: if ((k==6'd22) || (k>=6'd29 && k<=6'd31)) b=8'h20; // spaces
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
    reg [15:0] rd_len;       // blocking temp: CDB transfer length (sectors)

    // ---- unified data-in consumption (PIO data-register read OR ch5 DMA read) ----
    // Both paths drive the SAME ridx/completion machinery, so PIO remains a working
    // fallback and the DMA drain follows the exact per-sector/completion contract.
    wire pio_data_rd   = sel && re && (addr == 4'd0);
    wire data_consume  = (state == S_DATAIN) && (pio_data_rd || (dma_rd && datain_disc));

    always @(posedge clk) begin
        if (rst || ide_rst) begin
            state <= S_IDLE; pkt_idx <= 0; ridx <= 0; resp_len <= 0;
            irq_pending <= 1'b0; irq_event <= 1'b0; irq_out <= 1'b0;
            r_feat <= 0; r_devctl <= 0;
            datain_disc <= 1'b0; datain_ident <= 1'b0;
            sec_req <= 1'b0; sec_lba <= 32'd0;
            nblk <= 16'd0; cur_lba <= 32'd0;
            fetch_wait <= 13'd0; pf_cnt <= 2'd0; pf_addr <= 11'd0; dma_word <= 16'd0;
            pf_skid <= 16'd0; skid_valid <= 1'b0;
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
                                          // LBA in pkt[2..5] (big-endian). Transfer length from the CDB:
                                          // READ(10) = {pkt[7],pkt[8]}, READ(12) = pkt[6..9] (we honor the
                                          // low 16 bits -- 65535 sectors = 128 MB per command, far beyond
                                          // any BIOS/installer use). N per-sector data phases (byte count
                                          // 0x0800 each, INTRQ per sector) then ONE completion phase.
                                          rd_len = (pkt[0] == 8'hA8) ? {pkt[8], pkt[9]}
                                                                     : {pkt[7], pkt[8]};
                                          if (rd_len == 16'd0) begin
                                              // zero-length read -> immediate good completion (no data phase)
                                              r_status  <= ST_DRDY | ST_DSC;
                                              r_ireason <= IR_CD | IR_IO;
                                              r_error   <= 8'h00;
                                              irq_pending <= 1'b1; irq_event <= 1'b1;
                                              state <= S_IDLE;
                                          end else begin
                                              nblk      <= rd_len;
                                              cur_lba   <= {pkt[2], pkt[3], pkt[4], pkt[5]};
                                              sec_lba   <= {pkt[2], pkt[3], pkt[4], pkt[5]};
                                              sec_req   <= cd_attached;   // only when an image is mounted
                                              disc_base <= {pkt[5][$clog2(NSECT)-1:0], 11'd0};
                                              resp_len  <= 13'd2048;
                                              datain_disc <= 1'b1; datain_ident <= 1'b0;
                                              r_error   <= 8'h00;
                                              if (cd_attached) begin
                                                  // Data-ready gating: the HPS sector fetch is ms-scale, so
                                                  // hold BSY (DRQ clear -- protocol-legal, the BIOS polls
                                                  // with a bounded 0xf690-loop timeout) and assert the data
                                                  // phase only once s573_cdimg signals sec_ready. Firing
                                                  // DRQ+INTRQ at dispatch would let ch5 drain stale BRAM.
                                                  r_status   <= ST_BSY;
                                                  fetch_wait <= FETCH_SETTLE;
                                                  pf_cnt     <= 2'd0;
                                                  state      <= S_FETCH;
                                              end else begin
                                                  // legacy SIM disc[] store: combinational, serve at once
                                                  r_bclo <= 8'h00; r_bchi <= 8'h08; // 0x0800
                                                  ridx <= 0;
                                                  r_status <= ST_DRDY | ST_DRQ;
                                                  r_ireason <= IR_IO;
                                                  irq_pending <= 1'b1; irq_event <= 1'b1;
                                                  state <= S_DATAIN;
                                              end
                                          end
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
                            8'hEF: begin                         // SET FEATURES: accept-and-succeed
                                // The BIOS CD-init (0x803cb9e0) writes 0xEF (set transfer
                                // mode), waits for the IRQ and returns -1 if STATUS bit0
                                // (ERR) is set -- the old ABRT default failed the init.
                                r_status <= ST_DRDY | ST_DSC;
                                r_error  <= 8'h00;
                                irq_pending <= 1'b1; irq_event <= 1'b1;
                                state    <= S_IDLE;
                            end
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
            end

            // skid capture: on the FIRST idle cycle of a disc data phase, sbuf_q
            // still shows w[i+1] (latched at the consume edge); bank it before the
            // free-running BRAM re-latches w[i+2] over it.
            if (state == S_DATAIN && datain_disc && !data_consume && !skid_valid) begin
                pf_skid    <= sbuf_q;
                skid_valid <= 1'b1;
            end

            // ---- data-in consumption (PIO read of reg0 OR a ch5 DMA halfword) ----
            if (data_consume) begin
                // advance the prefetch pipe: w[i+1] comes from the skid register
                // after an idle gap, or straight from the BRAM at full rate.
                dma_word   <= skid_valid ? pf_skid : sbuf_q;
                skid_valid <= 1'b0;
                if (pf_addr != 11'h7FF) pf_addr <= pf_addr + 11'd1;
                if (ridx + 13'd2 >= resp_len) begin              // last word of this phase
                    if (datain_disc && nblk > 16'd1) begin
                        // sector fully consumed, more to go: BSY gap, fetch the next
                        // sector, and pace the next data IRQ (~4096 clk1x floor).
                        nblk      <= nblk - 16'd1;
                        cur_lba   <= cur_lba + 32'd1;
                        sec_lba   <= cur_lba + 32'd1;
                        sec_req   <= cd_attached;
                        disc_base <= disc_base + 13'd2048;       // legacy store advance
                        r_status  <= ST_BSY;
                        fetch_wait <= PACE_CLKS;
                        pf_cnt    <= 2'd0;
                        state     <= S_FETCH;
                    end else begin
                        // ONE completion phase (after the LAST sector / fixed response)
                        r_status  <= ST_DRDY | ST_DSC;
                        r_ireason <= IR_CD | IR_IO;
                        irq_pending <= 1'b1; irq_event <= 1'b1;
                        state <= S_IDLE;
                    end
                end else
                    ridx <= ridx + 13'd2;
            end

            // ---- sector fetch / pacing / prefetch prime (disc reads) ----
            // Hold BSY until the requested sector is REALLY buffered (sec_ready) and
            // the pacing floor has elapsed, then prime the 1-word prefetch register
            // over the 1-clk-latency sector BRAM and raise the per-sector data phase.
            if (state == S_FETCH) begin
                if (fetch_wait != 13'd0)
                    fetch_wait <= fetch_wait - 13'd1;
                else if (!cd_attached || sec_ready) begin
                    case (pf_cnt)
                        2'd0: begin pf_addr <= 11'd0; pf_cnt <= 2'd1; end
                        2'd1: begin pf_addr <= 11'd1; pf_cnt <= 2'd2; end  // BRAM out <- w0
                        2'd2: begin dma_word <= sbuf_q;                    // hold w0
                                    pf_addr <= 11'd2; pf_cnt <= 2'd3; end  // BRAM out <- w1
                        2'd3: begin
                            pf_skid    <= sbuf_q;                          // bank w1
                            skid_valid <= 1'b1;                            // (BRAM runs on to w2)
                            // per-sector data phase: bc=0x0800, ireason=IO,
                            // status=DRDY|DRQ, INTRQ
                            r_bclo <= 8'h00; r_bchi <= 8'h08;
                            r_ireason <= IR_IO;
                            r_status  <= ST_DRDY | ST_DRQ;
                            ridx <= 13'd0;
                            irq_pending <= 1'b1; irq_event <= 1'b1;
                            state <= S_DATAIN;
                        end
                    endcase
                end
            end
        end
    end

    // disc data-in word. Two sources:
    //  * cd_attached=1 (HW / CD-image sim): the EXTERNAL sector buffer in s573_cdimg.
    //    sbuf_q is registered (1-clk latency), so the data-phase word is served from
    //    the 1-word prefetch register dma_word (primed in S_FETCH, refilled on every
    //    consume) -- a back-to-back ce-rate ch5 DMA drain then always sees settled
    //    data, and the prefetch freezes whenever nothing consumes. sbuf_addr is the
    //    prefetch pointer (one word AHEAD of the word behind dma_word).
    //  * cd_attached=0 (legacy unit sim): the SIM-only disc[] store (asynchronous
    //    read, translate_off'd so synthesis does not infer ~64 Kbit of LUT RAM).
    assign sbuf_addr = pf_addr;
    reg [15:0] disc_dout;
    always @(*) begin
        disc_dout = 16'h0000;
        // synthesis translate_off
        disc_dout = {disc[disc_base + ridx + 13'd1], disc[disc_base + ridx]};
        // synthesis translate_on
    end

    // ch5 DMA drain (psx_patches/0023): dma_req is the device's data-phase request
    // line (level through a disc data-in phase; the BIOS's CHCR bit28 arm is the
    // real trigger, this is the sync1/request-form insurance). dma_dout must be
    // valid on the SAME cycle dma_rd is high: the prefetch register guarantees it.
    assign dma_req  = (state == S_DATAIN) && datain_disc && cd_attached;
    assign dma_dout = cd_attached ? dma_word : disc_dout;

    // read mux
    always @(*) begin
        case (addr)
            4'd0:    dout = (state != S_DATAIN) ? 16'h0000 :
                            datain_ident ? ident_word(ridx) :
                            datain_disc  ? (cd_attached ? dma_word : disc_dout)
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
