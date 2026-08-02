// tb_s573_mp3_path.v - P4b wire-up integration test: the ENTIRE fabric-side
// MP3 transport as wired in emu.sv, driven end-to-end over the real SPI
// protocol. REAL modules: s573_hps_ext (mailbox) + s573_pcm_ring (reader) +
// s573_mp3_pcm (elastic buffer + 44100 drain) + s573_audio_mix, plus a
// VERBATIM copy of the emu.sv DIO read-channel mux arbitrating the reader
// against a fake sample-RAM master. Fake: DDR3, the arb 4-phase responder
// (with latency), the sample-RAM client, and the HPS (an SPI-driving model
// that prefills the ring, advertises pointers via CMD_573_PTRS, enables the
// drain via CMD_573_CTRL, and reads CMD_573_STATUS).
//
// Proves, at the integration seam the unit benches cannot see:
//  * every HPS-written stereo sample crosses SPI-pointer -> ring -> buffer ->
//    drain -> MIXER in order, exactly one pcm_sample_tick each;
//  * the mixer is a bit-exact SPU passthrough while MP3 idles, and an exact
//    sum while both play;
//  * the sample-RAM client keeps completing correct reads while the ring
//    reader shares the channel (mux fairness both ways);
//  * starvation is HONEST end-to-end: ticks freeze, MP3 goes silent, and
//    CMD_573_STATUS reports a rising underrun NUMBER; streaming resumes with
//    no lost or duplicated sample;
//  * a core soft reset freezes the pointer leg (stale PTRS ignored) until
//    the HPS acks the new epoch -- the reader stays OFF the bus meanwhile --
//    and the restarted stream plays only fresh data.
//
// The bench uses BEATS_LOG2=6 (64-beat ring) for fast wraps; the mailbox
// pointer words are 16-bit as on silicon, zero-extended here (emu.sv uses
// BEATS_LOG2=15 where the widths match exactly; the ring holds an
// elaboration guard against >15).
//
// Verilog-2005 / iverilog -g2005-sv.
`timescale 1ns/1ps
module tb_s573_mp3_path;
    localparam integer BL    = 6;
    localparam integer BEATS = (1 << BL);
    localparam [BL:0]  RING_FULL = BEATS[BL:0];

    integer errors = 0;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ================= EXT_BUS / SPI model (as in tb_s573_hps_ext) =========
    reg  [15:0] tb_din    = 0;
    reg         tb_strobe = 0;
    reg         tb_enable = 0;
    wire [35:0] EXT_BUS;
    assign EXT_BUS[31:16] = tb_din;
    assign EXT_BUS[33]    = tb_strobe;
    assign EXT_BUS[34]    = tb_enable;
    assign EXT_BUS[35]    = 1'b0;

    task spi_begin; begin @(negedge clk); tb_enable = 1; @(negedge clk); end endtask
    task spi_end;   begin @(negedge clk); tb_enable = 0; repeat (2) @(negedge clk); end endtask
    task spi_word;
        input  [15:0] din;
        output [15:0] dout;
        begin
            @(negedge clk); tb_din = din; tb_strobe = 1;
            @(negedge clk); tb_strobe = 0;
            @(negedge clk);
            dout = EXT_BUS[15:0];
        end
    endtask

    // ================= the REAL transport, wired as in emu.sv ==============
    wire [15:0] mp3_fab_pcm_rd;
    wire [15:0] mp3_hps_pcm_wr;
    wire [15:0] mp3_ctrl_flags;
    wire        mp3_dec_frame_sync, mp3_dec_frame_idle, mp3_evt_ovf;
    wire [15:0] mp3_pcm_l, mp3_pcm_r;
    wire        mp3_pcm_sample_tick;
    wire [31:0] mp3_underrun_cnt32, mp3_overflow_cnt32;
    wire  [9:0] mp3_buf_level;
    wire        mp3_buf_wr_en;
    wire [15:0] mp3_buf_wr_l, mp3_buf_wr_r;
    wire        mp3_buf_wr_full;
    wire        ring_rd_req;
    wire [21:0] ring_rd_addr;
    wire        ring_rd_ack;
    wire        heartbeat;
    wire [63:0] dio_mem_rd_q;      // shared arb data bus (declared before use)
    wire        dio_mem_rd_ack;

    wire [15:0] mp3_underrun_sat = (|mp3_underrun_cnt32[31:16]) ? 16'hFFFF
                                                                : mp3_underrun_cnt32[15:0];
    wire [15:0] mp3_buf_level16  = {6'd0, mp3_buf_level};
    wire [15:0] mp3_status_flags = {12'd0, mp3_evt_ovf, (mp3_buf_level != 0),
                                    mp3_ctrl_flags[1], mp3_ctrl_flags[0]};

    // bench-only width adaptation (BL=6 here vs 15 in emu.sv)
    wire [BL:0] ring_fab_rd_ptr;
    assign mp3_fab_pcm_rd = {{(15-BL){1'b0}}, ring_fab_rd_ptr};

    s573_hps_ext mbox (
        .clk_sys(clk), .rst(rst), .EXT_BUS(EXT_BUS), .heartbeat(heartbeat),
        .fab_pcm_rd(mp3_fab_pcm_rd), .hps_pcm_wr(mp3_hps_pcm_wr),
        // option (c): the byte-ring leg is gone; these are the repurposed words
        .fab_pos_lo(16'd0), .cfg_epoch(16'd0), .hps_cons_bytes(),
        .mp3_start(25'd0), .mp3_end(25'd0),
        .mp3_key1(16'd0), .mp3_key2(16'd0), .mp3_key3(16'd0),
        .cfg_ddrsbm(1'b0), .fpga_ctrl_en(3'd0),
        .status_flags(mp3_status_flags), .underrun_cnt(mp3_underrun_sat),
        .buf_level(mp3_buf_level16),
        .ctrl_flags(mp3_ctrl_flags), .dec_frame_sync(mp3_dec_frame_sync),
        .dec_frame_idle(mp3_dec_frame_idle), .evt_ovf(mp3_evt_ovf)
    );

    s573_pcm_ring #(.RING_OFF_BEAT(22'd0), .BEATS_LOG2(BL)) u_pcm_ring (
        .clk(clk), .rst(rst),
        .hps_wr_ptr(mp3_hps_pcm_wr[BL:0]), .fab_rd_ptr(ring_fab_rd_ptr),
        .rd_req(ring_rd_req), .rd_addr(ring_rd_addr),
        .rd_data(dio_mem_rd_q), .rd_ack(ring_rd_ack),
        .wr_en(mp3_buf_wr_en), .wr_l(mp3_buf_wr_l), .wr_r(mp3_buf_wr_r),
        .wr_full(mp3_buf_wr_full)
    );

    s573_mp3_pcm #(.AW(9)) u_mp3_pcm (
        .clk(clk), .rst(rst),
        .wr_en(mp3_buf_wr_en), .wr_l(mp3_buf_wr_l), .wr_r(mp3_buf_wr_r),
        .wr_full(mp3_buf_wr_full), .wr_level(mp3_buf_level),
        .drain_en(mp3_ctrl_flags[1]),
        .pcm_l(mp3_pcm_l), .pcm_r(mp3_pcm_r), .pcm_sample_tick(mp3_pcm_sample_tick),
        .underrun_cnt(mp3_underrun_cnt32), .overflow_cnt(mp3_overflow_cnt32)
    );

    reg  [15:0] spu_l = 0, spu_r = 0;
    wire [15:0] audio_l, audio_r;
    s573_audio_mix u_audio_mix (
        .spu_l(spu_l), .spu_r(spu_r), .mp3_l(mp3_pcm_l), .mp3_r(mp3_pcm_r),
        .out_l(audio_l), .out_r(audio_r)
    );

    // ---- fake sample-RAM master (the mux's priority client) ----
    localparam [21:0] SRAM_ADDR    = 22'h000100;   // outside the 64-beat ring
    localparam [63:0] SRAM_PATTERN = 64'hA5A5_0573_DEAD_BEA7;
    reg         sm_req = 0;
    reg  [21:0] sm_addr = SRAM_ADDR;
    wire        sm_ack;
    integer     sm_done = 0, sm_bad = 0;
    reg  [2:0]  sm_state = 0;
    reg  [9:0]  sm_wait = 0;
    always @(posedge clk) begin
        if (rst) begin sm_req <= 0; sm_state <= 0; sm_wait <= 0; end
        else case (sm_state)
            0: begin sm_wait <= sm_wait + 1'd1;
                     if (&sm_wait[8:0]) begin sm_req <= 1; sm_state <= 1; end end
            1: if (sm_ack) begin
                   if (dio_mem_rd_q !== SRAM_PATTERN) sm_bad = sm_bad + 1;
                   sm_done = sm_done + 1;
                   sm_req <= 0; sm_state <= 2;
               end
            2: if (!sm_ack) sm_state <= 0;
        endcase
    end

    // ---- DIO read-channel mux: VERBATIM copy of the emu.sv wire-up ----
    // (client0 = sample-RAM master, client1 = PCM-ring reader)
    wire        dio_mem_rd_req  = sm_req;
    wire [21:0] dio_mem_rd_addr = sm_addr;
    assign      sm_ack          = dio_mem_rd_ack;
    reg         dio_rd_owner;
    reg         dio_rd_busy;
    reg  [21:0] dio_arb_rd_addr;   // registered at the grant edge, as in emu.sv
    wire dio_arb_rd_ack;
    always @(posedge clk) begin
        if (rst) begin
            dio_rd_busy  <= 0;
            dio_rd_owner <= 0;
        end else if (!dio_rd_busy) begin
            if (dio_mem_rd_req) begin
                dio_rd_busy  <= 1;
                dio_rd_owner <= 0;
                dio_arb_rd_addr <= dio_mem_rd_addr;
            end else if (ring_rd_req) begin
                dio_rd_busy  <= 1;
                dio_rd_owner <= 1;
                dio_arb_rd_addr <= ring_rd_addr;
            end
        end else if (!(dio_rd_owner ? ring_rd_req : dio_mem_rd_req) && !dio_arb_rd_ack) begin
            dio_rd_busy <= 0;
        end
    end
    wire dio_arb_rd_req = dio_rd_busy & (dio_rd_owner ? ring_rd_req : dio_mem_rd_req);
    assign dio_mem_rd_ack = dio_rd_busy & ~dio_rd_owner & dio_arb_rd_ack;
    assign ring_rd_ack    = dio_rd_busy &  dio_rd_owner & dio_arb_rd_ack;

    // sample-RAM latency tracker: the mux's stated property is "game reads
    // wait at most one in-flight ring beat" -- measure it, don't vibe it
    integer sm_lat = 0, sm_lat_max = 0;
    always @(posedge clk) begin
        if (rst) begin sm_lat <= 0; end
        else if (sm_req && !sm_ack) sm_lat <= sm_lat + 1;
        else if (sm_ack) begin
            if (sm_lat > sm_lat_max) sm_lat_max = sm_lat;
            sm_lat <= 0;
        end else sm_lat <= 0;
    end

    // ---- fake DDR3 + fake arb responder (4-phase, with latency) ----
    reg [63:0] ddr [0:BEATS-1];
    localparam [1:0] A_IDLE=2'd0, A_LAT=2'd1, A_ACK=2'd2, A_DROP=2'd3;
    reg [1:0]  as;
    reg [7:0]  alat;
    reg [63:0] arb_data;
    reg        arb_ack;
    assign dio_mem_rd_q  = arb_data;
    assign dio_arb_rd_ack = arb_ack;
    always @(posedge clk) begin
        if (rst) begin as <= A_IDLE; arb_ack <= 1'b0; arb_data <= 64'd0; alat <= 8'd0; end
        else case (as)
            A_IDLE: if (dio_arb_rd_req) begin alat <= 8'd4; as <= A_LAT; end
            A_LAT:  if (alat == 8'd0) begin
                        arb_data <= (dio_arb_rd_addr == SRAM_ADDR) ? SRAM_PATTERN
                                                                   : ddr[dio_arb_rd_addr[BL-1:0]];
                        arb_ack <= 1'b1; as <= A_ACK;
                    end else alat <= alat - 8'd1;
            A_ACK:  if (!dio_arb_rd_req) begin arb_ack <= 1'b0; as <= A_DROP; end
            A_DROP: as <= A_IDLE;
        endcase
    end

    // ---- tick capture at the MIXER OUTPUT (the k573dio counter's view) ----
    localparam integer MAXSAMP = 1200;
    integer nsamp = 0;
    reg [15:0] gl [0:MAXSAMP];
    reg [15:0] gr [0:MAXSAMP];
    reg [15:0] gspu_l [0:MAXSAMP];   // spu at tick time, to check the sum
    always @(posedge clk) if (!rst && mp3_pcm_sample_tick) begin
        if (nsamp <= MAXSAMP) begin
            gl[nsamp] = audio_l; gr[nsamp] = audio_r; gspu_l[nsamp] = spu_l;
        end
        nsamp = nsamp + 1;
    end

    function [15:0] enc_l; input integer idx; enc_l = 16'h1000 + idx[15:0]; endfunction
    function [15:0] enc_r; input integer idx; enc_r = 16'h2000 + idx[15:0]; endfunction

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

    // ---- HPS model state ----
    integer beats_written = 0;      // global beat index ever written (sample idx = 2x)
    reg [15:0] hps_wr = 0;          // HPS's own wr pointer (beats, [BL:0] live range)
    reg [15:0] hps_sync_cnt = 0;    // cumulative frame counter (low 8 bits used)
    reg [15:0] r0, r1, r2, r3;
    reg [15:0] last_fab_rd;
    integer i, w, room, base_samp, t0;

    // one PTRS poll: advertise hps_wr, learn fab_rd (word0), ack epoch
    reg [7:0] cur_epoch_ack = 0;
    task ptrs_poll;
        begin
            spi_begin;
            spi_word(16'h0068, last_fab_rd);
            spi_word(hps_wr, r1);
            spi_word(16'h0000, r2);
            spi_word({8'd0, cur_epoch_ack}, r3);
            spi_end;
        end
    endtask

    // one CTRL poll: cumulative counts + flags
    task ctrl_poll;
        input [15:0] flags;
        begin
            spi_begin;
            spi_word(16'h006A, r0);
            spi_word({hps_sync_cnt[7:0], 8'd0}, r1);
            spi_word(flags, r2);
            spi_end;
        end
    endtask

    // write N beats into the fake DDR3 ring (respecting free space via the
    // last SPI-learned fab_rd), then advertise via a PTRS poll
    localparam [15:0] PTR_MASK = 16'h007F;   // [BL:0] pointer space (BL=6)
    task produce_beats;
        input integer n;
        integer b;
        begin
            for (b = 0; b < n; b = b + 1) begin
                room = RING_FULL - ((hps_wr - last_fab_rd) & PTR_MASK);
                while (room < 1) begin
                    ptrs_poll;
                    repeat (50) @(posedge clk);
                    room = RING_FULL - ((hps_wr - last_fab_rd) & PTR_MASK);
                end
                @(negedge clk);
                ddr[hps_wr[BL-1:0]] = { enc_r(2*beats_written+1), enc_l(2*beats_written+1),
                                        enc_r(2*beats_written),   enc_l(2*beats_written) };
                hps_wr = (hps_wr + 1) & {{(15-BL){1'b0}}, {(BL+1){1'b1}}};
                beats_written = beats_written + 1;
            end
            ptrs_poll;
        end
    endtask

    // hard watchdog: the room-wait in produce_beats is unbounded by design
    // (real progress = drain rate); if the transport wedges, fail LOUDLY
    // instead of hanging the suite
    initial begin
        #12_000_000;   // 1.2M clk cycles >> the ~450k a healthy run needs
        $display("FAIL: global watchdog -- transport wedged");
        $display("  nsamp=%0d beats_written=%0d hps_wr=%h last_fab_rd=%h",
                 nsamp, beats_written, hps_wr, last_fab_rd);
        $display("  hps_pcm_wr=%h fab_rd=%h buf_level=%0d ctrl=%h uflow=%0d",
                 mp3_hps_pcm_wr, ring_fab_rd_ptr, mp3_buf_level,
                 mp3_ctrl_flags, mp3_underrun_cnt32);
        $display("  ring_req=%b busy=%b owner=%b arb_as=%0d sm_done=%0d",
                 ring_rd_req, dio_rd_busy, dio_rd_owner, as, sm_done);
        $display("RESULT: FAIL (s573_mp3_path, watchdog)");
        $finish;
    end

    initial begin
        // ---------- reset / init (order as on silicon) ----------
        repeat (6) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (4) @(posedge clk);

        // HPS init: the core-load reset already bumped rst_epoch, so the
        // first poll LEARNS the epoch and the second ACKS it (stored ack is
        // compared, so pointers thaw from the poll after the ack lands) --
        // exactly what the real s573mp3 service must do at startup
        ptrs_poll;
        chk(r3[7:0] != 8'd0, "init: core-load reset bumped rst_epoch");
        cur_epoch_ack = r3[7:0];
        ptrs_poll;
        // adopt baselines (rebaseline poll), ddrsbm on, drain OFF
        hps_sync_cnt = 0;
        ctrl_poll(16'h0001);
        chk(mp3_ctrl_flags == 16'h0001, "init: cfg_ddrsbm set, drain off");
        chk(mp3_pcm_sample_tick == 0,   "init: no ticks with drain off");

        // ---------- prefill, then enable the drain ----------
        produce_beats(32);              // 64 samples in the ring
        repeat (400) @(posedge clk);    // let the reader pull some into the buffer
        chk(mp3_buf_level != 0,         "prefill: reader filled the elastic buffer");
        chk(nsamp == 0,                 "prefill: still no ticks before drain_en");
        hps_sync_cnt = hps_sync_cnt + 1;   // pretend one frame decoded
        ctrl_poll(16'h0003);            // drain ON
        chk(mp3_ctrl_flags == 16'h0003, "start: drain enabled over SPI");

        // ---------- stream 200 beats (400 samples) with polls ----------
        spu_l = 16'h0100; spu_r = -16'sd256;   // constant SPU tone: mixer must SUM
        t0 = 0;
        for (i = 0; i < 21; i = i + 1) begin
            produce_beats(8);
            hps_sync_cnt = hps_sync_cnt + 1;
            ctrl_poll(16'h0003);
            repeat (2000) @(posedge clk);      // ~2.6 samples of drain per lap
        end
        // 32 + 21*8 = 200 beats = 400 samples total written
        w = 0;
        while (nsamp < 400 && w < 400*900) begin @(posedge clk); w = w + 1; end
        chk(nsamp == 400, "stream: all 400 samples drained (no stall)");

        // sample-RAM client kept running throughout. The ring reader holds a
        // multi-beat backlog through the whole stream phase (production
        // outpaces the 44100 drain), so these reads are genuinely contended.
        chk(sm_done >= 20, "mux: sample-RAM client completed reads under contention");
        chk(sm_bad == 0,   "mux: every sample-RAM read returned its own data");
        // bound: one in-flight ring beat (grant + 4-cyc arb latency + 4-phase
        // close, twice) plus own handshake -- measured healthy max ~24
        chk(sm_lat_max > 0,   "mux: latency tracker is non-vacuous");
        chk(sm_lat_max <= 32, "mux: game-read latency bounded by one in-flight ring beat");

        // values IN ORDER at the mixer output: audio = spu + pcm (no clip in range)
        w = 0;
        for (i = 0; i < 400; i = i + 1) begin
            if (gl[i] !== (enc_l(i) + gspu_l[i]))                w = w + 1;
            if (gr[i] !== (enc_r(i) - 16'd256))                  w = w + 1;
        end
        chk(w == 0, "stream: every sample in order, mixer sums SPU+MP3 exactly");

        // STATUS over SPI: zero underruns while fed
        spi_begin; spi_word(16'h0069, r0); spi_word(16'h0000, r1); spi_word(16'h0000, r2); spi_end;
        chk(r1 == 16'h0000, "stream: STATUS underrun == 0 while fed");
        chk(r0[1:0] == 2'b11, "stream: STATUS echoes ddrsbm+drain flags");

        // ---------- starve: everything produced is already drained ----------
        // (the nsamp==400 wait above ends exactly when ring+buffer emptied)
        base_samp = nsamp;
        repeat (4*800) @(posedge clk);   // several sample-clocks of starvation
        chk(nsamp == base_samp, "starve: ticks FROZEN (no fabricated samples)");
        chk(mp3_pcm_l == 0 && mp3_pcm_r == 0, "starve: MP3 channel honestly silent");
        chk(audio_l == 16'h0100, "starve: mixer passes SPU through");
        spi_begin; spi_word(16'h0069, r0); spi_word(16'h0000, r1); spi_word(16'h0000, r2); spi_end;
        chk(r1 != 16'h0000, "starve: STATUS underrun_cnt counts (a NUMBER, not a vibe)");

        // ---------- resume: no lost or duplicated sample ----------
        base_samp = nsamp;   // == total produced so far
        chk(base_samp == beats_written*2, "starve: drained exactly what was produced");
        produce_beats(20);
        w = 0;
        while (nsamp < base_samp + 40 && w < 60*900) begin @(posedge clk); w = w + 1; end
        chk(nsamp == base_samp + 40, "resume: stream continues");
        w = 0;
        for (i = base_samp; i < base_samp + 40; i = i + 1)
            if (gl[i] !== (enc_l(i) + 16'h0100)) w = w + 1;
        chk(w == 0, "resume: sequence continues exactly where it stopped");

        // ---------- core soft reset: pointer freeze end-to-end ----------
        @(negedge clk); rst = 1;
        repeat (3) @(negedge clk); rst = 0;
        repeat (10) @(posedge clk);
        chk(mp3_ctrl_flags == 0, "reset: drain disabled");
        // stale poll (old epoch ack): pointer must stay frozen, reader off the bus
        ptrs_poll;   // cur_epoch_ack is now stale; hps_wr still nonzero = stale
        repeat (200) @(posedge clk);
        chk(mp3_hps_pcm_wr == 0, "reset: stale PTRS pointer frozen out");
        chk(ring_rd_req == 0,    "reset: ring reader stays off the bus");
        chk(r3[7:0] == cur_epoch_ack + 8'd1, "reset: PTRS word3 reports the bumped epoch");
        // HPS reacts: re-init, ack the epoch, restart the stream fresh
        cur_epoch_ack = r3[7:0];
        hps_wr = 0; last_fab_rd = 0;
        beats_written = 0; nsamp = 0;        // fresh sequence from index 0
        ptrs_poll;                            // ack lands (pointer word still 0)
        ctrl_poll(16'h0003);                  // rebaseline consumed + drain on
        produce_beats(8);
        w = 0;
        while (nsamp < 16 && w < 20*900) begin @(posedge clk); w = w + 1; end
        chk(nsamp == 16, "reset: fresh stream flows after epoch ack");
        w = 0;
        for (i = 0; i < 16; i = i + 1)
            if (gl[i] !== (enc_l(i) + 16'h0100)) w = w + 1;
        chk(w == 0, "reset: only FRESH data plays (no stale replay)");

        if (errors == 0) $display("RESULT: PASS (s573_mp3_path)");
        else             $display("RESULT: FAIL (s573_mp3_path, %0d errors)", errors);
        $finish;
    end
endmodule
