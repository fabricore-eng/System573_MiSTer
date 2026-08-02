// -----------------------------------------------------------------------------
// s573_mp3_pcm.v - HPS-decoded MP3 PCM elastic buffer + 44100 Hz drain
//
// P4b(b), fabric slice 1 (the load-bearing, model-INDEPENDENT piece). The 573
// Digital I/O MP3 path decodes on the HPS (minimp3); decoded 16-bit stereo PCM
// arrives over a DDR3 ring (or any transport) and is pushed into THIS on-fabric
// elastic buffer. A fixed 44100 Hz drain pops one stereo sample per sample-clock
// into the audio mixer and emits exactly one `pcm_sample_tick` per REAL sample
// drained -- that tick is what advances the k573dio 0xca/cc sample counter the
// ddrsbm stage-"ready" loop polls (get_counter = PCM sample position, 44100/s).
//
// WHY THIS EXISTS / WHY IT IS SEPARATE. The elastic buffer decouples the steady
// 44100 Hz audio sink from the bursty, latency-variable DDR3 refill (the f2sdram
// bridge placement is marginal -- memory f2sdram-bridge-placement-marginal). The
// deep buffering lives in the DDR3 PCM ring; this on-fabric BRAM only needs to
// cover bridge/refill jitter (default 512 stereo samples ~= 11.6 ms). It is the
// same regardless of the transport choice (DDR3 ring vs SPI-FIO) or of whether
// the fabric->HPS byte leg exists -- so it is safe to build and sim-prove first.
//
// THE ONE RULE (no-mask doctrine, memory no-mask-fault-with-fake-data). The
// sample counter MUST track CONSUMED PCM, never bytes-sent and never a
// free-running clock. So:
//   * a `pcm_sample_tick` is emitted ONLY when a real sample is popped;
//   * on UNDERRUN (buffer empty at a 44100 sample-clock) the drain emits HONEST
//     SILENCE (pcm = 0) on the MP3 channel, does NOT pop, does NOT tick (the
//     counter FREEZES truthfully rather than running ahead of real audio), and
//     increments a saturating `underrun_cnt` so starvation is observable as a
//     NUMBER (the only verification available -- no MP3 sim/MAME oracle).
// NEVER replay-the-last-sample, zero-fill-AND-tick, or free-run a 44.1 kHz clock;
// all three fabricate the counter. `PCM_FAKE_UNDERRUN` compiles exactly that
// wrong behavior so the testbench is RED under it and GREEN by default -- proof
// the test exercises the doctrine, not a hand-reverted RTL.
//
// CLOCK. clk = clk_1x = 33.8688 MHz = 44100 * 768 exactly, so the fractional
// accumulator (acc += 44100; wrap at 33_868_800) produces one sample-clock every
// 768 cycles with ZERO drift. Parameterized for reuse/verification.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_mp3_pcm #(
    parameter [31:0] CLK_HZ = 32'd33_868_800,  // clk_1x frequency (accumulator modulus)
    parameter [31:0] SR_HZ  = 32'd44_100,      // PCM sample rate (accumulator increment)
    parameter integer AW    = 9                // elastic buffer depth = 2^AW stereo samples
)(
    input  wire        clk,
    input  wire        rst,

    // ---- fill side: HPS-decoded PCM in (from the DDR3 PCM-ring reader) ----
    // A stereo sample is enqueued when wr_en & !wr_full. The ring reader MUST
    // honor wr_full (an over-push is dropped + counted, never allowed to corrupt).
    input  wire        wr_en,
    input  wire [15:0] wr_l,          // signed 16-bit L
    input  wire [15:0] wr_r,          // signed 16-bit R
    output wire        wr_full,       // buffer full -> stop pushing
    output wire [AW:0] wr_level,      // occupancy in stereo samples (refill decision)

    // ---- drain control ----
    // drain_en high while the MP3 stream is playing: the 44100 Hz sample-clock
    // runs and each tick pops-or-underruns. Low = idle: no ticks, MP3 channel
    // silent, accumulator phase reset (a clean restart, no half-sample carry).
    input  wire        drain_en,

    // ---- outputs: to the audio mixer + the k573dio sample counter ----
    output reg  [15:0] pcm_l,             // held between sample-clocks; 0 on underrun/idle
    output reg  [15:0] pcm_r,
    output reg         pcm_sample_tick,   // 1-cyc per REAL sample drained @44100 -> 0xca/cc ++
    output reg  [31:0] underrun_cnt,      // saturating: sample-clocks that found the buffer empty
    output reg  [31:0] overflow_cnt       // saturating: wr_en pushes dropped because full (a bug upstream)
);
    // ---------------- elastic buffer (a plain synchronous FIFO) ----------------
    // One entry per stereo sample: {L,R} packed 32-bit. AW+1-bit pointers so the
    // MSB distinguishes full from empty.
    localparam integer DEPTH = (1 << AW);
    reg [31:0] mem [0:DEPTH-1];
    reg [AW:0] wptr, rptr;

    wire empty = (wptr == rptr);
    wire full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign wr_full  = full;
    assign wr_level = wptr - rptr;

    wire do_push = wr_en && !full;
    wire ovf     = wr_en &&  full;   // upstream ignored wr_full -> drop + count (never corrupt)

    // ---------------- 44100 Hz drain via fractional accumulator ----------------
    // acc in [0, CLK_HZ); each clk adds SR_HZ; the cycle it would reach/exceed
    // CLK_HZ is a sample-clock (pcm_ce) and acc wraps. Exactly SR_HZ ce's per
    // CLK_HZ cycles. With CLK_HZ = 44100*768 this reduces to one ce / 768 cycles.
    reg  [31:0] acc;
    wire [32:0] acc_next = {1'b0, acc} + {1'b0, SR_HZ};
    wire        pcm_ce   = drain_en && (acc_next >= {1'b0, CLK_HZ});

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0;
            rptr <= 0;
            acc  <= 32'd0;
            pcm_l <= 16'd0;
            pcm_r <= 16'd0;
            pcm_sample_tick <= 1'b0;
            underrun_cnt <= 32'd0;
            overflow_cnt <= 32'd0;
        end else begin
            pcm_sample_tick <= 1'b0;              // default: a 1-cycle pulse

            // ---- fill ----
            if (do_push) begin
                mem[wptr[AW-1:0]] <= {wr_l, wr_r};
                wptr <= wptr + 1'b1;
            end
            if (ovf && overflow_cnt != 32'hFFFF_FFFF)
                overflow_cnt <= overflow_cnt + 1'b1;

            // ---- accumulator phase ----
            if (!drain_en)
                acc <= 32'd0;                    // idle: reset phase (clean restart)
            else if (pcm_ce)
                acc <= acc_next[31:0] - CLK_HZ;  // wrap
            else
                acc <= acc_next[31:0];

            // ---- drain (only on a 44100 sample-clock) ----
            if (pcm_ce) begin
                if (!empty) begin
                    // a REAL sample is consumed
                    pcm_l <= mem[rptr[AW-1:0]][31:16];
                    pcm_r <= mem[rptr[AW-1:0]][15:0];
                    rptr  <= rptr + 1'b1;
                    pcm_sample_tick <= 1'b1;      // the honest, drain-driven tick
                end else begin
`ifdef PCM_FAKE_UNDERRUN
                    // WRONG (doctrine violation, compiled only to make the TB RED):
                    // replay the last sample AND tick anyway -> the sample counter
                    // free-runs at 44100 with no real audio, and underrun_cnt lies 0.
                    pcm_l <= pcm_l;
                    pcm_r <= pcm_r;
                    pcm_sample_tick <= 1'b1;
`else
                    // HONEST underrun: silence on the MP3 channel, NO pop, NO tick
                    // (counter freezes), count the starvation as a NUMBER.
                    pcm_l <= 16'd0;
                    pcm_r <= 16'd0;
                    if (underrun_cnt != 32'hFFFF_FFFF)
                        underrun_cnt <= underrun_cnt + 1'b1;
`endif
                end
            end else if (!drain_en) begin
                // idle: mute the MP3 channel (SPU still passes through the mixer)
                pcm_l <= 16'd0;
                pcm_r <= 16'd0;
            end
        end
    end
endmodule
