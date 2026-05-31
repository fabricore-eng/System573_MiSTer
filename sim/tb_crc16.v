`timescale 1ns/1ps
// Testbench for crc16.v - verifies the CRC-16/CCITT engine against the canonical
// "123456789" check vectors that are published for both common seedings:
//   * XMODEM      (poly 0x1021, init 0x0000) -> 0x31C3
//   * CCITT-FALSE (poly 0x1021, init 0xFFFF) -> 0x29B1
// These are universal ground-truth values (independent of any 573 reference),
// so a pass proves the polynomial division itself is correct.
module tb_crc16;
    reg        clk = 0;
    reg        load = 0, stb = 0;
    reg  [7:0] data = 8'h00;
    wire [15:0] crc_xmodem, crc_ccitt;
    integer errors = 0;

    crc16 #(.POLY(16'h1021), .INIT(16'h0000)) dut_xmodem (
        .clk(clk), .load(load), .stb(stb), .data(data), .crc(crc_xmodem));
    crc16 #(.POLY(16'h1021), .INIT(16'hFFFF)) dut_ccitt (
        .clk(clk), .load(load), .stb(stb), .data(data), .crc(crc_ccitt));

    always #5 clk = ~clk;

    // "123456789"
    reg [7:0] msg [0:8];
    integer i;
    initial begin
        msg[0]=8'h31; msg[1]=8'h32; msg[2]=8'h33; msg[3]=8'h34; msg[4]=8'h35;
        msg[5]=8'h36; msg[6]=8'h37; msg[7]=8'h38; msg[8]=8'h39;

        @(negedge clk); load = 1; @(negedge clk); load = 0;

        for (i = 0; i < 9; i = i + 1) begin
            data = msg[i]; stb = 1; @(negedge clk); stb = 0; @(negedge clk);
        end

        if (crc_xmodem !== 16'h31C3) begin
            $display("FAIL: XMODEM crc = %04h (expected 31C3)", crc_xmodem);
            errors = errors + 1;
        end
        if (crc_ccitt !== 16'h29B1) begin
            $display("FAIL: CCITT-FALSE crc = %04h (expected 29B1)", crc_ccitt);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("RESULT: PASS (crc16)  xmodem=%04h ccitt=%04h", crc_xmodem, crc_ccitt);
        else
            $display("RESULT: FAIL (crc16, %0d errors)", errors);
        $finish;
    end
endmodule
