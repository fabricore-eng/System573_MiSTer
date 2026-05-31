// -----------------------------------------------------------------------------
// k573_mp3stream.v - BEMANI Digital I/O board MP3 streaming controller
//
// The Digital I/O FPGA streams the (scrambled) MP3 bitstream out of board DRAM,
// descrambles it word-by-word with k573_mp3dec, and feeds the bytes to the
// MAS3507D decoder. This module is that streaming engine, faithful to the
// update_stream / get_fpga_ctrl logic in MAME's src/mame/konami/k573fpga.cpp:
//
//   * streaming runs while the FPGA control register has both MP3_ENABLE (bit13)
//     and STREAMING_ENABLE (bit14) set and the current address is within
//     [mp3_start, mp3_end);
//   * each step reads one 16-bit word from DRAM, descrambles it (default or DDR
//     SBM scheme), byte-swaps it, and emits the two bytes high-then-low to the
//     decoder, advancing the address by 2;
//   * get_fpga_ctrl reads back 0x1000 while actively streaming.
//
// The descrambler key schedule is seeded from the key latches at stream start.
// A byte counter is provided as a streamed-data position proxy; the real MP3
// sample/frame counter in hardware is derived from the decoder's frame-sync and
// is not modeled here (it needs actual MP3 decoding).
//
// The DRAM read port is a simple combinational read (rd_data valid for rd_addr).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module k573_mp3stream (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] fpga_ctrl,     // FPGA control register (bits 13/14)
    input  wire        ddrsbm,        // 0 = default scheme, 1 = DDR SBM
    input  wire [24:0] mp3_start,     // byte address in DRAM (word-aligned)
    input  wire [24:0] mp3_end,
    input  wire [15:0] key1,          // descrambler key seed
    input  wire [15:0] key2,
    input  wire [15:0] key3,

    // board DRAM read port (combinational)
    output reg  [24:0] rd_addr,
    input  wire [15:0] rd_data,

    // byte stream to the MAS3507D
    output reg  [7:0]  out_byte,
    output reg         out_valid,
    output reg  [31:0] byte_counter,

    output wire [15:0] fpga_ctrl_rb    // get_fpga_ctrl read-back
);
    localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_ADDR=3'd2, S_STB=3'd3,
                     S_CAP=3'd4, S_HI=3'd5, S_LO=3'd6;

    wire stream_en = fpga_ctrl[13] & fpga_ctrl[14];   // MP3_ENABLE & STREAMING_ENABLE

    reg [2:0]  state;
    reg [24:0] cur;
    reg        prev_en;
    reg [15:0] dw;

    // descrambler control (combinational on state). word_stb in S_STB ->
    // dec_dout valid in S_CAP, where it is latched into dw before emitting.
    wire        loadk = (state == S_LOAD);
    wire        wstb  = (state == S_STB);
    wire [15:0] dec_dout;
    k573_mp3dec u_dec (
        .clk(clk), .rst(rst),
        .load_keys(loadk), .key1_in(key1), .key2_in(key2), .key3_in(key3),
        .ddrsbm(ddrsbm), .word_stb(wstb), .din(rd_data), .dout(dec_dout),
        .key1(), .key2(), .key3()
    );

    // streaming while enabled and within the window (MAME get_fpga_ctrl, bit 14)
    assign fpga_ctrl_rb =
        (fpga_ctrl[14] && cur >= mp3_start && cur < mp3_end) ? 16'h1000 : 16'h0000;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; cur <= 25'd0; prev_en <= 1'b0;
            out_valid <= 1'b0; out_byte <= 8'd0; byte_counter <= 32'd0;
            rd_addr <= 25'd0;
        end else begin
            out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (stream_en && !prev_en) begin     // stream start
                        cur <= mp3_start;
                        byte_counter <= 32'd0;
                        state <= S_LOAD;                 // S_LOAD seeds the keys
                    end
                end
                S_LOAD: state <= S_ADDR;
                S_ADDR: begin
                    if (stream_en && cur < mp3_end) begin
                        rd_addr <= cur;                  // rd_data valid next cycle
                        state   <= S_STB;
                    end else
                        state <= S_IDLE;                 // window done / disabled
                end
                S_STB:  state <= S_CAP;                  // word_stb asserted (comb)
                S_CAP: begin
                    dw    <= dec_dout;                   // descrambled word now valid
                    state <= S_HI;
                end
                S_HI: begin
                    out_byte  <= dw[15:8];               // high byte first (byte-swap)
                    out_valid <= 1'b1;
                    byte_counter <= byte_counter + 32'd1;
                    state <= S_LO;
                end
                S_LO: begin
                    out_byte  <= dw[7:0];
                    out_valid <= 1'b1;
                    byte_counter <= byte_counter + 32'd1;
                    cur   <= cur + 25'd2;
                    state <= S_ADDR;
                end
                default: state <= S_IDLE;
            endcase

            // a disable mid-stream stops cleanly
            if (!stream_en && state != S_IDLE) state <= S_IDLE;

            prev_en <= stream_en;
        end
    end
endmodule
