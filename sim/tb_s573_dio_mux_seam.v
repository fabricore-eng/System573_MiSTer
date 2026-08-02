// tb_s573_dio_mux_seam.v - the clk_1x mux / clk_2x REAL s573_ddram_arb seam
// (the one surface tb_s573_mp3_path's single-clock fake arb cannot see).
// Authored during the adversarial after-review of the P4b wire-up:
// REAL s573_ddram_arb @ clk_2x + VERBATIM emu.sv DIO read mux @ clk_1x,
// k573dio-cadence client + ring-cadence client + random PSX traffic +
// dio write traffic + random multi-cycle resets.
// Checks: no stale/cross ack, data-per-address integrity per client,
// PSX beat integrity (DIO beats must be eaten), no deadlock, fairness.
`timescale 1ns/1ps
module tb_s573_dio_mux_seam;
    integer errors = 0;
    integer seed = 573;

    // edge-aligned related clocks: clk1 = 20ns, clk2 = 10ns, rise together
    reg clk1 = 1, clk2 = 1;
    always #10 clk1 = ~clk1;
    always #5  clk2 = ~clk2;

    // emu.sv-style clk1-registered reset
    reg rst_cmd = 1;          // request from the test sequencer
    reg reset   = 1;
    always @(posedge clk1) reset <= rst_cmd;

    // ---------------- DDR model (clk2) ----------------
    localparam [28:0] DIO_BASE_BEAT = 29'h0640_0000;
    function [63:0] pat; input [28:0] a;
        pat = {~a[13:0], a[28:14], a, 6'h2A} ^ 64'h5A5A_1234_9876_A5A5;
    endfunction

    wire        ddr_busy;
    wire [7:0]  ddr_burstcnt;
    wire [28:0] ddr_addr;
    reg  [63:0] ddr_dout = 0;
    reg         ddr_dout_ready = 0;
    wire        ddr_rd;
    wire [63:0] ddr_din;
    wire [7:0]  ddr_be;
    wire        ddr_we;

    reg        busy_r = 0;
    assign ddr_busy = busy_r;
    // pending read-beat queue
    reg [28:0] q_addr [0:255];
    reg [7:0]  q_wp = 0, q_rp = 0;
    wire [7:0] q_cnt = q_wp - q_rp;
    integer bi;
    always @(posedge clk2) begin
        busy_r <= ($random(seed) % 10) < 3;   // ~30% busy
        ddr_dout_ready <= 0;
        if (reset) begin
            q_wp <= 0; q_rp <= 0;
        end else begin
            if (ddr_rd && !ddr_busy) begin
                for (bi = 0; bi < ddr_burstcnt; bi = bi + 1)
                    q_addr[q_wp + bi[7:0]] <= ddr_addr + bi[28:0];
                q_wp <= q_wp + ddr_burstcnt;
            end
            // writes just absorbed
            if (q_cnt != 0 && (($random(seed) % 10) < 4)) begin
                ddr_dout <= pat(q_addr[q_rp]);
                ddr_dout_ready <= 1;
                q_rp <= q_rp + 8'd1;
            end
        end
    end

    // ---------------- PSX master model (clk2) ----------------
    reg        psx_rd = 0, psx_we = 0;
    reg [28:0] psx_addr = 0;
    reg [7:0]  psx_burstcnt = 1;
    reg [63:0] psx_din = 0;
    wire       psx_busy;
    wire [63:0] psx_dout;
    wire        psx_dout_ready;

    // expected read-return queue for the PSX side
    reg [28:0] pq_addr [0:255];
    reg [7:0]  pq_wp = 0, pq_rp = 0;
    integer    psx_reads_done = 0, psx_bad = 0;
    reg [2:0]  pst = 0;
    reg [7:0]  wr_left = 0;
    integer    r;
    always @(posedge clk2) begin
        if (reset) begin
            pst <= 0; psx_rd <= 0; psx_we <= 0; pq_wp <= 0; pq_rp <= 0; wr_left <= 0;
        end else begin
            // check returned beats (may arrive any time)
            if (psx_dout_ready) begin
                if (pq_wp == pq_rp) begin
                    psx_bad = psx_bad + 1;   // beat with nothing expected = DIO leak
                    $display("FAIL: PSX got unexpected beat t=%0t data=%h", $time, psx_dout);
                end else begin
                    if (psx_dout !== pat(pq_addr[pq_rp])) begin
                        psx_bad = psx_bad + 1;
                        $display("FAIL: PSX beat mismatch t=%0t addr=%h got=%h want=%h",
                                 $time, pq_addr[pq_rp], psx_dout, pat(pq_addr[pq_rp]));
                    end
                    pq_rp <= pq_rp + 8'd1;
                    psx_reads_done = psx_reads_done + 1;
                end
            end
            case (pst)
                0: begin
                    r = $random(seed) % 10;
                    if (r < 3) begin   // start read burst
                        psx_addr <= {8'h06, $random(seed)} & 29'h0FFF_FFF0;  // clear of DIO window
                        psx_burstcnt <= 1 + ($unsigned($random(seed)) % 4);
                        psx_rd <= 1; pst <= 1;
                    end else if (r < 5) begin  // start write burst
                        psx_addr <= {8'h06, $random(seed)} & 29'h0FFF_FFF0;
                        r = 1 + ($unsigned($random(seed)) % 4);
                        psx_burstcnt <= r[7:0];
                        wr_left <= r[7:0];        // beats sent MUST equal burstcnt
                        psx_din <= {$random(seed), $random(seed)};
                        psx_we <= 1; pst <= 2;
                    end
                end
                1: if (!psx_busy) begin        // read cmd accepted
                    for (bi = 0; bi < psx_burstcnt; bi = bi + 1)
                        pq_addr[pq_wp + bi[7:0]] <= psx_addr + bi[28:0];
                    pq_wp <= pq_wp + psx_burstcnt;
                    psx_rd <= 0; pst <= 0;
                end
                2: if (!psx_busy) begin        // write beat accepted
                    if (wr_left == 1) begin psx_we <= 0; pst <= 0; end
                    else begin
                        wr_left <= wr_left - 8'd1;
                        // random gap mid-burst (legal Avalon)
                        if (($random(seed) % 4) == 0) begin psx_we <= 0; pst <= 3; end
                    end
                end
                3: begin psx_we <= 1; pst <= 2; end   // resume gapped burst
            endcase
        end
    end

    // ---------------- DIO clients (clk1) ----------------
    wire [63:0] dio_mem_rd_q;
    // client 0: k573dio cadence (E_IDLE/E_RD/E_RD_END)
    reg         dio_mem_rd_req = 0;
    reg  [21:0] dio_mem_rd_addr = 0;
    wire        dio_mem_rd_ack;
    integer     c0_done = 0, c0_bad = 0;
    reg [1:0]   c0 = 0;
    always @(posedge clk1) begin
        if (reset) begin c0 <= 0; dio_mem_rd_req <= 0; end
        else case (c0)
            0: if (($random(seed) % 4) == 0) begin
                   dio_mem_rd_addr <= $unsigned($random(seed)) % 4096;
                   c0 <= 1;                       // E_IDLE decided; req next cycle
               end
            1: begin
                   dio_mem_rd_req <= 1;
                   if (dio_mem_rd_req && dio_mem_rd_ack) begin
                       if (dio_mem_rd_q !== pat(DIO_BASE_BEAT | {7'd0, dio_mem_rd_addr})) begin
                           c0_bad = c0_bad + 1;
                           $display("FAIL: c0 data mismatch t=%0t beat=%h got=%h want=%h",
                                    $time, dio_mem_rd_addr, dio_mem_rd_q,
                                    pat(DIO_BASE_BEAT | {7'd0, dio_mem_rd_addr}));
                       end
                       c0_done = c0_done + 1;
                       dio_mem_rd_req <= 0; c0 <= 2;
                   end
               end
            2: if (!dio_mem_rd_ack) c0 <= 0;      // E_RD_END
        endcase
    end

    // client 1: ring cadence (S_IDLE/S_REQ/S_PUSH0/S_PUSH1/S_WAIT)
    reg         ring_rd_req = 0;
    reg  [21:0] ring_rd_addr = 0;
    wire        ring_rd_ack;
    integer     c1_done = 0, c1_bad = 0;
    reg [2:0]   c1 = 0;
    always @(posedge clk1) begin
        if (reset) begin c1 <= 0; ring_rd_req <= 0; end
        else case (c1)
            0: if (($random(seed) % 3) == 0) begin
                   ring_rd_addr <= 22'h3E2000 | ($unsigned($random(seed)) % 4096);
                   ring_rd_req  <= 1;
                   c1 <= 1;
               end
            1: if (ring_rd_ack) begin
                   if (dio_mem_rd_q !== pat(DIO_BASE_BEAT | {7'd0, ring_rd_addr})) begin
                       c1_bad = c1_bad + 1;
                       $display("FAIL: c1 data mismatch t=%0t beat=%h got=%h want=%h",
                                $time, ring_rd_addr, dio_mem_rd_q,
                                pat(DIO_BASE_BEAT | {7'd0, ring_rd_addr}));
                   end
                   c1_done = c1_done + 1;
                   ring_rd_req <= 0; c1 <= 2;
               end
            2: c1 <= 3;        // S_PUSH0
            3: c1 <= 4;        // S_PUSH1
            4: if (!ring_rd_ack) c1 <= 0;   // S_WAIT
        endcase
    end

    // dio write client (clk1, k573dio E_WR cadence, direct to arb)
    reg         dio_wr_req = 0;
    reg  [23:0] dio_wr_addr = 0;
    reg  [15:0] dio_wr_data = 0;
    wire        dio_wr_ack;
    integer     cw_done = 0;
    reg [1:0]   cw = 0;
    always @(posedge clk1) begin
        if (reset) begin cw <= 0; dio_wr_req <= 0; end
        else case (cw)
            0: if (($random(seed) % 6) == 0) begin
                   dio_wr_addr <= $random(seed);
                   dio_wr_data <= $random(seed);
                   dio_wr_req  <= 1; cw <= 1;
               end
            1: if (dio_wr_req && dio_wr_ack) begin
                   cw_done = cw_done + 1;
                   dio_wr_req <= 0; cw <= 2;
               end
            2: if (!dio_wr_ack) cw <= 0;
        endcase
    end

    // ---------------- VERBATIM emu.sv mux (clk1) ----------------
    reg         dio_rd_owner;
    reg         dio_rd_busy;
    reg  [21:0] dio_arb_rd_addr;   // registered at the grant edge, as in emu.sv
    wire dio_arb_rd_ack;
    always @(posedge clk1) begin
       if (reset) begin
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

    // protocol assertions: an ack may only RISE while its client's req is high
    reg mack_d = 0, rack_d = 0;
    always @(posedge clk1) if (!reset) begin
        mack_d <= dio_mem_rd_ack;
        rack_d <= ring_rd_ack;
        if (dio_mem_rd_ack && !mack_d && !dio_mem_rd_req) begin
            errors = errors + 1;
            $display("FAIL: stale ack rose for client0 with req low t=%0t", $time);
        end
        if (ring_rd_ack && !rack_d && !ring_rd_req) begin
            errors = errors + 1;
            $display("FAIL: stale ack rose for client1 with req low t=%0t", $time);
        end
    end

    // ---------------- REAL arbiter (clk2) ----------------
    s573_ddram_arb #(.DIO_BASE_BEAT(DIO_BASE_BEAT)) u_arb (
        .clk(clk2), .rst(reset),
        .ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr),
        .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
        .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
        .psx_busy(psx_busy), .psx_burstcnt(psx_burstcnt), .psx_addr(psx_addr),
        .psx_dout(psx_dout), .psx_dout_ready(psx_dout_ready),
        .psx_rd(psx_rd), .psx_din(psx_din), .psx_be(8'hFF), .psx_we(psx_we),
        .dio_rd_req(dio_arb_rd_req), .dio_rd_addr(dio_arb_rd_addr),
        .dio_rd_data(dio_mem_rd_q), .dio_rd_ack(dio_arb_rd_ack),
        .dio_wr_req(dio_wr_req), .dio_wr_addr(dio_wr_addr),
        .dio_wr_data(dio_wr_data), .dio_wr_ack(dio_wr_ack)
    );

    // deadlock watchdog: c0/c1 must both keep completing
    integer last_c0 = 0, last_c1 = 0;
    integer stall = 0;
    always @(posedge clk1) if (!reset) begin
        if (c0_done == last_c0 && c1_done == last_c1) stall = stall + 1;
        else stall = 0;
        last_c0 = c0_done; last_c1 = c1_done;
        if (stall > 20000) begin
            $display("FAIL: DEADLOCK t=%0t c0=%0d c1=%0d busy=%b owner=%b arb_dstate=? req0=%b req1=%b ack=%b",
                     $time, c0_done, c1_done, dio_rd_busy, dio_rd_owner,
                     dio_mem_rd_req, ring_rd_req, dio_arb_rd_ack);
            $finish;
        end
    end

    // ---------------- sequencer: run + random mid-op resets ----------------
    integer k;
    initial begin
        rst_cmd = 1;
        repeat (10) @(posedge clk1);
        rst_cmd = 0;
        for (k = 0; k < 12; k = k + 1) begin
            // run a burst of traffic
            repeat (30000 + ($unsigned($random(seed)) % 20000)) @(posedge clk1);
            // random mid-op reset, 2..5 clk1 cycles
            rst_cmd = 1;
            repeat (2 + ($unsigned($random(seed)) % 4)) @(posedge clk1);
            rst_cmd = 0;
        end
        repeat (30000) @(posedge clk1);
        $display("c0_done=%0d c0_bad=%0d c1_done=%0d c1_bad=%0d cw_done=%0d psx_reads=%0d psx_bad=%0d errors=%0d",
                 c0_done, c0_bad, c1_done, c1_bad, cw_done, psx_reads_done, psx_bad, errors);
        if (c0_bad == 0 && c1_bad == 0 && psx_bad == 0 && errors == 0
            && c0_done > 1000 && c1_done > 1000 && cw_done > 500 && psx_reads_done > 1000)
            $display("RESULT: PASS (s573_dio_mux_seam)");
        else
            $display("RESULT: FAIL (s573_dio_mux_seam)");
        $finish;
    end
endmodule
