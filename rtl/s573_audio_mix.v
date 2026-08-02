// -----------------------------------------------------------------------------
// s573_audio_mix.v - 2-channel saturating audio mixer (SPU + HPS MP3 PCM)
//
// P4b(b), fabric slice 3. The PSX SPU output (sound_out_left/right) currently
// drives AUDIO_L/R directly at emu.sv:1520-1521. The Digital I/O MP3 path adds a
// second stereo source (s573_mp3_pcm's drained PCM). This module sums them with
// SIGNED SATURATION so a loud SPU + loud MP3 clip cleanly at the 16-bit rails
// instead of wrapping (a wrap would be an audible full-scale glitch).
//
// Purely combinational; both inputs are signed 16-bit, output signed 16-bit
// (AUDIO_S = 1). When the MP3 channel is idle/underrun, s573_mp3_pcm drives its
// PCM to 0, so this reduces to a passthrough of the SPU -- game SFX unaffected.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_audio_mix (
    input  wire signed [15:0] spu_l,   // PSX SPU L
    input  wire signed [15:0] spu_r,   // PSX SPU R
    input  wire signed [15:0] mp3_l,   // HPS MP3 PCM L (0 when idle/underrun)
    input  wire signed [15:0] mp3_r,   // HPS MP3 PCM R
    output wire signed [15:0] out_l,
    output wire signed [15:0] out_r
);
    // 17-bit signed sum, then clamp to the 16-bit rails [-32768, 32767].
    wire signed [16:0] sum_l = spu_l + mp3_l;
    wire signed [16:0] sum_r = spu_r + mp3_r;

    function signed [15:0] sat16;
        input signed [16:0] v;
        begin
            if (v > 17'sd32767)       sat16 = 16'sd32767;
            else if (v < -17'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    assign out_l = sat16(sum_l);
    assign out_r = sat16(sum_r);
endmodule
