// -----------------------------------------------------------------------------
// s573_mp3_credit.v - HPS consumption credit -> k573_mp3stream out_ready
//
// P4b(b) decision-B option (c), slice 3. Under option (c) the HPS descrambles
// the MP3 stream itself out of the DIO window, so the fabric streamer no longer
// FEEDS anyone -- but it must still advance `cur`, because 0xae bit12
// (get_fpga_ctrl "still streaming") is derived from it and the game's own
// START/STOP routines are guarded on that bit. With out_ready tied low `cur`
// freezes, the bit never self-clears, and the game can never observe a song
// ENDING (disassembly: docs/2026-07-29-p4b-decision-b-spike-result.md).
//
// This module is the missing advance source. The HPS reports a CUMULATIVE count
// of bytes it has consumed from the (descrambled) stream; we diff it against a
// baseline and release exactly that many out_ready cycles. The streamer emits
// the identical byte sequence the HPS is consuming -- that is precisely what the
// decision-B spike proved bit-exact over 45,377 bytes -- so one credit is one
// byte and `cur` tracks true playback position.
//
// WHY CUMULATIVE, not a per-poll delta: a retried, duplicated or aborted SPI
// exchange cannot double-count, because the diff of an unchanged counter is
// zero. Same reasoning as the CMD_573_CTRL frame counters (s573_hps_ext header),
// and the same mod-2^16 truncation trick: an 8/16-bit wrap is correct as long as
// fewer than 2^16 bytes pass between polls -- 1.6 s at 320 kbps against a ~5 ms
// poll, four orders of margin. The HPS never has to reason about ordering.
//
// NO-MASK: out_ready is driven ONLY by real credit. It never free-runs, never
// "tops up" on a timer, and goes low the instant credit hits zero. That is the
// whole point -- a free-running out_ready would advance `cur` (and therefore the
// game-visible position) at a rate nobody measured, which is the pacing-model
// doctrine's central prohibition. `make MP3_CREDIT_FREERUN=1 s573_mp3_credit`
// compiles exactly that mistake; the bench is RED under it.
//
// REBASELINE on a song change. cfg_epoch (k573dio, ++ per re-arm) changing means
// the streamer just re-armed to a new window and the HPS has restarted its own
// byte count. We ADOPT the next report as the new baseline and release ZERO
// credit for it, so a restarted counter cannot be read as a huge delta and dump
// a burst of out_ready into the fresh song. Identical in shape to the mailbox's
// post-reset `rebaseline`, and load-bearing for the same reason.
//
// CLAMP, never wrap. The credit accumulator saturates and raises a sticky
// cred_ovf instead of wrapping: an overflow means we would under-advance `cur`
// forever after, which must be LOUD. Unreachable at the designed cadence (a poll
// delta is ~200 bytes at 320 kbps vs a 16-bit accumulator), but that is a
// cadence assumption, not an interlock.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_mp3_credit #(
    parameter integer CRED_W = 16          // credit accumulator width
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] hps_cons_bytes,     // CUMULATIVE, from the SPI mailbox
    input  wire [15:0] cfg_epoch,          // k573dio re-arm epoch; change = rebaseline

    input  wire        out_valid,          // k573_mp3stream out_valid
    output wire        out_ready,          // -> k573_mp3stream out_ready

    output reg [CRED_W-1:0] credit,        // observability (SignalTap / status)
    output reg              cred_ovf       // sticky: accumulator clamped
);
    reg [15:0] last_cons  = 16'd0;
    reg [15:0] last_epoch = 16'd0;
    reg        rebaseline = 1'b1;          // power-up: adopt, do not credit

`ifdef MP3_CREDIT_FREERUN
    // pre-fix / anti-pattern: ignore the credit and let the streamer flood. This
    // is the "invent a clock" failure the pacing model forbids -- cur races ahead
    // of real playback and 0xae bit12 drops early.
    assign out_ready = 1'b1;
`else
    assign out_ready = (credit != {CRED_W{1'b0}});
`endif

    wire accept = out_valid & out_ready;

    always @(posedge clk) begin
        // ONE blocking next-value chain. credit has TWO writers in the worst
        // cycle -- an accept (-1) and a fresh report (+delta) -- and two
        // competing non-blocking assigns would silently drop the decrement,
        // handing out a byte of credit that was already spent. The mailbox's
        // pend_* accumulators carry the identical warning; this is that trap.
        reg [CRED_W-1:0] cred_nxt;
        reg [15:0]       delta;
        reg [CRED_W:0]   sum;

        cred_nxt = credit;

        if (accept && cred_nxt != {CRED_W{1'b0}})
            cred_nxt = cred_nxt - 1'b1;

        if (cfg_epoch != last_epoch) begin
            // song change: the streamer re-armed and the HPS restarted its
            // count. Adopt whatever it reports next, release nothing, and drop
            // any credit still outstanding for the PREVIOUS window -- spending
            // it here would advance cur into the new song for bytes that were
            // never played.
            last_epoch <= cfg_epoch;
            rebaseline <= 1'b1;
            cred_nxt    = {CRED_W{1'b0}};
        end
        else if (hps_cons_bytes != last_cons) begin
            if (rebaseline) begin
                rebaseline <= 1'b0;         // adopt with zero credit
            end else begin
                // 16-bit temporary forces the mod-2^16 truncation that makes
                // the wrap case (last=0xFFFE, new=0x0002 -> +4) come out right.
                delta = hps_cons_bytes - last_cons;
                sum   = {1'b0, cred_nxt} + {{(CRED_W+1-16){1'b0}}, delta};
                if (sum[CRED_W]) begin
                    cred_nxt = {CRED_W{1'b1}};
                    cred_ovf <= 1'b1;
                end else
                    cred_nxt = sum[CRED_W-1:0];
            end
            last_cons <= hps_cons_bytes;
        end

        if (rst) begin
            credit     <= {CRED_W{1'b0}};
            cred_ovf   <= 1'b0;
            // ADOPT whatever is on the inputs rather than zeroing the baselines.
            // The mailbox does clear hps_cons_bytes on reset today, so zeroing
            // would usually be equivalent -- but "usually" is a cross-module
            // assumption, and if it ever stops holding, the stale value would be
            // consumed by the rebaseline and the HPS's first REAL report would
            // land as a spurious delta (found by tb_s573_mp3_credit P8). Adopting
            // the live inputs is correct no matter what the mailbox does.
            last_cons  <= hps_cons_bytes;
            last_epoch <= cfg_epoch;
            rebaseline <= 1'b1;
        end else begin
            credit <= cred_nxt;
        end
    end

    initial begin
        credit   = {CRED_W{1'b0}};
        cred_ovf = 1'b0;
    end
endmodule
