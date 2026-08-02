`timescale 1ns/1ps
// Testbench for s573_ddram_arb.v - the DDR3 port arbiter (psx master priority +
// 573 DIO-RAM single-beat client).
//
// Models the three parties around the DUT:
//   * an Avalon-ish DDR slave (random BUSY, in-order read beats with random
//     latency/gaps, first-beat-address burst writes with byte enables);
//   * a psx-like master issuing read bursts and write bursts -- INCLUDING
//     write bursts with WE gaps mid-burst (the wr_rem hazard: a DIO op slipped
//     into such a gap would be counted as a burst beat by the slave and corrupt
//     both sides);
//   * a DIO client on a half-rate, edge-aligned clock (the clk_1x fabric)
//     doing 4-phase reads/writes into its 32 MiB window.
//
// Correctness = pure data scoreboarding: psx addresses always hold f(addr)
// (writes rewrite it, so any interleave corruption surfaces as a mismatch);
// DIO words are shadowed per-write. Any misrouting, lost beat, misattributed
// DOUT_READY, or mid-burst interleave shows up as a data error on one side.
module tb_s573_ddram_arb;
    reg clk2 = 0, clk1 = 0, rst = 1;
    always #5  clk2 = ~clk2;
    always #10 clk1 = ~clk1;   // half rate. TB phase puts clk1 edges on clk2 NEGEDGES;
                               // the 4-phase LEVEL handshakes under test are phase-
                               // insensitive (real silicon has coincident rising edges)

    integer errors = 0;

    // ---- DUT wires ----
    reg         busy = 0;
    wire [7:0]  ddr_burstcnt;
    wire [28:0] ddr_addr;
    reg  [63:0] ddr_dout = 0;
    reg         ddr_dout_ready = 0;
    wire        ddr_rd, ddr_we;
    wire [63:0] ddr_din;
    wire [7:0]  ddr_be;

    wire        psx_busy_w;
    reg  [7:0]  p_burst = 8'd1;
    reg  [28:0] p_addr = 0;
    wire [63:0] psx_dout_w;
    wire        psx_rdy_w;
    reg         p_rd = 0, p_we = 0;
    reg  [63:0] p_din = 0;

    reg         d_rd_req = 0, d_wr_req = 0;
    reg  [21:0] d_rd_addr = 0;
    wire [63:0] d_rd_data;
    wire        d_rd_ack, d_wr_ack;
    reg  [23:0] d_wr_addr = 0;
    reg  [15:0] d_wr_data = 0;

    s573_ddram_arb #(.DIO_BASE_BEAT(29'h0640_0000)) dut (
        .clk(clk2), .rst(rst),
        .ddr_busy(busy), .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr),
        .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
        .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
        .psx_busy(psx_busy_w), .psx_burstcnt(p_burst), .psx_addr(p_addr),
        .psx_dout(psx_dout_w), .psx_dout_ready(psx_rdy_w),
        .psx_rd(p_rd), .psx_din(p_din), .psx_be(8'hFF), .psx_we(p_we),
        .dio_rd_req(d_rd_req), .dio_rd_addr(d_rd_addr),
        .dio_rd_data(d_rd_data), .dio_rd_ack(d_rd_ack),
        .dio_wr_req(d_wr_req), .dio_wr_addr(d_wr_addr),
        .dio_wr_data(d_wr_data), .dio_wr_ack(d_wr_ack)
    );

    // deterministic psx-region content: every address always holds f64(addr)
    function [63:0] f64(input [28:0] a);
        f64 = {a ^ 29'h15A5A5A, 3'b010, a, 3'b101};
    endfunction

    // ---- backing stores ----
    // psx region: beats 0x0600_0000..+1023 (bursts from idx<=511 stay inside).
    // psx writes are GENERATION-stamped and shadowed in psh -- pure-f64 data
    // would make the write path vacuous (a dropped psx write would be invisible).
    reg [63:0] pmem [0:1023];
    reg [63:0] psh  [0:1023];   // psx shadow (expected content at issue time)
    // dio: TWO banks so the full 22-bit beat address path through the arbiter
    // is observable -- low (beats 0..511) and window-top (beats 0x3FFE00..).
    // dmem index = {beat[21], beat[8:0]}; dsh index = {word[23], word[10:0]}.
    reg [63:0] dmem [0:1023];
    reg [15:0] dsh  [0:4095];   // dio shadow, per 16-bit word

    // ---- DDR slave model (clk2) ----
    reg [28:0] rq_addr [0:255];   // pending read beats, in order
    reg [7:0]  rq_wp = 0, rq_rp = 0;
    integer    resp_gap = 0;
    reg [7:0]  s_wrem = 0;        // write-burst beats remaining
    reg [28:0] s_waddr = 0;
    integer    k;

    task slave_apply(input [28:0] a, input [63:0] d, input [7:0] be);
        integer j; reg [63:0] cur;
        begin
            if (a[28:20] == 9'h060)      cur = pmem[a[9:0]];
            else if (a[28:22] == 7'h19)  cur = dmem[{a[21], a[8:0]}];
            else begin
                errors = errors + 1; cur = 64'd0;
                if (errors <= 10) $display("FAIL: write to unmapped beat %07h", a);
            end
            for (j = 0; j < 8; j = j + 1)
                if (be[j]) cur[j*8 +: 8] = d[j*8 +: 8];
            if (a[28:20] == 9'h060)      pmem[a[9:0]] = cur;
            else if (a[28:22] == 7'h19)  dmem[{a[21], a[8:0]}] = cur;
        end
    endtask

    always @(posedge clk2) begin
        busy <= (($random & 31'h7fffffff) % 100) < 25;   // ~25% busy
        ddr_dout_ready <= 1'b0;
        if (!rst) begin
            // command acceptance
            if (ddr_rd && !busy) begin
                for (k = 0; k < ddr_burstcnt; k = k + 1) begin
                    rq_addr[rq_wp] = ddr_addr + k[28:0];
                    rq_wp = rq_wp + 8'd1;
                end
            end
            if (ddr_we && !busy) begin
                if (s_wrem == 8'd0) begin
                    slave_apply(ddr_addr, ddr_din, ddr_be);
                    s_waddr <= ddr_addr + 29'd1;
                    s_wrem  <= ddr_burstcnt - 8'd1;
                end else begin
                    slave_apply(s_waddr, ddr_din, ddr_be);
                    s_waddr <= s_waddr + 29'd1;
                    s_wrem  <= s_wrem - 8'd1;
                end
            end
            // in-order read beat returns with random gaps
            if (rq_wp != rq_rp) begin
                if (resp_gap == 0) begin
                    if (rq_addr[rq_rp][28:20] == 9'h060)
                        ddr_dout <= pmem[rq_addr[rq_rp][9:0]];
                    else
                        ddr_dout <= dmem[{rq_addr[rq_rp][21], rq_addr[rq_rp][8:0]}];
                    ddr_dout_ready <= 1'b1;
                    rq_rp    = rq_rp + 8'd1;
                    resp_gap = ($random & 31'h7fffffff) % 4;
                end else
                    resp_gap = resp_gap - 1;
            end
        end
    end

    // ---- psx read-response checker (in-order expectation queue) ----
    reg [63:0] expq [0:255];
    reg [7:0]  eq_wp = 0, eq_rp = 0;
    always @(posedge clk2) if (!rst && psx_rdy_w) begin
        if (eq_wp == eq_rp) begin
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: unexpected psx_dout_ready");
        end else begin
            if (psx_dout_w !== expq[eq_rp]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL: psx beat = %016h expected %016h", psx_dout_w, expq[eq_rp]);
            end
            eq_rp = eq_rp + 8'd1;
        end
    end

    // ---- psx master tasks (clk2) ----
    // Acceptance sampling: the value psx_busy_w holds MID-CYCLE (at a negedge)
    // is exactly what the slave/arbiter read at the following posedge, so the
    // command is held while busy is seen at negedges and released right after
    // the accepting posedge (avoids the classic post-NBA busy sampling race).
    task psx_read(input [8:0] idx, input integer n);
        integer j;
        begin
            while ((eq_wp - eq_rp) > 8'd24) @(posedge clk2);
            @(negedge clk2);
            p_addr  = 29'h0600_0000 + {20'd0, idx};
            p_burst = n[7:0];
            for (j = 0; j < n; j = j + 1) begin
                expq[eq_wp] = psh[idx + j];
                eq_wp = eq_wp + 8'd1;
            end
            p_rd = 1; #1;
            while (psx_busy_w) begin @(negedge clk2); #1; end
            @(posedge clk2);   // command accepted at this edge
            p_rd = 0;
        end
    endtask

    reg [31:0] pgen = 32'd0;   // per-write-op generation stamp
    task psx_write(input [8:0] idx, input integer n);
        integer j;
        begin
            // no pending read responses may overlap a write (read expectations
            // are issue-time psh snapshots) -- drain first
            while (eq_wp != eq_rp) @(posedge clk2);
            @(negedge clk2);
            pgen    = pgen + 32'd1;
            p_addr  = 29'h0600_0000 + {20'd0, idx};
            p_burst = n[7:0];
            for (j = 0; j < n; j = j + 1) begin
                p_din = f64(29'h0600_0000 + {20'd0, idx} + j[28:0]) ^ {pgen, ~pgen};
                p_we  = 1; #1;
                while (psx_busy_w) begin @(negedge clk2); #1; end
                @(posedge clk2);   // beat accepted at this edge
                psh[idx + j] = p_din;
                if (j + 1 == n)
                    p_we = 0;
                else begin
                    // WE gap mid-burst: the wr_rem hazard window
                    if (($random & 3) == 0) begin
                        p_we = 0;
                        repeat (1 + ($random & 1)) @(negedge clk2);
                    end
                    @(negedge clk2);   // next beat's din set mid-cycle
                end
            end
        end
    endtask

    // ---- dio client tasks (clk1, 4-phase) ----
    task dio_write(input [23:0] wa, input [15:0] wd);
        begin
            @(negedge clk1); d_wr_addr = wa; d_wr_data = wd; d_wr_req = 1;
            @(posedge clk1); while (!d_wr_ack) @(posedge clk1);
            dsh[{wa[23], wa[10:0]}] = wd;
            @(negedge clk1); d_wr_req = 0;
            @(posedge clk1); while (d_wr_ack) @(posedge clk1);
        end
    endtask

    task dio_read(input [21:0] ba);
        reg [63:0] exp;
        begin
            @(negedge clk1); d_rd_addr = ba; d_rd_req = 1;
            @(posedge clk1); while (!d_rd_ack) @(posedge clk1);
            exp = {dsh[{ba[21], ba[8:0], 2'd3}], dsh[{ba[21], ba[8:0], 2'd2}],
                   dsh[{ba[21], ba[8:0], 2'd1}], dsh[{ba[21], ba[8:0], 2'd0}]};
            if (d_rd_data !== exp) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL: dio beat[%06h] = %016h expected %016h", ba, d_rd_data, exp);
            end
            @(negedge clk1); d_rd_req = 0;
            @(posedge clk1); while (d_rd_ack) @(posedge clk1);
        end
    endtask

    // ---- traffic ----
    integer pi, di, fk;   // fk: final sweep only -- k belongs to the slave model
    integer wi, ri, ci;   // concurrent rd+wr phase threads
    reg psx_done = 0, dio_done = 0;
    reg [8:0]  ridx;
    reg [23:0] rwa;

    // the two DIO acks must never overlap (one channel served at a time);
    // relevant since the emu.sv wire-up made concurrent rd+wr pending REACHABLE
    integer ack_overlap = 0;
    always @(posedge clk1) if (d_rd_ack && d_wr_ack) ack_overlap = ack_overlap + 1;

    initial begin
        for (k = 0; k < 1024; k = k + 1) begin
            pmem[k] = f64(29'h0600_0000 + k[28:0]);
            psh[k]  = pmem[k];
            dmem[k] = 64'd0;
        end
        for (k = 0; k < 4096; k = k + 1) dsh[k] = 16'd0;

        repeat (6) @(posedge clk2); @(negedge clk2); rst = 0;
        repeat (4) @(posedge clk2);

        fork
            // psx side: 600 mixed ops with idle gaps
            begin
                for (pi = 0; pi < 600; pi = pi + 1) begin
                    ridx = $random & 9'h1ff;
                    case ($random & 3)
                        0: psx_read (ridx, 1 + ($random & 3));
                        1: psx_read (ridx, 1);
                        2: psx_write(ridx, 1 + ($random & 3));
                        3: psx_write(ridx, 1);
                    endcase
                    if (($random & 3) == 0) repeat (1 + ($random & 7)) @(posedge clk2);
                end
                psx_done = 1;
            end
            // dio side: 300 mixed ops (word writes / beat reads)
            begin
                for (di = 0; di < 300; di = di + 1) begin
                    // alternate banks: low words 0..2047 / window-top 0xFFF800..
                    rwa = ($random & 24'h0007ff) | (($random & 1) ? 24'hFFF800 : 24'h0);
                    if (($random & 3) != 0)
                        dio_write(rwa, $random & 16'hffff);
                    else
                        dio_read(rwa[23:2]);
                    if (($random & 7) == 0) repeat (1 + ($random & 3)) @(posedge clk1);
                end
                dio_done = 1;
            end
        join

        // ---- concurrent DIO rd+wr phase ----
        // The P4b emu.sv DIO read mux gives the arb's read channel a second
        // master (s573_pcm_ring), so d_rd_req and d_wr_req can now sit
        // PENDING TOGETHER across the D_IDLE write-first select and the
        // D_END exits -- previously structurally impossible (k573dio's
        // single scheduler serialized them). Writes hammer the LOW bank
        // while reads sweep the TOP bank (disjoint shadow entries), with
        // psx bursts still running; dio_read's shadow check catches any
        // beat delivered to the wrong channel or address.
        fork
            begin
                for (ci = 0; ci < 200; ci = ci + 1) begin
                    ridx = $random & 9'h1ff;
                    if ($random & 1) psx_read (ridx, 1 + ($random & 3));
                    else             psx_write(ridx, 1 + ($random & 3));
                end
            end
            begin
                for (wi = 0; wi < 400; wi = wi + 1)
                    dio_write($random & 24'h0007ff, $random & 16'hffff);
            end
            begin
                for (ri = 0; ri < 400; ri = ri + 1)
                    dio_read(22'h3FFE00 | ($random & 22'h0001ff));
            end
        join
        if (ack_overlap != 0) begin
            errors = errors + 1;
            $display("FAIL: dio_rd_ack and dio_wr_ack overlapped %0d times", ack_overlap);
        end

        // drain the last psx read responses
        repeat (200) @(posedge clk2);
        if (eq_wp != eq_rp) begin
            errors = errors + 1;
            $display("FAIL: %0d psx read beats never returned", eq_wp - eq_rp);
        end

        // final sweep: EVERY beat of BOTH dio banks reads back its shadow
        // through the DUT -- any lost or misrouted dio write shows up here
        for (fk = 0; fk < 512; fk = fk + 1) dio_read(fk[21:0]);
        for (fk = 0; fk < 512; fk = fk + 1) dio_read(22'h3FFE00 | fk[21:0]);

        if (errors == 0) $display("RESULT: PASS (s573_ddram_arb)");
        else             $display("RESULT: FAIL (s573_ddram_arb, %0d errors)", errors);
        $finish;
    end

    initial begin
        #4_000_000;
        $display("RESULT: FAIL (timeout -- arbiter deadlock?)");
        $finish;
    end
endmodule
