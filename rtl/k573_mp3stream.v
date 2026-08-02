// -----------------------------------------------------------------------------
// k573_mp3stream.v - BEMANI Digital I/O board MP3 streaming controller
//
// The Digital I/O FPGA streams the (scrambled) MP3 bitstream out of board DRAM,
// descrambles it word-by-word with k573_mp3dec, and feeds the bytes to the
// MAS3507D decoder. This module is that streaming engine, faithful to the
// update_stream / get_fpga_ctrl / set_fpga_ctrl / update_mp3_decode_state logic in
// MAME's src/mame/konami/k573fpga.cpp + the demand model in src/devices/sound/
// mas3507d.cpp:
//
//   * streaming runs while the FPGA control register has both MP3_ENABLE (bit13)
//     and STREAMING_ENABLE (bit14) set and the current address is within
//     [mp3_start, mp3_end);
//   * each step reads one 16-bit word from DRAM, descrambles it (default or DDR
//     SBM scheme), byte-swaps it, and emits its two bytes high-then-low to the
//     decoder, advancing the address by 2;
//   * get_fpga_ctrl reads back 0x1000 while actively streaming.
//
// PACING (the whole point -- see docs/2026-07-03-p4-mp3-pacing-model.md). In
// hardware the byte rate is NOT free-running and NOT a fixed throttle: the MAS3507D
// raises a DEMAND line whenever its 3584-byte input FIFO is not full, and the FPGA
// feeds one byte per demand-tick, stalling when the FIFO fills. The FIFO drains as
// the decoder turns bytes into 44100 Hz PCM, so the average byte rate emerges as
// the MP3 bitrate/8 (~16 KB/s @128kbps ... ~40 KB/s @320kbps). We model that with
// an `out_ready` back-pressure input (the sink's "can accept a byte" = DEMAND): a
// byte is emitted (out_valid) with out_byte HELD stable and is only consumed --
// advancing the stream -- on a cycle where out_valid && out_ready. There is
// deliberately NO rate number in this RTL: the sink sets the pace (no-mask doctrine
// -- pace to consumption, never invent a clock). In our core the sink is the HPS
// byte FIFO of the minimp3 decode service (P4b); until that is wired, emu.sv holds
// out_ready low so the stream is honestly back-pressured to a halt.
//
// RE-ARM / START. MAME re-inits the stream (cur<-start, re-seed keys, zero the
// position proxy) ONLY in update_mp3_decode_state(), reached on a write to any MP3
// setup register (start/end hi+lo, key1/2/3) -- NEVER on an MP3/STREAMING enable-bit
// change (set_fpga_ctrl only reset_playback()s the decoder FIFO, leaving mp3_cur_addr
// and the key schedule intact). We mirror that: a one-cycle `reload` pulse (from
// k573dio on any setup-register write) re-inits + re-seeds; the enable bits merely
// GATE streaming. So the stream STARTS/RESUMES from the current cur when enabled
// (S_IDLE level-start after a reload has seeded the keys), and an enable-bit toggle
// resumes in place instead of rewinding to the top of the window. This also fixes
// the pre-fix one-shot that ignored an mp3_end extension after parking.
//
// TIMING CONTRACT ON `reload` (do not "simplify" this away): the pulse must arrive one
// cycle AFTER the bus write that caused it, because `cur <= mp3_start` here would
// otherwise sample mp3_start on the very edge that write updates it -- i.e. the PREVIOUS
// song's address. k573dio.v registers its combinational pulse for exactly this reason
// (mp3_reload -> mp3_reload_q); see sim/tb_dio_mp3_reload.v and MP3_RELOAD_RACE.
//
// ENABLE GATING / PAUSE-IN-PLACE. MAME's set_fpga_ctrl leaves BOTH mp3_cur_addr and
// the key schedule intact on an enable-bit change (it only reset_playback()s the
// decoder FIFO), and update_stream() simply does not run while disabled -- the word
// it already read+decrypted stays buffered. We must match that, and the subtlety is
// that our key schedule advances on `word_stb` (S_STB) while `cur` advances two
// states later (S_LO). Between those points the schedule has moved for a word the
// stream has not yet finished with, so unwinding to S_IDLE and re-fetching on resume
// would re-read the SAME cur and re-descramble that word with an ALREADY-ADVANCED
// schedule -- corrupting the rest of the stream and emitting one extra byte. A
// disable may therefore only bail out from the PRE-DECODE states (S_ADDR/S_REQ,
// where nothing has been consumed); from S_STB onward the FSM PAUSES in place
// (`emit_en` gates out_valid and the last-word retire) and resumes mid-word.
// `make MP3_ENGATE_BUG=1 k573_mp3stream_engate` restores the old unwind-from-any-state
// behaviour; tb_k573_mp3stream_engate is RED under it and GREEN by default.
//
// TODO (P4b, SINK SIDE -- not this module): MAME also calls mas3507d reset_playback()
// on BOTH enable edges (k573fpga.cpp set_fpga_ctrl -> mas3507d.cpp reset_playback),
// which FLUSHES the decoder's 3584-byte input FIFO and forces a re-sync on the next
// frame header. So in MAME the decoder does NOT see a continuous bitstream across a
// pause, whereas our sink currently would. This module's port is correct either way
// (it is the FIFO that is flushed, not the streamer), but whoever wires the HPS byte
// FIFO + minimp3 sink MUST decide whether to model that flush -- an unflushed decoder
// resuming mid-frame is a plausible-but-wrong audio source. Nothing in the suite
// pins it today.
//
// LAST-BYTE BOUNDARY. MAME's update_stream() checks the window (cur >= end) BEFORE
// feeding the buffered low byte, so it drops the FINAL in-window word's low byte and
// feeds 2N-1 bytes for an N-word window. We match that exactly (suppress the last
// word's low byte) to stay byte-identical to the oracle. NOTE: this is an
// oracle-derived boundary detail; real CR-589/DIO-FPGA behavior here is unconfirmed
// (a whole-word emit would give 2N). It is immaterial to MP3 decode (self-framing;
// the game's chart clock is the decode counter, not bytes-sent) -- flagged for
// silicon confirmation in P4c. The descrambler key schedule still advances for the
// last word (MAME reads+decrypts it before dropping the low byte).
//
// A byte counter is provided as a streamed-data POSITION proxy only; the real MP3
// sample/frame counter the game reads to sync the chart (0xa8/0xca/cc) is derived
// from decoder frame-sync / PCM drain, NOT from bytes sent, and is driven by P4b.
//
// The DRAM read port is a req/ready handshake: rd_req is held (with rd_addr stable)
// until the backing pulses rd_ready with rd_data REGISTERED and held until the next
// request -- so a real external backing (DDR3 line cache, k573dio BACKING_EXTERNAL)
// can insert arbitrary latency, and the sim backing answers in one cycle.
//
// `make MP3_UNPACED=1 k573_mp3stream` compiles the pre-fix streamer (ignores
// out_ready -> floods; re-inits on the enable edge and rewinds to mp3_start; ignores
// reload -> one-shot park). tb_k573_mp3stream is RED under it (a paced sink loses
// bytes; an mp3_end extension never resumes; a re-enable rewinds the song) and GREEN
// by default -- proof the test exercises the fix without hand-reverting RTL.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module k573_mp3stream (
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] fpga_ctrl,     // FPGA control register (bits 13/14)
    input  wire        ddrsbm,        // 0 = default scheme, 1 = DDR SBM
    input  wire [24:0] mp3_start,     // byte address in DRAM (word-aligned)
    input  wire [24:0] mp3_end,
    input  wire [15:0] key1,          // descrambler key seed
    input  wire [15:0] key2,
    input  wire [15:0] key3,
    input  wire        reload,        // 1-cycle: re-init on start/end/key change

    // board DRAM read port (req/ready; rd_data held until the next request)
    output reg  [24:0] rd_addr,
    output reg         rd_req,
    input  wire [15:0] rd_data,
    input  wire        rd_ready,

    // byte stream to the sink (MAS3507D DEMAND model): out_valid asserted with
    // out_byte held; the byte is consumed only when out_valid && out_ready.
    input  wire        out_ready,
    output wire [7:0]  out_byte,
    output wire        out_valid,
    output reg  [31:0] byte_counter,

    // Current stream position, for the P4b option-(c) mailbox. Purely an
    // observability echo -- the HPS cross-checks its own cursor against it to
    // catch a word-alignment desync, which is the one failure mode that would
    // otherwise produce plausible-but-wrong audio while every counter reads
    // GREEN. Nothing in the fabric consumes it.
    output wire [24:0] cur_pos,

    output wire [15:0] fpga_ctrl_rb    // get_fpga_ctrl read-back
);
    localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_ADDR=3'd2, S_REQ=3'd3,
                     S_STB=3'd4, S_CAP=3'd5, S_HI=3'd6, S_LO=3'd7;

    wire stream_en = fpga_ctrl[13] & fpga_ctrl[14];   // MP3_ENABLE & STREAMING_ENABLE

    reg [2:0]  state;
    reg [24:0] cur;
    reg        prev_en;
    reg [15:0] dw;

    // this in-window word is the window's LAST (its low byte is dropped -- MAME
    // update_stream checks cur>=end before feeding the buffered low byte).
    wire last_word = (cur + 25'd2) >= mp3_end;

    // ---- enable gating (see ENABLE GATING / PAUSE-IN-PLACE in the header) ----
    // Once word_stb has fired the key schedule has advanced for the word in flight,
    // so the emit states must PAUSE rather than unwind. emit_en gates both out_valid
    // (hence `accept`) and the last-word retire.
`ifdef MP3_ENGATE_BUG
    wire emit_en = 1'b1;                      // pre-fix: emit gating ignores the enables
`else
    wire emit_en = stream_en;
`endif

    // ---- output byte handshake (combinational; sink sets the pace) ----
    // out_valid high in the emit states (except the suppressed last low byte);
    // out_byte holds the current byte stable across stalls until the sink accepts.
    assign out_valid = emit_en && ((state == S_HI) || (state == S_LO && !last_word));
    assign out_byte  = (state == S_HI) ? dw[15:8] : dw[7:0];

`ifdef MP3_UNPACED
    wire ready_eff = 1'b1;                    // pre-fix: ignore back-pressure (flood)
    wire do_reinit = stream_en & ~prev_en;    // pre-fix: enable-edge re-init (rewind), ignores reload
`else
    wire ready_eff = out_ready;               // demand-paced: wait for the sink
    wire do_reinit = reload;                   // re-init ONLY on a setup-register write
`endif
    wire accept = out_valid & ready_eff;      // a byte is consumed this cycle

    // descrambler control (combinational on state). word_stb in S_STB ->
    // dec_dout valid in S_CAP, where it is latched into dw before emitting.
    wire        loadk = (state == S_LOAD);
    wire        wstb  = (state == S_STB);
    wire [15:0] dec_dout;
    k573_mp3dec u_dec (
        .clk(clk), .rst(rst),
        .load_keys(loadk), .key1_in(key1), .key2_in(key2), .key3_in(key3),
        .ddrsbm(ddrsbm), .word_stb(wstb), .din(rd_data), .dout(dec_dout),
        .key1(), .key2(), .key3()
    );

    assign cur_pos = cur;

    // streaming while enabled and within the window (MAME get_fpga_ctrl, bit 14)
    assign fpga_ctrl_rb =
        (fpga_ctrl[14] && cur >= mp3_start && cur < mp3_end) ? 16'h1000 : 16'h0000;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; cur <= 25'd0; prev_en <= 1'b0;
            byte_counter <= 32'd0;
            rd_addr <= 25'd0; rd_req <= 1'b0; dw <= 16'd0;
        end else begin
            if (do_reinit) begin
                // MAME update_mp3_decode_state: cur<-start, re-seed keys (S_LOAD),
                // zero the position proxy. Streaming (if enabled) resumes after.
                cur          <= mp3_start;
                byte_counter <= 32'd0;
                rd_req       <= 1'b0;
                state        <= S_LOAD;          // S_LOAD seeds the keys
            end else begin
                case (state)
                    S_IDLE:
`ifdef MP3_UNPACED
                        ;                        // pre-fix: start only via the enable-edge re-init
`else
                        // start/resume from the current cur (keys already seeded by
                        // a prior reload); the enable bits only GATE streaming.
                        if (stream_en && cur < mp3_end) state <= S_ADDR;
`endif
                    S_LOAD: state <= S_ADDR;
                    S_ADDR: begin
                        if (stream_en && cur < mp3_end) begin
                            rd_addr <= cur;
                            rd_req  <= 1'b1;             // hold until rd_ready
                            state   <= S_REQ;
                        end else
                            state <= S_IDLE;             // window done / disabled
                    end
                    S_REQ: if (rd_ready) begin
                        rd_req <= 1'b0;                  // rd_data now held stable
                        state  <= S_STB;
                    end
                    S_STB:  state <= S_CAP;              // word_stb asserted (comb)
                    S_CAP: begin
                        dw    <= dec_dout;               // descrambled word valid
                        state <= S_HI;
                    end
                    S_HI: if (accept) begin              // emit high byte (paced)
                        byte_counter <= byte_counter + 32'd1;
                        state <= S_LO;
                    end
                    S_LO: begin
                        if (!emit_en) begin
                            // paused mid-word: hold dw, cur and the key schedule;
                            // a re-enable resumes here, it does not re-fetch.
                        end else if (last_word) begin    // MAME drops the final word's low byte
                            cur   <= cur + 25'd2;
                            state <= S_ADDR;             // -> S_ADDR sees cur>=end -> park
                        end else if (accept) begin       // emit low byte (paced)
                            byte_counter <= byte_counter + 32'd1;
                            cur   <= cur + 25'd2;
                            state <= S_ADDR;
                        end
                    end
                    default: state <= S_IDLE;
                endcase

                // A disable mid-stream stops cleanly, but ONLY from the PRE-DECODE
                // states: there nothing has been consumed (word_stb has not fired,
                // so the key schedule has not moved), the dropped req just goes
                // unserved, and cur is preserved -> a re-enable re-fetches the same
                // word cleanly. From S_STB onward the schedule HAS moved for the word
                // in flight, so those states pause in place via emit_en instead --
                // unwinding there re-descrambles that word with an advanced schedule.
                // (S_REQ also covers the rd_ready-in-the-same-cycle case: this
                // override wins over the case's S_STB assignment, so word_stb never
                // fires for a word we are about to abandon.)
`ifdef MP3_ENGATE_BUG
                if (!stream_en && state != S_IDLE) begin
`else
                if (!stream_en && (state == S_ADDR || state == S_REQ)) begin
`endif
                    state  <= S_IDLE;
                    rd_req <= 1'b0;
                end
            end

            prev_en <= stream_en;
        end
    end
endmodule
