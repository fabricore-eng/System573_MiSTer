`timescale 1ns/1ps
// Testbench for s573_mp3_credit.v -- the HPS consumption credit that paces
// k573_mp3stream under decision-B option (c).
//
// THE INVARIANT: out_ready is released EXACTLY as many cycles as the HPS says it
// consumed bytes. Never more (that would advance `cur`, and therefore the
// game-visible 0xae bit12, for audio nobody played), never fewer (the song would
// never reach mp3_end and would never appear to end).
//
// `make MP3_CREDIT_FREERUN=1 s573_mp3_credit` ties out_ready high -- the "invent
// a clock" anti-pattern the pacing model forbids. RED under it, GREEN by default.
module tb_s573_mp3_credit;
    reg         clk = 0, rst = 1;
    reg  [15:0] cons = 0, epoch = 0;
    reg         out_valid = 0;
    wire        out_ready;
    wire [15:0] credit;
    wire        cred_ovf;
    integer     errors = 0, accepts = 0;

    s573_mp3_credit #(.CRED_W(16)) dut (
        .clk(clk), .rst(rst),
        .hps_cons_bytes(cons), .cfg_epoch(epoch),
        .out_valid(out_valid), .out_ready(out_ready),
        .credit(credit), .cred_ovf(cred_ovf)
    );

    always #5 clk = ~clk;

    // count every accepted byte -- the ONLY thing that advances cur downstream
    always @(posedge clk) if (!rst && out_valid && out_ready) accepts = accepts + 1;

    task chk(input cond, input [511:0] name);
        begin
            if (!cond) begin $display("FAIL: %0s", name); errors = errors + 1; end
        end
    endtask

    // let the streamer sit ready for n cycles and drain whatever credit exists
    task drain(input integer n);
        integer k;
        begin
            out_valid = 1;
            for (k = 0; k < n; k = k + 1) @(posedge clk);
            @(negedge clk); out_valid = 0;
            @(negedge clk);
        end
    endtask

    integer a0;
    initial begin
        repeat (4) @(negedge clk); rst = 0; @(negedge clk);

        // ---- P1: nothing reported -> NOTHING released (the frozen-cur case) ----
        drain(50);
        chk(accepts == 0,        "P1: no credit reported -> out_ready never rises");
        chk(out_ready == 0,      "P1: out_ready low at rest");

        // ---- P2: first report is ADOPTED as the baseline, not credited ----
        // (the HPS may already be at a nonzero count when we first see it)
        @(negedge clk); cons = 16'd5000; @(negedge clk);
        drain(50);
        chk(accepts == 0,        "P2: first report rebaselines, releases nothing");

        // ---- P3: exact release ----
        a0 = accepts;
        @(negedge clk); cons = 16'd5100; @(negedge clk);   // +100
        drain(400);
        chk(accepts - a0 == 100, "P3: +100 reported -> exactly 100 bytes accepted");
        chk(out_ready == 0,      "P3: out_ready drops the moment credit is spent");
        chk(credit == 0,         "P3: credit fully consumed");

        // ---- P4: a REPEATED report (retried/duplicated poll) credits nothing ----
        a0 = accepts;
        @(negedge clk); cons = 16'd5100; @(negedge clk);
        drain(200);
        chk(accepts - a0 == 0,   "P4: an unchanged cumulative count releases nothing");

        // ---- P5: accumulation across several polls, and partial drains ----
        a0 = accepts;
        @(negedge clk); cons = 16'd5150; @(negedge clk);   // +50
        drain(20);                                          // spend only ~20
        @(negedge clk); cons = 16'd5200; @(negedge clk);   // +50 more while owing
        drain(400);
        chk(accepts - a0 == 100, "P5: credit accumulates across polls (50+50 = 100)");

        // ---- P6: mod-2^16 wrap ----
        a0 = accepts;
        @(negedge clk); cons = 16'hFFFE; @(negedge clk);   // jump; big delta
        drain(65600);
        @(negedge clk); cons = 16'h0002; @(negedge clk);   // wraps -> +4
        a0 = accepts;
        drain(60);
        chk(accepts - a0 == 4,   "P6: 0xFFFE -> 0x0002 releases 4, not 65540");

        // ---- P7: song change rebaselines and DROPS stale credit ----
        // The HPS restarts its byte count on a new song. A restarted counter must
        // not read as a giant delta, and credit still owed for the PREVIOUS window
        // must not be spent advancing cur into the NEW one.
        @(negedge clk); cons = 16'h0102; @(negedge clk);   // +256 outstanding
        chk(credit == 256,       "P7 pre: credit outstanding before the song change");
        @(negedge clk); epoch = epoch + 1'd1; @(negedge clk);
        chk(credit == 0,         "P7: stale credit dropped on the song change");
        a0 = accepts;
        @(negedge clk); cons = 16'd0; @(negedge clk);      // HPS restarted at 0
        drain(300);
        chk(accepts - a0 == 0,   "P7: restarted HPS count is ADOPTED, not credited");
        a0 = accepts;
        @(negedge clk); cons = 16'd30; @(negedge clk);
        drain(100);
        chk(accepts - a0 == 30,  "P7: crediting resumes normally after the rebaseline");

        // ---- P8: reset clears everything and does NOT spuriously rebaseline ----
        // NOTE cons is deliberately left NON-ZERO across the reset. The mailbox
        // does zero hps_cons_bytes on reset today, but this module must not
        // DEPEND on that: if it zeroed its own baseline instead of adopting the
        // live input, the stale value would eat the rebaseline and the HPS's
        // first real report would land as a spurious delta -- a burst of
        // out_ready into a freshly re-armed stream. This assertion is what
        // caught exactly that.
        @(negedge clk); cons = 16'd500; @(negedge clk);
        @(negedge clk); rst = 1; repeat (3) @(negedge clk); rst = 0; @(negedge clk);
        chk(credit == 0,         "P8: reset clears credit");
        chk(cred_ovf == 0,       "P8: reset clears the sticky overflow");
        a0 = accepts;
        drain(60);
        chk(accepts - a0 == 0,   "P8: a value HELD across reset releases nothing");
        a0 = accepts;
        @(negedge clk); cons = 16'd600; @(negedge clk);
        drain(200);
        chk(accepts - a0 == 0,   "P8: first post-reset report rebaselines");
        a0 = accepts;
        @(negedge clk); cons = 16'd640; @(negedge clk);
        drain(120);
        chk(accepts - a0 == 40,  "P8: crediting resumes after the post-reset adopt");

        // ---- P8b: the same, with the mailbox's real behaviour (cons zeroed) ----
        @(negedge clk); rst = 1; cons = 16'd0; repeat (3) @(negedge clk);
        rst = 0; @(negedge clk);
        a0 = accepts;
        @(negedge clk); cons = 16'd700; @(negedge clk);
        drain(200);
        chk(accepts - a0 == 0,   "P8b: zeroed-on-reset path also rebaselines");

        // ---- P9: clamp, not wrap, and the flag is LOUD ----
        // two near-max deltas back to back must saturate rather than roll over
        @(negedge clk); cons = 16'd0;     @(negedge clk);   // adopt
        @(negedge clk); cons = 16'hF000;  @(negedge clk);   // +61440
        @(negedge clk); cons = 16'hE000;  @(negedge clk);   // +61440 more -> clamp
        chk(cred_ovf == 1,       "P9: sticky cred_ovf raised on clamp");
        chk(credit == 16'hFFFF,  "P9: credit clamped at max, did not wrap to a small value");

        if (errors == 0) $display("RESULT: PASS (s573_mp3_credit)");
        else             $display("RESULT: FAIL (s573_mp3_credit, %0d errors)", errors);
        $finish;
    end
endmodule
