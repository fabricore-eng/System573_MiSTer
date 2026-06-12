`timescale 1ns/1ps
// Testbench for s573_flash.v with SIM_BACKING=0 -- the 16 MB SDRAM-backed flash
// line-buffer path. A tiny behavioral SDRAM line model answers each 128-bit burst
// request a few cycles later from a backing array, exercising:
//   * a line-buffer MISS that stalls (flash_ready=0) then fills and HITs
//   * subsequent sequential reads in the same line returning HITs (flash_ready=1)
//   * a second-line MISS (re-fill), and a read back of the first line (re-MISS)
//   * the autoselect MFR/DEV ID read answering immediately (flash_ready=1) even
//     though it is a flash select -- POST's flash-ID check must never stall.
//   * NOR PROGRAM write-back: a programmed word is written through the line buffer
//     AND committed to the SDRAM image (ch3), and reads back correctly even after
//     the line is evicted -- the writable-flash path a CD game's installer needs.
module tb_s573_flash_sdram;
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
    reg [127:0] flash_mem_q = 0;
    reg         flash_mem_ready = 0;
    // write-back port
    wire        flash_wr_req;
    wire        flash_wr_busy;
    wire [26:0] flash_wr_addr;
    wire [15:0] flash_wr_data;
    reg         flash_wr_ack = 0;
    integer errors = 0;

    s573_flash #(.WIN_WORDS(2048), .SECTOR_WORDS(512), .NUM_BANKS(4),
                 .SIM_BACKING(0)) dut (
        .clk(clk), .rst(rst), .ctl_we(ctl_we), .ctl_din(ctl_din),
        .bank(bank), .sec_io0_dir(sec_io0_dir), .cpld_sig(cpld_sig),
        .win_sel(win_sel), .win_addr(win_addr), .win_we(win_we),
        .win_din(win_din), .win_dout(win_dout), .flash_ready(flash_ready),
        .flash_mem_req(flash_mem_req), .flash_mem_addr(flash_mem_addr),
        .flash_mem_q(flash_mem_q), .flash_mem_ready(flash_mem_ready),
        .flash_wr_req(flash_wr_req), .flash_wr_busy(flash_wr_busy),
        .flash_wr_addr(flash_wr_addr), .flash_wr_data(flash_wr_data),
        .flash_wr_ack(flash_wr_ack)
    );

    always #5 clk = ~clk;

    // ---- behavioral 16 MB SDRAM line model ----
    // Factory content: word w (flat 23-bit index) holds a recognisable pattern.
    function [15:0] backing(input [22:0] w);
        backing = {w[6:0], 9'h0A5} ^ 16'hC000;   // arbitrary but deterministic
    endfunction

    // Programmed-word overlay: a small CAM that SHADOWS the factory backing() for
    // words the DUT has written back (NOR program). Models the SDRAM image being
    // mutated by ch3 writes. Reads consult the overlay first, else the factory word.
    localparam OV = 64;
    reg [22:0] ov_addr [0:OV-1];
    reg [15:0] ov_data [0:OV-1];
    reg        ov_val  [0:OV-1];
    integer    oi;
    initial for (oi = 0; oi < OV; oi = oi + 1) ov_val[oi] = 0;

    function [15:0] read_word(input [22:0] w);
        integer j; reg [15:0] r;
        begin
            r = backing(w);
            for (j = 0; j < OV; j = j + 1)
                if (ov_val[j] && ov_addr[j] == w) r = ov_data[j];
            read_word = r;
        end
    endfunction

    // Answer a burst request 3 cycles after flash_mem_req, returning 8 words
    // starting at flash_mem_addr (a flat word index), overlay-aware.
    reg [2:0] dly = 0;
    reg       pending = 0;
    reg [22:0] base = 0;
    integer i;
    always @(posedge clk) begin
        flash_mem_ready <= 0;
        if (flash_mem_req && !pending) begin
            pending <= 1; dly <= 3; base <= flash_mem_addr[22:0];
        end else if (pending) begin
            if (dly > 1) dly <= dly - 1;
            else begin
                for (i = 0; i < 8; i = i + 1)
                    flash_mem_q[i*16 +: 16] <= read_word(base + i[22:0]);
                flash_mem_ready <= 1;
                pending <= 0;
            end
        end
    end

    // ---- behavioral ch3 single-word WRITE-BACK model ----
    // Commits flash_wr_data into the overlay 3 cycles after flash_wr_req, then
    // pulses flash_wr_ack (the ch3 completion). Mirrors the real ch3 latency.
    reg [2:0]  wdly = 0;
    reg        wpend = 0;
    reg [22:0] wadr = 0;
    reg [15:0] wdat = 0;
    integer    wj;
    reg        wdone;
    always @(posedge clk) begin
        flash_wr_ack <= 0;
        if (flash_wr_req && !wpend) begin
            wpend <= 1; wdly <= 3; wadr <= flash_wr_addr[22:0]; wdat <= flash_wr_data;
        end else if (wpend) begin
            if (wdly > 1) wdly <= wdly - 1;
            else begin
                // upsert (wadr, wdat) into the overlay
                wdone = 0;
                for (wj = 0; wj < OV; wj = wj + 1)
                    if (!wdone && ov_val[wj] && ov_addr[wj] == wadr) begin
                        ov_data[wj] = wdat; wdone = 1;
                    end
                for (wj = 0; wj < OV; wj = wj + 1)
                    if (!wdone && !ov_val[wj]) begin
                        ov_val[wj] = 1; ov_addr[wj] = wadr; ov_data[wj] = wdat; wdone = 1;
                    end
                flash_wr_ack <= 1;
                wpend <= 0;
            end
        end
    end

    // EXP1-style read: present address + win_sel with win_we=0, then wait for
    // flash_ready (the wait handshake), then sample win_dout. Reports how many
    // wait cycles the access stalled for (0 = HIT, >0 = MISS that filled).
    integer last_stall;
    task flash_read(input [20:0] a, output [15:0] d);
        integer guard;
        begin
            @(negedge clk); win_sel = 1; win_we = 0; win_addr = a;
            #1;                                   // let flash_ready settle
            guard = 0;
            // hold the access asserted until ready (mirrors memorymux EXT_READ_NEXT)
            while (flash_ready !== 1'b1 && guard < 200) begin
                @(negedge clk); #1; guard = guard + 1;
            end
            last_stall = guard;
            d = win_dout;
            @(negedge clk); win_sel = 0;
        end
    endtask

    task win_write(input [20:0] a, input [15:0] dd);
        begin @(negedge clk); win_sel=1; win_we=1; win_addr=a; win_din=dd;
              @(negedge clk); win_sel=0; win_we=0; end
    endtask

    // Issue the AMD program command sequence then the data write to `a`.
    task flash_program(input [20:0] a, input [15:0] dd);
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h00A0);   // program command
            win_write(a, dd);               // data cycle -> prog_now -> write-back
            // let the background ch3 write-back complete before returning
            @(negedge clk);
            while (flash_wr_busy === 1'b1) @(negedge clk);
        end
    endtask

    task set_ctl(input [15:0] dd);
        begin @(negedge clk); ctl_we=1; ctl_din=dd; @(negedge clk); ctl_we=0; end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin if (got!==exp) begin
            $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
            errors=errors+1; end
        end
    endtask

    reg [15:0] v;
    reg [22:0] fw;
    integer cyc;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);
        set_ctl(16'h0000);                 // bank 0

        // 1) MISS then HIT: read word 0x40 (bank0). flat word = 0x40. The first
        //    access to a fresh line must STALL (last_stall>0), then return data.
        flash_read(21'h40, v); chk(v, backing(23'h40), "miss->fill word 0x40");
        if (last_stall == 0) begin
            $display("FAIL: first access to a fresh line should MISS (stall>0)");
            errors = errors + 1;
        end

        // 2) HIT: neighbour words in the same 16-word line (0x40..0x4F) -> no stall.
        flash_read(21'h41, v); chk(v, backing(23'h41), "line hit word 0x41");
        if (last_stall != 0) begin $display("FAIL: word 0x41 should HIT (no stall)"); errors=errors+1; end
        flash_read(21'h4F, v); chk(v, backing(23'h4F), "line hit word 0x4F");
        if (last_stall != 0) begin $display("FAIL: word 0x4F should HIT (no stall)"); errors=errors+1; end

        // 3) second-line MISS: word 0x80 is a different line -> re-fill (stall>0).
        flash_read(21'h80, v); chk(v, backing(23'h80), "second line word 0x80");
        if (last_stall == 0) begin $display("FAIL: word 0x80 (new line) should MISS"); errors=errors+1; end
        flash_read(21'h88, v); chk(v, backing(23'h88), "second line word 0x88");
        if (last_stall != 0) begin $display("FAIL: word 0x88 should HIT (no stall)"); errors=errors+1; end

        // 4) back to first line: now a MISS again (only one line buffered).
        flash_read(21'h40, v); chk(v, backing(23'h40), "refetch first line 0x40");
        if (last_stall == 0) begin $display("FAIL: refetch 0x40 should MISS (line evicted)"); errors=errors+1; end

        // 5) different bank changes the flat address (bank in tag high bits).
        //    Internal bank index is the raw control value ctl[1:0] (MAME: onboard
        //    banks are control 0-3), so bank 1 = ctl 0x01 and flat word = {1, win}.
        set_ctl(16'h0001);                 // bank 1 (ctl 0x01)
        fw = {2'd1, 21'h40};               // flat word for bank1, offset 0x40
        flash_read(21'h40, v); chk(v, backing(fw), "bank1 word 0x40");
        set_ctl(16'h0000);                 // back to bank 0

        // 6) autoselect ID read must answer IMMEDIATELY (no stall), even though
        //    it's a flash select. Unlock 0x555/0x2AA, cmd 0x90, then read 0x00/0x01.
        win_write(21'h555, 16'h00AA);
        win_write(21'h2AA, 16'h0055);
        win_write(21'h555, 16'h0090);      // autoselect
        // ID read at offset 0: must be ready in the same access (flash_ready=1).
        flash_read(21'h000, v); chk(v, 16'h0004, "autoselect MFR id");
        if (last_stall != 0) begin
            $display("FAIL: autoselect MFR id read must NOT stall");
            errors = errors + 1;
        end
        flash_read(21'h001, v); chk(v, 16'h00AD, "autoselect DEV id");
        if (last_stall != 0) begin
            $display("FAIL: autoselect DEV id read must NOT stall");
            errors = errors + 1;
        end
        // reset out of autoselect
        win_write(21'h000, 16'h00F0);

        // 7) after reset, an array read still works (MISS->fill of word 0x100).
        flash_read(21'h100, v); chk(v, backing(23'h100), "post-reset array read 0x100");
        if (last_stall == 0) begin $display("FAIL: post-reset 0x100 should MISS"); errors=errors+1; end

        // ---- WRITABLE FLASH (NOR program write-back) ----

        // 8) UNCACHED program: word 0x300's line has never been read, so the DUT
        //    treats it as erased (0xFFFF) and writes the raw data. Program 0x0F0F,
        //    then read it back -- the value must come from the SDRAM image (overlay).
        flash_program(21'h300, 16'h0F0F);
        flash_read(21'h300, v); chk(v, 16'h0F0F, "program uncached 0x300 reads back");

        // 8b) EVICTION re-read: force the 0x300 line out (read a far line) then read
        //     0x300 again. A line-buffer-only write would now read the FACTORY word;
        //     a real SDRAM commit reads back 0x0F0F. This is the load-bearing check.
        flash_read(21'h900, v);            // different line -> evicts 0x300's line
        flash_read(21'h300, v); chk(v, 16'h0F0F, "program 0x300 PERSISTED after evict");
        if (last_stall == 0) begin $display("FAIL: evicted 0x300 should MISS+refill"); errors=errors+1; end

        // 9) CACHED program with the NOR AND rule: read word 0x305 (caches its line
        //    with the factory value), then program 0xFF00 into it. The committed word
        //    must be factory(0x305) & 0xFF00 (NOR only clears bits), and read back so.
        flash_read(21'h305, v);            // cache 0x305's line (factory value)
        flash_program(21'h305, 16'hFF00);
        flash_read(21'h305, v);
        chk(v, backing(23'h305) & 16'hFF00, "program cached 0x305 = factory & data");
        // persist check after eviction
        flash_read(21'h980, v);            // evict
        flash_read(21'h305, v);
        chk(v, backing(23'h305) & 16'hFF00, "program 0x305 PERSISTED (NOR AND) after evict");

        // 10) program does NOT disturb the adjacent word (single-word, be=0011).
        //     0x300 was programmed; its pair-neighbour 0x301 must still be factory.
        flash_read(21'h301, v); chk(v, backing(23'h301), "neighbour 0x301 untouched by 0x300 program");

        if (errors == 0) $display("RESULT: PASS (s573_flash_sdram)");
        else             $display("RESULT: FAIL (s573_flash_sdram, %0d errors)", errors);
        $finish;
    end

    // global watchdog so a deadlocked handshake fails instead of hanging.
    initial begin
        for (cyc = 0; cyc < 40000; cyc = cyc + 1) @(posedge clk);
        $display("RESULT: FAIL (s573_flash_sdram timeout -- handshake deadlock?)");
        $finish;
    end
endmodule
