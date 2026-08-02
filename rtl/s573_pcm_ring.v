// -----------------------------------------------------------------------------
// s573_pcm_ring.v - HPS->fabric PCM ring reader (DDR3 -> elastic buffer)
//
// P4b(b), fabric slice: the transport half that pulls HPS-decoded PCM out of a
// ring buffer in DDR3 and feeds it to the s573_mp3_pcm elastic buffer, which the
// 44100 Hz drain then consumes. The HPS (forked-Main minimp3 service) memcpys
// decoded interleaved 16-bit stereo PCM into the ring and advertises its write
// pointer over the EXT_BUS SPI sideband (NOT through DDR3 -- see the transport
// design doc). This reader reads whole 64-bit beats (= 2 stereo samples) via the
// s573_ddram_arb DIO read channel, unpacks each into two sample pushes, and
// publishes its read pointer back to the HPS (free-space feedback).
//
// Pointers are BEAT-granular (1 beat = 2 stereo samples = 8 bytes), so a 256 KiB
// ring is 32768 beats -> a 15-bit index that fits one 16-bit SPI word. The HPS
// therefore writes whole beats (minimp3 emits 1152 samples/frame = 576 beats).
//
// The elastic buffer (s573_mp3_pcm) absorbs the arb's opportunistic, bursty read
// latency (the DIO client only wins the bus when the PSX side is idle, and the
// f2sdram bridge is placement-marginal), so the steady 44100 drain never sees the
// jitter as long as the ring stays fed. This reader NEVER fabricates a sample:
// if the ring has no new data it simply does not read; the drain's own underrun
// path (honest silence + no tick + underrun_cnt) handles starvation.
//
// 64-bit beat layout (DDR3 little-endian, matching an HPS interleaved int16 buffer
// L0,R0,L1,R1): data[15:0]=S0.L data[31:16]=S0.R data[47:32]=S1.L data[63:48]=S1.R.
//
// arb DIO read handshake (4-phase, mirrors emu.sv dio_mem_rd_*): assert rd_req +
// rd_addr; the arb returns rd_ack=1 with rd_data valid (held); drop rd_req; the arb
// drops rd_ack. Runs in clk_1x; clk_1x/clk_2x are edge-aligned related clocks so the
// level handshake into the arb's clk_2x DIO client is an ordinary related-clock path.
//
// This module is STANDALONE (its rd_* master is muxed onto the shared arb DIO read
// channel at the emu.sv wire-up slice; unwired today). Verilog-2005 / GPLv2.
// -----------------------------------------------------------------------------
module s573_pcm_ring #(
    // Beat offset of the PCM ring WITHIN the 32 MiB DIO window (arb ORs in
    // DIO_BASE_BEAT). PROVISIONAL: byte 0x1F10000 (phys 0x33F10000) >> 3. Must be
    // re-checked against ddrsbm's actual top-of-window sample-RAM usage before HW
    // (transport-design must-fix #2) -- kept a parameter so it is not baked in.
    parameter [21:0]  RING_OFF_BEAT = 22'h3E2000,
    // Ring depth = 2^BEATS_LOG2 beats (default 15 -> 32768 beats = 256 KiB). Tunable
    // (design must-fix #4: latency vs underrun-margin is an HW-dialed trade) --
    // but ONLY downward: must stay <= 15 while the pointers ride ONE 16-bit SPI
    // word each in s573_hps_ext CMD_573_PTRS ([BEATS_LOG2:0] incl. the wrap MSB,
    // which the full/empty compare needs). Larger needs a 2-word pointer
    // exchange; the elaboration guard below fails the build rather than let a
    // retune silently truncate the wrap bit.
    parameter integer BEATS_LOG2 = 15
)(
    input  wire        clk,             // clk_1x
    input  wire        rst,

    // ---- HPS write pointer (beats), from the SPI mailbox; drain-enable gate ----
    input  wire [BEATS_LOG2:0] hps_wr_ptr,   // extra MSB vs fab_rd_ptr (full/empty)
    output reg  [BEATS_LOG2:0] fab_rd_ptr,   // published back to the HPS via the mailbox

    // ---- arb DIO read master (4-phase; muxed onto the shared channel at wire-up) ----
    output reg         rd_req,
    output reg  [21:0] rd_addr,          // 64-bit beat index in the 32 MiB DIO window
    input  wire [63:0] rd_data,
    input  wire        rd_ack,

    // ---- to the s573_mp3_pcm elastic buffer fill side ----
    output reg         wr_en,           // COMBINATIONAL 1-cycle push (see below)
    output reg  [15:0] wr_l,
    output reg  [15:0] wr_r,
    input  wire        wr_full
);
    // Elaboration guard: BEATS_LOG2 > 15 no longer fits one 16-bit SPI pointer
    // word (see parameter comment) -- instantiate a deliberately-undefined
    // module so the build FAILS instead of silently truncating.
    generate
        if (BEATS_LOG2 > 15) begin : g_beats_log2_guard
            s573_pcm_ring_BEATS_LOG2_exceeds_16bit_spi_word_ERROR u_err();
        end
    endgenerate

    localparam [2:0] S_IDLE=3'd0, S_REQ=3'd1, S_PUSH0=3'd2, S_PUSH1=3'd3, S_WAIT=3'd4;
    reg [2:0]  state;
    reg [63:0] beat;

    // beats the HPS has made available but we have not yet read
    wire have_data = (hps_wr_ptr != fab_rd_ptr);

    // Push outputs are COMBINATIONAL so a push lands the SAME cycle wr_en asserts
    // and updates the sink's wr_full BEFORE the next push's check. A registered
    // wr_en would lag by a cycle, so with exactly one free slot the two pushes of a
    // beat would both fire (over-push/overflow). Sample 0 = beat[31:0], sample 1 =
    // beat[63:32]; L=[15:0]/[47:32], R=[31:16]/[63:48] (DDR3 little-endian).
    always @(*) begin
        wr_en = 1'b0;
        wr_l  = beat[15:0];
        wr_r  = beat[31:16];
        if (state == S_PUSH0) begin wr_l = beat[15:0];  wr_r = beat[31:16]; wr_en = !wr_full; end
        if (state == S_PUSH1) begin wr_l = beat[47:32]; wr_r = beat[63:48]; wr_en = !wr_full; end
    end

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            fab_rd_ptr <= {(BEATS_LOG2+1){1'b0}};
            rd_req     <= 1'b0;
            rd_addr    <= 22'd0;
            beat       <= 64'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    // read the next beat only if the HPS has data AND the elastic
                    // buffer has room (honest back-pressure; never over-read).
                    if (have_data && !wr_full) begin
                        rd_addr <= RING_OFF_BEAT + {{(22-BEATS_LOG2){1'b0}}, fab_rd_ptr[BEATS_LOG2-1:0]};
                        rd_req  <= 1'b1;
                        state   <= S_REQ;
                    end
                end
                S_REQ: begin
                    if (rd_ack) begin           // arb returned the beat (held)
                        beat   <= rd_data;
                        rd_req <= 1'b0;          // drop req -> arb will drop ack
                        state  <= S_PUSH0;
                    end
                end
                // S_PUSH0/1: the combinational block drives wr_en=!wr_full; advance
                // only on the cycle the push actually lands (!wr_full).
                S_PUSH0: if (!wr_full) state <= S_PUSH1;
                S_PUSH1: if (!wr_full) begin
                    fab_rd_ptr <= fab_rd_ptr + 1'b1;   // one beat consumed
                    state      <= S_WAIT;
                end
                S_WAIT: begin
                    // let the 4-phase complete (arb drops ack after we dropped req)
                    // before issuing the next read.
                    if (!rd_ack) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
