// tb_s573_mp3_pcm.v - unit test for the HPS-PCM elastic buffer + 44100 Hz drain.
//
// Proves the load-bearing, no-mask behavior of the P4b(b) PCM slice WITHOUT any
// HW or HPS: a fake producer fills the buffer; the fixed 44100 Hz drain must emit
// exactly one pcm_sample_tick per REAL sample popped, in order, at the exact rate
// (768 clk_1x cycles apart, zero drift); and on starvation it must emit SILENCE
// with NO tick and a rising underrun_cnt (the counter freezes truthfully).
// `make PCM_FAKE_UNDERRUN=1 s573_mp3_pcm` compiles the doctrine-violating
// replay-and-tick behavior -> this TB is RED under it and GREEN by default (proof
// it exercises the doctrine, not a hand-reverted RTL).
//
// Phases: A one-tick-per-sample/order; B sustained-underrun RED/GREEN discriminator;
// C backpressure+overflow honesty; D idle-mute + clean-restart phase; E steady-state
// concurrent push+pop across >2 ring laps with EXACT 768-cycle inter-tick spacing;
// F slow producer (underrun-interleaved) integrity. E/F close the review's test gaps.
//
// Event-driven (wait-for-N-ticks), so checks do not depend on sub-cycle phase.
// Verilog-2005 / iverilog -g2005-sv.

`timescale 1ns/1ps
module tb_s573_mp3_pcm;
    localparam [31:0] CLKHZ  = 32'd33_868_800;  // clk_1x
    localparam [31:0] SRHZ   = 32'd44_100;      // 33_868_800 / 44_100 = 768 exactly
    localparam integer PERIOD = 768;            // clk_1x cycles per PCM sample
    localparam integer AW = 9;                  // 512-entry buffer

    reg         clk = 0, rst = 1;
    reg         wr_en = 0;
    reg  [15:0] wr_l = 0, wr_r = 0;
    reg         drain_en = 0;
    wire        wr_full;
    wire [AW:0] wr_level;
    wire [15:0] pcm_l, pcm_r;
    wire        pcm_sample_tick;
    wire [31:0] underrun_cnt, overflow_cnt;

    s573_mp3_pcm #(.CLK_HZ(CLKHZ), .SR_HZ(SRHZ), .AW(AW)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_l(wr_l), .wr_r(wr_r),
        .wr_full(wr_full), .wr_level(wr_level),
        .drain_en(drain_en),
        .pcm_l(pcm_l), .pcm_r(pcm_r), .pcm_sample_tick(pcm_sample_tick),
        .underrun_cnt(underrun_cnt), .overflow_cnt(overflow_cnt)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

    // ---- free-running cycle counter + tick capture (one block, no inter-block race) ----
    integer cyc = 0;
    integer tick_count = 0;
    reg [15:0] got_l   [0:2047];
    reg [15:0] got_r   [0:2047];
    integer    tick_cyc[0:2047];
    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        if (pcm_sample_tick) begin
            if (tick_count < 2048) begin
                got_l[tick_count]   = pcm_l;
                got_r[tick_count]   = pcm_r;
                tick_cyc[tick_count] = cyc;
            end
            tick_count = tick_count + 1;
        end
    end

    task push; input [15:0] l; input [15:0] r; begin
        @(negedge clk); wr_en = 1; wr_l = l; wr_r = r;
        @(negedge clk); wr_en = 0;
    end endtask

    integer rc;
    task run_cyc; input integer n; begin
        for (rc = 0; rc < n; rc = rc + 1) @(posedge clk);   // private counter (not `i`)
    end endtask

    integer w;
    task wait_ticks; input integer target; input integer limit; begin
        w = 0;
        while (tick_count < target && w < limit) begin @(posedge clk); w = w + 1; end
        if (tick_count < target) begin
            $display("FAIL: wait_ticks timeout (got %0d of %0d)", tick_count, target);
            errors = errors + 1;
        end
    end endtask

    task do_reset; begin
        rst = 1; run_cyc(2); @(negedge clk); rst = 0; run_cyc(2);
    end endtask

    integer u0, first_tick_cyc, push_idx, bad, dmin, dmax;

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        run_cyc(2);

        // =====================================================================
        // Phase A: one tick per REAL sample, in order, no false underrun while
        // data is available. Prefill 64, drain until exactly 64 ticks, stop.
        // =====================================================================
        for (i = 0; i < 64; i = i + 1)
            push(16'h1000 + i[15:0], 16'h2000 + i[15:0]);
        if (wr_level !== 11'd64) begin $display("FAIL: phaseA wr_level=%0d (exp 64)", wr_level); errors=errors+1; end
        if (underrun_cnt !== 32'd0) begin $display("FAIL: phaseA underrun before drain"); errors=errors+1; end

        drain_en = 1;
        wait_ticks(64, 70*PERIOD);
        @(negedge clk); drain_en = 0;
        if (tick_count !== 64) begin $display("FAIL: phaseA tick_count=%0d (exp 64)", tick_count); errors=errors+1; end
        if (underrun_cnt !== 32'd0) begin $display("FAIL: phaseA false underrun while data present (cnt=%0d)", underrun_cnt); errors=errors+1; end
        for (i = 0; i < 64 && i < tick_count; i = i + 1) begin
            if (got_l[i] !== (16'h1000 + i[15:0])) begin $display("FAIL: phaseA L[%0d]=%04h", i, got_l[i]); errors=errors+1; end
            if (got_r[i] !== (16'h2000 + i[15:0])) begin $display("FAIL: phaseA R[%0d]=%04h", i, got_r[i]); errors=errors+1; end
        end

        // =====================================================================
        // Phase B: sustained underrun = the no-mask discriminator (RED/GREEN).
        // Buffer empty, drain_en high. GREEN: NO ticks, pcm==0, underrun_cnt rises.
        // RED (PCM_FAKE_UNDERRUN): ticks keep firing -> this check FAILS.
        // =====================================================================
        u0 = underrun_cnt;
        tick_count = 0;
        drain_en = 1;
        run_cyc(20*PERIOD + (PERIOD/2));
        drain_en = 0;
        if (tick_count !== 0) begin
            $display("FAIL: phaseB NO-MASK VIOLATION -- %0d ticks with an empty buffer (fabricated clock)", tick_count);
            errors = errors + 1;
        end
        if (!(underrun_cnt > u0)) begin $display("FAIL: phaseB underrun_cnt did not track starvation (u0=%0d now=%0d)", u0, underrun_cnt); errors=errors+1; end
        if (pcm_l !== 16'd0 || pcm_r !== 16'd0) begin $display("FAIL: phaseB MP3 channel not silent during starvation"); errors=errors+1; end

        // =====================================================================
        // Phase C: backpressure + overflow are honest (drop + count, no corrupt).
        // =====================================================================
        do_reset;
        tick_count = 0;
        for (i = 0; i < 512; i = i + 1)
            push(16'h4000 + i[15:0], 16'h5000 + i[15:0]);
        if (wr_full !== 1'b1) begin $display("FAIL: phaseC wr_full not asserted at 512"); errors=errors+1; end
        if (wr_level !== 11'd512) begin $display("FAIL: phaseC wr_level=%0d (exp 512)", wr_level); errors=errors+1; end
        push(16'hDEAD, 16'hBEEF);
        if (overflow_cnt !== 32'd1) begin $display("FAIL: phaseC over-push not counted (cnt=%0d)", overflow_cnt); errors=errors+1; end
        if (wr_full !== 1'b1) begin $display("FAIL: phaseC wr_full dropped after over-push"); errors=errors+1; end
        drain_en = 1;
        wait_ticks(512, 520*PERIOD);
        @(negedge clk); drain_en = 0;
        if (tick_count !== 512) begin $display("FAIL: phaseC tick_count=%0d (exp 512)", tick_count); errors=errors+1; end
        for (i = 0; i < 512 && i < tick_count; i = i + 1)
            if (got_l[i] !== (16'h4000 + i[15:0]) || got_r[i] !== (16'h5000 + i[15:0])) begin
                $display("FAIL: phaseC drained data corrupted at %0d (L=%04h R=%04h)", i, got_l[i], got_r[i]);
                errors = errors + 1;
            end

        // =====================================================================
        // Phase D: idle mutes the MP3 channel + clean restart (correct phase).
        // =====================================================================
        do_reset;
        tick_count = 0;
        drain_en = 0;
        run_cyc(3*PERIOD);
        if (tick_count !== 0) begin $display("FAIL: phaseD ticked while idle"); errors=errors+1; end
        if (pcm_l !== 16'd0 || pcm_r !== 16'd0) begin $display("FAIL: phaseD MP3 channel not muted when idle"); errors=errors+1; end
        push(16'h55AA, 16'hAA55);
        drain_en = 1;
        first_tick_cyc = 0;
        while (tick_count === 0 && first_tick_cyc < 2*PERIOD) begin @(posedge clk); first_tick_cyc = first_tick_cyc + 1; end
        if (tick_count !== 1) begin $display("FAIL: phaseD no tick after restart"); errors=errors+1; end
        if (got_l[0] !== 16'h55AA || got_r[0] !== 16'hAA55) begin $display("FAIL: phaseD restart data wrong"); errors=errors+1; end
        if (!(first_tick_cyc >= (PERIOD-2) && first_tick_cyc <= (PERIOD+2))) begin
            $display("FAIL: phaseD first-tick phase = %0d (exp ~%0d)", first_tick_cyc, PERIOD);
            errors = errors + 1;
        end
        drain_en = 0;

        // =====================================================================
        // Phase E: steady-state CONCURRENT push+pop across >2 ring laps, with
        // EXACT 768-cycle inter-tick spacing (zero drift) and full data integrity.
        // Closes review gaps: concurrent read+write, rate/drift, second-lap wrap.
        // Producer pushes 1300 in-order samples (> 2*512) as fast as wr_full
        // allows while the 44100 drain runs -> buffer stays full, never underruns.
        // =====================================================================
        do_reset;
        tick_count = 0;
        u0 = underrun_cnt;                 // 0 after reset
        // cushion so the first ce never underruns, then enable drain
        for (i = 0; i < 40; i = i + 1)
            push(16'h8000 + i[15:0], 16'h9000 + i[15:0]);
        push_idx = 40;
        drain_en = 1;
        // interleave: each cycle push the next sample if there is room + more to send
        while (tick_count < 1300) begin
            @(negedge clk);
            if (push_idx < 1300 && !wr_full) begin
                wr_en = 1; wr_l = 16'h8000 + push_idx[15:0]; wr_r = 16'h9000 + push_idx[15:0];
                push_idx = push_idx + 1;
            end else wr_en = 0;
        end
        @(negedge clk); wr_en = 0;
        drain_en = 0;

        if (tick_count < 1300) begin $display("FAIL: phaseE only %0d ticks", tick_count); errors=errors+1; end
        if (underrun_cnt !== u0) begin $display("FAIL: phaseE underran a fed buffer (cnt=%0d, exp %0d)", underrun_cnt, u0); errors=errors+1; end
        // data integrity across >2 laps (indices 0..1299 cross 512 and 1024)
        bad = 0;
        for (i = 0; i < 1300; i = i + 1)
            if (got_l[i] !== (16'h8000 + i[15:0]) || got_r[i] !== (16'h9000 + i[15:0])) bad = bad + 1;
        if (bad !== 0) begin $display("FAIL: phaseE data corrupted across laps (%0d mismatches)", bad); errors=errors+1; end
        // EXACT rate: every consecutive inter-tick delta must be exactly PERIOD (768)
        dmin = 1<<30; dmax = 0; bad = 0;
        for (i = 1; i < 1300; i = i + 1) begin
            w = tick_cyc[i] - tick_cyc[i-1];
            if (w < dmin) dmin = w;
            if (w > dmax) dmax = w;
            if (w !== PERIOD) bad = bad + 1;
        end
        if (bad !== 0 || dmin !== PERIOD || dmax !== PERIOD) begin
            $display("FAIL: phaseE inter-tick spacing not exactly %0d (bad=%0d min=%0d max=%0d) -- rate drift", PERIOD, bad, dmin, dmax);
            errors = errors + 1;
        end
        // span of N ticks == (N-1)*PERIOD, the zero-drift invariant
        if ((tick_cyc[1299] - tick_cyc[0]) !== (1299*PERIOD)) begin
            $display("FAIL: phaseE 1300-tick span=%0d (exp %0d)", tick_cyc[1299]-tick_cyc[0], 1299*PERIOD);
            errors = errors + 1;
        end

        // =====================================================================
        // Phase F: SLOW producer -> the buffer repeatedly empties + refills, so
        // pushes land at many phase offsets vs the drain ce (including on/near a
        // starved ce). Every tick must still carry the correct real sample in
        // order (no drop/dup/fabricate), and starvation must be counted.
        // =====================================================================
        do_reset;
        tick_count = 0;
        u0 = underrun_cnt;
        drain_en = 1;
        for (i = 0; i < 40; i = i + 1) begin
            push(16'h6000 + i[15:0], 16'h7000 + i[15:0]);
            run_cyc(1000);                 // slower than the 768 drain -> underruns between
        end
        wait_ticks(40, 4*PERIOD);
        @(negedge clk); drain_en = 0;
        if (tick_count !== 40) begin $display("FAIL: phaseF tick_count=%0d (exp 40, no drop/dup/fabricate)", tick_count); errors=errors+1; end
        if (!(underrun_cnt > u0)) begin $display("FAIL: phaseF expected underruns between slow pushes"); errors=errors+1; end
        for (i = 0; i < 40 && i < tick_count; i = i + 1)
            if (got_l[i] !== (16'h6000 + i[15:0]) || got_r[i] !== (16'h7000 + i[15:0])) begin
                $display("FAIL: phaseF data wrong at %0d (L=%04h R=%04h)", i, got_l[i], got_r[i]);
                errors = errors + 1;
            end

        if (errors == 0) $display("RESULT: PASS (s573_mp3_pcm)");
        else             $display("RESULT: FAIL (s573_mp3_pcm, %0d errors)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("RESULT: FAIL (s573_mp3_pcm, TIMEOUT)");
        $finish;
    end
endmodule
