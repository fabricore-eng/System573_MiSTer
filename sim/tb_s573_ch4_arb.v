// -----------------------------------------------------------------------------
// tb_s573_ch4_arb.v - red/green for the SDRAM ch4 arbiter (flash SAVE-read fix)
//
// The bug this proves fixed (HW-confirmed 2026-06-14): the SDRAM controller
// samples ch4_addr at SERVICE time, not request time (sdram.sv services ch4
// behind ch1/ch2/ch3 + refresh, many cycles after the 1-cycle req pulse). The old
// emu.sv shared ch4 with a bare combinational mux
//     ch4_addr = a_req ? a_addr : b_addr;   ch4_req = a_req | b_req;   (single ready
//     fanned to both clients)
// so by service time the saver's (A's) address had reverted to the BIOS (B's) and
// the lone ready cross-latched into both -> the SAVE read the wrong offset.
//
// This TB instantiates a FAITHFUL ch4 model: it latches the REQUEST on ch4_req but
// samples ch4_addr only later, at SERVICE time. That is the one property the old
// saver unit TB lacked (it serviced ch4 immediately, so it never reproduced the
// bug). Built with the arbiter -> PASS. Built with -DS573_CH4_NOARB (the old bare
// mux) -> FAIL (Test 1). Verilog-2005. GNU GPL v2.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_s573_ch4_arb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst = 1'b1;

    // client A (saver SAVE-read) and B (BIOS line-fill) request lines (TB-driven)
    reg         a_req = 1'b0;
    reg  [26:0] a_addr = 27'd0;
    reg         b_req = 1'b0;
    reg  [26:0] b_addr = 27'd0;

    // ready lines back to the clients (DUT- or mux-driven)
    wire        a_ready;
    wire        b_ready;

    // shared SDRAM ch4 port
    wire [26:0] ch4_addr;
    wire        ch4_req;
    reg         ch4_ready = 1'b0;     // model-driven
    reg  [127:0] ch4_dout = 128'd0;   // model-driven

    // -------------------------------------------------------------------------
    // DUT: the arbiter, or (red reference) the old bare mux.
    // -------------------------------------------------------------------------
`ifdef S573_CH4_NOARB
    assign ch4_addr = a_req ? a_addr : b_addr;   // old: addr valid only during req
    assign ch4_req  = a_req | b_req;             // old: OR'd request
    assign a_ready  = ch4_ready;                 // old: single ready, cross-latched
    assign b_ready  = ch4_ready;
`else
    s573_ch4_arb dut (
        .clk      (clk),
        .rst      (rst),
        .a_req    (a_req),
        .a_addr   (a_addr),
        .a_ready  (a_ready),
        .b_req    (b_req),
        .b_addr   (b_addr),
        .b_ready  (b_ready),
        .ch4_addr (ch4_addr),
        .ch4_req  (ch4_req),
        .ch4_ready(ch4_ready)
    );
`endif

    // -------------------------------------------------------------------------
    // FAITHFUL ch4 model: single outstanding transaction (the arbiter guarantees
    // this; the bare mux respects it in Test 1). On ch4_req, latch the request and
    // start a service-delay countdown WITHOUT capturing the address. When the delay
    // expires, sample ch4_addr NOW (service time) and return a burst whose low 27
    // bits echo that sampled address, pulsing ch4_ready for one cycle.
    // -------------------------------------------------------------------------
    localparam integer SVC_DELAY = 4;     // > 0 so the 1-cycle req pulse has dropped
    reg        m_busy = 1'b0;
    reg [3:0]  m_cnt  = 4'd0;
    always @(posedge clk) begin
        ch4_ready <= 1'b0;
        if (rst) begin
            m_busy <= 1'b0;
        end else if (!m_busy) begin
            if (ch4_req) begin
                m_busy <= 1'b1;
                m_cnt  <= SVC_DELAY[3:0];
            end
        end else begin
            if (m_cnt != 4'd0) begin
                m_cnt <= m_cnt - 4'd1;
            end else begin
                ch4_dout  <= {101'd0, ch4_addr};   // burst echoes the SAMPLED addr
                ch4_ready <= 1'b1;
                m_busy    <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    integer nfail = 0;
    integer npass = 0;

    localparam [26:0] POISON_B = 27'h0BAD_BAD;   // B's line value at service time
    localparam [26:0] POISON_A = 27'h0DEAD_E >> 1; // A's line after its pulse drops

    // Test 1 (the red/green toggle): A issues ONE burst for AA, then both the A and
    // B address lines move to poison values BEFORE service. A faithful service-time
    // sample of the LIVE mux would read poison; the arbiter holds AA. b_req stays 0.
    task automatic t1_single_save_read(input [26:0] aa);
        integer guard;
        reg got; reg [26:0] sa;
        begin
            got = 1'b0; sa = 27'd0;
            b_addr = POISON_B;
            a_addr = aa;
            @(posedge clk); a_req = 1'b1;
            @(posedge clk); a_req = 1'b0;
            a_addr = POISON_A;          // the live mux input now reverts to poison
            for (guard = 0; guard < 300 && !got; guard = guard + 1) begin
                @(posedge clk);
                if (a_ready) begin got = 1'b1; sa = ch4_dout[26:0]; end
            end
            if (!got) begin
                $display("FAIL t1 aa=%h: a_ready timeout", aa);
                nfail = nfail + 1;
            end else if (sa !== aa) begin
                $display("FAIL t1: SAVE read addr %h but got data for addr %h (wrong offset)", aa, sa);
                nfail = nfail + 1;
            end else begin
                $display("  ok  t1: SAVE read of %h returned its own data", aa);
                npass = npass + 1;
            end
        end
    endtask

    // Test 2 (concurrency, arbiter only in practice): A and B both pulse the SAME
    // cycle, addresses held until both readies. Each must get ITS own offset's data
    // -- no cross-latch, no wrong-offset. Repeated to exercise back-to-back turns.
    task automatic t2_pair(input [26:0] aa, input [26:0] bb);
        integer guard;
        reg ga, gb; reg [26:0] sa, sb;
        begin
            ga = 1'b0; gb = 1'b0; sa = 27'd0; sb = 27'd0;
            a_addr = aa; b_addr = bb;
            @(posedge clk); a_req = 1'b1; b_req = 1'b1;
            @(posedge clk); a_req = 1'b0; b_req = 1'b0;
            for (guard = 0; guard < 600 && !(ga && gb); guard = guard + 1) begin
                @(posedge clk);
                if (a_ready) begin ga = 1'b1; sa = ch4_dout[26:0]; end
                if (b_ready) begin gb = 1'b1; sb = ch4_dout[26:0]; end
            end
            if (!ga || !gb) begin
                $display("FAIL t2 aa=%h bb=%h: timeout (a=%b b=%b)", aa, bb, ga, gb);
                nfail = nfail + 1;
            end else if (sa !== aa || sb !== bb) begin
                $display("FAIL t2: A wanted %h got %h | B wanted %h got %h", aa, sa, bb, sb);
                nfail = nfail + 1;
            end else begin
                $display("  ok  t2: A=%h and B=%h each read their own offset", aa, bb);
                npass = npass + 1;
            end
        end
    endtask

    integer i;
    initial begin
        a_req = 0; b_req = 0; a_addr = 0; b_addr = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---- Test 1: the SAVE-read addr must survive to service time ----
        t1_single_save_read(27'h0123_450);
        t1_single_save_read(27'h1F00_002);   // bank-3-ish high offset

        // ---- Test 2: A and B contend; each gets its own offset ----
        for (i = 0; i < 8; i = i + 1)
            t2_pair(27'h0100_000 + (i << 5), 27'h0EEE_000 + (i << 4));

        @(posedge clk);
        $display("-----------------------------------------");
        $display("ch4_arb: %0d passed, %0d failed", npass, nfail);
        if (nfail == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

    // global watchdog
    initial begin
        #200000;
        $display("FAIL: global timeout");
        $display("RESULT: FAIL");
        $finish;
    end
endmodule
