`timescale 1ns/1ps
// Testbench for the k573dio MP3 re-arm pulse TIMING -- driven through the REAL
// k573dio register bus, not the streamer's ports.
//
// THE BUG THIS GUARDS (pre-existing; found 2026-07-29 reviewing 45b09e8, NOT
// introduced by it -- the same repro fails identically against HEAD~2's streamer):
//
//   `mp3_reload` in k573dio.v is COMBINATIONAL on the bus write (sel && we && off ==
//   one of a0/a2/a4/a6/a8/ea/ec), while the register the write updates lands
//   NON-BLOCKING on that SAME posedge (`mp3_start[15:0] <= din`). k573_mp3stream does
//   `cur <= mp3_start` on that same edge in its do_reinit branch, so it samples the
//   PRE-write mp3_start: the stream re-arms to the address of the PREVIOUS song.
//   MAME cannot have this -- k573dio.cpp stores the register FIRST and only then calls
//   update_mp3_decode_state(), so its mp3_cur_addr always gets the NEW mp3_start.
//
// It is a LAST-WRITE bug: any further setup write re-pulses reload and self-heals it
// (the reload list includes the three key registers), so it only bites when a0 or a2
// closes the burst. That is exactly why nothing in the 45-test suite saw it --
// tb_k573dio's stream case writes mp3_start = 0 (stale == correct == 0) and ends its
// burst on 0xa6, and tb_k573_mp3stream / _engate drive the streamer's `reload` port
// directly, bypassing k573dio's pulse entirely. Only a bench on the real bus that ends
// the burst on a START write can see it.
//
// WHAT EACH PHASE PINS. Every phase disables streaming first, then writes a full
// setup burst, then enables -- so what is under test is the burst's LAST write, not
// any enable-edge interaction (that is tb_k573_mp3stream_engate's job).
//   P1  a2 (start LOW) last, stale start INSIDE the window  -> the stream plays the
//       WRONG DRAM REGION and runs long (garbage audio: 2*20-1 bytes from word 0
//       instead of 2*4-1 from word 16).
//   P2  a0 (start HIGH) last, stale start OUTSIDE the window -> the stream never
//       starts at all and the game-visible "still streaming" bit (0xae readback
//       0x1000) never rises: a hung song, not a corrupt one.
//   P3  CONTROL, passes in BOTH builds: the same a2-last burst plus one trailing key
//       write. This is the self-heal that hid the bug -- it must keep working.
//   P4  CONTROL, passes in BOTH builds: the mp3_end-EXTENSION re-arm that
//       tb_k573_mp3stream phase 2 pins, re-checked here through the bus, so the
//       one-cycle pulse delay cannot silently break it.
//
// `make MP3_RELOAD_RACE=1 dio_mp3_reload` compiles k573dio.v with -DMP3_RELOAD_RACE,
// restoring the same-edge pulse. This bench is RED under it (P1 + P2) and GREEN by
// default -- proof it exercises the fix without hand-reverting RTL.
//
// NOTE on the reference model: r_common/r_derive/r_spread mirror the RTL's own
// functions, so the descrambled byte VALUES are self-confirming, not independently
// validated (same caveat as tb_k573dio / tb_k573_mp3stream_engate). That is fine here
// because the property under test is WHICH ADDRESS the stream re-armed to; value
// fidelity to MAME is established separately (docs/2026-07-29-p4b-decision-b-spike-result.md).
module tb_dio_mp3_reload;
    localparam integer NW = 24;                 // DRAM words seeded (word 0..23)

    // the NEW song: bytes 0x20..0x27 -> words 16..19 (4 words -> 2*4-1 = 7 bytes)
    localparam [15:0] NEW_START_HI = 16'h0000, NEW_START_LO = 16'h0020;
    localparam [15:0] NEW_END_HI   = 16'h0000, NEW_END_LO   = 16'h0028;
    localparam integer NEW_SW = 16, NEW_NW = 4;

    localparam [15:0] KEY1 = 16'h1357, KEY2 = 16'h2468, KEY3 = 16'h9BDF;

    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [7:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire [31:0] mp3_start_w, mp3_end_w;
    wire [15:0] cfg_epoch_w;
    reg  [15:0] ep0, ep1;
    reg         cfg_ddrsbm_r = 1'b0;
    wire [7:0]  mp3_out_byte;
    wire        mp3_out_valid;
    integer errors = 0;

    k573dio #(.RAM_WORDS(4096), .DS_SERIAL(48'hABCD_EF12_3456), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(),
        .dio_wait(), .cfg_ddrsbm(cfg_ddrsbm_r),
        .mem_rd_req(), .mem_rd_addr(), .mem_rd_q(64'd0), .mem_rd_ack(1'b0),
        .mem_wr_req(), .mem_wr_addr(), .mem_wr_data(), .mem_wr_ack(1'b0),
        .dbg_wfifo_ovf(),
        .crypto_key1(), .crypto_key2(), .crypto_key3(),
        .mp3_start(mp3_start_w), .mp3_end(mp3_end_w),
        .fpga_ctrl(), .network_id(),
        .cfg_epoch(cfg_epoch_w), .mp3_cur_pos(),
        // always-ready sink: the pacing contract is tb_k573_mp3stream's job, this
        // bench is about WHICH address the stream re-armed to.
        .mp3_out_ready(1'b1),
        .mp3_out_byte(mp3_out_byte), .mp3_out_valid(mp3_out_valid),
        .dec_frame_sync(1'b0), .dec_frame_idle(1'b0), .pcm_sample_tick(1'b0)
    );

    always #5 clk = ~clk;

    task bus_write(input [7:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; off=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task bus_read(input [7:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; off=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask

    // ---- byte capture (out_ready is tied high, so every out_valid is an accept) ----
    reg [7:0]  got [0:127];
    integer    gi = 0;
    always @(posedge clk) if (!rst && mp3_out_valid && gi < 128) begin
        got[gi] = mp3_out_byte; gi = gi + 1;
    end

    // ---- the game-visible "still streaming" bit: exactly what a 0xae read returns ----
    reg rb_live = 1'b0;
    always @(posedge clk) if (!rst && dut.fpga_ctrl_rb == 16'h1000) rb_live <= 1'b1;

    // ---- descramble reference (default scheme, cfg_ddrsbm=0; mirrors k573_mp3dec) ----
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

    reg [15:0] mem [0:NW-1];               // mirror of what we pushed into board DRAM
    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [7:0]  expb [0:2*NW-1];
    integer    exp_n;
    reg [7:0]  decoy_b0;                   // first byte of the STALE-region stream
    reg [15:0] v;
    integer    i, k;

    function [15:0] pat(input integer n); begin
        pat = 16'hC000 + n[15:0] * 16'h0321;   // distinct per word
    end endfunction

    task seed_dram;
        begin
            bus_write(8'hb0, 16'h0000); bus_write(8'hb2, 16'h0000);   // DRAM write ptr = 0
            for (i = 0; i < NW; i = i + 1) begin
                mem[i] = pat(i);
                bus_write(8'hb4, mem[i]);
            end
        end
    endtask

    // expected byte stream for an n-word window starting at word sw, keys fresh
    // (a reload re-seeds the schedule from crypto_key1/2/3). MAME feeds 2n-1 bytes.
    task build_ref(input integer sw, input integer n);
        begin
            sk1=KEY1; sk2=KEY2; sk3=KEY3;
            for (i = 0; i < n; i = i + 1) begin
                dk   = r_derive(sk1 ^ sk2);
                dval = r_common(mem[sw+i], dk) ^ r_spread(sk3);
                expb[2*i]   = dval[15:8];
                expb[2*i+1] = dval[7:0];
                if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
                sk1 = {sk1[15], sk1[13:0], sk1[14]};
                sk3 = sk3 + 16'd1;
            end
            exp_n = 2*n - 1;
        end
    endtask

    task keys_and_end;                     // the non-START part of a setup burst
        begin
            bus_write(8'ha8, KEY1); bus_write(8'hea, KEY2); bus_write(8'hec, KEY3);
            bus_write(8'ha4, NEW_END_HI); bus_write(8'ha6, NEW_END_LO);
        end
    endtask

    task arm_start;                        // ready a phase: park, disable, clear capture
        begin
            bus_write(8'hae, 16'h0000);    // streaming OFF for the whole setup burst
            repeat (4) @(posedge clk);
            gi = 0; rb_live = 1'b0;
        end
    endtask

    // the register really did take the write; only `cur` lagged. Reported together so
    // a failure reads like the original repro line.
    task chk_cur(input [127:0] tag, input [24:0] want);
        begin
            repeat (2) @(negedge clk);     // settle: the fixed pulse lands 1 cycle late
            if (dut.u_stream.cur !== want) begin
                $display("FAIL: %0s: after the setup burst mp3_start=%0d but u_stream.cur=%0d (expected %0d)",
                         tag, mp3_start_w[24:0], dut.u_stream.cur, want);
                errors = errors + 1;
            end
            if (mp3_start_w[24:0] !== want) begin
                $display("FAIL: %0s: mp3_start register itself is %0d (expected %0d) -- bench wrote the wrong burst",
                         tag, mp3_start_w[24:0], want);
                errors = errors + 1;
            end
        end
    endtask

    task check_stream(input [127:0] tag);
        reg bad;
        begin
            bad = 1'b0;
            if (gi !== exp_n) begin
                bad = 1'b1;
                $display("FAIL: %0s: streamed %0d bytes (expected %0d = 2N-1)%0s",
                         tag, gi, exp_n,
                         (gi == 0)     ? "  <-- never started: stale start outside [start,end)" :
                         (gi > exp_n)  ? "  <-- ran long: re-armed to a STALE start address" : "");
            end
            for (k = 0; k < exp_n && k < gi; k = k + 1)
                if (got[k] !== expb[k]) begin
                    if (!bad)
                        $display("FAIL: %0s: byte[%0d]=%02h expected %02h  <-- streamed the WRONG DRAM region",
                                 tag, k, got[k], expb[k]);
                    bad = 1'b1;
                    k = exp_n;             // first divergence only
                end
            if (!rb_live) begin
                bad = 1'b1;
                $display("FAIL: %0s: the 0xae 'still streaming' bit never rose -- the game would hang on its poll", tag);
            end
            if (bad) errors = errors + 1;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        seed_dram;

        // Anti-vacuity guard: P1's value check only discriminates if the stale region
        // descrambles to a DIFFERENT first byte than the intended one. Pin that, so a
        // future change to `pat` cannot hollow the discriminator out into a no-op.
        build_ref(0, 1);        decoy_b0 = expb[0];
        build_ref(NEW_SW, 1);
        if (decoy_b0 === expb[0]) begin
            $display("FAIL: rig broken -- word 0 and word %0d descramble to the same first byte (%02h);",
                     NEW_SW, decoy_b0);
            $display("      P1 could not tell a stale-address stream from a correct one.");
            errors = errors + 1;
        end

        // ---------------------------------------------------------------------
        // P1 -- a2 (start LOW) last, stale start INSIDE the window.
        // Previous song started at byte 0; the new burst ends on the 0xa2 write.
        // Buggy: cur re-arms to 0 (< end 0x28) -> 20 words of the wrong region.
        // ---------------------------------------------------------------------
        arm_start;
        bus_write(8'ha0, 16'h0000); bus_write(8'ha2, 16'h0000);   // "previous song" @ 0
        keys_and_end;
        bus_write(8'ha0, NEW_START_HI);
        bus_write(8'ha2, NEW_START_LO);                            // <-- LAST write
        chk_cur("P1 a2-last", NEW_START_LO);
        gi = 0; rb_live = 1'b0;
        build_ref(NEW_SW, NEW_NW);
        bus_write(8'hae, 16'h6000);                                // MP3_ENABLE|STREAMING
        repeat (400) @(posedge clk);
        check_stream("P1 a2-last");
        bus_read(8'hae, v);
        if (v !== 16'h0000) begin
            $display("FAIL: P1 a2-last: 0xae = %04h after the window drained (expected 0000)", v);
            errors = errors + 1;
        end

        // ---------------------------------------------------------------------
        // P2 -- a0 (start HIGH) last, stale start OUTSIDE the window.
        // Previous song started at byte 0x10000; the new burst sets the low word
        // first, then closes on 0xa0. Buggy: cur re-arms to {old a0, new a2} =
        // 0x10020 >= end 0x28 -> the FSM never leaves S_IDLE and 0xae never reads
        // 0x1000, so the game's "is the song still playing" poll never goes true.
        // ---------------------------------------------------------------------
        arm_start;
        bus_write(8'ha0, 16'h0001); bus_write(8'ha2, 16'h0000);   // "previous song" @ 0x10000
        keys_and_end;
        bus_write(8'ha2, NEW_START_LO);
        bus_write(8'ha0, NEW_START_HI);                            // <-- LAST write
        chk_cur("P2 a0-last", NEW_START_LO);
        gi = 0; rb_live = 1'b0;
        build_ref(NEW_SW, NEW_NW);
        bus_write(8'hae, 16'h6000);
        repeat (400) @(posedge clk);
        check_stream("P2 a0-last");

        // ---------------------------------------------------------------------
        // P3 -- CONTROL (green in BOTH builds): the self-heal that hid the bug.
        // Same a2-last burst, plus one trailing key write; that write re-pulses
        // reload against an already-updated mp3_start, so cur lands correctly even
        // with the same-edge pulse. It must keep working after the fix.
        // ---------------------------------------------------------------------
        arm_start;
        bus_write(8'ha0, 16'h0000); bus_write(8'ha2, 16'h0000);
        keys_and_end;
        bus_write(8'ha0, NEW_START_HI);
        bus_write(8'ha2, NEW_START_LO);
        bus_write(8'ha8, KEY1);                                    // trailing key write
        chk_cur("P3 self-heal", NEW_START_LO);
        gi = 0; rb_live = 1'b0;
        build_ref(NEW_SW, NEW_NW);
        bus_write(8'hae, 16'h6000);
        repeat (400) @(posedge clk);
        check_stream("P3 self-heal");

        // ---------------------------------------------------------------------
        // P4 -- CONTROL (green in BOTH builds): the mp3_end EXTENSION re-arm that
        // tb_k573_mp3stream phase 2 pins, re-checked through the real bus. The
        // stream is parked at end 0x28; extending end to 0x30 with 0xa6 as the LAST
        // write must re-arm from mp3_start (MAME update_mp3_decode_state: cur<-start)
        // and re-stream the longer window. mp3_start is unchanged here, so this is a
        // regression guard on the pulse delay, not a discriminator.
        // ---------------------------------------------------------------------
        arm_start;
        bus_write(8'ha6, 16'h0030);                                // extend end: 0x28 -> 0x30
        chk_cur("P4 end-extend", NEW_START_LO);
        gi = 0; rb_live = 1'b0;
        build_ref(NEW_SW, 8);                                      // words 16..23
        bus_write(8'hae, 16'h6000);
        repeat (400) @(posedge clk);
        check_stream("P4 end-extend");

        // ---------- P5: cfg_epoch (P4b option (c)) ----------
        // The HPS re-reads CMD_573_MP3CFG only when this MOVES, so it must tick
        // on EVERY re-arm and on nothing else. A missed tick = the HPS keeps
        // descrambling the next song with the previous song's keys, which is
        // silent noise with every honesty counter still GREEN. A COUNTER, not a
        // sticky bit: two song changes between polls must not look like one.
        // A DRAM-pointer write mirrors nothing the HPS holds -> must NOT tick.
        ep0 = cfg_epoch_w;
        bus_write(8'hb0, 16'h0000);
        bus_write(8'hb2, 16'h0000);
        @(negedge clk);
        if (cfg_epoch_w !== ep0) begin
            $display("FAIL: P5 cfg_epoch moved on a NON-mirrored write (%0d -> %0d)", ep0, cfg_epoch_w);
            errors = errors + 1;
        end

        // 0xae (MP3_ENABLE / STREAMING_ENABLE) is the game pressing play or stop.
        // It does NOT re-arm the stream (MAME set_fpga_ctrl), so there is no reload
        // pulse -- but the HPS drives the PCM drain off these bits, so the epoch
        // MUST tick or playback would never start and nothing would report why.
        ep0 = cfg_epoch_w;
        bus_write(8'hae, 16'h0000);          // stop (earlier phases left it at 0x6000)
        repeat (3) @(negedge clk);
        if (cfg_epoch_w !== (ep0 + 16'd1)) begin
            $display("FAIL: P5 cfg_epoch did not tick on a play/stop enable change (%0d -> %0d)",
                     ep0, cfg_epoch_w);
            errors = errors + 1;
        end
        ep0 = cfg_epoch_w;
        bus_write(8'hae, 16'h6000);          // play again: a real change, must tick
        repeat (3) @(negedge clk);
        if (cfg_epoch_w !== (ep0 + 16'd1)) begin
            $display("FAIL: P5 cfg_epoch did not tick on play (%0d -> %0d)", ep0, cfg_epoch_w);
            errors = errors + 1;
        end
        ep0 = cfg_epoch_w;
        bus_write(8'hae, 16'h6000);          // SAME value: must NOT re-tick
        repeat (3) @(negedge clk);
        if (cfg_epoch_w !== ep0) begin
            $display("FAIL: P5 cfg_epoch ticked on an unchanged 0xae write");
            errors = errors + 1;
        end
        // each of the seven setup registers must bump it exactly once
        ep1 = cfg_epoch_w;
        bus_write(8'ha0, 16'h0000);  bus_write(8'ha2, 16'h0020);
        bus_write(8'ha4, 16'h0000);  bus_write(8'ha6, 16'h0030);
        bus_write(8'ha8, KEY1);      bus_write(8'hea, KEY2);
        bus_write(8'hec, KEY3);
        @(negedge clk);
        if (cfg_epoch_w !== (ep1 + 16'd7)) begin
            $display("FAIL: P5 cfg_epoch: 7 setup writes moved it by %0d (expected 7)",
                     cfg_epoch_w - ep1);
            errors = errors + 1;
        end

        // cfg_ddrsbm is an OSD bit (emu.sv O[101]) and can move with NO game
        // activity, so the epoch must tick on it too -- otherwise the HPS keeps
        // the previous key schedule and the audio is noise while every decode
        // counter still reads GREEN.
        ep1 = cfg_epoch_w;
        @(negedge clk); cfg_ddrsbm_r = 1'b1; repeat (3) @(negedge clk);
        if (cfg_epoch_w !== (ep1 + 16'd1)) begin
            $display("FAIL: P5 cfg_epoch did not tick on a cfg_ddrsbm change (%0d -> %0d)",
                     ep1, cfg_epoch_w);
            errors = errors + 1;
        end
        ep1 = cfg_epoch_w;
        repeat (4) @(negedge clk);           // held steady: must NOT keep ticking
        if (cfg_epoch_w !== ep1) begin
            $display("FAIL: P5 cfg_epoch free-runs while cfg_ddrsbm is steady");
            errors = errors + 1;
        end

        $display("dio_mp3_reload: 5 phases (2 discriminating, 2 controls, 1 epoch), %0d failed", errors);
        if (errors == 0) $display("RESULT: PASS (dio_mp3_reload)");
        else             $display("RESULT: FAIL (dio_mp3_reload, %0d errors)", errors);
        $finish;
    end
endmodule
