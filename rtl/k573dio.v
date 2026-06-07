// -----------------------------------------------------------------------------
// k573dio.v - Konami System 573 BEMANI "Digital I/O" board register block
//             (GX894, mapped at 0x1f640000)
//
// The Digital I/O board adds, around an Altera FPGA: lamp/light outputs, an
// MP3 streaming path (MAS3507D decoder fed from board DRAM, with a three-word
// descrambler key), the board's own DS2401 serial number, and a small network
// link. This module implements the *deterministic register glue* of that board
// and instantiates the board DS2401; the FPGA-internal MP3 decoder, MAS3507D
// I2C and network engine are left as clearly-marked stubs for now.
//
// Register map (16-bit, byte offsets within the 0x1f640000 window), from MAME's
// src/mame/konami/k573dio.cpp:
//
//   0x00 r =0x0000  0x02 r =0x0001  0x04/06/0a r =0x0000   0x80 r =0x1234 (id)
//   0xa0..a7 r/w  MP3 start/end address (32-bit, hi/lo)
//   0xa8 w  crypto key1 (r = MP3 frame counter, FPGA - stub)
//   0xaa r  MPEG control (FPGA - stub)      0xac r/w MAS3507D I2C (stub)
//   0xae r/w FPGA control latch
//   0xb0/b2 w  DRAM write address hi/lo     0xb4 r/w DRAM data (auto-increment)
//   0xb6/b8 w  DRAM read  address hi/lo
//   0xc0..c5 network (stub)                 0xca/cc/ce MP3 counters (stub)
//   0xe0/e2/e4/e6/fa/fc/fe w  lamp outputs (registers 1,0,3,7,4,5,2)
//   0xea w crypto key2   0xec w crypto key3
//   0xee r/w  board DS2401 (1-wire on bit 12)
//   0xf6 r =0xB000 FPGA status    0xf8 w FPGA firmware (stub)
//   0x90 w network id    0x10 w unknown
//
// Each lamp register takes bits [15:12] as a 4-bit value and fans it out to four
// lamp lines with the fixed bit remap {0,2,3,1} (see output() in MAME).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module k573dio #(
    parameter integer RAM_WORDS  = 4096,                 // sim-sized DRAM window
    parameter [47:0]  DS_SERIAL  = 48'h0000_0000_0001,   // board DS2401 serial
    parameter integer DS_CLK_HZ  = 1_000_000,
    parameter [0:0]   DDRSBM     = 1'b0                   // MP3 descramble scheme
)(
    input  wire        clk,
    input  wire        rst,

    // bus side (offset within the 0x1f640000 window, as decoded by s573_bus)
    input  wire        sel,
    input  wire [7:0]  off,
    input  wire        we,
    input  wire        re,
    input  wire [15:0] din,
    output reg  [15:0] dout,

    // board outputs
    output reg  [31:0] lamp,         // 32 lamp/light lines
    output reg  [15:0] crypto_key1,  // MP3 descrambler keys (to the FPGA path)
    output reg  [15:0] crypto_key2,
    output reg  [15:0] crypto_key3,
    output reg  [31:0] mp3_start,    // MP3 data window in board DRAM
    output reg  [31:0] mp3_end,
    output reg  [15:0] fpga_ctrl,
    output reg  [15:0] network_id,

    // descrambled MP3 byte stream out to the MAS3507D decoder
    output wire [7:0]  mp3_out_byte,
    output wire        mp3_out_valid
);
    // ----- board DS2401 (1-wire), driven through register 0xee bit 12 -----
    reg         ow_master_low;
    wire        ow_pd;
    wire        ow_line = ~(ow_master_low | ow_pd);  // wired-AND, pulled up
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) board_id (
        .clk(clk), .rst(rst), .dq_in(ow_line), .dq_pd(ow_pd),
        // The DIO board's DS2401 keeps its compile-time SERIAL param (no image load).
        .load_we(1'b0), .load_addr(3'd0), .load_data(8'd0)
    );

    // ----- board DRAM (sim-sized) with separate read/write pointers -----
    reg [15:0] ram [0:RAM_WORDS-1];
    reg [24:0] ram_adr;        // write pointer
    reg [24:0] ram_read_adr;   // read pointer
    wire [24:0] widx = (ram_adr      >> 1) & (RAM_WORDS-1);
    wire [24:0] ridx = (ram_read_adr >> 1) & (RAM_WORDS-1);

    // ----- MP3 streaming: read DRAM, descramble, emit bytes to the MAS3507D -----
    wire [24:0] s_rd_addr;
    wire [15:0] s_rd_data = ram[(s_rd_addr >> 1) & (RAM_WORDS-1)];
    wire [15:0] fpga_ctrl_rb;
    k573_mp3stream u_stream (
        .clk(clk), .rst(rst),
        .fpga_ctrl(fpga_ctrl), .ddrsbm(DDRSBM),
        .mp3_start(mp3_start[24:0]), .mp3_end(mp3_end[24:0]),
        .key1(crypto_key1), .key2(crypto_key2), .key3(crypto_key3),
        .rd_addr(s_rd_addr), .rd_data(s_rd_data),
        .out_byte(mp3_out_byte), .out_valid(mp3_out_valid),
        .byte_counter(), .fpga_ctrl_rb(fpga_ctrl_rb)
    );

    // fan a lamp register's high nibble out to four lamp lines (remap {0,2,3,1})
    task set_lamp(input [2:0] offs, input [15:0] d);
        begin
            lamp[{offs,2'd0}]        <= d[12];          // 4*offs + 0  <- bit 0
            lamp[{offs,2'd0} + 3'd1] <= d[14];          // 4*offs + 1  <- bit 2
            lamp[{offs,2'd0} + 3'd2] <= d[15];          // 4*offs + 2  <- bit 3
            lamp[{offs,2'd0} + 3'd3] <= d[13];          // 4*offs + 3  <- bit 1
        end
    endtask

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            lamp <= 32'd0; crypto_key1 <= 16'd0; crypto_key2 <= 16'd0;
            crypto_key3 <= 16'd0; mp3_start <= 32'd0; mp3_end <= 32'd0;
            fpga_ctrl <= 16'd0; network_id <= 16'd0;
            ram_adr <= 25'd0; ram_read_adr <= 25'd0; ow_master_low <= 1'b0;
        end else begin
            if (sel && we) begin
                case (off)
                    8'h90: network_id      <= din;
                    8'ha0: mp3_start[31:16] <= din;
                    8'ha2: mp3_start[15:0]  <= din;
                    8'ha4: mp3_end[31:16]   <= din;
                    8'ha6: mp3_end[15:0]    <= din;
                    8'ha8: crypto_key1      <= din;
                    8'hae: fpga_ctrl        <= din;
                    8'hb0: ram_adr          <= {din[8:0], ram_adr[15:0]};
                    8'hb2: ram_adr          <= {ram_adr[24:16], din};
                    8'hb4: begin ram[widx] <= din; ram_adr <= ram_adr + 25'd2; end
                    8'hb6: ram_read_adr     <= {din[8:0], ram_read_adr[15:0]};
                    8'hb8: ram_read_adr     <= {ram_read_adr[24:16], din};
                    8'he0: set_lamp(3'd1, din);
                    8'he2: set_lamp(3'd0, din);
                    8'he4: set_lamp(3'd3, din);
                    8'he6: set_lamp(3'd7, din);
                    8'hea: crypto_key2      <= din;
                    8'hec: crypto_key3      <= din;
                    8'hee: ow_master_low    <= din[12];
                    8'hfa: set_lamp(3'd4, din);
                    8'hfc: set_lamp(3'd5, din);
                    8'hfe: set_lamp(3'd2, din);
                    default: ; // 0x10, 0xac, 0xcc, 0xf8, network: stub/unhandled
                endcase
            end
            // DRAM data read auto-increments the read pointer
            if (sel && re && off == 8'hb4)
                ram_read_adr <= ram_read_adr + 25'd2;
        end
    end

    // read mux (combinational)
    always @(*) begin
        case (off)
            8'h02:   dout = 16'h0001;
            8'h80:   dout = 16'h1234;        // board id
            8'ha0:   dout = mp3_start[31:16];
            8'ha2:   dout = mp3_start[15:0];
            8'ha4:   dout = mp3_end[31:16];
            8'ha6:   dout = mp3_end[15:0];
            8'hae:   dout = fpga_ctrl_rb;    // get_fpga_ctrl: streaming status (bit 12)
            8'hb4:   dout = ram[ridx];
            8'hee:   dout = {3'b000, ow_line, 12'b0};
            8'hf6:   dout = 16'hB000;        // FPGA status (0x8000|0x2000|0x1000)
            default: dout = 16'h0000;        // 0x00/04/06/0a + FPGA/MAS/net stubs
        endcase
    end
endmodule
