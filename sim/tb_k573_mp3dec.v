`timescale 1ns/1ps
// Testbench for k573_mp3dec.v - the BEMANI MP3 audio descrambler.
// Compares the RTL against an independent transliteration of the algorithm over
// both schemes (default and DDR SBM) with a running key schedule, and anchors a
// couple of outputs to values hand-computed from the spec for the zero-key case.
module tb_k573_mp3dec;
    reg        clk = 0, rst = 1;
    reg        load_keys = 0, ddrsbm = 0, word_stb = 0;
    reg [15:0] key1_in = 0, key2_in = 0, key3_in = 0, din = 0;
    wire [15:0] dout, key1, key2, key3;
    integer errors = 0;

    k573_mp3dec dut (
        .clk(clk), .rst(rst), .load_keys(load_keys),
        .key1_in(key1_in), .key2_in(key2_in), .key3_in(key3_in), .ddrsbm(ddrsbm),
        .word_stb(word_stb), .din(din), .dout(dout),
        .key1(key1), .key2(key2), .key3(key3)
    );

    always #5 clk = ~clk;

    // ---- reference model (mirrors the RTL functions) ----
    reg [15:0] sk1, sk2, sk3;

    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d;
        begin
            d = 16'd0;
            for (i = 0; i < 8; i = i + 1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555);
        end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r = s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2];
        r_derive = r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7];
        r_spread = r; end
    endfunction

    task load(input [15:0] k1, input [15:0] k2, input [15:0] k3, input m);
        begin
            ddrsbm = m;
            @(negedge clk); load_keys = 1; key1_in = k1; key2_in = k2; key3_in = k3;
            @(negedge clk); load_keys = 0;
            sk1 = k1; sk2 = k2; sk3 = k3;
        end
    endtask

    // drive one word, compare RTL output + key state to the reference
    task check_word(input [15:0] d);
        reg [15:0] exp, dk;
        begin
            if (ddrsbm) begin
                exp = r_common(d, sk1);
                sk1 = {sk1[14:0], sk1[15]};
            end else begin
                dk  = r_derive(sk1 ^ sk2);
                exp = r_common(d, dk) ^ r_spread(sk3);
                if (sk1[14] ^ sk1[15]) sk2 = {sk2[14:0], sk2[15]};
                sk1 = {sk1[15], sk1[13:0], sk1[14]};
                sk3 = sk3 + 16'd1;
            end
            @(negedge clk); din = d; word_stb = 1;
            @(negedge clk); word_stb = 0;
            if (dout !== exp) begin
                $display("FAIL: dout=%04h expected %04h (din=%04h)", dout, exp, d);
                errors = errors + 1;
            end
            if (key1 !== sk1 || key2 !== sk2 || key3 !== sk3) begin
                $display("FAIL: key state k1=%04h/%04h k2=%04h/%04h k3=%04h/%04h",
                         key1, sk1, key2, sk2, key3, sk3);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    reg [15:0] seed;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0;

        // ---- golden anchors: zero keys, default scheme ----
        load(16'h0000, 16'h0000, 16'h0000, 1'b0);
        @(negedge clk); din = 16'hABCD; word_stb = 1; @(negedge clk); word_stb = 0;
        if (dout !== 16'hABCD) begin $display("FAIL: golden1 %04h != ABCD", dout); errors=errors+1; end
        @(negedge clk); din = 16'hABCD; word_stb = 1; @(negedge clk); word_stb = 0;
        if (dout !== 16'hEBCF) begin $display("FAIL: golden2 %04h != EBCF", dout); errors=errors+1; end

        // ---- default scheme, non-trivial keys, a run of words ----
        load(16'h1357, 16'h2468, 16'h9BDF, 1'b0);
        seed = 16'h0001;
        for (i = 0; i < 24; i = i + 1) begin
            check_word(seed);
            seed = (seed << 1) ^ (seed[15] ? 16'h2D87 : 16'h0000) ^ 16'h5A5A;
        end

        // ---- DDR SBM scheme ----
        load(16'hACE1, 16'h0000, 16'h0000, 1'b1);
        seed = 16'hF00D;
        for (i = 0; i < 24; i = i + 1) begin
            check_word(seed);
            seed = (seed << 1) ^ (seed[15] ? 16'h2D87 : 16'h0000) ^ 16'h1234;
        end

        if (errors == 0) $display("RESULT: PASS (k573_mp3dec)");
        else             $display("RESULT: FAIL (k573_mp3dec, %0d errors)", errors);
        $finish;
    end
endmodule
