// tb_s573_audio_mix.v - saturating 2-ch mixer (SPU + MP3 PCM) unit test.
// Verilog-2005 / iverilog -g2005-sv.
`timescale 1ns/1ps
module tb_s573_audio_mix;
    reg  signed [15:0] spu_l, spu_r, mp3_l, mp3_r;
    wire signed [15:0] out_l, out_r;

    s573_audio_mix dut (
        .spu_l(spu_l), .spu_r(spu_r), .mp3_l(mp3_l), .mp3_r(mp3_r),
        .out_l(out_l), .out_r(out_r)
    );

    integer errors = 0;

    task chk;
        input signed [15:0] sl, sr, ml, mr;   // inputs
        input signed [15:0] el, er;            // expected outputs
        begin
            spu_l = sl; spu_r = sr; mp3_l = ml; mp3_r = mr; #1;
            if (out_l !== el) begin
                $display("FAIL: L: spu=%0d mp3=%0d -> %0d (exp %0d)", sl, ml, out_l, el);
                errors = errors + 1;
            end
            if (out_r !== er) begin
                $display("FAIL: R: spu=%0d mp3=%0d -> %0d (exp %0d)", sr, mr, out_r, er);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        //   spu_l  spu_r   mp3_l  mp3_r    exp_l   exp_r
        chk( 16'sd100,  16'sd200,  16'sd50,   16'sd60,   16'sd150,   16'sd260);   // no clip
        chk( 16'sd0,    16'sd0,    16'sd0,    16'sd0,    16'sd0,     16'sd0);     // silence
        chk( 16'sd12345,16'sd9999, 16'sd0,    16'sd0,    16'sd12345, 16'sd9999);  // MP3 idle -> passthrough
        chk( 16'sd30000,16'sd30000,16'sd10000,16'sd10000,16'sd32767, 16'sd32767); // +clip both
        chk(-16'sd30000,-16'sd30000,-16'sd10000,-16'sd10000,-16'sd32768,-16'sd32768); // -clip both
        chk( 16'sd32767,16'sd32767,16'sd32767,16'sd32767,16'sd32767, 16'sd32767); // max+max -> +rail
        chk(-16'sd32768,-16'sd32768,-16'sd32768,-16'sd32768,-16'sd32768,-16'sd32768); // min+min -> -rail
        chk( 16'sd32767,-16'sd32768,-16'sd32768,16'sd32767,-16'sd1,   -16'sd1);   // opposite extremes -> -1
        // independent channels: L clips +, R stays linear
        chk( 16'sd32767,-16'sd100,  16'sd1,    -16'sd200, 16'sd32767, -16'sd300);
        // just below / at the rails (boundary)
        chk( 16'sd16383,16'sd16384, 16'sd16384,16'sd16383,16'sd32767, 16'sd32767); // 32767 both (exact rail, no clip)
        chk( 16'sd16384,16'sd16384, 16'sd16384,16'sd16384,16'sd32767, 16'sd32767); // 32768 -> clip to 32767

        if (errors == 0) $display("RESULT: PASS (s573_audio_mix)");
        else             $display("RESULT: FAIL (s573_audio_mix, %0d errors)", errors);
        $finish;
    end
endmodule
