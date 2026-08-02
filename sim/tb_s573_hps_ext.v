// tb_s573_hps_ext.v - 573 EXT_BUS SPI mailbox loopback bench.
//
// Models the HPS side of the EXT_BUS word protocol as sys_top.v + hps_io.sv
// deliver it to a core's hps_ext: io_enable frames a transaction, io_strobe
// is high for exactly ONE clk edge per 16-bit word, and the word the HPS's
// spi_w(X) returns is the DUT's io_dout as registered AT the X strobe -- the
// HPS samples it at ack-fall, SEVERAL edges later, so every spi_word here
// also asserts io_dout HOLDS for 5 further cycles (a response that glitches
// after the bench's early sample but before the real HPS sample would
// otherwise be invisible). The real framework also delivers strobes with
// io_enable LOW during every FPGA-channel/OSD transfer (sys_top.v strobe is
// channel-agnostic) -- modeled in P1b.
//
// Covers: enable-low strobes; foreign/boundary command rejection INCLUDING
// 0x36 = UIO_INFO_GET (the one range-adjacent code with live framework
// traffic) and dout_en RELEASE after every claimed transaction (a stale
// claim corrupts framework reads via the hps_io.sv:194 mux -- both
// mutation-proven bench holes from the adversarial review); psx-stub
// heartbeat parity; PTRS round-trip + cmd-time snapshot atomicity (the
// consistent-pair rule, must-fix #1 mailbox half) + the rst_epoch/ack
// pointer freeze; STATUS snapshot; CTRL cumulative-event diff ->
// exactly-N gap-spaced 1-cycle pulses (0xa8 doctrine: retry-idempotent,
// wrap-correct, BOTH collision parities, sync-before-idle ordering, never
// same-cycle); core-reset semantics (state clear, pend flush, rebaseline
// adopt, epoch thaw); pend clamp-not-wrap + sticky evt_ovf.
//
// RED/GREEN discriminator: `make HPS_EXT_WIDE_DELTA=1 s573_hps_ext` compiles
// the context-widened (untruncated) counter diff -- the wrap phase then
// floods 260 pulses instead of 4 and this bench FAILS. GREEN by default.
//
// Verilog-2005 / iverilog -g2005-sv.
`timescale 1ns/1ps
module tb_s573_hps_ext;
    reg clk = 0;
    always #14.76 clk = ~clk;   // ~33.8688 MHz clk_1x (period irrelevant to logic)

    // ---- EXT_BUS: tb drives the hps_io side, DUT drives [15:0] + [32] ----
    reg  [15:0] tb_din    = 0;
    reg         tb_strobe = 0;
    reg         tb_enable = 0;
    reg         tb_rst    = 0;
    wire [35:0] EXT_BUS;
    assign EXT_BUS[31:16] = tb_din;
    assign EXT_BUS[33]    = tb_strobe;
    assign EXT_BUS[34]    = tb_enable;
    assign EXT_BUS[35]    = 1'b0;
    wire [15:0] dut_dout  = EXT_BUS[15:0];
    wire        dut_en    = EXT_BUS[32];

    // ---- DUT fabric-side ports ----
    reg  [15:0] fab_pcm_rd   = 0;
    reg  [15:0] fab_pos_lo   = 0;
    reg  [15:0] cfg_epoch    = 0;
    reg  [24:0] mp3_start    = 0;
    reg  [24:0] mp3_end      = 0;
    reg  [15:0] mp3_key1     = 0;
    reg  [15:0] mp3_key2     = 0;
    reg  [15:0] mp3_key3     = 0;
    reg         cfg_ddrsbm   = 0;
    reg   [2:0] fpga_ctrl_en = 0;
    reg  [15:0] status_flags = 0;
    reg  [15:0] underrun_cnt = 0;
    reg  [15:0] buf_level    = 0;
    wire [15:0] hps_pcm_wr;
    wire [15:0] hps_cons_bytes;
    wire [15:0] ctrl_flags;
    wire        dec_frame_sync;
    wire        dec_frame_idle;
    wire        evt_ovf;
    wire        heartbeat;

    s573_hps_ext dut (
        .clk_sys(clk), .rst(tb_rst), .EXT_BUS(EXT_BUS), .heartbeat(heartbeat),
        .fab_pcm_rd(fab_pcm_rd), .hps_pcm_wr(hps_pcm_wr),
        .fab_pos_lo(fab_pos_lo), .cfg_epoch(cfg_epoch), .hps_cons_bytes(hps_cons_bytes),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .mp3_key1(mp3_key1), .mp3_key2(mp3_key2), .mp3_key3(mp3_key3),
        .cfg_ddrsbm(cfg_ddrsbm), .fpga_ctrl_en(fpga_ctrl_en),
        .status_flags(status_flags), .underrun_cnt(underrun_cnt), .buf_level(buf_level),
        .ctrl_flags(ctrl_flags), .dec_frame_sync(dec_frame_sync),
        .dec_frame_idle(dec_frame_idle), .evt_ovf(evt_ovf)
    );

    // ---- pulse monitors: count every high cycle; flag back-to-back highs
    // and same-cycle sync+idle overlap (either would double-count / misorder
    // in k573dio) ----
    integer sync_pulses = 0, idle_pulses = 0, gap_viol = 0, overlap_viol = 0;
    reg sync_prev = 0, idle_prev = 0;
    always @(posedge clk) begin
        if (dec_frame_sync) sync_pulses = sync_pulses + 1;
        if (dec_frame_idle) idle_pulses = idle_pulses + 1;
        if (dec_frame_sync && sync_prev) gap_viol = gap_viol + 1;
        if (dec_frame_idle && idle_prev) gap_viol = gap_viol + 1;
        if (dec_frame_sync && dec_frame_idle) overlap_viol = overlap_viol + 1;
        sync_prev <= dec_frame_sync;
        idle_prev <= dec_frame_idle;
    end

    integer errors = 0;
    task chk;
        input cond;
        input [511:0] name;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ---- SPI word primitives (sys_top timing model) ----
    task spi_begin;
        begin
            @(negedge clk); tb_enable = 1;
            @(negedge clk);
        end
    endtask

    task spi_end;
        begin
            @(negedge clk); tb_enable = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    // one 16-bit word: strobe high for exactly one posedge; response = io_dout
    // registered at that posedge. Sample it, then HOLD-CHECK 5 more cycles:
    // the real HPS reads at ack-fall (later than our first sample), so the
    // response must stay put until the next strobe or enable-fall.
    integer hold_i;
    task spi_word;
        input  [15:0] din;
        output [15:0] dout;
        begin
            @(negedge clk); tb_din = din; tb_strobe = 1;
            @(negedge clk); tb_strobe = 0;
            @(negedge clk);
            dout = dut_dout;
            for (hold_i = 0; hold_i < 5; hold_i = hold_i + 1) begin
                @(negedge clk);
                if (dut_dout !== dout) begin
                    $display("FAIL: io_dout not held after strobe (was %h now %h)",
                             dout, dut_dout);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // a raw strobe OUTSIDE any enabled transaction (FPGA-channel traffic model)
    task naked_strobe;
        input [15:0] din;
        begin
            @(negedge clk); tb_din = din; tb_strobe = 1;
            @(negedge clk); tb_strobe = 0;
            @(negedge clk);
        end
    endtask

    reg [15:0] r0, r1, r2, r3, r4;
    integer s_base, i_base, c1;
    integer k;
    reg seen_idle, order_bad;

    initial begin
        // ---------- P1: idle sanity ----------
        repeat (10) @(negedge clk);
        chk(dut_en == 0,            "P1 idle: dout_en low");
        chk(sync_pulses == 0,       "P1 idle: no sync pulses");
        chk(idle_pulses == 0,       "P1 idle: no idle pulses");
        chk(hps_pcm_wr == 0,        "P1 idle: hps_pcm_wr reset");
        chk(ctrl_flags == 0,        "P1 idle: ctrl_flags reset");
        chk(evt_ovf == 0,           "P1 idle: evt_ovf clear");

        // ---------- P1b: strobes with io_enable LOW (FPGA-channel words) ----------
        // the framework strobes the mailbox constantly with enable low; data
        // words that happen to equal claimable commands must not advance state
        naked_strobe(16'h0068);
        naked_strobe(16'h0034);
        naked_strobe(16'h006A);
        chk(dut_en == 0,            "P1b enable-low strobes: dout_en stays low");
        repeat (5) @(negedge clk);
        chk(sync_pulses == 0 && idle_pulses == 0, "P1b enable-low strobes: no state advance");
        // and the next enabled transaction decodes from word 0
        fab_pcm_rd = 16'h0AA0;
        spi_begin;
        spi_word(16'h0068, r0);
        chk(dut_en == 1 && r0 == 16'h0AA0, "P1b: transaction after naked strobes decodes from word0");
        spi_end;
        chk(dut_en == 0,            "P1b: dout_en releases");

        // ---------- P2: foreign + boundary commands are NOT claimed ----------
        spi_begin;
        spi_word(16'h0014, r0);     // framework UIO code
        chk(dut_en == 0,            "P2 foreign 0x14: dout_en stays low");
        spi_word(16'hABCD, r0);
        chk(dut_en == 0,            "P2 foreign 0x14 data word: dout_en stays low");
        spi_end;
        spi_begin;
        spi_word(16'h0067, r0);     // one below CMD_573_PTRS
        chk(dut_en == 0,            "P2 boundary 0x67: not claimed");
        spi_end;
        spi_begin;
        spi_word(16'h006C, r0);     // one above CMD_573_MP3CFG (the new top)
        chk(dut_en == 0,            "P2 boundary 0x6C: not claimed");
        spi_end;
        spi_begin;
        spi_word(16'h0033, r0);     // one below CD_GET
        chk(dut_en == 0,            "P2 boundary 0x33: not claimed");
        spi_end;
        spi_begin;
        spi_word(16'h0036, r0);     // one above CD_SET = UIO_INFO_GET, LIVE framework traffic
        chk(dut_en == 0,            "P2 boundary 0x36 (UIO_INFO_GET): not claimed");
        chk(dut_dout == 0,          "P2 boundary 0x36: io_dout stays quiet");
        spi_end;
        chk(heartbeat == 0,         "P2: no heartbeat toggle from foreign cmds");

        // ---------- P3: psx stub parity (CD_GET/CD_SET) ----------
        spi_begin;
        spi_word(16'h0034, r0);     // CD_GET
        chk(dut_en == 1,            "P3 CD_GET: claimed (stub parity)");
        chk(r0 == 16'h0000,         "P3 CD_GET: answers zeros");
        spi_word(16'h0000, r1);
        chk(r1 == 16'h0000,         "P3 CD_GET data word: zeros");
        chk(heartbeat == 0,         "P3 CD_GET: no toggle before enable falls");
        spi_end;
        chk(heartbeat == 1,         "P3 CD_GET: heartbeat toggles once at transaction end");
        chk(dut_en == 0,            "P3 CD_GET: dout_en releases at transaction end");
        spi_begin;
        spi_word(16'h0035, r0);     // CD_SET
        chk(dut_en == 1,            "P3 CD_SET: claimed (stub parity)");
        spi_end;
        chk(heartbeat == 1,         "P3 CD_SET: heartbeat does NOT toggle");
        chk(dut_en == 0,            "P3 CD_SET: dout_en releases");

        // ---------- P4: PTRS exchange + snapshot atomicity + epoch word ----------
        fab_pcm_rd  = 16'h1234;
        fab_pos_lo = 16'hBEEF;
        cfg_epoch  = 16'h0007;
        @(negedge clk);
        spi_begin;
        spi_word(16'h0068, r0);
        chk(dut_en == 1,            "P4 PTRS: claimed");
        chk(r0 == 16'h1234,         "P4 PTRS word0: fab_pcm_rd on the cmd word");
        // mutate ALL fabric inputs mid-transaction: words 1..3 must serve the
        // cmd-time snapshot ({fab_pos_lo, epoch} consistent pair)
        fab_pcm_rd  = 16'h9999;
        fab_pos_lo = 16'hDEAD;
        cfg_epoch  = 16'h0008;
        spi_word(16'h4321, r1);
        chk(r1 == 16'hBEEF,         "P4 PTRS word1: snapshotted fab_pos_lo");
        chk(hps_pcm_wr == 16'h4321, "P4 PTRS word1: hps_pcm_wr applied at the strobe");
        spi_word(16'h0055, r2);
        chk(r2 == 16'h0007,         "P4 PTRS word2: snapshotted epoch (consistent pair)");
        chk(hps_cons_bytes == 16'h0055,"P4 PTRS word2: hps_cons_bytes applied");
        spi_word(16'h0000, r3);     // word3: rst_epoch up / ack down
        chk(r3 == 16'h0000,         "P4 PTRS word3: rst_epoch 0 at power-up");
        spi_word(16'hFFFF, r4);     // past-end word: benign
        chk(r4 == 16'h0000,         "P4 PTRS word4: past-end reads zero");
        spi_end;
        chk(hps_pcm_wr == 16'h4321, "P4 PTRS: hps_pcm_wr survives transaction end");
        chk(dut_en == 0,            "P4 PTRS: dout_en releases");
        // fresh transaction sees the mutated values (fresh snapshot)
        spi_begin;
        spi_word(16'h0068, r0);
        spi_word(16'h4322, r1);
        spi_word(16'h0056, r2);
        spi_word(16'h0000, r3);
        spi_end;
        chk(r0 == 16'h9999,         "P4 PTRS 2nd: fresh fab_pcm_rd");
        chk(r1 == 16'hDEAD,         "P4 PTRS 2nd: fresh fab_pos_lo");
        chk(r2 == 16'h0008,         "P4 PTRS 2nd: fresh epoch");
        chk(r3 == 16'h0000,         "P4 PTRS 2nd: rst_epoch still 0");

        // ---------- P5: STATUS snapshot ----------
        status_flags = 16'h00C3;
        underrun_cnt = 16'h0042;
        buf_level    = 16'h01FF;
        @(negedge clk);
        spi_begin;
        spi_word(16'h0069, r0);
        chk(dut_en == 1,            "P5 STATUS: claimed");
        chk(r0 == 16'h00C3,         "P5 STATUS word0: flags on the cmd word");
        underrun_cnt = 16'h0043;    // mutate mid-transaction
        buf_level    = 16'h0000;
        spi_word(16'h0000, r1);
        chk(r1 == 16'h0042,         "P5 STATUS word1: snapshotted underrun_cnt");
        spi_word(16'h0000, r2);
        chk(r2 == 16'h01FF,         "P5 STATUS word2: snapshotted buf_level");
        spi_end;
        chk(dut_en == 0,            "P5 STATUS: dout_en releases");

        // ---------- P6: CTRL events ----------
        // first CTRL after power-up: REBASELINE -- counts adopted, ZERO pulses
        // (covers a Main that restarted mid-session with nonzero counters)
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        chk(dut_en == 1,            "P6 CTRL: claimed");
        chk(r0 == 16'h0000,         "P6 CTRL#1 word0: zero baselines at power-up");
        spi_word({8'd5, 8'd3}, r1); // nonzero adopt
        spi_word(16'h0001, r2);     // ctrl_flags: cfg_ddrsbm=1
        spi_end;
        repeat (20) @(negedge clk);
        chk(ctrl_flags == 16'h0001, "P6 CTRL#1: flags applied");
        chk(sync_pulses - s_base == 0, "P6 CTRL#1 (rebaseline): ZERO pulses on adopt");
        chk(idle_pulses - i_base == 0, "P6 CTRL#1 (rebaseline): ZERO idle pulses on adopt");

        // normal delta poll
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        chk(r0 == {8'd5, 8'd3},     "P6 CTRL#2 word0: adopted baselines read back");
        spi_word({8'd8, 8'd4}, r1); // +3 sync, +1 idle
        spi_word(16'h0001, r2);
        spi_end;
        repeat (20) @(negedge clk);
        chk(sync_pulses - s_base == 3, "P6 CTRL#2: exactly 3 sync pulses");
        chk(idle_pulses - i_base == 1, "P6 CTRL#2: exactly 1 idle pulse");

        // retry with the SAME cumulative counts -> zero new pulses
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'd8, 8'd4}, r1);
        spi_word(16'h0001, r2);
        spi_end;
        repeat (10) @(negedge clk);
        chk(sync_pulses - s_base == 0, "P6 CTRL retry: no double-count (idempotent)");
        chk(idle_pulses - i_base == 0, "P6 CTRL retry: no idle double-count");

        // abort after the event word: events land, flags unchanged
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'd10, 8'd5}, r1);
        spi_end;                    // aborted before the flags word
        repeat (10) @(negedge clk);
        chk(sync_pulses - s_base == 2, "P6 CTRL abort: +2 syncs applied");
        chk(idle_pulses - i_base == 1, "P6 CTRL abort: +1 idle applied");
        chk(ctrl_flags == 16'h0001,    "P6 CTRL abort: flags unchanged");

        // wrap: 10 -> 0xFE (+244), then 0xFE -> 0x02 (+4). The WIDE_DELTA
        // build floods 260 on the second step instead of 4 -> RED.
        s_base = sync_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'hFE, 8'd5}, r1);
        spi_end;
        repeat (520) @(negedge clk); // 244 gap-spaced pulses need ~490 cycles
        chk(sync_pulses - s_base == 244, "P6 CTRL: +244 up to the wrap point");
        s_base = sync_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        chk(r0 == {8'hFE, 8'd5},    "P6 CTRL: baselines track pre-wrap");
        spi_word({8'h02, 8'd5}, r1);
        spi_end;
        repeat (20) @(negedge clk);
        chk(sync_pulses - s_base == 4, "P6 CTRL: wrapped delta = exactly 4");

        // mid-drain collision at BOTH strobe parities: drain decrements sit
        // on one parity, and a fixed SPI cadence pins the add strobe to one
        // parity too -- so run the pattern twice with a 1-cycle skew to
        // guarantee one round actually collides (a two-NBA pend writer bug
        // is invisible at the non-colliding parity)
        s_base = sync_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'h52, 8'd5}, r1);   // 0x02 -> 0x52: +80 syncs
        spi_word(16'h0001, r2);
        spi_end;
        spi_begin;                      // parity 0: immediately, mid-drain
        spi_word(16'h006A, r0);
        spi_word({8'h5C, 8'd5}, r1);   // +10 more, mid-drain
        spi_word(16'h0001, r2);
        spi_end;
        repeat (220) @(negedge clk);
        chk(sync_pulses - s_base == 90, "P6 CTRL collision parity0: exactly 90 total");
        s_base = sync_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'hAC, 8'd5}, r1);   // 0x5C -> 0xAC: +80
        spi_word(16'h0001, r2);
        spi_end;
        @(negedge clk);                 // parity 1: 1-cycle skew
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'hB6, 8'd5}, r1);   // +10, mid-drain, other parity
        spi_word(16'h0001, r2);
        spi_end;
        repeat (220) @(negedge clk);
        chk(sync_pulses - s_base == 90, "P6 CTRL collision parity1: exactly 90 total");

        // ordering: a mixed poll must deliver ALL sync pulses before any idle
        // pulse (k573dio's mpeg state keys off the LAST pulse; song-end order
        // is sync-then-idle)
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'hBB, 8'd8}, r1);   // +5 sync, +3 idle
        spi_word(16'h0001, r2);
        spi_end;
        seen_idle = 0; order_bad = 0;
        for (k = 0; k < 40; k = k + 1) begin
            @(negedge clk);
            if (dec_frame_idle) seen_idle = 1;
            if (dec_frame_sync && seen_idle) order_bad = 1;
        end
        chk(sync_pulses - s_base == 5, "P6 order: exactly 5 sync pulses");
        chk(idle_pulses - i_base == 3, "P6 order: exactly 3 idle pulses");
        chk(!order_bad,                "P6 order: all sync pulses precede any idle pulse");

        // foreign command AFTER claimed transactions: no stale-claim leak
        spi_begin;
        spi_word(16'h0014, r0);
        chk(dut_en == 0,            "P6 foreign-after-claimed: dout_en stays low");
        spi_end;

        // ---------- P8: core reset -- state clear, pend flush, epoch, rebaseline ----------
        // preload a big pend so the reset lands mid-drain
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'h83, 8'd8}, r1);   // 0xBB -> 0x83: +200 sync
        spi_word(16'h0001, r2);
        spi_end;
        s_base = sync_pulses;
        repeat (21) @(negedge clk);
        chk(sync_pulses - s_base >= 5, "P8: drain running before reset");
        // reset pulse
        @(negedge clk); tb_rst = 1;
        repeat (3) @(negedge clk); tb_rst = 0;
        c1 = sync_pulses;
        repeat (30) @(negedge clk);
        chk(sync_pulses == c1,      "P8 rst: pending pulses flushed (counter frozen)");
        chk(hps_pcm_wr == 0,        "P8 rst: hps_pcm_wr cleared");
        chk(hps_cons_bytes == 0,       "P8 rst: hps_cons_bytes cleared");
        chk(ctrl_flags == 0,        "P8 rst: ctrl_flags cleared (drain_en off)");
        chk(evt_ovf == 0,           "P8 rst: evt_ovf cleared");
        // stale poll: Main does not know about the reset -- its pointer words
        // must be FROZEN OUT until it acks the new epoch
        spi_begin;
        spi_word(16'h0068, r0);
        spi_word(16'h7777, r1);        // stale hps_pcm_wr
        spi_word(16'h0066, r2);        // stale hps_cons_bytes
        spi_word(16'h0000, r3);        // stale ack (old epoch)
        spi_end;
        chk(hps_pcm_wr == 0,        "P8 stale PTRS: pointer frozen (epoch not acked)");
        chk(hps_cons_bytes == 0,       "P8 stale PTRS: byte ptr frozen");
        chk(r3 == 16'h0001,         "P8 stale PTRS word3: rst_epoch bumped to 1");
        // acking poll: the ack rides word3, AFTER this poll's own word1 --
        // so this poll's pointer is still frozen and only the NEXT poll's
        // pointer applies (the gate compares against the LAST-stored ack)
        spi_begin;
        spi_word(16'h0068, r0);
        spi_word(16'h0100, r1);
        spi_word(16'h0000, r2);
        spi_word(16'h0001, r3);        // ack epoch 1 (learned last poll)
        spi_end;
        chk(hps_pcm_wr == 0,        "P8 ack-poll: word1 still frozen (ack lands after it)");
        spi_begin;
        spi_word(16'h0068, r0);
        spi_word(16'h0100, r1);
        spi_word(16'h0000, r2);
        spi_word(16'h0001, r3);
        spi_end;
        chk(hps_pcm_wr == 16'h0100, "P8 post-ack PTRS: pointer thawed and applied");
        chk(r3 == 16'h0001,         "P8 post-ack PTRS: epoch steady at 1");
        // first CTRL after reset: REBASELINE (adopt, zero pulses), baselines
        // preserved across rst until then
        s_base = sync_pulses; i_base = idle_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        chk(r0 == {8'h83, 8'd8},    "P8 CTRL word0: baselines preserved across rst");
        spi_word({8'h90, 8'd9}, r1);
        spi_word(16'h0003, r2);
        spi_end;
        repeat (20) @(negedge clk);
        chk(sync_pulses - s_base == 0, "P8 CTRL (rebaseline): zero pulses on adopt");
        chk(idle_pulses - i_base == 0, "P8 CTRL (rebaseline): zero idle pulses");
        chk(ctrl_flags == 16'h0003,    "P8 CTRL: flags re-applied");
        // and normal deltas resume
        s_base = sync_pulses;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'h93, 8'd9}, r1);   // +3 sync
        spi_word(16'h0003, r2);
        spi_end;
        repeat (12) @(negedge clk);
        chk(sync_pulses - s_base == 3, "P8 post-reset deltas: exactly 3 pulses");

        // ---------- P9: pend clamp-not-wrap + sticky evt_ovf ----------
        // three +200 polls back-to-back outrun the drain (~12 pulses between
        // adds): pend hits 511 and CLAMPS. Under mod-512 wrap the total would
        // be ~90; with the clamp it is ~535 (600 added minus the clamped
        // loss). Assert a clean band, not an exact count -- the property is
        // clamp-vs-wrap, and the sticky flag makes the loss LOUD.
        s_base = sync_pulses;
        chk(evt_ovf == 0,           "P9: evt_ovf clear before the burst");
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'h5B, 8'd9}, r1);   // 0x93 -> 0x5B: +200
        spi_word(16'h0003, r2);
        spi_end;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'h23, 8'd9}, r1);   // +200
        spi_word(16'h0003, r2);
        spi_end;
        spi_begin;
        spi_word(16'h006A, r0);
        spi_word({8'hEB, 8'd9}, r1);   // +200 -> clamps
        spi_word(16'h0003, r2);
        spi_end;
        repeat (1100) @(negedge clk);   // full drain
        chk(evt_ovf == 1,           "P9: evt_ovf sticky after clamp");
        chk(sync_pulses - s_base >= 450 && sync_pulses - s_base <= 620,
                                    "P9: clamped total in band (wrap would be ~90)");
        c1 = sync_pulses;
        repeat (30) @(negedge clk);
        chk(sync_pulses == c1,      "P9: drain fully empties after the burst");

        // ---------- P10: pulse shape (global invariants) ----------
        chk(gap_viol == 0,          "P10: every pulse is 1 cycle with a gap (no double-count)");
        chk(overlap_viol == 0,      "P10: sync and idle never fire in the same cycle");

        // ---------- P11: CMD_573_MP3CFG (0x6B) -- option-(c) config read-out ----------
        // The HPS needs exactly this tuple to reproduce the fabric descramble
        // byte-for-byte. All eight words MUST come from ONE cmd-strobe snapshot:
        // a torn set (old start address, new key schedule) descrambles to noise
        // while every downstream honesty counter still reads GREEN.
        mp3_start    = 25'h01A2468;
        mp3_end      = 25'h1FE0246;
        mp3_key1     = 16'h1357;
        mp3_key2     = 16'h2468;
        mp3_key3     = 16'h9BDF;
        cfg_ddrsbm   = 1'b1;
        fpga_ctrl_en = 3'b110;
        cfg_epoch    = 16'h0021;
        @(negedge clk);

        spi_begin;
        spi_word(16'h006B, r0);
        chk(r0 == 16'h0021,         "P11 MP3CFG word0: cfg_epoch");
        // rewrite EVERY config input mid-transaction -- the snapshot must hold
        mp3_start    = 25'h1FFFFFE;
        mp3_end      = 25'h0000002;
        mp3_key1     = 16'hFFFF;
        mp3_key2     = 16'hEEEE;
        mp3_key3     = 16'hDDDD;
        cfg_ddrsbm   = 1'b0;
        fpga_ctrl_en = 3'b001;
        cfg_epoch    = 16'h0022;
        spi_word(16'h0000, r1);
        chk(r1 == 16'h2468,         "P11 MP3CFG word1: mp3_start[15:0] snapshotted");
        spi_word(16'h0000, r2);
        chk(r2 == 16'h001A,         "P11 MP3CFG word2: mp3_start[24:16] snapshotted");
        spi_word(16'h0000, r1);
        chk(r1 == 16'h0246,         "P11 MP3CFG word3: mp3_end[15:0] snapshotted");
        spi_word(16'h0000, r2);
        chk(r2 == 16'h01FE,         "P11 MP3CFG word4: mp3_end[24:16] snapshotted");
        spi_word(16'h0000, r1);
        chk(r1 == 16'h1357,         "P11 MP3CFG word5: key1 snapshotted");
        spi_word(16'h0000, r2);
        chk(r2 == 16'h2468,         "P11 MP3CFG word6: key2 snapshotted");
        spi_word(16'h0000, r1);
        chk(r1 == 16'h9BDF,         "P11 MP3CFG word7: key3 snapshotted");
        spi_word(16'h0000, r2);
        chk(r2 == {12'd0, 3'b110, 1'b1},
                                    "P11 MP3CFG word8: {fpga_ctrl[15:13], ddrsbm} snapshotted");
        spi_end;

        // a SECOND exchange must serve the NEW values (the snapshot is per-cmd,
        // not a one-shot latch)
        spi_begin;
        spi_word(16'h006B, r0);
        chk(r0 == 16'h0022,         "P11 MP3CFG 2nd: fresh cfg_epoch");
        spi_word(16'h0000, r1);
        chk(r1 == 16'hFFFE,         "P11 MP3CFG 2nd: fresh mp3_start[15:0]");
        spi_word(16'h0000, r2);
        chk(r2 == 16'h01FF,         "P11 MP3CFG 2nd: fresh mp3_start[24:16]");
        spi_end;

        // early abort after word0 is legal and must not corrupt the next command
        spi_begin;
        spi_word(16'h006B, r0);
        chk(r0 == 16'h0022,         "P11 MP3CFG early-abort: epoch still served");
        spi_end;
        spi_begin;
        spi_word(16'h0069, r0);
        chk(r0 == status_flags,     "P11: STATUS still framed correctly after an aborted MP3CFG");
        spi_end;

        // cfg_epoch must ALSO ride the hot PTRS poll (word2 up), so the HPS can
        // watch one word per poll instead of issuing MP3CFG every time
        cfg_epoch = 16'h0033;
        @(negedge clk);
        spi_begin;
        spi_word(16'h0068, r0);
        spi_word(16'h0000, r1);
        spi_word(16'h0000, r2);
        chk(r2 == 16'h0033,         "P11: cfg_epoch advertised on PTRS word2");
        spi_end;

        // dout_en must cover 0x6B and STILL be low one past the range -- 0x6C
        // would corrupt a framework read (hps_io muxes EXT_BUS whenever it is set)
        spi_begin;
        @(negedge clk); tb_din = 16'h006B; tb_strobe = 1;
        @(negedge clk); tb_strobe = 0; @(negedge clk);
        chk(dut_en == 1,            "P11: dout_en asserted for 0x6B");
        spi_end;
        spi_begin;
        @(negedge clk); tb_din = 16'h006C; tb_strobe = 1;
        @(negedge clk); tb_strobe = 0; @(negedge clk);
        chk(dut_en == 0,            "P11: dout_en STAYS LOW for 0x6C (one past the range)");
        spi_end;

        if (errors == 0) $display("RESULT: PASS (s573_hps_ext)");
        else             $display("RESULT: FAIL (s573_hps_ext, %0d errors)", errors);
        $finish;
    end
endmodule
