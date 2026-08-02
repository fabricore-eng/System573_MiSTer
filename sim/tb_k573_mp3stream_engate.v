`timescale 1ns/1ps
// Testbench for k573_mp3stream.v - ENABLE-GATING pause/resume fidelity.
//
// THE BUG THIS GUARDS (found 2026-07-29 by cross-checking the RTL against MAME
// during the P4b decision-B spike; see docs/2026-07-29-p4b-decision-b-spike-result.md):
//
//   The key schedule advances on `word_stb` (S_STB) but `cur` advances two states
//   later (S_LO). The pre-fix streamer unwound to S_IDLE from ANY state on an
//   fpga_ctrl bit13/14 disable, so a disable landing in that window left the
//   schedule advanced for a word the stream had not finished with. On re-enable it
//   re-read the SAME cur and re-descrambled that word with an ALREADY-ADVANCED
//   schedule -- corrupting every byte after the pause and emitting one EXTRA byte
//   (2N instead of 2N-1). MAME buffers the decrypted word and simply stops running
//   update_stream() while disabled, so it never re-reads.
//
// THE INVARIANT: an enable-bit pause is TRANSPARENT. Pausing anywhere, for any
// length, must yield a byte stream IDENTICAL to the uninterrupted one -- same bytes,
// same count, same byte_counter. Nothing about where the pause lands may be
// observable in the output.
//
// PART 1 -- THE SWEEP. The bug only bites when the pause lands in the S_STB..S_LO
// window, a minority of cycles, so a single hand-placed pause passes ~80% of the
// time and would have shipped it. This sweeps a pause across the live span of the
// stream at every cycle offset, at two pause lengths, in BOTH descramble schemes.
// It reaches the S_HI/S_LO emit window and the S_ADDR/S_REQ bail-out states; it does
// NOT claim to park a pause in every FSM state (S_STB/S_CAP are single-cycle
// pass-through with no emit_en-dependent behaviour, and are covered by part 2).
// A coverage guard counts pauses that actually landed on a RUNNING FSM and fails if
// that count collapses -- otherwise a future pacing change could quietly hollow the
// sweep out into a row of no-ops that still says PASS.
//
// PART 2 -- THE S_LO HOLD. The sweep alone does NOT pin the whole fix: removing just
// the `if (!emit_en)` hold in S_LO leaves the sweep 0/360 GREEN (measured), because
// the last-word retire does not depend on `accept` and so is invisible to a
// byte-stream comparison that never reaches it while paused. The directed
// hold_guard() case below parks the FSM in S_LO on the FINAL word, pauses with bit14
// still set, and asserts via fpga_ctrl_rb that `cur` did NOT retire. Without the
// hold, cur advances past mp3_end while paused and the game-visible "still
// streaming" bit drops early.
//
// `make MP3_ENGATE_BUG=1 k573_mp3stream_engate` compiles the pre-fix unwind-from-any-
// state behaviour. This bench is RED under it and GREEN by default -- proof it
// exercises the fix without hand-reverting RTL.
//
// NOTE on the reference model: r_common/r_derive/r_spread below mirror the RTL's own
// functions, so the descrambled byte VALUES are self-confirming, not independently
// validated (the same caveat as sim/tb_k573_mp3dec.v). That is acceptable here
// because the property under test is ORDERING -- the schedule model is a plain
// per-word loop with no FSM, so it cannot reproduce an FSM re-read bug. Value
// fidelity to MAME is established separately (see the decision-B spike doc).
module tb_k573_mp3stream_engate;
    localparam integer NWORDS       = 8;
    localparam integer NBYTES       = 2*NWORDS - 1;   // MAME's 2N-1
    localparam integer TRIAL_CYCLES = 400;
    localparam integer SWEEP_LAST   = 110;   // live span measured at <=99; margin to 110
    localparam integer MIN_LIVE     = 300;   // coverage floor across all 4 sweeps
    localparam integer MAX_REPORT   = 12;

    // mirror of the DUT's state encoding (for the directed S_LO case)
    localparam [2:0] S_IDLE_C = 3'd0, S_HI_C = 3'd6, S_LO_C = 3'd7;

    reg        clk = 0, rst = 1;
    reg [15:0] fpga_ctrl = 0;
    reg [24:0] mp3_start = 0, mp3_end = 2*NWORDS;
    reg [15:0] key1 = 16'h1357, key2 = 16'h2468, key3 = 16'h9BDF;
    reg        reload = 0;
    reg        out_ready = 0;
    reg        sbm = 1'b0;                   // descramble scheme under test

    wire [24:0] rd_addr;
    wire        rd_req;
    wire [7:0]  out_byte;
    wire        out_valid;
    wire [31:0] byte_counter;
    wire [15:0] fpga_ctrl_rb;

    integer errors = 0, reported = 0, trials = 0, live_pauses = 0, ctl_errors = 0;

    // ---- DRAM model: rotating 0..3-cycle latency, data registered and held until
    // the next request (the k573dio backing contract, sim and DDR3 modes alike).
    reg [15:0] mem [0:NWORDS-1];
    reg [15:0] rd_data_r = 16'd0;
    reg        rd_ready_r = 1'b0;
    reg [1:0]  srv_lat = 2'd0, srv_cnt = 2'd0;
    always @(posedge clk) begin
        rd_ready_r <= 1'b0;
        if (rst) begin
            srv_cnt <= 2'd0;
        end else if (rd_req && !rd_ready_r) begin
            if (srv_cnt == srv_lat) begin
                rd_data_r  <= mem[rd_addr >> 1];
                rd_ready_r <= 1'b1;
                srv_cnt    <= 2'd0;
                srv_lat    <= srv_lat + 2'd1;
            end else
                srv_cnt <= srv_cnt + 2'd1;
        end
    end

    // ---- paced sink: out_ready high 1-of-4 cycles (MAS3507D DEMAND bursts).
    // Deliberately INDEPENDENT of fpga_ctrl -- the sink does not know the game
    // paused. Under the pre-fix RTL that is exactly how the extra byte escapes.
    reg [1:0] rdy_cnt = 2'd0;
    always @(posedge clk) begin
        if (rst) begin rdy_cnt <= 2'd0; out_ready <= 1'b0; end
        else begin
            rdy_cnt   <= rdy_cnt + 2'd1;
            out_ready <= (rdy_cnt == 2'd0);
        end
    end

    k573_mp3stream dut (
        .clk(clk), .rst(rst), .fpga_ctrl(fpga_ctrl), .ddrsbm(sbm),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .key1(key1), .key2(key2), .key3(key3), .reload(reload),
        .rd_addr(rd_addr), .rd_req(rd_req),
        .rd_data(rd_data_r), .rd_ready(rd_ready_r),
        .out_ready(out_ready), .out_byte(out_byte), .out_valid(out_valid),
        .byte_counter(byte_counter), .fpga_ctrl_rb(fpga_ctrl_rb)
    );

    always #5 clk = ~clk;

    // ---- descramble reference (both schemes) ----
    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d; begin
            d = 16'd0;
            for (i=0;i<8;i=i+1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555); end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r=s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2];
        r_derive=r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7];
        r_spread=r; end
    endfunction

    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [7:0]  expb [0:2*NWORDS-1];
    reg [7:0]  gotb [0:127];
    integer    gi = 0, i, c, t, plen, guard, sch;

    always @(posedge clk) if (!rst && out_valid && out_ready && gi < 128) begin
        gotb[gi] = out_byte; gi = gi + 1;
    end

    // rebuild the expected byte stream for the currently selected scheme
    task build_ref;
        begin
            sk1=key1; sk2=key2; sk3=key3;
            for (i=0;i<NWORDS;i=i+1) begin
                if (sbm) begin
                    dval = r_common(mem[i], sk1);
                    sk1  = {sk1[14:0], sk1[15]};
                end else begin
                    dk   = r_derive(sk1 ^ sk2);
                    dval = r_common(mem[i], dk) ^ r_spread(sk3);
                    if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
                    sk1 = {sk1[15], sk1[13:0], sk1[14]};
                    sk3 = sk3 + 16'd1;
                end
                expb[2*i]   = dval[15:8];
                expb[2*i+1] = dval[7:0];
            end
        end
    endtask

    // bring the DUT up: reset, seed the key schedule via a setup-register write
    // (MAME update_mp3_decode_state), then enable
    task arm;
        begin
            fpga_ctrl = 16'h0000;
            @(negedge clk); rst = 1'b1;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            gi = 0;
            @(negedge clk); reload = 1'b1; @(negedge clk); reload = 1'b0;
            repeat (2) @(posedge clk);
            fpga_ctrl = 16'h6000;              // MP3_ENABLE | STREAMING_ENABLE
        end
    endtask

    // one swept trial. fpga_ctrl is driven on the NEGEDGE so the control word is
    // stable across the sampling edge -- matching the real registered fpga_ctrl in
    // k573dio.v, and avoiding a same-delta race that would bias which FSM states the
    // pause can land in.  pause_at > TRIAL_CYCLES = the no-pause control.
    task run_trial(input integer pause_at, input integer pause_len);
        begin
            trials = trials + 1;
            arm;
            for (c = 1; c <= TRIAL_CYCLES; c = c + 1) begin
                @(negedge clk);
                if (c == pause_at) begin
                    fpga_ctrl = 16'h0000;
                    if (dut.state !== S_IDLE_C) live_pauses = live_pauses + 1;
                end
                if (c == pause_at + pause_len) fpga_ctrl = 16'h6000;
            end
            fpga_ctrl = 16'h6000;              // a pause never outlives its trial
            repeat (64) @(posedge clk);
        end
    endtask

    task check_trial(input integer pause_at, input integer pause_len);
        integer k; reg bad;
        begin
            bad = 1'b0;
            if (gi !== NBYTES) begin
                bad = 1'b1;
                if (reported < MAX_REPORT)
                    $display("FAIL: sbm=%0d pause@%0d len=%0d -> %0d bytes (expected %0d)%s",
                             sbm, pause_at, pause_len, gi, NBYTES,
                             (gi > NBYTES) ? "  <-- EXTRA byte: word re-read after resume" : "");
            end
            for (k = 0; k < NBYTES && k < gi; k = k + 1)
                if (gotb[k] !== expb[k]) begin
                    if (!bad && reported < MAX_REPORT)
                        $display("FAIL: sbm=%0d pause@%0d len=%0d -> byte[%0d]=%02h expected %02h  <-- key schedule desync",
                                 sbm, pause_at, pause_len, k, gotb[k], expb[k]);
                    bad = 1'b1;
                    k = NBYTES;                // report the FIRST divergence only
                end
            if (!bad && byte_counter !== NBYTES) begin
                bad = 1'b1;
                if (reported < MAX_REPORT)
                    $display("FAIL: sbm=%0d pause@%0d len=%0d -> byte_counter=%0d (expected %0d)",
                             sbm, pause_at, pause_len, byte_counter, NBYTES);
            end
            if (bad) begin
                errors   = errors + 1;
                reported = reported + 1;
                if (reported == MAX_REPORT) $display("       (further failures suppressed)");
            end
        end
    endtask

    // PART 2: pin the S_LO hold specifically. Park the FSM in S_LO on the FINAL word
    // (reached only after the high byte is accepted), then pause with bit14 STILL SET
    // so fpga_ctrl_rb remains a live window indicator. With the hold, cur must not
    // retire -> rb stays 0x1000. Without it, the last-word branch fires while paused,
    // cur passes mp3_end, and rb drops to 0x0000 -- the game sees the song end early.
    task hold_guard;
        begin
            trials = trials + 1;
            arm;
            guard = 0;
            // Sample on the NEGEDGE, where state / out_valid / the registered
            // out_ready are all settled -- reading them at the posedge races the
            // very NBA updates we are trying to observe.  Wait for the negedge at
            // which the LAST word's high byte is poised to be accepted.
            while (!(dut.state === S_HI_C && dut.last_word && out_valid && out_ready)
                   && guard < 4000) begin
                @(negedge clk); guard = guard + 1;
            end
            @(posedge clk);          // that byte is consumed here; FSM -> S_LO
            @(negedge clk);          // settle, still inside the S_LO cycle
            if (guard >= 4000 || dut.state !== S_LO_C) begin
                $display("FAIL: sbm=%0d hold_guard could not park in S_LO on the last word (state=%0d guard=%0d)",
                         sbm, dut.state, guard);
                errors = errors + 1;
            end else begin
                fpga_ctrl = 16'h4000;                      // bit14 set, bit13 clear
                repeat (8) @(posedge clk);
                // With the hold, cur has NOT retired -> the window is still live.
                // Without it, the last-word branch fired while paused, cur passed
                // mp3_end, and the game-visible "still streaming" bit drops early.
                if (fpga_ctrl_rb !== 16'h1000) begin
                    $display("FAIL: sbm=%0d S_LO hold missing -- cur retired while paused (fpga_ctrl_rb=%04h, expected 1000)",
                             sbm, fpga_ctrl_rb);
                    errors = errors + 1;
                end
                // the last word contributes ONLY its high byte (2N-1), so the full
                // count is already reached before the pause
                if (gi !== NBYTES) begin
                    $display("FAIL: sbm=%0d S_LO hold: %0d bytes emitted before the pause (expected %0d)",
                             sbm, gi, NBYTES);
                    errors = errors + 1;
                end
                @(negedge clk); fpga_ctrl = 16'h6000;      // resume: must retire cleanly
                repeat (32) @(posedge clk);
                if (gi !== NBYTES) begin
                    $display("FAIL: sbm=%0d S_LO hold: %0d bytes after resume (expected %0d)", sbm, gi, NBYTES);
                    errors = errors + 1;
                end
                if (fpga_ctrl_rb !== 16'h0000) begin
                    $display("FAIL: sbm=%0d S_LO hold: still streaming after resume+retire (rb=%04h)", sbm, fpga_ctrl_rb);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        mem[0]=16'h1234; mem[1]=16'h5678; mem[2]=16'h9ABC; mem[3]=16'hDEF0;
        mem[4]=16'h0F1E; mem[5]=16'h2D3C; mem[6]=16'h4B5A; mem[7]=16'h6978;

        for (sch = 0; sch <= 1; sch = sch + 1) begin
            sbm = sch[0];
            build_ref;

            // positive control FIRST: with no pause the bench must pass CLEANLY.
            // Captures the error count so a wrong-VALUE control aborts too, not just
            // a wrong-COUNT one.
            ctl_errors = errors;
            run_trial(TRIAL_CYCLES + 100, 4);
            check_trial(TRIAL_CYCLES + 100, 4);
            if (errors !== ctl_errors) begin
                $display("FAIL: sbm=%0d no-pause control did not stream cleanly -- rig broken, sweep meaningless", sbm);
                $display("RESULT: FAIL (k573_mp3stream_engate)");
                $finish;
            end

            // the sweep: a pause at every cycle offset across the live span, two
            // lengths. Short (3) can sit inside one FSM state; long (17) spans
            // several and covers the sink's 4-cycle DEMAND period.
            for (plen = 3; plen <= 17; plen = plen + 14)
                for (t = 1; t <= SWEEP_LAST; t = t + 1) begin
                    run_trial(t, plen);
                    check_trial(t, plen);
                end

            hold_guard;                        // part 2
        end

        // Coverage guard: a sweep of no-ops would still read PASS. Fail loudly if the
        // pauses stopped landing on a running FSM.
        $display("k573_mp3stream_engate: %0d trials, %0d live pauses (floor %0d), %0d failed",
                 trials, live_pauses, MIN_LIVE, errors);
        if (live_pauses < MIN_LIVE) begin
            $display("FAIL: coverage collapsed -- only %0d pauses landed on a RUNNING FSM (need >= %0d).",
                     live_pauses, MIN_LIVE);
            $display("      The sweep has gone vacuous; widen SWEEP_LAST or check the pacing model.");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (k573_mp3stream_engate)");
        else             $display("RESULT: FAIL (k573_mp3stream_engate, %0d errors)", errors);
        $finish;
    end
endmodule
