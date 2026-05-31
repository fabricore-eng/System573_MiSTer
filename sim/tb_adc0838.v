`timescale 1ns/1ps
// Testbench for adc0838.v - drives the 5-bit MUX address serial protocol and
// checks the selected channel (single-ended {SEL1,SEL0,ODD}) comes back.
module tb_adc0838;
    reg clk = 0, rst = 1;
    reg cs_n = 1, adc_clk = 0, di = 0;
    wire do_o, sars;
    reg [7:0] ch0=8'h10, ch1=8'h21, ch2=8'h32, ch3=8'h43,
              ch4=8'h54, ch5=8'h65, ch6=8'h76, ch7=8'h87;
    integer errors = 0;
    reg [7:0] captured;

    adc0838 dut (
        .clk(clk), .rst(rst), .cs_n(cs_n), .adc_clk(adc_clk), .di(di),
        .do_o(do_o), .sars(sars),
        .ch0(ch0), .ch1(ch1), .ch2(ch2), .ch3(ch3),
        .ch4(ch4), .ch5(ch5), .ch6(ch6), .ch7(ch7)
    );

    always #5 clk = ~clk;
    task wclk; begin repeat (4) @(posedge clk); #1; end endtask
    task sclk; begin adc_clk = 1; wclk; adc_clk = 0; wclk; end endtask

    task read_channel(input sgl, input odd, input sel1, input sel0, output [7:0] val);
        integer k; reg [7:0] acc;
        begin
            cs_n = 0; wclk;
            di = 1'b1;  sclk;          // start
            di = sgl;   sclk;
            di = odd;   sclk;
            di = sel1;  sclk;
            di = sel0;  sclk;          // 5th rising edge -> S_SARS
            acc = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin sclk; acc = {acc[6:0], do_o}; end
            val = acc;
            cs_n = 1; wclk;
        end
    endtask

    task check(input [7:0] got, input [7:0] exp, input [127:0] name);
        begin if (got!==exp) begin $display("FAIL: %0s got %02h expected %02h",name,got,exp); errors=errors+1; end end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst = 0; wclk;

        read_channel(1'b1, 1'b0, 1'b0, 1'b0, captured); check(captured, ch0, "ch0");
        read_channel(1'b1, 1'b1, 1'b0, 1'b1, captured); check(captured, ch3, "ch3");
        read_channel(1'b1, 1'b1, 1'b1, 1'b0, captured); check(captured, ch5, "ch5");
        read_channel(1'b1, 1'b1, 1'b1, 1'b1, captured); check(captured, ch7, "ch7");
        read_channel(1'b1, 1'b0, 1'b1, 1'b0, captured); check(captured, ch4, "ch4");

        if (errors == 0) $display("RESULT: PASS (adc0838)");
        else             $display("RESULT: FAIL (adc0838, %0d errors)", errors);
        $finish;
    end
endmodule
