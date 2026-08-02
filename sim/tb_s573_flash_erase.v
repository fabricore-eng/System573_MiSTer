`timescale 1ns/1ps
// Testbench for the SDRAM-backed JEDEC ERASE engine in s573_flash.v (SIM_BACKING=0).
//
// What ddrsbm's installer actually does (full-EXE disasm, 2026-07-02, see
// docs/2026-07-01-ddrsbm-dio-i2c-result.md §4): per 128 KB sector it issues the
// AMD sector-erase sequence (AA/55/80/AA/55 then 0x30 at the sector base) on all
// 4 banks back-to-back, DQ7-data-polls each bank's sector base ((read ^ 0xFFFF) &
// 0x8080 == 0 -> done) under a ~2 s budget, runs the autoselect ID check on the
// NEXT bank while the previous still erases, then read-verifies the whole sector
// expects 0xFFFF. This TB drives exactly those access patterns and asserts:
//   * reads of the erasing bank return AMD busy status (DQ7=0, DQ6/DQ2 toggling,
//     DQ3=1, DQ5=0 -> 0x4C4C/0x0808 alternating, both x8 lanes), with NO stall
//   * idle banks stay live during a walk: autoselect ID answers immediately and
//     an array read line-fills normally (bounded stall, not walk-duration)
//   * the DQ7 poll completes and every word of the region -- including after a
//     line-buffer eviction, i.e. really committed to SDRAM -- reads 0xFFFF
//   * words outside the sector, and the same sector index on OTHER banks, are
//     untouched; program-after-erase works; program to a BUSY bank is ignored
//   * chip erase (0x10) spans the whole bank (walk length scaled down via the
//     ERASE_CHIP_WORDS parameter so it stays simulable; the region-bounds math
//     is what's under test -- synthesis uses the real 2M-word default)
//
// RED/GREEN: `make S573_FLASH_ERASE_NOOP=1 s573_flash_erase` restores the pre-fix
// no-op erase (decoded, dropped) -- the busy-status asserts fail and the DQ7 poll
// times out exactly like the silicon ERASE TIMEOUT. GREEN by default.
module tb_s573_flash_erase;
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
    wire        flash_wr_req;
    wire        flash_wr_busy;
    wire [26:0] flash_wr_addr;
    wire [15:0] flash_wr_data;
    reg         flash_wr_ack = 0;
    integer errors = 0;

    // ERASE_CHIP_WORDS scaled from the real 2M words (a whole 4 MB bank) to 4096
    // so the chip-erase walk is simulable; sector geometry is NOT scaled (the
    // real win_addr[20:16] layout is exactly what this TB exercises).
    s573_flash #(.WIN_WORDS(2048), .SECTOR_WORDS(512), .NUM_BANKS(4),
                 .ERASE_CHIP_WORDS(4096), .SIM_BACKING(0)) dut (
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

    // ---- behavioral 16 MB SDRAM model ----
    // Factory content: word w (flat 23-bit index) holds a recognisable pattern
    // (same as tb_s573_flash_sdram).
    function [15:0] backing(input [22:0] w);
        backing = {w[6:0], 9'h0A5} ^ 16'hC000;
    endfunction

    // Programmed-word overlay CAM (as tb_s573_flash_sdram) PLUS an erased-range
    // layer: the erase walker commits 64K+ sequential 0xFFFF writes -- far beyond
    // any word-CAM. A 0xFFFF write that doesn't update an existing CAM entry
    // instead extends/opens one of a few contiguous [base..end] erased ranges
    // (walker order is ascending). Reads: CAM first, then erased ranges (0xFFFF),
    // then the factory pattern.
    localparam OV = 64;
    reg [22:0] ov_addr [0:OV-1];
    reg [15:0] ov_data [0:OV-1];
    reg        ov_val  [0:OV-1];
    localparam NR = 8;
    reg [22:0] rg_base [0:NR-1];
    reg [22:0] rg_end  [0:NR-1];
    reg        rg_val  [0:NR-1];
    integer    oi;
    initial begin
        for (oi = 0; oi < OV; oi = oi + 1) ov_val[oi] = 0;
        for (oi = 0; oi < NR; oi = oi + 1) rg_val[oi] = 0;
    end

    function [15:0] read_word(input [22:0] w);
        integer j; reg [15:0] r;
        begin
            r = backing(w);
            for (j = 0; j < NR; j = j + 1)
                if (rg_val[j] && w >= rg_base[j] && w <= rg_end[j]) r = 16'hFFFF;
            for (j = 0; j < OV; j = j + 1)
                if (ov_val[j] && ov_addr[j] == w) r = ov_data[j];   // CAM wins
            read_word = r;
        end
    endfunction

    task commit_write(input [22:0] a, input [15:0] d);
        integer j; reg done;
        begin
            done = 0;
            // update an existing CAM entry (covers program-over AND erase-over)
            for (j = 0; j < OV; j = j + 1)
                if (!done && ov_val[j] && ov_addr[j] == a) begin
                    ov_data[j] = d; done = 1;
                end
            if (!done && d == 16'hFFFF) begin
                // walker traffic: extend (ascending), swallow, or open a range
                for (j = 0; j < NR; j = j + 1)
                    if (!done && rg_val[j] && a == rg_end[j] + 1) begin
                        rg_end[j] = a; done = 1;
                    end
                for (j = 0; j < NR; j = j + 1)
                    if (!done && rg_val[j] && a >= rg_base[j] && a <= rg_end[j])
                        done = 1;                    // already inside a range
                for (j = 0; j < NR; j = j + 1)
                    if (!done && !rg_val[j]) begin
                        rg_val[j] = 1; rg_base[j] = a; rg_end[j] = a; done = 1;
                    end
                if (!done) begin
                    $display("TB-INFRA FAIL: erased-range slots exhausted at %h", a);
                    errors = errors + 1;
                end
            end else if (!done) begin
                for (j = 0; j < OV; j = j + 1)
                    if (!done && !ov_val[j]) begin
                        ov_val[j] = 1; ov_addr[j] = a; ov_data[j] = d; done = 1;
                    end
                if (!done) begin
                    $display("TB-INFRA FAIL: overlay CAM full at %h", a);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // Answer a burst request 3 cycles after flash_mem_req (8 words, overlay-aware).
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

    // ch3 single-word write-back model: commit 3 cycles after flash_wr_req, then
    // pulse flash_wr_ack (mirrors the real ch3 latency).
    reg [2:0]  wdly = 0;
    reg        wpend = 0;
    reg [22:0] wadr = 0;
    reg [15:0] wdat = 0;
    always @(posedge clk) begin
        flash_wr_ack <= 0;
        if (flash_wr_req && !wpend) begin
            wpend <= 1; wdly <= 3; wadr <= flash_wr_addr[22:0]; wdat <= flash_wr_data;
        end else if (wpend) begin
            if (wdly > 1) wdly <= wdly - 1;
            else begin
                commit_write(wadr, wdat);
                flash_wr_ack <= 1;
                wpend <= 0;
            end
        end
    end

    // EXP1-style read (as tb_s573_flash_sdram): hold win_sel until flash_ready,
    // sample, report stall cycles.
    integer last_stall;
    task flash_read(input [20:0] a, output [15:0] d);
        integer guard;
        begin
            @(negedge clk); win_sel = 1; win_we = 0; win_addr = a;
            #1;
            guard = 0;
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

    // AMD program sequence. Only call while the erase walker is IDLE: the
    // completion wait watches flash_wr_busy, which also pulses per walker word.
    // (The busy-bank-program test below relies on the drop happening at the
    // prog_now guard, not on this wait.)
    task flash_program(input [20:0] a, input [15:0] dd);
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h00A0);
            win_write(a, dd);
            @(negedge clk);
            while (flash_wr_busy === 1'b1) @(negedge clk);
        end
    endtask

    // AMD erase sequences (the exact writes ddrsbm issues, 16-bit lanes doubled).
    task flash_erase_prefix;
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h0080);
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
        end
    endtask
    task flash_sector_erase(input [20:0] a);
        begin flash_erase_prefix; win_write(a, 16'h0030); end
    endtask
    task flash_chip_erase;
        begin flash_erase_prefix; win_write(21'h555, 16'h0010); end
    endtask

    // The game's own completion condition: DQ7 data-poll on both lanes,
    // (read ^ 0xFFFF) & 0x8080 == 0 -> done (0x8009f044 in the ddrsbm EXE).
    task dq7_poll(input [20:0] a, input integer max_polls, output reg timed_out);
        reg [15:0] pv; integer n; reg done;
        begin
            done = 0;
            for (n = 0; n < max_polls && !done; n = n + 1) begin
                flash_read(a, pv);
                if (((pv ^ 16'hFFFF) & 16'h8080) == 16'h0000) done = 1;
            end
            timed_out = !done;
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
    reg        t_o;
    integer cyc;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);
        set_ctl(16'h0000);                 // bank 0

        // 1) sanity: factory read (also proves the model wiring).
        flash_read(21'h40, v); chk(v, backing(23'h40), "factory word 0x40");

        // 2) stage NON-0xFF content inside and outside the region under test:
        //    bank0 sector1 (words 0x10000-0x1FFFF) gets two programmed words; a
        //    bank0 sector0 word and a bank1 sector1 word are isolation canaries.
        flash_program(21'h10000, 16'h1234);   // sector base: also the poll target
        flash_program(21'h10777, 16'hBEEF);
        flash_program(21'h00700, 16'hABCD);   // bank0 sector0: must survive
        set_ctl(16'h0001);                    // bank 1
        flash_program(21'h10040, 16'h5A5A);   // bank1 sector1: must survive
        set_ctl(16'h0000);                    // back to bank 0

        // 3) SECTOR ERASE bank0 sector1, then immediate status reads: AMD busy
        //    status on both lanes, DQ7=0, DQ6/DQ2 toggling per access, DQ3=1,
        //    DQ5=0 (0x4C4C / 0x0808 alternating, first read 0x4C4C), NO stall.
        flash_sector_erase(21'h10000);
        flash_read(21'h10000, v); chk(v, 16'h4C4C, "busy status read #1 (0x4C4C)");
        if (last_stall != 0) begin $display("FAIL: status read #1 must not stall"); errors=errors+1; end
        flash_read(21'h10000, v); chk(v, 16'h0808, "busy status read #2 (0x0808)");
        flash_read(21'h10000, v); chk(v, 16'h4C4C, "busy status read #3 (0x4C4C)");
        // any address of the busy bank returns status (Fujitsu/MAME semantics)
        flash_read(21'h00040, v); chk(v, 16'h0808, "busy status at other offset");

        // 4) idle banks stay LIVE while bank0 walks: autoselect ID check on bank1
        //    (what ddrsbm does on bank N+1 mid-erase) + a normal array line-fill.
        set_ctl(16'h0001);
        win_write(21'h555, 16'h00AA);
        win_write(21'h2AA, 16'h0055);
        win_write(21'h555, 16'h0090);
        flash_read(21'h000, v); chk(v, 16'h0404, "bank1 MFR id during bank0 walk");
        if (last_stall != 0) begin $display("FAIL: ID read must not stall during walk"); errors=errors+1; end
        flash_read(21'h001, v); chk(v, 16'hADAD, "bank1 DEV id during bank0 walk");
        win_write(21'h000, 16'h00F0);      // reset out of autoselect
        flash_read(21'h200, v); chk(v, backing({2'd1, 21'h200}), "bank1 array read during walk");
        if (last_stall == 0 || last_stall > 50) begin
            $display("FAIL: bank1 fill during walk should stall briefly (got %0d)", last_stall);
            errors = errors + 1;
        end
        set_ctl(16'h0000);

        // 5) completion via the game's own DQ7 poll, then full-region verify.
        //    The walker commits 64K words through the 5-cycle ch3 model, so allow
        //    generous polls; the poll flips to done on REAL array data (0xFFFF).
        dq7_poll(21'h10000, 250000, t_o);
        if (t_o) begin $display("FAIL: DQ7 poll TIMED OUT (the silicon ERASE TIMEOUT)"); errors=errors+1; end
        flash_read(21'h10000, v); chk(v, 16'hFFFF, "erased sector base");
        flash_read(21'h10001, v); chk(v, 16'hFFFF, "erased sector base+1");
        flash_read(21'h10777, v); chk(v, 16'hFFFF, "erased over programmed word");
        flash_read(21'h18000, v); chk(v, 16'hFFFF, "erased sector middle");
        flash_read(21'h1FFFF, v); chk(v, 16'hFFFF, "erased sector last word");
        // SDRAM commit, not just the line buffer: evict then re-read
        flash_read(21'h00900, v);
        flash_read(21'h10000, v); chk(v, 16'hFFFF, "erase base PERSISTED post-evict");
        // region bounds: neighbours untouched
        flash_read(21'h0FFFF, v); chk(v, backing(23'h0FFFF), "sector0 last word untouched");
        flash_read(21'h20000, v); chk(v, backing(23'h20000), "sector2 base untouched");
        flash_read(21'h00700, v); chk(v, 16'hABCD, "bank0 sector0 canary untouched");
        set_ctl(16'h0001);
        flash_read(21'h10040, v); chk(v, 16'h5A5A, "bank1 same-sector canary untouched");
        set_ctl(16'h0000);

        // 6) program-after-erase works and persists (the install's next phase).
        flash_program(21'h10100, 16'h5AA5);
        flash_read(21'h10100, v); chk(v, 16'h5AA5, "program after erase");
        flash_read(21'h00900, v);          // evict
        flash_read(21'h10100, v); chk(v, 16'h5AA5, "program after erase PERSISTED");

        // 7) writes to a BUSY chip-pair are ignored (MAME/JEDEC): program into
        //    bank0 sector3 mid-walk must be dropped; the word erases to 0xFFFF.
        flash_sector_erase(21'h30000);
        flash_program(21'h30040, 16'h1111);   // aimed at the busy bank -> dropped
        dq7_poll(21'h30000, 250000, t_o);
        if (t_o) begin $display("FAIL: sector3 DQ7 poll TIMED OUT"); errors=errors+1; end
        flash_read(21'h30040, v); chk(v, 16'hFFFF, "program during busy was ignored");

        // 8) CHIP erase (0x10) on bank1, scaled span (ERASE_CHIP_WORDS=4096):
        //    proves the chip-vs-sector region-bounds mux. Words inside the scaled
        //    span erase; words beyond it stay (at the real 2M default the whole
        //    bank would erase); bank0 is untouched.
        set_ctl(16'h0001);
        flash_chip_erase;
        flash_read(21'h00000, v); chk(v[7:0], 8'h4C, "bank1 chip-erase busy status");
        dq7_poll(21'h00000, 50000, t_o);
        if (t_o) begin $display("FAIL: chip-erase DQ7 poll TIMED OUT"); errors=errors+1; end
        flash_read(21'h00000, v); chk(v, 16'hFFFF, "chip-erased word 0");
        flash_read(21'h00FFF, v); chk(v, 16'hFFFF, "chip-erased last scaled word");
        flash_read(21'h00900, v); chk(v, 16'hFFFF, "chip-erased middle word");
        flash_read(21'h01000, v); chk(v, backing({2'd1, 21'h01000}), "beyond scaled span untouched");
        flash_read(21'h10040, v); chk(v, 16'h5A5A, "bank1 far word beyond scaled span");
        set_ctl(16'h0000);
        flash_read(21'h00700, v); chk(v, 16'hABCD, "bank0 canary after bank1 chip erase");

        // 9) THE ACTUAL DDRSBM SHAPE: the same sector erased on ALL 4 banks
        //    back-to-back (multi-bank er_busy queue + region chaining), with the
        //    installer's autoselect ID check run on each bank just before its
        //    erase -- i.e. on an idle bank while the previous banks still walk.
        //    Then per-bank status toggle independence, DQ7 polls on all 4, and
        //    full isolation canaries on the virgin banks.
        for (oi = 0; oi < 4; oi = oi + 1) begin
            set_ctl(oi[15:0]);                 // bank oi
            win_write(21'h000, 16'h00F0);      // F0 prefix (as the game does)
            win_write(21'h555, 16'h00AA);      // autoselect ID check
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h0090);
            flash_read(21'h000, v); chk(v, 16'h0404, "batch: MFR id before erase");
            flash_read(21'h001, v); chk(v, 16'hADAD, "batch: DEV id before erase");
            win_write(21'h000, 16'h00F0);
            flash_sector_erase(21'h20000);     // sector 2 of this bank
        end
        // per-bank DQ6 toggle independence: each bank's toggle is its own reg
        set_ctl(16'h0000);
        flash_read(21'h20000, v); chk(v[7:0], 8'h4C, "batch: bank0 status #1");
        set_ctl(16'h0003);
        flash_read(21'h20000, v);
        if (v !== 16'h4C4C && v !== 16'hFFFF) begin
            // bank3 may legitimately have finished if the walker raced ahead,
            // but its FIRST status read (if busy) must be 0x4C4C, not bank0's
            // toggled 0x0808 -- that's the per-bank independence check.
            $display("FAIL: batch bank3 status = %04h (expected 4C4C or FFFF)", v);
            errors = errors + 1;
        end
        set_ctl(16'h0000);
        flash_read(21'h20000, v);
        if (v !== 16'h0808 && v !== 16'hFFFF) begin
            $display("FAIL: batch bank0 status #2 = %04h (expected 0808 or FFFF)", v);
            errors = errors + 1;
        end
        // the game's poll loop: DQ7 on each bank's sector base until all done
        for (oi = 0; oi < 4; oi = oi + 1) begin
            set_ctl(oi[15:0]);
            dq7_poll(21'h20000, 250000, t_o);
            if (t_o) begin
                $display("FAIL: batch DQ7 poll bank %0d TIMED OUT", oi);
                errors = errors + 1;
            end
        end
        // read-verify samples + region bounds on every bank; canaries on the
        // virgin banks (2,3): sector1 last word and sector3 base stay factory
        for (oi = 0; oi < 4; oi = oi + 1) begin
            set_ctl(oi[15:0]);
            flash_read(21'h20000, v); chk(v, 16'hFFFF, "batch: erased sector base");
            flash_read(21'h28000, v); chk(v, 16'hFFFF, "batch: erased sector mid");
            flash_read(21'h2FFFF, v); chk(v, 16'hFFFF, "batch: erased sector last");
        end
        set_ctl(16'h0002);
        flash_read(21'h1FFFF, v); chk(v, backing({2'd2, 21'h1FFFF}), "bank2 below-sector canary");
        flash_read(21'h30000, v); chk(v, backing({2'd2, 21'h30000}), "bank2 above-sector canary");
        set_ctl(16'h0003);
        flash_read(21'h1FFFF, v); chk(v, backing({2'd3, 21'h1FFFF}), "bank3 below-sector canary");
        flash_read(21'h30000, v); chk(v, backing({2'd3, 21'h30000}), "bank3 above-sector canary");
        set_ctl(16'h0000);
        // SDRAM commit proof across the batch: evict then re-read two banks
        flash_read(21'h00900, v);
        flash_read(21'h20000, v); chk(v, 16'hFFFF, "batch bank0 PERSISTED post-evict");
        set_ctl(16'h0003);
        flash_read(21'h20000, v); chk(v, 16'hFFFF, "batch bank3 PERSISTED post-evict");
        set_ctl(16'h0000);

        if (errors == 0) $display("RESULT: PASS (s573_flash_erase)");
        else             $display("RESULT: FAIL (s573_flash_erase, %0d errors)", errors);
        $finish;
    end

    // Global watchdog: two full 64K-word sector walks + polls fit well inside.
    initial begin
        for (cyc = 0; cyc < 8000000; cyc = cyc + 1) @(posedge clk);
        $display("RESULT: FAIL (s573_flash_erase timeout -- handshake deadlock?)");
        $finish;
    end
endmodule
