`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_spike_descramble.v - vector DUMPER for Decision-B's differential oracle.
//
// This is NOT a self-checking unit test: it has no expected values inside it. It
// instantiates the REAL rtl/k573_mp3stream.v (+ rtl/k573_mp3dec.v), streams a
// window out of a sim DRAM backing, and writes every ACCEPTED out_byte to a file.
// The C reference (s573_descramble.c) is run over the same DRAM image with the
// same parameters and the two byte files are compared byte-for-byte by
// run_spike.py. Neither side can see the other's answer.
//
// Deliberate stimulus properties:
//   * the DRAM backing answers with a RANDOMIZED, always non-zero latency
//     (>= 2 cycles req->ready, occasional ~40-cycle DDR3-ish stalls), data
//     registered and held until the next request -- the k573dio backing contract;
//   * out_ready (the MAS3507D DEMAND model) is driven by a seeded pseudo-random
//     pattern selected by +bp=, including a near-stalled sink. The emitted byte
//     SEQUENCE must be invariant to it -- that invariance is part of the claim;
//   * +reload_at=N pulses `reload` (MAME update_mp3_decode_state) mid-stream, with
//     the sink quiesced first so the epoch boundary is unambiguous; the ACTUAL
//     pre-reload byte count is written to the .meta file for the C side to cut at.
//     (Quiescing is required: with the sink live, whether the byte in flight at the
//     reload posedge is consumed is a race -- which is exactly must-fix #1.)
//
// Plusargs (all decimal):
//   +hex=<file> +out=<file> +meta=<file>
//   +start= +end= +end2= +key1= +key2= +key3= +ddrsbm= +bp= +seed= +reload_at=
//   +maxcyc=
// -----------------------------------------------------------------------------
module tb_spike_descramble;

    localparam integer MEMW = 8192;          // 16 KiB sim DRAM window

    // ---- stimulus parameters (plusargs) -------------------------------------
    reg [1023:0] hexfile, outfile, metafile;
    integer p_start, p_end, p_end2, p_k1, p_k2, p_k3, p_sbm, p_bp, p_seed;
    integer p_reload_at, p_maxcyc;

    // ---- DUT plumbing -------------------------------------------------------
    reg         clk = 0, rst = 1;
    reg  [15:0] fpga_ctrl = 16'h0000;
    reg  [24:0] mp3_start = 25'd0, mp3_end = 25'd0;
    reg  [15:0] key1 = 16'd0, key2 = 16'd0, key3 = 16'd0;
    reg         ddrsbm = 1'b0;
    reg         reload = 1'b0;

    wire [24:0] rd_addr;
    wire        rd_req;
    reg  [15:0] rd_data_r = 16'd0;
    reg         rd_ready_r = 1'b0;

    wire [7:0]  out_byte;
    wire        out_valid;
    wire [31:0] byte_counter;
    wire [15:0] fpga_ctrl_rb;

    reg         sink_hold = 1'b0;            // force the sink dead (reload window)
    reg         rdy_r = 1'b0;
    wire        out_ready = rdy_r & ~sink_hold;

    reg  [15:0] mem [0:MEMW-1];

    always #5 clk = ~clk;

    k573_mp3stream dut (
        .clk(clk), .rst(rst),
        .fpga_ctrl(fpga_ctrl), .ddrsbm(ddrsbm),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .key1(key1), .key2(key2), .key3(key3), .reload(reload),
        .rd_addr(rd_addr), .rd_req(rd_req),
        .rd_data(rd_data_r), .rd_ready(rd_ready_r),
        .out_ready(out_ready), .out_byte(out_byte), .out_valid(out_valid),
        .byte_counter(byte_counter), .fpga_ctrl_rb(fpga_ctrl_rb)
    );

    // ---- seeded xorshift32 (portable + reproducible; no $random) -------------
    function [31:0] xs32(input [31:0] x);
        begin
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xs32 = x;
        end
    endfunction

    // ---- DRAM backing: req/ready, randomized NON-ZERO latency ---------------
    // Contract (k573dio BACKING_EXTERNAL): rd_req is held with rd_addr stable until
    // the backing pulses rd_ready for one cycle with rd_data REGISTERED and held.
    reg [31:0] lrnd;
    reg [7:0]  lat_cnt;
    reg        serving;
    wire [12:0] mem_idx = rd_addr[13:1];

    always @(posedge clk) begin
        rd_ready_r <= 1'b0;
        if (rst) begin
            serving <= 1'b0; lat_cnt <= 8'd0;
        end else if (!rd_req) begin
            serving <= 1'b0;                       // request withdrawn (reload)
        end else if (!serving) begin
            lrnd    <= xs32(lrnd);
            serving <= 1'b1;
            // 0..7 extra cycles, with a rare long DDR3-ish stall
            lat_cnt <= ((xs32(lrnd) & 32'h3f) == 32'd0) ? 8'd40
                                                        : (xs32(lrnd) & 32'h7);
        end else if (lat_cnt == 8'd0) begin
            rd_data_r  <= mem[mem_idx];
            rd_ready_r <= 1'b1;
            serving    <= 1'b0;
        end else begin
            lat_cnt <= lat_cnt - 8'd1;
        end
    end

    // ---- sink back-pressure (MAS3507D DEMAND model) -------------------------
    //  0 always ready | 1 deterministic 1-of-4 | 2 random ~50% | 3 random ~1/8
    //  4 bursty runs  | 5 near-stalled ~1/64
    reg [31:0] brnd;
    reg [1:0]  det_cnt;
    reg [15:0] burst_cnt;
    reg        burst_rdy;

    always @(posedge clk) begin
        if (rst) begin
            rdy_r <= 1'b0; det_cnt <= 2'd0; burst_cnt <= 16'd0; burst_rdy <= 1'b0;
        end else begin
            det_cnt <= det_cnt + 2'd1;
            case (p_bp)
                0: rdy_r <= 1'b1;
                1: rdy_r <= (det_cnt == 2'd0);
                2: begin brnd <= xs32(brnd); rdy_r <= (xs32(brnd) & 32'h1) != 0; end
                3: begin brnd <= xs32(brnd); rdy_r <= (xs32(brnd) & 32'h7) == 0; end
                4: begin
                       if (burst_cnt == 16'd0) begin
                           brnd      <= xs32(brnd);
                           burst_cnt <= 16'd1 + (xs32(brnd) & 32'h1f);
                           burst_rdy <= ~burst_rdy;
                           rdy_r     <= ~burst_rdy;
                       end else begin
                           burst_cnt <= burst_cnt - 16'd1;
                           rdy_r     <= burst_rdy;
                       end
                   end
                default: begin brnd <= xs32(brnd); rdy_r <= (xs32(brnd) & 32'h3f) == 0; end
            endcase
        end
    end

    // ---- byte collector: ONLY on an accepted transfer -----------------------
    integer fd_out, fd_meta;
    integer nbytes = 0;

    always @(posedge clk) if (!rst && out_valid && out_ready) begin
        $fwrite(fd_out, "%c", out_byte);
        nbytes = nbytes + 1;
    end

    // ---- sequence -----------------------------------------------------------
    integer cyc, idle, nb_pre, done, i, got;

    initial begin
        hexfile = 0; outfile = 0; metafile = 0;
        p_start = 0; p_end = 0; p_end2 = 0; p_k1 = 0; p_k2 = 0; p_k3 = 0;
        p_sbm = 0; p_bp = 0; p_seed = 1; p_reload_at = 0; p_maxcyc = 20000000;

        if (!$value$plusargs("hex=%s",  hexfile))  begin $display("SPIKE-TB: need +hex"); $finish; end
        if (!$value$plusargs("out=%s",  outfile))  begin $display("SPIKE-TB: need +out"); $finish; end
        got = $value$plusargs("meta=%s",      metafile);
        got = $value$plusargs("start=%d",     p_start);
        got = $value$plusargs("end=%d",       p_end);
        got = $value$plusargs("end2=%d",      p_end2);
        got = $value$plusargs("key1=%d",      p_k1);
        got = $value$plusargs("key2=%d",      p_k2);
        got = $value$plusargs("key3=%d",      p_k3);
        got = $value$plusargs("ddrsbm=%d",    p_sbm);
        got = $value$plusargs("bp=%d",        p_bp);
        got = $value$plusargs("seed=%d",      p_seed);
        got = $value$plusargs("reload_at=%d", p_reload_at);
        got = $value$plusargs("maxcyc=%d",    p_maxcyc);

        for (i = 0; i < MEMW; i = i + 1) mem[i] = 16'h0000;
        $readmemh(hexfile, mem);

        fd_out = $fopen(outfile, "wb");
        if (fd_out == 0) begin $display("SPIKE-TB: cannot open %0s", outfile); $finish; end

        // seeds: distinct streams for latency and back-pressure
        lrnd = xs32(32'h9E3779B9 ^ p_seed);
        brnd = xs32(32'h85EBCA6B + p_seed * 32'd2654435761);
        if (lrnd == 0) lrnd = 32'hDEADBEEF;
        if (brnd == 0) brnd = 32'hCAFEBABE;

        mp3_start = p_start;                  // truncates to 25 bits
        mp3_end   = p_end;
        key1      = p_k1;                     // truncates to 16 bits
        key2      = p_k2;
        key3      = p_k3;
        ddrsbm    = (p_sbm != 0);

        cyc = 0; idle = 0; nb_pre = -1; done = 0;

        repeat (4) @(posedge clk);
        @(negedge clk); rst = 1'b0; @(negedge clk);

        // seed the key schedule the way the game does: a setup-register write
        // (reload pulse), NOT an enable edge.
        @(negedge clk); reload = 1'b1; @(negedge clk); reload = 1'b0;
        repeat (2) @(posedge clk);

        fpga_ctrl = 16'h6000;                 // MP3_ENABLE | STREAMING_ENABLE

        while (done == 0) begin
            @(posedge clk);
            cyc = cyc + 1;

            if (p_reload_at > 0 && nb_pre < 0 && nbytes >= p_reload_at) begin
                sink_hold = 1'b1;             // quiesce the sink: unambiguous epoch
                repeat (16) @(posedge clk);
                nb_pre = nbytes;              // the MEASURED pre-reload byte count
                if (p_end2 > 0) mp3_end = p_end2;
                @(negedge clk); reload = 1'b1; @(negedge clk); reload = 1'b0;
                repeat (4) @(posedge clk);
                sink_hold = 1'b0;
                idle = 0;
            end

            if (nbytes > 0 && fpga_ctrl_rb == 16'h0000 && !sink_hold)
                idle = idle + 1;
            else
                idle = 0;

            if (idle > 3000) done = 1;                    // parked
            if (cyc > p_maxcyc) begin
                $display("SPIKE-TB: TIMEOUT at %0d cycles (nbytes=%0d)", cyc, nbytes);
                done = 2;
            end
        end

        $fclose(fd_out);

        if (metafile != 0) begin
            fd_meta = $fopen(metafile, "w");
            $fwrite(fd_meta, "nbytes %0d\n", nbytes);
            $fwrite(fd_meta, "cut %0d\n", (nb_pre < 0) ? 0 : nb_pre);
            $fwrite(fd_meta, "byte_counter %0d\n", byte_counter);
            $fwrite(fd_meta, "cycles %0d\n", cyc);
            $fwrite(fd_meta, "timeout %0d\n", (done == 2) ? 1 : 0);
            $fclose(fd_meta);
        end

        $display("SPIKE-TB: bytes=%0d cut=%0d byte_counter=%0d cycles=%0d%s",
                 nbytes, (nb_pre < 0) ? 0 : nb_pre, byte_counter, cyc,
                 (done == 2) ? " TIMEOUT" : "");
        $finish;
    end
endmodule
