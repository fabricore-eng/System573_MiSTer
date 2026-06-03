`timescale 1ns/1ps
// Testbench for s573_flash.v - the bank-switched flash window + control latch.
// Verifies the control-register decode (bank / IO0 direction / CPLD bit), that
// each internal bank is an independent backing region, and that an absent
// PCMCIA bank reads all-ones.
module tb_s573_flash;
    reg        clk = 0, rst = 1;
    reg        ctl_we = 0;
    reg [15:0] ctl_din = 0;
    wire [5:0] bank;
    wire       sec_io0_dir, cpld_sig;
    reg        win_sel = 0, win_we = 0;
    reg [20:0] win_addr = 0;
    reg [15:0] win_din = 0;
    wire [15:0] win_dout;
    wire        flash_ready;
    wire        flash_mem_req;
    wire [26:0] flash_mem_addr;
    integer errors = 0;

    // SIM_BACKING=1 (default): inline flash_nor chips; the SDRAM ports are unused.
    s573_flash #(.WIN_WORDS(2048), .SECTOR_WORDS(512), .NUM_BANKS(4),
                 .SIM_BACKING(1)) dut (
        .clk(clk), .rst(rst), .ctl_we(ctl_we), .ctl_din(ctl_din),
        .bank(bank), .sec_io0_dir(sec_io0_dir), .cpld_sig(cpld_sig),
        .win_sel(win_sel), .win_addr(win_addr), .win_we(win_we),
        .win_din(win_din), .win_dout(win_dout), .flash_ready(flash_ready),
        .flash_mem_req(flash_mem_req), .flash_mem_addr(flash_mem_addr),
        .flash_mem_q(128'd0), .flash_mem_ready(1'b0)
    );

    always #5 clk = ~clk;

    task set_ctl(input [15:0] d);
        begin @(negedge clk); ctl_we=1; ctl_din=d; @(negedge clk); ctl_we=0; end
    endtask
    task win_write(input [15:0] a, input [15:0] d);
        begin @(negedge clk); win_sel=1; win_we=1; win_addr=a; win_din=d;
              @(negedge clk); win_sel=0; win_we=0; end
    endtask
    task win_read(input [15:0] a, output [15:0] d);
        begin @(negedge clk); win_sel=1; win_addr=a; #1 d=win_dout; @(negedge clk); win_sel=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [127:0] what);
        begin if (got!==exp) begin $display("FAIL: %0s = %04h (expected %04h)",what,got,exp); errors=errors+1; end end
    endtask
    // NOR program: unlock then 0xA0 then data (the backing is real flash)
    task flash_prog(input [15:0] a, input [15:0] d);
        begin win_write(16'h555,16'h00AA); win_write(16'h2AA,16'h0055);
              win_write(16'h555,16'h00A0); win_write(a,d); end
    endtask

    reg [15:0] v;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- control register decode: bank 2, IO0 dir + CPLD set ----
        set_ctl(16'h00C2);                 // bits: bank=0x02, bit6=1, bit7=1
        if (bank !== 6'd2)       begin $display("FAIL: bank"); errors=errors+1; end
        if (sec_io0_dir !== 1'b1) begin $display("FAIL: io0_dir"); errors=errors+1; end
        if (cpld_sig !== 1'b1)    begin $display("FAIL: cpld"); errors=errors+1; end

        // ---- a raw write (no unlock) does nothing: real NOR flash ----
        set_ctl(16'h0000); win_write(16'd5, 16'h1234);
        win_read(16'd5, v); chk(v, 16'hFFFF, "raw write ignored");

        // ---- per-bank isolation (each bank is an independent flash chip) ----
        set_ctl(16'h0000); flash_prog(16'd5, 16'hAAAA);   // bank 0, addr 5
        set_ctl(16'h0001); flash_prog(16'd5, 16'h5555);   // bank 1, addr 5
        set_ctl(16'h0000); win_read(16'd5, v); chk(v, 16'hAAAA, "bank0[5]");
        set_ctl(16'h0001); win_read(16'd5, v); chk(v, 16'h5555, "bank1[5]");

        // ---- different offset within a bank ----
        set_ctl(16'h0000); flash_prog(16'd200, 16'h1234);
        win_read(16'd200, v); chk(v, 16'h1234, "bank0[200]");
        win_read(16'd5,   v); chk(v, 16'hAAAA, "bank0[5] intact");

        // ---- absent PCMCIA bank reads all-ones ----
        set_ctl(16'h0010);                 // bank 16 = PCMCIA1 (not backed)
        win_read(16'd5, v); chk(v, 16'hFFFF, "pcmcia read");

        if (errors == 0) $display("RESULT: PASS (s573_flash)");
        else             $display("RESULT: FAIL (s573_flash, %0d errors)", errors);
        $finish;
    end
endmodule
