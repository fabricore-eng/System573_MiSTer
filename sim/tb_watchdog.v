`timescale 1ns/1ps
// Testbench for watchdog.v
module tb_watchdog;
    reg clk = 0, rst = 1, kick = 0;
    wire reset_out;
    integer i;
    integer errors = 0;
    integer bites  = 0;

    localparam TO = 20;
    watchdog #(.TIMEOUT_CYCLES(TO)) dut (
        .clk(clk), .rst(rst), .kick(kick), .reset_out(reset_out)
    );

    always #5 clk = ~clk;

    // Count bites
    always @(posedge clk) if (!rst && reset_out) bites = bites + 1;

    task step; begin @(posedge clk); #1; end endtask

    initial begin
        // release reset
        repeat (3) step;
        rst = 0;

        // Phase 1: kick every 10 cycles for 100 cycles -> must not bite.
        bites = 0;
        for (i = 0; i < 100; i = i + 1) begin
            kick = (i % 10 == 0);
            step;
        end
        kick = 0;
        if (bites != 0) begin
            $display("FAIL: watchdog bit while being kicked (bites=%0d)", bites);
            errors = errors + 1;
        end

        // Phase 2: stop kicking, wait > timeout -> must bite exactly once soon.
        bites = 0;
        for (i = 0; i < TO + 5; i = i + 1) step;
        if (bites < 1) begin
            $display("FAIL: watchdog did not bite after timeout");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (watchdog)");
        else             $display("RESULT: FAIL (watchdog, %0d errors)", errors);
        $finish;
    end
endmodule
