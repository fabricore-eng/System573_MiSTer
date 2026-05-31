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

    output wire        intrq        // interrupt request (IRQ10 on the 573)
);
    // status bits
    localparam [7:0] ST_BSY=8'h80, ST_DRDY=8'h40, ST_DF=8'h20, ST_DSC=8'h10,
                     ST_DRQ=8'h08, ST_ERR=8'h01;
    // interrupt reason (sector-count) bits: C/D=bit0, I/O=bit1
    localparam [7:0] IR_CD=8'h01, IR_IO=8'h02;

    localparam [1:0] S_IDLE=2'd0, S_PKT=2'd1, S_DATAIN=2'd2;

    reg [7:0] r_error, r_feat, r_ireason, r_lbalo, r_bclo, r_bchi, r_device, r_status, r_devctl;
    reg [1:0] state;

    reg [7:0]  pkt  [0:11];
    reg [7:0]  resp [0:63];
    reg [6:0]  pkt_idx;       // bytes received (0..12)
    reg [12:0] ridx;          // data-in byte index
    reg [12:0] resp_len;
    reg        irq_pending;
    reg        datain_disc;   // data-in source: 1 = disc store, 0 = resp[]
    reg [12:0] disc_base;     // byte base into the disc store for READ commands

    // small disc backing store (sim) with a deterministic per-byte pattern
    reg [7:0]  disc [0:NSECT*2048-1];
    integer    s;
    initial for (s = 0; s < NSECT*2048; s = s + 1) disc[s] = s[7:0];

    assign intrq = irq_pending & ~r_devctl[1];   // nIEN = device control bit1

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
            irq_pending <= 1'b0; r_feat <= 0; r_devctl <= 0; datain_disc <= 1'b0;
            set_signature;
        end else begin
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
                                          irq_pending <= 1'b1;
                                          state <= S_IDLE;
                                      end
                                      8'h12: begin              // INQUIRY (data-in)
                                          resp[0]<=8'h05; resp[1]<=8'h80; resp[2]<=8'h00;
                                          resp[3]<=8'h21; resp[4]<=8'h1f; resp[5]<=8'h00;
                                          resp[6]<=8'h00; resp[7]<=8'h00;
                                          resp[8]<=8'h4b;  resp[9]<=8'h4f;  resp[10]<=8'h4e; // "KON"
                                          resp[11]<=8'h41; resp[12]<=8'h4d; resp[13]<=8'h49; // "AMI"
                                          resp[14]<=8'h20; resp[15]<=8'h20;
                                          for (i=16;i<32;i=i+1) resp[i]<=8'h20;             // product
                                          resp[16]<=8'h35; resp[17]<=8'h37; resp[18]<=8'h33;// "573"
                                          resp[32]<=8'h31; resp[33]<=8'h2e;                 // "1."
                                          resp[34]<=8'h30; resp[35]<=8'h30;                 // "00"
                                          n = 7'd36;
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ;
                                          r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; state <= S_DATAIN;
                                      end
                                      8'h25: begin              // READ CAPACITY (data-in)
                                          resp[0]<=8'h00; resp[1]<=8'h01; resp[2]<=8'h23; resp[3]<=8'h44;
                                          resp[4]<=8'h00; resp[5]<=8'h00; resp[6]<=8'h08; resp[7]<=8'h00;
                                          n = 7'd8;
                                          resp_len <= n; r_bclo <= {1'b0, n}; r_bchi <= 8'h00;
                                          ridx <= 0; datain_disc <= 1'b0;
                                          r_status <= ST_DRDY | ST_DRQ;
                                          r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; state <= S_DATAIN;
                                      end
                                      8'h28, 8'hA8: begin       // READ(10) / READ(12) (disc data-in)
                                          // LBA in pkt[2..5] (big-endian); one
                                          // 2048-byte sector streamed per request.
                                          disc_base <= {pkt[5][$clog2(NSECT)-1:0], 11'd0};
                                          resp_len  <= 13'd2048;
                                          r_bclo <= 8'h00; r_bchi <= 8'h08; // 0x0800
                                          ridx <= 0; datain_disc <= 1'b1;
                                          r_status <= ST_DRDY | ST_DRQ;
                                          r_ireason <= IR_IO; r_error <= 8'h00;
                                          irq_pending <= 1'b1; state <= S_DATAIN;
                                      end
                                      default: begin            // unsupported -> CHECK CONDITION
                                          r_status  <= ST_DRDY | ST_ERR;
                                          r_error   <= 8'h50;   // sense key 5 (illegal request)
                                          r_ireason <= IR_CD | IR_IO;
                                          irq_pending <= 1'b1;
                                          state <= S_IDLE;
                                      end
                                  endcase
                              end
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
                            8'h08: begin set_signature; state <= S_IDLE; end  // DEVICE RESET
                            default: begin                       // unsupported command
                                r_status <= ST_DRDY | ST_ERR;
                                r_error  <= 8'h04;               // ABRT
                                irq_pending <= 1'b1;
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
                        irq_pending <= 1'b1;
                        state <= S_IDLE;
                    end else
                        ridx <= ridx + 13'd2;
                end
            end
        end
    end

    // read mux
    always @(*) begin
        case (addr)
            4'd0:    dout = (state != S_DATAIN) ? 16'h0000 :
                            datain_disc ? {disc[disc_base + ridx + 13'd1], disc[disc_base + ridx]}
                                        : {resp[ridx[5:0] + 6'd1], resp[ridx[5:0]]};
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
