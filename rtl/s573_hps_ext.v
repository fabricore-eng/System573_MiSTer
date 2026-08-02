// -----------------------------------------------------------------------------
// s573_hps_ext.v - 573 EXT_BUS SPI mailbox (HPS<->fabric sideband)
//
// P4b(b), fabric slice: the pointer/status/control mailbox for the MP3
// transport. Replaces the vendored psx hps_ext stub at the emu.sv wire-up
// (same EXT_BUS + heartbeat interface, bit-identical stub behavior for the
// PSX CD_GET/CD_SET range), and adds the three 573 commands the forked-Main
// s573mp3 service polls. Pointers/status ride THIS SPI sideband, never DDR3
// (design doc: keeps ring coherence off the placement-marginal f2sdram
// bridge; the bridge carries bulk payload only).
//
// Command codes: 0x68..0x6A. Verified free on BOTH sides against this tree:
// Main_MiSTer user_io.h defines nothing in 0x65..0x6F (0x61..0x63 are
// UIO_DMA_*, which MD+'s 0x60..0x62 shadow -- we do not repeat that), and
// sys/hps_io.sv handles nothing there either. The EXT_BUS shares io_enable/
// io_strobe with hps_io's user-io channel, so dout_en MUST stay 0 for every
// command outside our ranges or we'd corrupt framework reads (hps_io.sv:194
// muxes EXT_BUS[15:0] over io_dout whenever EXT_BUS[32] is set).
//
// SPI word timing (sys_top.v rack/io_ack): io_strobe is high for exactly one
// clk_sys edge per 16-bit word; io_dout registered AT that edge is sampled by
// the HPS only after io_ack falls, several edges later -- so io_dout must be
// HELD until the next strobe or enable-fall. The word returned by the HPS's
// spi_w(X) is our response TO X -- same-word response semantics, exactly how
// the shipping MD+ ext_exchange_ptrs() gets rd_ptr back from the command word
// itself (Main_MiSTer support/megadrive/mdplus.cpp). NOTE the framework
// delivers io_strobe pulses with io_enable LOW during every FPGA-channel/OSD
// transfer (sys_top.v strobe is channel-agnostic) -- all state advance is
// gated on io_enable.
//
// DECISION B RESOLVED 2026-07-29 -- option (c). The descramble moves to the
// HPS (proven bit-exact: docs/2026-07-29-p4b-decision-b-spike-result.md), so
// the fabric->HPS BYTE RING IS NOT BEING BUILT. The three words that leg
// reserved are repurposed here rather than left dead:
//   fab_byte_wr -> fab_pos_lo      (fabric position echo, drift check)
//   byte_epoch  -> cfg_epoch       (per-song config epoch; drives MP3CFG)
//   hps_byte_rd -> hps_cons_bytes  (the option-(c) consumption credit)
// The epoch-freeze semantics on the down word are UNCHANGED and are exactly
// as load-bearing for a credit as they were for a ring pointer: a stale
// post-reset credit must never advance the streamer. k573_mp3stream STAYS as
// a credit-paced position tracker, because 0xae bit12 is a START/STOP
// idempotence guard in the game and a constant value breaks one of the two
// paths (disassembly in the spike doc). That is why option (c), not literal B.
//
// CMD_573_PTRS (0x68) -- the hot-path exchange, ~5 ms poll:
//   word0 (cmd)  up: fab_pcm_rd (PCM-ring beat read ptr, 16-bit -- matches
//                    s573_pcm_ring BEATS_LOG2=15 -> [15:0] exactly; the ring
//                    holds an elaboration guard against BEATS_LOG2>15, which
//                    would no longer fit one SPI word)
//                    + SNAPSHOT of {fab_pos_lo, cfg_epoch, rst_epoch}
//   word1        dn: hps_pcm_wr      up: snapshotted fab_pos_lo
//   word2        dn: hps_cons_bytes  up: snapshotted cfg_epoch
//   word3        dn: hps_rst_ack     up: snapshotted rst_epoch (low 8 bits)
// Snapshotting at the cmd strobe makes the set a consistent tuple in one
// exchange -- the mailbox half of transport-design must-fix #1. Staleness is
// in the safe direction: a snapshot under-reports HPS free space, never over-
// reports it.
//
// hps_cons_bytes is CUMULATIVE bytes consumed by the HPS from the scrambled
// window -- same shape as the CTRL event counters, and for the same reason: a
// retried or aborted poll cannot double-count, because the diff of an
// unchanged counter is zero. The wire-up diffs it against a baseline and
// releases that many bytes of out_ready to k573_mp3stream, so `cur` (and
// therefore 0xae bit12) tracks real consumption instead of free-running. It is
// FROZEN while the reset epoch is unacked, exactly like the old ring pointer.
//
// cfg_epoch is advertised in the HOT poll on purpose: the config itself is 8
// words and changes only once per song, so the HPS watches this one word every
// poll and issues CMD_573_MP3CFG only when it MOVES. That keeps the per-poll
// cost at four words in the steady state.
//
// CORE-RESET protocol (rst_epoch / hps_rst_ack). A core soft reset (OSD)
// resets every fabric consumer (ring reader, drain, k573dio counters) while
// Main and the HPS service keep running with stale pointers -- without a
// guard, the next poll would re-advertise a stale hps_pcm_wr and the reader
// would replay stale DDR3 PCM whose ticks fabricate the freshly-zeroed
// sample counter (the no-mask class). So: rst bumps rst_epoch (8-bit) and
// zeroes hps_pcm_wr/hps_cons_bytes/ctrl_flags/pending events, and the mailbox
// IGNORES the pointer words (word1/word2) of every PTRS whose LAST-acked
// epoch (hps_rst_ack from a previous exchange) != rst_epoch. The HPS MUST:
// on a word3 epoch change, re-init its ring writer (wr ptr = 0, flush,
// mp3dec_init), re-push ctrl_flags, and ack the new epoch in its next PTRS
// -- pointers thaw only then. NOTE the core-load reset pulse itself bumps
// rst_epoch (the mailbox cannot tell power-up from soft reset), so the
// service's FIRST PTRS poll always learns a nonzero epoch and must ack it
// before the pointer leg thaws -- one poll (~5 ms) of latency at startup,
// and one uniform code path for every reset.
//
// CMD_573_STATUS (0x69) -- observability (underrun is a NUMBER, not a vibe):
//   word0 (cmd)  up: status_flags + SNAPSHOT of {underrun_cnt, buf_level}
//   word1        up: snapshotted underrun_cnt
//   word2        up: snapshotted buf_level
//
// CMD_573_CTRL (0x6A) -- HPS->fabric control + decode events:
//   word0 (cmd)  up: {last_sync_cnt, last_idle_cnt} (the fabric's current
//                    cumulative baselines -- a RESTARTED HPS must read these
//                    and adopt them as its own starting counts, or its
//                    zero-based counters would diff as garbage deltas)
//   word1        dn: {frame_sync_cnt[15:8], frame_idle_cnt[7:0]} CUMULATIVE
//                    8-bit event counters; the fabric diffs against its
//                    baselines and emits that many 1-cycle pulses
//   word2        dn: ctrl_flags (bit0 = cfg_ddrsbm, bit1 = mp3_drain_en,
//                    rest reserved-write-0)
// CUMULATIVE counts, not per-poll deltas: a retried/aborted CTRL cannot
// double-count events (the diff of an unchanged counter is zero), which is
// what keeps dec_frame_sync exactly +1 per decoded frame (0xa8 doctrine --
// k573dio counts every cycle the input is high, so pulses are gap-spaced).
// An 8-bit wrap is fine: deltas are bounded by frames-decoded-per-poll,
// itself bounded by PCM-ring free space (~56 frames) << 255.
// HPS CONTRACT: frame_idle_cnt is a RECURRING per-no-frame-decode event
// (MAME mpeg_frame_sync(0) per stalled/EOF poll), NOT a one-shot transition
// -- k573dio derives mpeg IDLE state from its cadence.
// EVENT ORDERING: all pending sync pulses drain BEFORE any idle pulse, and
// the two never fire in the same cycle. k573dio's mpeg state keys off the
// LAST pulse seen; in the dangerous mixed poll (song end: syncs then idle)
// idle-last is the true order. The inverted case (idle then new-song sync
// in one poll) momentarily reads IDLE and self-heals on the next poll's
// sync deltas.
// After a core rst, the first CTRL word1 is ADOPTED as the new baselines
// with ZERO pulses (rebaseline) -- frames decoded across the reset window
// are dropped honestly (that audio never played), and a simultaneously
// restarted HPS adopts cleanly too.
//
// CMD_573_MP3CFG (0x6B) -- per-song descramble config, fabric -> HPS.
// Everything the HPS needs to reproduce the fabric's descramble byte-for-byte
// (the spike's C reference takes exactly this set):
//   word0 (cmd)  up: {8'd0, cfg_epoch[7:0]} + SNAPSHOT of all words below
//   word1        up: mp3_start[15:0]
//   word2        up: {7'd0, mp3_start[24:16]}
//   word3        up: mp3_end[15:0]
//   word4        up: {7'd0, mp3_end[24:16]}
//   word5        up: key1
//   word6        up: key2
//   word7        up: key3
//   word8        up: {12'd0, fpga_ctrl[15:13], cfg_ddrsbm}
// ALL EIGHT are snapshotted at the cmd strobe, so the HPS can never read a
// TORN set (old start with new keys) even if the game rewrites the setup
// registers mid-transaction -- one word-aligned start address descrambled with
// the wrong key schedule is silent noise that every honesty counter would
// still report GREEN, so atomicity here is not optional. The snapshot bank is
// shared with PTRS/STATUS: one command is in flight at a time.
// The HPS MAY END THE TRANSACTION AFTER word0 (drop io_enable) when the epoch
// is unchanged -- the remaining words are only needed when it moves. It should
// normally not need to: cfg_epoch rides the hot PTRS poll.
// NOTE this carries fpga_ctrl[15:13] but NOT a decoded "streaming" bit: the
// game's own start/stop guards read 0xae bit12, which the FABRIC owns and
// derives from `cur`. The HPS must not try to synthesize it.
//
// pend saturation: the 9-bit pending-pulse accumulators clamp at 511 and
// set the sticky evt_ovf output (fold into status_flags at wire-up) instead
// of wrapping -- an overflow means lost events, which must be LOUD, never a
// silent mod-512 alias. Unreachable at the designed poll cadence (drain
// empties 255 pulses in ~510 cycles << ~5 ms poll), but the bound is a
// cadence assumption, not an interlock -- hence the clamp + flag.
//
// underrun_cnt port: feed the SATURATED view at wire-up --
// (|u32[31:16]) ? 16'hFFFF : u32[15:0] -- NOT the raw low 16 bits, which
// wrap every ~1.49 s of continuous starvation and would read as a fresh
// counter mid-incident.
//
// All in clk_1x -- no CDC anywhere in this module. rst clears CORE-facing
// state only; SPI framing (byte_cnt/cmd/dout_en/io_dout) is owned by the
// io_enable envelope and deliberately NOT reset (clearing it mid-transaction
// would desync Main's word framing).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_hps_ext
(
    input             clk_sys,
    input             rst,            // core reset (emu.sv `reset`)
    inout      [35:0] EXT_BUS,

    output reg        heartbeat,

    // ---- CMD_573_PTRS: PCM pointers + the option-(c) consumption credit ----
    input      [15:0] fab_pcm_rd,      // from s573_pcm_ring fab_rd_ptr (beats)
    output reg [15:0] hps_pcm_wr,      // -> s573_pcm_ring hps_wr_ptr (beats)
    input      [15:0] fab_pos_lo,      // k573_mp3stream cur[16:1] echo (drift check)
    input      [15:0] cfg_epoch,       // bumped per mp3_reload -> HPS re-reads MP3CFG
    output reg [15:0] hps_cons_bytes,  // CUMULATIVE bytes consumed by the HPS
                                       // (epoch-frozen; paces k573_mp3stream)

    // ---- CMD_573_MP3CFG: per-song descramble config, fabric -> HPS ----
    input      [24:0] mp3_start,     // k573dio 0xa0/a2, byte address
    input      [24:0] mp3_end,       // k573dio 0xa4/a6
    input      [15:0] mp3_key1,      // k573dio 0xa8
    input      [15:0] mp3_key2,      // k573dio 0xea
    input      [15:0] mp3_key3,      // k573dio 0xec
    input             cfg_ddrsbm,    // descramble scheme select
    input       [2:0] fpga_ctrl_en,  // fpga_ctrl[15:13] as the game last wrote them
    // MAS3507D output gain matrix (k573dio decodes it off the I2C bus). The game's
    // OWN output level; 0 = mute. gain_stb pulses when it is set, and gain_seen
    // below makes that sticky so the HPS can tell 'never told' from 'told 0'.
    input      [19:0] gain_ll,
    input      [19:0] gain_rr,
    input             gain_stb,

    // ---- CMD_573_STATUS: fabric -> HPS observability ----
    input      [15:0] status_flags,  // wire-up picks (mp3_synced, drain_en, evt_ovf, cfg_ddrsbm echo...)
    input      [15:0] underrun_cnt,  // s573_mp3_pcm underrun_cnt, SATURATED to 16 bits (see header)
    input      [15:0] buf_level,     // elastic-buffer occupancy (wr_level, zero-extended)

    // ---- CMD_573_CTRL: HPS -> fabric control + decode events ----
    output reg [15:0] ctrl_flags,      // bit0=cfg_ddrsbm, bit1=mp3_drain_en, rest reserved
    output reg        dec_frame_sync,  // 1-cycle pulse per HPS-decoded MPEG frame
    output reg        dec_frame_idle,  // 1-cycle pulse per HPS no-frame decode
    output reg        evt_ovf          // sticky: a pend accumulator clamped (events lost -> LOUD)
);

reg [15:0] io_dout = 0;
reg        dout_en = 0;
reg  [9:0] byte_cnt = 0;

assign EXT_BUS[15:0] = io_dout;
wire [15:0] io_din = EXT_BUS[31:16];
assign EXT_BUS[32] = dout_en;
wire io_strobe = EXT_BUS[33];
wire io_enable = EXT_BUS[34];

// PSX stub parity range (claimed-with-zeros exactly like psx/rtl/hps_ext.v;
// Main never sends these to a non-"PSX" core name, but behavior must not drift).
localparam CD_GET = 'h34;
localparam CD_SET = 'h35;

// 573 mailbox range
localparam CMD_573_PTRS   = 'h68;
localparam CMD_573_STATUS = 'h69;
localparam CMD_573_CTRL   = 'h6A;
localparam CMD_573_MP3CFG = 'h6B;   // must stay the TOP of the range (dout_en)

// Snapshot bank: latched at the cmd strobe, served on words 1..N. ONE command
// is in flight at a time, so the bank is shared across PTRS (3), STATUS (2)
// and MP3CFG (8). Written in parallel, read through a mux -- plain flops, no
// RAM inference. (Declared before the initial block that seeds it.)
// Sticky: has the game EVER set the output gain? Booting muted because it has not
// yet spoken would be a worse bug than the clipping this fixes, so the HPS applies
// unity until this is 1.
reg gain_seen = 1'b0;
always @(posedge clk_sys) if (rst) gain_seen <= 1'b0; else if (gain_stb) gain_seen <= 1'b1;

reg [15:0] snap [1:11];

integer si;
initial begin
    heartbeat      = 0;
    hps_pcm_wr     = 0;
    hps_cons_bytes = 0;
    ctrl_flags     = 0;
    dec_frame_sync = 0;
    dec_frame_idle = 0;
    evt_ovf        = 0;
    for (si = 1; si <= 11; si = si + 1) snap[si] = 16'd0;
end


// core-reset epoch: bumped once per rst assertion edge; pointers frozen
// until the HPS acks the current value (see header)
reg  [7:0] rst_epoch = 0;
reg  [7:0] hps_rst_ack = 0;
reg        rst_d = 0;
wire       ptrs_thawed = (hps_rst_ack == rst_epoch);

// cumulative event baselines (what the HPS counters read at last apply)
reg  [7:0] last_sync_cnt = 0;
reg  [7:0] last_idle_cnt = 0;
// post-reset (and power-up): adopt the next CTRL counts with zero pulses
reg        rebaseline = 1;

// pending pulse counts (9-bit, clamped -- see header)
reg  [8:0] pend_sync = 0;
reg  [8:0] pend_idle = 0;

always @(posedge clk_sys) begin
    // block-local temporaries (psx-stub style). pend_* has TWO writers per
    // cycle in the worst case -- the drain (-1) and a CTRL strobe (+delta) --
    // so both go through one blocking next-value chain; two competing
    // non-blocking assigns would silently drop the decrement (an extra,
    // fabricated pulse later = an 0xa8 over-count).
    reg [15:0] cmd;
    reg  [8:0] pend_sync_nxt;
    reg  [8:0] pend_idle_nxt;
    reg  [7:0] dsync;
    reg  [7:0] didle;
    reg  [9:0] tmp10;

    pend_sync_nxt = pend_sync;
    pend_idle_nxt = pend_idle;

    // ---- event pulse drain: gap-spaced 1-cycle pulses, sync strictly
    // before idle, never both in one cycle (sync fires only when the
    // REGISTERED pend_sync != 0, idle only when it == 0 -- exclusive) ----
    dec_frame_sync <= 0;
    dec_frame_idle <= 0;
    if (!dec_frame_sync && pend_sync_nxt != 0) begin
        dec_frame_sync <= 1;
        pend_sync_nxt  = pend_sync_nxt - 1'd1;
    end
    if (!dec_frame_idle && pend_idle_nxt != 0
        && pend_sync == 0 && pend_sync_nxt == 0) begin
        dec_frame_idle <= 1;
        pend_idle_nxt  = pend_idle_nxt - 1'd1;
    end

    if(~io_enable) begin
        dout_en <= 0;
        io_dout <= 0;
        byte_cnt <= 0;
        cmd <= 0;
        if(cmd == CD_GET) heartbeat <= ~heartbeat;
    end
    else if(io_strobe) begin
        io_dout <= 0;
        if(~&byte_cnt) byte_cnt <= byte_cnt + 1'd1;

        if(byte_cnt == 0) begin
            cmd <= io_din;
            dout_en <= (io_din >= CD_GET && io_din <= CD_SET) ||
                       (io_din >= CMD_573_PTRS && io_din <= CMD_573_MP3CFG);
            case(io_din)
                CMD_573_PTRS: begin
                    io_dout <= fab_pcm_rd;
                    snap[1] <= fab_pos_lo;    // consistent {pos, cfg_epoch,
                    snap[2] <= cfg_epoch;     // rst_epoch} tuple in ONE
                    snap[3] <= {8'd0, rst_epoch};  // exchange (must-fix #1)
                end
                CMD_573_STATUS: begin
                    io_dout <= status_flags;
                    snap[1] <= underrun_cnt;
                    snap[2] <= buf_level;
                end
                CMD_573_MP3CFG: begin
                    // the whole descramble config latched as ONE tuple -- a
                    // torn set is silent noise that reads GREEN downstream
                    io_dout <= {8'd0, cfg_epoch[7:0]};
                    snap[1] <= mp3_start[15:0];
                    snap[2] <= {7'd0, mp3_start[24:16]};
                    snap[3] <= mp3_end[15:0];
                    snap[4] <= {7'd0, mp3_end[24:16]};
                    snap[5] <= mp3_key1;
                    snap[6] <= mp3_key2;
                    snap[7] <= mp3_key3;
                    snap[8] <= {12'd0, fpga_ctrl_en, cfg_ddrsbm};
                    snap[9]  <= gain_ll[15:0];
                    snap[10] <= gain_rr[15:0];
                    snap[11] <= {7'd0, gain_seen, gain_rr[19:16], gain_ll[19:16]};
                end
                CMD_573_CTRL: begin
                    io_dout <= {last_sync_cnt, last_idle_cnt};
                end
                default: ; // CD_GET/CD_SET answer zeros (stub parity)
            endcase
        end else begin
            case(cmd)
                CMD_573_PTRS: begin
                    if(byte_cnt == 1) begin
                        // frozen until the HPS has acked the current reset
                        // epoch -- a stale post-reset pointer must never
                        // reopen the ring (see header)
                        if (ptrs_thawed) hps_pcm_wr <= io_din;
                        io_dout <= snap[1];
                    end
                    else if(byte_cnt == 2) begin
                        // same freeze for the consumption credit: a stale
                        // post-reset count would release a burst of out_ready
                        // and run `cur` (hence 0xae bit12) past the truth
                        if (ptrs_thawed) hps_cons_bytes <= io_din;
                        io_dout <= snap[2];
                    end
                    else if(byte_cnt == 3) begin
                        hps_rst_ack <= io_din[7:0];
                        io_dout <= snap[3];
                    end
                end
                CMD_573_STATUS: begin
                    if(byte_cnt == 1) io_dout <= snap[1];
                    else if(byte_cnt == 2) io_dout <= snap[2];
                end
                CMD_573_MP3CFG: begin
                    // pure read-out of the latched tuple; the HPS may stop
                    // early (drop io_enable) when the epoch is unchanged
                    if(byte_cnt >= 1 && byte_cnt <= 11) io_dout <= snap[byte_cnt[3:0]];
                end
                CMD_573_CTRL: begin
                    if(byte_cnt == 1) begin
                        if (rebaseline) begin
                            // post-reset / power-up: adopt without pulsing
                            rebaseline <= 0;
                        end else begin
                        // cumulative-counter diff -> pending pulses. The
                        // 8-bit temporaries force mod-256 truncation, which
                        // is what makes the wrap case (last=0xFE, new=0x02
                        // -> +4) come out right; done inline, Verilog would
                        // context-widen the subtraction and break it.
                        // HPS_EXT_WIDE_DELTA compiles exactly that wrong
                        // inline form (tb RED under it, GREEN default --
                        // proof the bench exercises wrap correctness).
`ifdef HPS_EXT_WIDE_DELTA
                        pend_sync_nxt = pend_sync_nxt + (io_din[15:8] - last_sync_cnt);
                        pend_idle_nxt = pend_idle_nxt + (io_din[7:0]  - last_idle_cnt);
                        dsync = 0; didle = 0; tmp10 = 0; // silence unused-var lint
`else
                        dsync = io_din[15:8] - last_sync_cnt;
                        didle = io_din[7:0]  - last_idle_cnt;
                        // clamp-not-wrap (see header); sticky evt_ovf = LOUD
                        tmp10 = {1'b0, pend_sync_nxt} + {2'b0, dsync};
                        if (tmp10[9]) begin
                            pend_sync_nxt = 9'h1FF;
                            evt_ovf <= 1;
                        end else pend_sync_nxt = tmp10[8:0];
                        tmp10 = {1'b0, pend_idle_nxt} + {2'b0, didle};
                        if (tmp10[9]) begin
                            pend_idle_nxt = 9'h1FF;
                            evt_ovf <= 1;
                        end else pend_idle_nxt = tmp10[8:0];
`endif
                        end
                        last_sync_cnt <= io_din[15:8];
                        last_idle_cnt <= io_din[7:0];
                    end
                    else if(byte_cnt == 2) begin
                        ctrl_flags <= io_din;
                    end
                end
                default: ;
            endcase
        end
    end

    // ---- core reset: clear CORE-facing state, leave SPI framing alone ----
    // (last after the SPI branch so it dominates a same-cycle strobe)
    rst_d <= rst;
    if (rst) begin
        if (!rst_d) rst_epoch <= rst_epoch + 8'd1;  // once per assertion
        hps_pcm_wr     <= 0;
        hps_cons_bytes <= 0;
        ctrl_flags     <= 0;
        dec_frame_sync <= 0;
        dec_frame_idle <= 0;
        pend_sync      <= 0;
        pend_idle      <= 0;
        evt_ovf        <= 0;
        rebaseline     <= 1;
        // last_sync/idle_cnt deliberately NOT cleared: rebaseline adopts the
        // HPS's counts on the next CTRL, whatever they are
    end else begin
        pend_sync <= pend_sync_nxt;
        pend_idle <= pend_idle_nxt;
    end
end

endmodule
