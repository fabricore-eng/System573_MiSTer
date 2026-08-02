// tb_s573_pcm_ring.v - integration test: HPS PCM ring -> reader -> elastic buffer
// -> 44100 drain. A fake DDR3 + fake arb responder (4-phase, with latency) + a
// fake HPS writer drive the REAL s573_mp3_pcm sink. Proves the transport delivers
// every HPS-written stereo sample to the drain in order, across multiple ring
// wraps, with reader back-pressure when the buffer fills and NO underrun when fed.
//
// Verilog-2005 / iverilog -g2005-sv.
`timescale 1ns/1ps
module tb_s573_pcm_ring;
    localparam integer BL     = 6;             // BEATS_LOG2 -> 64-beat ring (fast wrap)
    localparam integer BEATS  = (1 << BL);
    localparam [BL:0]  RING_FULL = BEATS[BL:0];
    localparam integer NBEATS = 300;           // 600 samples > ring(64) and > buffer(512): wrap + back-pressure
    localparam integer NSAMP  = 2 * NBEATS;
    localparam integer PERIOD_GUARD = 900;     // ~drain period (768) + slack, per sample

    integer errors = 0;
    integer i, bad, w, bn;
    reg [BL:0] outstanding;

    reg  clk = 0, rst = 1;

    // reader <-> arb (4-phase read)
    wire        rd_req;
    wire [21:0] rd_addr;
    reg  [63:0] rd_data;
    reg         rd_ack;
    // reader <-> sink (elastic buffer fill)
    wire        wr_en;
    wire [15:0] wr_l, wr_r;
    wire        wr_full;
    // ring pointers
    reg  [BL:0] hps_wr_ptr;
    wire [BL:0] fab_rd_ptr;

    s573_pcm_ring #(.RING_OFF_BEAT(22'd0), .BEATS_LOG2(BL)) rdr (
        .clk(clk), .rst(rst),
        .hps_wr_ptr(hps_wr_ptr), .fab_rd_ptr(fab_rd_ptr),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_data(rd_data), .rd_ack(rd_ack),
        .wr_en(wr_en), .wr_l(wr_l), .wr_r(wr_r), .wr_full(wr_full)
    );

    // real elastic buffer + 44100 drain sink
    wire [15:0] pcm_l, pcm_r;
    wire        pcm_tick;
    wire [31:0] uflow, oflow;
    wire [9:0]  lvl;
    reg         drain_en = 0;
    s573_mp3_pcm #(.AW(9)) snk (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_l(wr_l), .wr_r(wr_r), .wr_full(wr_full), .wr_level(lvl),
        .drain_en(drain_en),
        .pcm_l(pcm_l), .pcm_r(pcm_r), .pcm_sample_tick(pcm_tick),
        .underrun_cnt(uflow), .overflow_cnt(oflow)
    );

    always #5 clk = ~clk;

    // ---- fake DDR3 (the PCM ring) ----
    reg [63:0] ddr [0:BEATS-1];

    // ---- fake arb responder: 4-phase level handshake with fixed latency ----
    localparam [1:0] A_IDLE=2'd0, A_LAT=2'd1, A_ACK=2'd2, A_DROP=2'd3;
    reg [1:0] as;
    reg [7:0] alat;
    reg [7:0] ARB_LAT;
    always @(posedge clk) begin
        if (rst) begin as <= A_IDLE; rd_ack <= 1'b0; rd_data <= 64'd0; alat <= 8'd0; end
        else case (as)
            A_IDLE: if (rd_req) begin alat <= ARB_LAT; as <= A_LAT; end
            A_LAT:  if (alat == 8'd0) begin rd_data <= ddr[rd_addr[BL-1:0]]; rd_ack <= 1'b1; as <= A_ACK; end
                    else alat <= alat - 8'd1;
            A_ACK:  if (!rd_req) begin rd_ack <= 1'b0; as <= A_DROP; end   // data holds through A_ACK
            A_DROP: as <= A_IDLE;
        endcase
    end

    // ---- tick capture ----
    integer nsamp = 0;
    reg [15:0] gl [0:NSAMP+8];
    reg [15:0] gr [0:NSAMP+8];
    always @(posedge clk) if (!rst && pcm_tick) begin
        if (nsamp <= NSAMP+8) begin gl[nsamp] = pcm_l; gr[nsamp] = pcm_r; end
        nsamp = nsamp + 1;
    end

    // sample value encoding: L = 0x1000+idx, R = 0x2000+idx (idx = global sample index)
    function [15:0] enc_l; input integer idx; enc_l = 16'h1000 + idx[15:0]; endfunction
    function [15:0] enc_r; input integer idx; enc_r = 16'h2000 + idx[15:0]; endfunction

    // ---- fake HPS writer (own process): NBEATS beats, respecting ring free space ----
    initial begin
        hps_wr_ptr = 0;
        @(negedge rst);
        repeat (3) @(posedge clk);
        for (bn = 0; bn < NBEATS; bn = bn + 1) begin
            outstanding = hps_wr_ptr - fab_rd_ptr;
            while (outstanding >= RING_FULL) begin
                @(posedge clk); outstanding = hps_wr_ptr - fab_rd_ptr;
            end
            @(negedge clk);
            ddr[hps_wr_ptr[BL-1:0]] = { enc_r(2*bn+1), enc_l(2*bn+1), enc_r(2*bn), enc_l(2*bn) };
            hps_wr_ptr = hps_wr_ptr + 1'b1;      // advertise AFTER the payload write
            repeat (60) @(posedge clk);          // pace producer; the 44100 drain is the bottleneck
        end
    end

    // ---- main: run the drain, wait for all samples, check ----
    initial begin
        ARB_LAT = 8'd4;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat (2) @(posedge clk);
        drain_en = 1;

        w = 0;
        while (nsamp < NSAMP && w < (NSAMP*PERIOD_GUARD)) begin @(posedge clk); w = w + 1; end

        if (nsamp !== NSAMP) begin
            $display("FAIL: drained %0d of %0d samples (timeout)", nsamp, NSAMP);
            errors = errors + 1;
        end
        bad = 0;
        for (i = 0; i < NSAMP && i < nsamp; i = i + 1)
            if (gl[i] !== enc_l(i) || gr[i] !== enc_r(i)) begin
                if (bad < 6) $display("FAIL: sample %0d = (%04h,%04h) exp (%04h,%04h)", i, gl[i], gr[i], enc_l(i), enc_r(i));
                bad = bad + 1;
            end
        if (bad !== 0) begin $display("FAIL: %0d sample mismatches across the transport", bad); errors = errors + 1; end
        if (uflow !== 32'd0) begin $display("FAIL: underrun on a fed ring (cnt=%0d)", uflow); errors = errors + 1; end
        if (oflow !== 32'd0) begin $display("FAIL: reader over-pushed the elastic buffer (cnt=%0d)", oflow); errors = errors + 1; end

        if (errors == 0) $display("RESULT: PASS (s573_pcm_ring)");
        else             $display("RESULT: FAIL (s573_pcm_ring, %0d errors)", errors);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("RESULT: FAIL (s573_pcm_ring, TIMEOUT)");
        $finish;
    end
endmodule
