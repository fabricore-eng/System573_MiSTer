`timescale 1ns/1ps
// tb_atapi_settle.v - RED/GREEN proof for the IDENTIFY (0xA1) data-ready IRQ-race fix.
//
// THE BUG (proven on silicon, SignalTap 2026-06-25): rtl/atapi.v raised IDENTIFY's
// DRQ+INTRQ in the SAME cycle as the 0xA1 command write. ddrsbm's digital-board POST
// interrupt handler then ran BEFORE its driver had set the software transfer-pending
// state byte, took the skip-to-exit dispatch branch, and never drained the 512-byte
// IDENTIFY block -> DRQ stuck -> the drive check times out -> "BOOT CHECK".
//
// THE FIX: hold BSY for IDENT_SETTLE clk1x, THEN raise DRQ+INTRQ (atapi.v S_PREP),
// mirroring the S_FETCH data-ready pacing the disc READ path uses. A real CR-589 (and
// MAME) delay this interrupt by the drive's data-prep latency, so the driver finishes
// "write cmd -> set state byte -> wait" before the interrupt arrives.
//
// This TB asserts, after writing 0xA1:
//   (1) the interrupt does NOT fire on the command-write cycle -- the device shows BSY
//       with DRQ clear and INTRQ low immediately after the write;
//   (2) DRQ rises only AFTER a real settle window (BSY observed, >= MIN_SETTLE_POLLS
//       status polls), and a fresh INTRQ edge is delivered then;
//   (3) the 256-word IDENTIFY block still drains correctly (word0=0x8500, word49 DMA
//       bit set) and the command completes (DRDY|DSC, ERR clear) with a 2nd INTRQ edge.
//
// GREEN by default (the fix). RED with -DATAPI_IDENT_NOSETTLE (the instant-IRQ RED
// reference compiled into atapi.v): checks (1) and (2) fail -- DRQ is set on the
// command-write cycle, no BSY phase, the INTRQ edge arrives immediately. This proves the
// test exercises the fix without hand-reverting RTL. The Makefile `ATAPI_IDENT_NOSETTLE=1`
// knob sets the define (same pattern as S573_CH4_NOARB / S573_FLASH_OLD_AND).
module tb_atapi_settle;
    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [3:0]  addr = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire        intrq;
    integer errors = 0;

    // cd_attached=0 -> the fixed-response/legacy path (this test only drives IDENTIFY,
    // which is independent of the CD image).
    atapi dut (.clk(clk), .rst(rst), .ide_rst(1'b0),
               .sel(sel), .addr(addr), .we(we), .re(re),
               .din(din), .dout(dout), .intrq(intrq),
               .cd_attached(1'b0), .sec_req(), .sec_lba(),
               .sbuf_addr(), .sbuf_q(16'h0000), .sec_ready(1'b0),
               .toc_track_count(8'd1), .toc_leadout(32'd16680),
               .toc_qtrack(), .toc_qstart(32'd0), .toc_qaudio(1'b0),
               .dma_req(), .dma_rd(1'b0), .dma_dout());

    always #5 clk = ~clk;

    task io_write(input [3:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; addr=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task io_read(input [3:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; addr=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    // alt-status read (reg8) does NOT clear INTRQ (unlike a reg7 read), so we can poll
    // BSY/DRQ all through the settle without disturbing the interrupt under test.
    task altstat(output [15:0] d);
        begin @(negedge clk); sel=1; re=1; addr=4'd8; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // free-running INTRQ rising-edge counter, independent of the stimulus
    reg     intrq_d = 0;
    integer intrq_rises = 0;
    always @(posedge clk) begin
        if (rst) intrq_d <= 0;
        else begin
            if (intrq && !intrq_d) intrq_rises = intrq_rises + 1;
            intrq_d <= intrq;
        end
    end

    reg [15:0] v, w0, w49;
    integer i, settle_polls, saw_bsy;
    // GREEN settles for ~IDENT_SETTLE (2048) status polls; RED is effectively 0. A small
    // floor cleanly separates the two without pinning the exact tuned value.
    localparam integer MIN_SETTLE_POLLS = 8;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ===== issue IDENTIFY PACKET DEVICE (0xA1) =====
        io_write(4'd7, 16'h00A1);

        // (1) the interrupt must NOT fire on the command-write cycle. Sample alt-status
        // right after the write: the fix holds BSY (0x80) with DRQ clear and INTRQ low.
        altstat(v);
        if (v[3] === 1'b1) begin
            $display("FAIL: DRQ set immediately after 0xA1 (no BSY settle) status=%04h", v);
            errors = errors + 1;
        end
        if (intrq === 1'b1) begin
            $display("FAIL: INTRQ asserted on/just after the 0xA1 command-write cycle (the race)");
            errors = errors + 1;
        end

        // (2) poll alt-status until DRQ rises; count the settle window and confirm BSY
        // was actually held (a real device-busy phase, not an instant DRQ).
        settle_polls = 0; saw_bsy = 0;
        while (settle_polls < 8000 && v[3] !== 1'b1) begin
            if (v[7] === 1'b1) saw_bsy = 1;
            altstat(v);
            settle_polls = settle_polls + 1;
        end
        if (v[3] !== 1'b1) begin
            $display("FAIL: DRQ never rose after IDENTIFY (settle hung) status=%04h", v);
            errors = errors + 1;
        end
        if (saw_bsy === 0) begin
            $display("FAIL: BSY never observed during IDENTIFY settle (instant IRQ -> the race)");
            errors = errors + 1;
        end
        if (settle_polls < MIN_SETTLE_POLLS) begin
            $display("FAIL: IDENTIFY settle too short (%0d polls < %0d): IRQ effectively instant",
                     settle_polls, MIN_SETTLE_POLLS);
            errors = errors + 1;
        end else
            $display("  ok: IDENTIFY settled for %0d status polls before DRQ (BSY seen=%0d)",
                     settle_polls, saw_bsy);

        // let the edge observer's intrq_d pipeline catch the data-ready rise
        repeat (3) @(posedge clk);
        // the data-ready interrupt must have been delivered exactly once by now
        if (intrq !== 1'b1) begin
            $display("FAIL: INTRQ not asserted after the settle (data-ready interrupt missing)");
            errors = errors + 1;
        end
        if (intrq_rises != 1) begin
            $display("FAIL: %0d INTRQ rising edges before data drain (expected 1)", intrq_rises);
            errors = errors + 1;
        end

        // after the settle: DRQ set, IO ireason, byte count 0x0200
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "IDENT status DRDY|DRQ");
        io_read(4'd2, v); chk(v & 16'h00ff, 16'h0002, "IDENT ireason IO");
        io_read(4'd4, v); chk(v & 16'h00ff, 16'h0000, "IDENT bc lo");
        io_read(4'd5, v); chk(v & 16'h00ff, 16'h0002, "IDENT bc hi (0x0200)");

        // the reg7 status read above cleared INTRQ -> it must have fallen
        repeat (2) @(posedge clk);
        if (intrq !== 1'b0) begin
            $display("FAIL: INTRQ did not clear after the reg7 status read");
            errors = errors + 1;
        end

        // (3) drain the 256-word IDENTIFY block; the data must still be intact.
        for (i = 0; i < 256; i = i + 1) begin
            io_read(4'd0, v);
            if (i == 0)  w0  = v;
            if (i == 49) w49 = v;
        end
        chk(w0,  16'h8500, "IDENT word0 (ATAPI CD-ROM, exact CR-589)");
        chk(w49 & 16'h0400, 16'h0400, "IDENT word49 DMA-supported bit");

        // completion: 2nd INTRQ edge, status back to DRDY|DSC, ERR clear
        repeat (3) @(posedge clk);
        if (intrq !== 1'b1) begin
            $display("FAIL: INTRQ not asserted at IDENTIFY completion");
            errors = errors + 1;
        end
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "IDENT done status DRDY|DSC");
        io_read(4'd1, v); chk(v & 16'h00ff, 16'h0000, "IDENT done error=0");

        if (intrq_rises != 2) begin
            $display("FAIL: %0d INTRQ rising edges total (expected 2: data-ready + completion)", intrq_rises);
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (atapi_settle)");
        else             $display("RESULT: FAIL (atapi_settle, %0d errors)", errors);
        $finish;
    end

    // global watchdog: a hung settle (DRQ never raised) must not stall the suite
    initial begin #5000000; $display("RESULT: FAIL (atapi_settle timeout)"); $finish; end
endmodule
