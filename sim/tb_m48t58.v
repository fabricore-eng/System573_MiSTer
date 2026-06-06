`timescale 1ns/1ps
// Testbench for m48t58.v - NVRAM persistence, BCD second->minute rollover and
// the read-freeze snapshot. CLK_FREQ_HZ=1 => one clock == one RTC second.
module tb_m48t58;
    reg clk = 0, rst = 1, we = 0;
    reg [12:0] addr = 0;
    reg [7:0]  din = 0;
    wire [7:0] dout;
    reg        nvram_we = 0;
    reg [12:0] nvram_addr = 0;
    reg [7:0]  nvram_din = 0;
    integer errors = 0;
    reg [7:0] got;

    localparam SEC = 13'd8185, MIN = 13'd8186, CTRL = 13'd8184;

    m48t58 #(.CLK_FREQ_HZ(1)) dut (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din)
    );

    always #5 clk = ~clk;

    task wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; din = d; we = 1;
            @(posedge clk);
            @(negedge clk); we = 0;
        end
    endtask

    // One ioctl image-load write (one byte). Replicates the HPS NVRAM download; on HW
    // this streams while the core reset is HELD HIGH, so the tests drive it under rst.
    task nv_load(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); nvram_addr = a; nvram_din = d; nvram_we = 1;
            @(posedge clk);
            @(negedge clk); nvram_we = 0;
        end
    endtask

    // RTC register reads are combinational.
    task rd(input [12:0] a, output [7:0] d);
        begin
            addr = a; #1; d = dout;
        end
    endtask

    // NVRAM reads are synchronous now (registered M10K output): present the address,
    // then wait a clock edge for the read data before sampling.
    task rd_nv(input [12:0] a, output [7:0] d);
        begin
            addr = a; @(posedge clk); #1 d = dout;
        end
    endtask

    task check(input [7:0] g, input [7:0] e, input [127:0] name);
        begin
            if (g !== e) begin
                $display("FAIL: %0s got %02h expected %02h", name, g, e);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // 0) HW-FIDELITY NVRAM IMAGE LOAD under reset. emu.sv holds the core reset HIGH
        //    for the ENTIRE NVRAM ioctl download, so the image load MUST land while
        //    rst==1. Regression for the hyperbbc hang -- the old RTL gated the load
        //    behind rst==0, silently dropping it: the M10K read back zeros, the boot
        //    self-test's GQ876 signature compare failed, status|=0x40, red "N".
        nv_load(13'd0,    8'h47);   // 'G' (first signature byte)
        nv_load(13'd1,    8'h51);   // 'Q'
        nv_load(13'd4096, 8'hC3);   // a mid-array byte, far from addr 0
        repeat (3) @(posedge clk); @(negedge clk); rst = 0;   // release reset (download done)
        rd_nv(13'd0,    got); check(got, 8'h47, "nvram image load@0 under rst");
        rd_nv(13'd1,    got); check(got, 8'h51, "nvram image load@1 under rst");
        rd_nv(13'd4096, got); check(got, 8'hC3, "nvram image load@4096 under rst");

        // 1) NVRAM persistence (post-reset bus writes).
        wr(13'd100, 8'hAB);
        wr(13'd8000, 8'h5A);
        rd_nv(13'd100, got);  check(got, 8'hAB, "nvram@100");
        rd_nv(13'd8000, got); check(got, 8'h5A, "nvram@8000");

        // 2) Set time via WRITE freeze, then release and advance 3 seconds.
        wr(CTRL, 8'h80);          // enter write freeze (clock paused)
        wr(SEC,  8'h58);          // seconds = 58 (BCD)
        wr(MIN,  8'h30);          // minutes = 30 (BCD)
        wr(CTRL, 8'h00);          // release -> clock runs, no advance this edge
        @(posedge clk);           // 58 -> 59
        @(posedge clk);           // 59 -> 00, minute 30 -> 31
        @(posedge clk);           // 00 -> 01
        wr(CTRL, 8'h40);          // enter read freeze -> snapshot = 01:31

        rd(SEC, got); check(got, 8'h01, "rollover seconds");
        rd(MIN, got); check(got, 8'h31, "rollover minute carry");

        // 3) Read freeze holds while the live clock keeps ticking.
        repeat (5) @(posedge clk);
        rd(SEC, got); check(got, 8'h01, "freeze holds seconds");
        rd(MIN, got); check(got, 8'h31, "freeze holds minute");

        // Unfreeze: live value must now differ from the frozen snapshot.
        wr(CTRL, 8'h00);
        rd(SEC, got);
        if (got === 8'h01) begin
            $display("FAIL: clock did not advance under read freeze");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (m48t58)");
        else             $display("RESULT: FAIL (m48t58, %0d errors)", errors);
        $finish;
    end
endmodule
