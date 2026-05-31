// -----------------------------------------------------------------------------
// k573_mp3dec.v - BEMANI Digital I/O board MP3 audio descrambler datapath
//
// The Digital I/O board's FPGA descrambles the (Konami-scrambled) MP3 bitstream
// word-by-word as it streams out of board DRAM toward the MAS3507D decoder,
// using the three key words latched at 0x1f640000+0xa8/0xea/0xec. Two schemes
// exist: the common one (decrypt_default) and the DDR Solo Bass Mix variant
// (decrypt_ddrsbm). This module implements both as a per-word transform with the
// running key schedule, faithful to MAME's src/mame/konami/k573fpga.cpp.
//
//   decrypt_common(d,k): for each adjacent bit pair (2i,2i+1), swap the two bits
//     iff key bit (2i+1) is set, then XOR with (k & 0x5555).
//   decrypt_default(d):  derive a key from a fixed bitswap of (key1^key2), run
//     decrypt_common, XOR an 8->16 spread of key3, then advance the schedule:
//     key2 rotates left when key1[15]^key1[14], key1 rotates left within [14:0]
//     (bit15 fixed), key3 increments.
//   decrypt_ddrsbm(d):   decrypt_common(d,key1); key1 rotates left by 1.
//
// One input word is consumed per `word_stb`; `dout` is the descrambled word and
// the key registers hold the advanced schedule. `load_keys` (re)seeds key1/2/3
// from the board key latches before a stream starts.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module k573_mp3dec (
    input  wire        clk,
    input  wire        rst,

    input  wire        load_keys,         // seed key1/2/3 from the board latches
    input  wire [15:0] key1_in,
    input  wire [15:0] key2_in,
    input  wire [15:0] key3_in,
    input  wire        ddrsbm,            // 0 = default scheme, 1 = DDR SBM

    input  wire        word_stb,          // process one scrambled word
    input  wire [15:0] din,
    output reg  [15:0] dout,              // descrambled word

    output reg  [15:0] key1,              // live key schedule (for visibility)
    output reg  [15:0] key2,
    output reg  [15:0] key3
);
    // swap each adjacent bit pair iff the odd key bit is set, then XOR even bits
    function [15:0] dec_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d;
        begin
            d = 16'd0;
            for (i = 0; i < 8; i = i + 1) begin
                if (key[2*i+1]) begin
                    d[2*i]   = data[2*i+1];
                    d[2*i+1] = data[2*i];
                end else begin
                    d[2*i]   = data[2*i];
                    d[2*i+1] = data[2*i+1];
                end
            end
            dec_common = d ^ (key & 16'h5555);
        end
    endfunction

    // derived key = bitswap of (key1^key2): swap bit pairs (13,14),(7,8),(1,2)
    function [15:0] derive_key(input [15:0] s);
        reg [15:0] r;
        begin
            r = s;
            r[14] = s[13]; r[13] = s[14];
            r[8]  = s[7];  r[7]  = s[8];
            r[2]  = s[1];  r[1]  = s[2];
            derive_key = r;
        end
    endfunction

    // 8->16 spread of key3's low byte (XOR mask in decrypt_default)
    function [15:0] key3_spread(input [15:0] k);
        reg [15:0] r;
        begin
            r[15]=k[7]; r[14]=k[0]; r[13]=k[6]; r[12]=k[1];
            r[11]=k[5]; r[10]=k[2]; r[9] =k[4]; r[8] =k[3];
            r[7] =k[3]; r[6] =k[4]; r[5] =k[2]; r[4] =k[5];
            r[3] =k[1]; r[2] =k[6]; r[1] =k[0]; r[0] =k[7];
            key3_spread = r;
        end
    endfunction

    reg [15:0] dk;
    always @(posedge clk) begin
        if (rst) begin
            key1 <= 16'd0; key2 <= 16'd0; key3 <= 16'd0; dout <= 16'd0;
        end else if (load_keys) begin
            key1 <= key1_in; key2 <= key2_in; key3 <= key3_in;
        end else if (word_stb) begin
            if (ddrsbm) begin
                dout <= dec_common(din, key1);
                key1 <= {key1[14:0], key1[15]};            // rotate left by 1
            end else begin
                dk   = derive_key(key1 ^ key2);
                dout <= dec_common(din, dk) ^ key3_spread(key3);
                if (key1[14] ^ key1[15])
                    key2 <= {key2[14:0], key2[15]};        // conditional rotate
                key1 <= {key1[15], key1[13:0], key1[14]};  // rotate [14:0], keep 15
                key3 <= key3 + 16'd1;
            end
        end
    end
endmodule
