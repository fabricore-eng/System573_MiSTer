`timescale 1ns/1ps
// Testbench for adc0834.v - drives the bit-banged serial interface like the
// Konami ASIC would and checks the converted channel value comes back.
module tb_adc0834;
    reg clk = 0, rst = 1;
    reg cs_n = 1, adc_clk = 0, di = 0;
    wire do_o, sars;
    reg [7:0] ch0 = 8'h11, ch1 = 8'hA5, ch2 = 8'h3C, ch3 = 8'hF0;
    integer errors = 0;
    reg [7:0] captured;

    adc0834 dut (
        .clk(clk), .rst(rst), .cs_n(cs_n), .adc_clk(adc_clk), .di(di),
        .do_o(do_o), .sars(sars), .ch0(ch0), .ch1(ch1), .ch2(ch2), .ch3(ch3)
    );

    always #5 clk = ~clk;            // 100 MHz sample clock
    task wclk; begin repeat (4) @(posedge clk); #1; end endtask

    // One serial clock: rising edge (ADC samples DI), then falling edge.
    task sclk; begin
        adc_clk = 1; wclk;
        adc_clk = 0; wclk;
    end endtask

    // Read one channel given the 3 address bits (sgl_dif, odd, sel1); returns 8b.
    task read_channel(input sgl, input odd, input sel1, output [7:0] val);
        integer k;
        reg [7:0] acc;
        begin
            cs_n = 0; wclk;            // select
            // address: start(1), sgl_dif, odd, sel1 - MSB first
            di = 1'b1;  sclk;          // start bit
            di = sgl;   sclk;
            di = odd;   sclk;
            di = sel1;  sclk;          // 4th rising edge -> S_SARS; its fall = SARS
            // 8 data bits: sample DO after each falling edge
            acc = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                sclk;
                acc = {acc[6:0], do_o};
            end
            val  = acc;
            cs_n = 1; wclk;
        end
    endtask

    task check(input [7:0] got, input [7:0] exp, input [127:0] name);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got %02h expected %02h", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst = 0; wclk;

        read_channel(1'b1, 1'b1, 1'b0, captured); // {odd,sel1}=10 -> ch1
        check(captured, ch1, "ch1");

        read_channel(1'b1, 1'b0, 1'b0, captured); // 00 -> ch0
        check(captured, ch0, "ch0");

        read_channel(1'b1, 1'b1, 1'b1, captured); // 11 -> ch3
        check(captured, ch3, "ch3");

        read_channel(1'b1, 1'b0, 1'b1, captured); // 01 -> ch2
        check(captured, ch2, "ch2");

        if (errors == 0) $display("RESULT: PASS (adc0834)");
        else             $display("RESULT: FAIL (adc0834, %0d errors)", errors);
        $finish;
    end
endmodule
