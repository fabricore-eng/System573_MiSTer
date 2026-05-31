`timescale 1ns/1ps
// Testbench for flash_nor.v - exercises the AMD/Fujitsu NOR command set:
// autoselect ID, that a bare write does nothing, the program unlock sequence
// (with 1->0-only AND semantics), and sector erase back to 0xFFFF.
module tb_flash_nor;
    reg        clk = 0, rst = 1;
    reg        ce = 0, we = 0;
    reg [15:0] addr = 0, din = 0;
    wire [15:0] dout;
    integer errors = 0;

    flash_nor #(.WORDS(2048), .SECTOR_WORDS(512),
                .MFR_ID(16'h0004), .DEV_ID(16'h00AD)) dut (
        .clk(clk), .rst(rst), .ce(ce), .we(we), .addr(addr), .din(din), .dout(dout)
    );

    always #5 clk = ~clk;

    task wr(input [15:0] a, input [15:0] d);
        begin @(negedge clk); ce=1; we=1; addr=a; din=d; @(negedge clk); ce=0; we=0; end
    endtask
    task rd(input [15:0] a, output [15:0] d);
        begin @(negedge clk); ce=1; we=0; addr=a; #1 d=dout; @(negedge clk); ce=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [127:0] what);
        begin if (got!==exp) begin $display("FAIL: %0s = %04h (expected %04h)",what,got,exp); errors=errors+1; end end
    endtask
    task unlock; begin wr(16'h555, 16'h00AA); wr(16'h2AA, 16'h0055); end endtask

    reg [15:0] v;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- autoselect: read manufacturer / device IDs ----
        unlock; wr(16'h555, 16'h0090);
        rd(16'h000, v); chk(v, 16'h0004, "mfr id");
        rd(16'h001, v); chk(v, 16'h00AD, "device id");
        wr(16'h000, 16'h00F0);              // reset to read mode
        rd(16'h001, v); chk(v, 16'hFFFF, "after reset (erased)");

        // ---- a bare write without an unlock sequence does nothing ----
        wr(16'h010, 16'h1234);
        rd(16'h010, v); chk(v, 16'hFFFF, "bare write ignored");

        // ---- program (NOR AND semantics) ----
        unlock; wr(16'h555, 16'h00A0); wr(16'h010, 16'h1234);
        rd(16'h010, v); chk(v, 16'h1234, "program into erased");
        unlock; wr(16'h555, 16'h00A0); wr(16'h010, 16'h0F0F);
        rd(16'h010, v); chk(v, 16'h0204, "program ANDs (1234 & 0F0F)");

        // ---- program a word in another sector, then sector-erase sector 0 ----
        unlock; wr(16'h555, 16'h00A0); wr(16'h600, 16'hBEEF);   // sector 1
        unlock; wr(16'h555, 16'h0080); unlock; wr(16'h010, 16'h0030); // sector erase @0
        rd(16'h010, v); chk(v, 16'hFFFF, "sector 0 erased");
        rd(16'h600, v); chk(v, 16'hBEEF, "sector 1 intact");

        if (errors == 0) $display("RESULT: PASS (flash_nor)");
        else             $display("RESULT: FAIL (flash_nor, %0d errors)", errors);
        $finish;
    end
endmodule
