`timescale 1ns/1ps
// Testbench for k573_mp3stream.v - the MP3 streaming controller.
// Loads scrambled words into a DRAM model, starts streaming, and checks the
// emitted byte stream against an independent descramble reference (descramble
// each word with the running key schedule, emit high byte then low byte).
module tb_k573_mp3stream;
    reg        clk = 0, rst = 1;
    reg [15:0] fpga_ctrl = 0;
    reg [24:0] mp3_start = 0, mp3_end = 8;   // 4 words
    reg [15:0] key1 = 16'h1357, key2 = 16'h2468, key3 = 16'h9BDF;
    wire [24:0] rd_addr;
    wire [7:0]  out_byte;
    wire        out_valid;
    wire [31:0] byte_counter;
    wire [15:0] fpga_ctrl_rb;
    integer errors = 0;

    // DRAM model (scrambled MP3 words)
    reg [15:0] mem [0:7];
    wire [15:0] rd_data_w;
    assign rd_data_w = mem[rd_addr >> 1];

    k573_mp3stream dut (
        .clk(clk), .rst(rst), .fpga_ctrl(fpga_ctrl), .ddrsbm(1'b0),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .key1(key1), .key2(key2), .key3(key3),
        .rd_addr(rd_addr), .rd_data(rd_data_w),
        .out_byte(out_byte), .out_valid(out_valid),
        .byte_counter(byte_counter), .fpga_ctrl_rb(fpga_ctrl_rb)
    );

    always #5 clk = ~clk;

    // ---- descramble reference (mirrors k573_mp3dec) ----
    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d; begin
            d = 16'd0;
            for (i=0;i<8;i=i+1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555); end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r=s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2];
        r_derive=r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7];
        r_spread=r; end
    endfunction

    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [7:0]  expb [0:7];
    reg [7:0]  gotb [0:7];
    integer    gi = 0, i;

    // collect emitted bytes
    always @(posedge clk) if (!rst && out_valid) begin
        gotb[gi] = out_byte; gi = gi + 1;
    end

    initial begin
        mem[0]=16'h1234; mem[1]=16'h5678; mem[2]=16'h9ABC; mem[3]=16'hDEF0;

        // expected descrambled byte stream
        sk1=key1; sk2=key2; sk3=key3;
        for (i=0;i<4;i=i+1) begin
            dk   = r_derive(sk1 ^ sk2);
            dval = r_common(mem[i], dk) ^ r_spread(sk3);
            expb[2*i]   = dval[15:8];
            expb[2*i+1] = dval[7:0];
            if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
            sk1 = {sk1[15], sk1[13:0], sk1[14]};
            sk3 = sk3 + 16'd1;
        end

        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        fpga_ctrl = 16'h6000;            // MP3_ENABLE | STREAMING_ENABLE
        repeat (40) @(posedge clk);      // let it stream the 4 words (8 bytes)

        if (gi !== 8) begin $display("FAIL: emitted %0d bytes (expected 8)", gi); errors=errors+1; end
        for (i=0;i<8 && i<gi;i=i+1)
            if (gotb[i] !== expb[i]) begin
                $display("FAIL: byte[%0d]=%02h expected %02h", i, gotb[i], expb[i]);
                errors = errors + 1;
            end
        if (byte_counter !== 32'd8) begin $display("FAIL: byte_counter=%0d", byte_counter); errors=errors+1; end
        if (fpga_ctrl_rb !== 16'h0000) begin $display("FAIL: still streaming after end %04h", fpga_ctrl_rb); errors=errors+1; end

        if (errors == 0) $display("RESULT: PASS (k573_mp3stream)");
        else             $display("RESULT: FAIL (k573_mp3stream, %0d errors)", errors);
        $finish;
    end
endmodule
