`timescale 1ns/1ps
// tb_gate5_replay.v -- gate-5 CDROM-timeout RED bench (build-free reproduction).
//
// Gate 4 (ddrsbm DIO RAM) is cleared on silicon; the game now dies AFTER
// title/attract with `HARD-WARE ERROR -1N / CDROM DRIVE TIMEOUT` (reproducible
// 2/2 boots). docs/2026-07-02-gate5-cdrom-timeout-observation.md reconciled the
// verdict (MAME oracle CLEAN 600 emu-s -> Gate -1 holds; the data is fine): the
// timeout is an async READ(12) COMPLETION STALL that PERSISTS across the game's
// own 2-3 drive resets. The RTL audit found the exact defect that supplies that
// persistence, in two silicon-proven modules:
//
//   * s573_cdimg.v samples the 1-clk `sec_req` strobe ONLY in S_IDLE (line 94),
//     waits UNBOUNDEDLY in S_REQ (on cd_ack) and S_STREAM (on 1176 cd_wr), and
//     raises an UNTAGGED `sec_ready` (no LBA);
//   * `ide_rst` resets atapi.v (line 293) but is NOT wired to s573_cdimg
//     (system573_top.v:278-285 -- cdimg gets only clk/rst);
//   * atapi.v S_FETCH (line 611) has NO device timeout: it holds BSY forever
//     waiting for a sec_ready that a wedged cdimg never raises -> the game's
//     driver sees status -10 forever -> the observed screen, immune to every
//     drive reset the game issues.
//   * START_STOP (0x1b) -- the per-song ritual opcode, issued x2 after every
//     preload (oracle log n=545/546 ...) -- falls to atapi.v's default arm
//     (line 431) -> CHECK CONDITION, while REQUEST SENSE reports key 0 and the
//     real CR-589 (+ MAME) answer GOOD.
//
// THE FIX HAS LANDED (2026-07-03): the four bullets above describe the PRE-fix
// defect this bench reproduced. It is now GREEN and stays as the regression guard.
//
// THIS BENCH replays the oracle ATA workload (local/g5_mame_oracle/g5_ata_e.log,
// exact LBAs + CDBs) against atapi.v + s573_cdimg.v + s573_cdtoc.v and asserts,
// for EVERY command: bounded completion + served data == commanded LBA. It drove
// the gate-5 fix RED->GREEN: RED against the pre-fix RTL, GREEN now that the fix
// landed -- ide_rst wired -> s573_cdimg (sec_req accepted in any state + sec_ready
// re-tagged by re-fetch), and STOP UNIT (0x1b) answered GOOD. Build-free: iverilog.
//
//   make -C sim gate5_replay     -> GREEN (the gate-5 fix in place)
//   make -C sim                  -> the 38-test suite (this target is NOT in TESTS;
//                                   it is a standalone gate-5 regression guard)
//
// DOCTRINE (LESSONS.md #1): the host BFM below NEVER fakes/zero-fills a lost
// response to hide the stall. It models the REAL contract: an IDE reset aborts
// the drive's in-flight command, and Main's request-driven CD service re-serves
// the core's NEXT fresh request. The stall is an HONEST injected environment
// fault (a mid-transfer HPS/f2sdram hiccup -- the marginal bridge); the RTL's JOB
// is to recover from it via ide_rst. Current RTL cannot -> RED. That is the point.
//
// LBA SPACES (support/psx/psx.cpp, Main 250828 -- same contract as tb_cdboot.v):
// the BIOS/ATAPI world is USER space; Main's CD service is MSF = user+150. The
// host BFM serves ZEROS below the 150-sector pregap and reads the image at
// lba-150, so s573_cdimg's user->MSF +150 on sd_lba1 is exercised end to end.
//
// Verilog-2005 (-g2005-sv). Released under the GNU GPL v2.
module tb_gate5_replay;
    reg         clk = 0, rst = 1;
    reg         ide_rst = 0;
    reg         sel = 0, we = 0, re = 0;
    reg  [3:0]  addr = 0;
    reg  [15:0] din = 0;
    wire [15:0] dout;
    wire        intrq;
    integer     errors = 0;

    localparam [31:0] PREGAP = 32'd150;     // Main's fake track-1 pregap (psx.cpp:142-146)

    // atapi <-> cdimg sector interface
    wire        sec_req;
    wire [31:0] sec_lba;
    wire [10:0] sbuf_addr;
    wire [15:0] sbuf_q;
    wire        sec_ready, sec_busy;
    // cdimg <-> host (CUECHD sd-block) interface
    wire        cd_req;
    wire [31:0] cd_lba;
    reg         cd_ack = 0, cd_wr = 0;
    reg  [15:0] cd_data = 0;
    // ch5 DMA BFM <-> atapi
    reg         dma_rd = 0;
    wire [15:0] dma_dout;
    wire        dma_req;
    // cdtoc <-> atapi (disc metadata; unused by the READ path, tied for symmetry)
    wire [7:0]  toc_track_count;
    wire [31:0] toc_leadout;
    wire [6:0]  toc_qtrack;
    wire [31:0] toc_qstart;
    wire        toc_qaudio;

    atapi dut (
        .clk(clk), .rst(rst), .ide_rst(ide_rst),
        .sel(sel), .addr(addr), .we(we), .re(re),
        .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b1),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready),
        .toc_track_count(toc_track_count), .toc_leadout(toc_leadout),
        .toc_qtrack(toc_qtrack), .toc_qstart(toc_qstart), .toc_qaudio(toc_qaudio),
        .dma_req(dma_req), .dma_rd(dma_rd), .dma_dout(dma_dout)
    );

    // The gate-5 fix has LANDED: s573_cdimg now carries a real `ide_rst` PORT
    // (wired to the board IDE reset in system573_top.v), so this bench drives it
    // directly -- exactly the top-level wiring the fix added. Before the fix cdimg
    // had only clk/rst and the recovery ritual's ide_rst was dropped, wedging the
    // fetch (sub-tests [C]/[D]). With the port wired (+ sec_req accepted in any
    // state, sec_ready re-tagged by re-fetch) AND atapi's STOP-UNIT-as-GOOD, this
    // bench is GREEN with NO define -- a permanent gate-5 regression guard.
    s573_cdimg cdimg (
        .clk(clk), .rst(rst), .ide_rst(ide_rst),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready), .sec_busy(sec_busy),
        .cd_req(cd_req), .cd_lba(cd_lba),
        .cd_ack(cd_ack), .cd_wr(cd_wr), .cd_data(cd_data)
    );

    s573_cdtoc cdtoc (
        .clk(clk), .rst(rst),
        .ti_write(1'b0), .ti_addr(9'd0), .ti_data(32'd0),
        .img_mounted(1'b0), .img_size(64'd0),
        .toc_track_count(toc_track_count), .toc_leadout(toc_leadout),
        .toc_qtrack(toc_qtrack), .toc_qstart(toc_qstart), .toc_qaudio(toc_qaudio)
    );

    always #5 clk = ~clk;

    // ---- deterministic, LBA-SENSITIVE disc oracle (== tb_cdboot.v) ----
    // user_byte depends on lba, so a STALE-sector fetch (served the wrong LBA's
    // buffer) is caught by the per-word data check -- the untagged-sec_ready RED.
    function [7:0] user_byte(input [31:0] lba, input integer u);
        reg [7:0] b;
        begin
            if (lba == 16) begin
                case (u)
                    0: b = 8'h01;
                    1: b = "C"; 2: b = "D"; 3: b = "0"; 4: b = "0"; 5: b = "1";
                    6: b = 8'h01;
                    default: b = (u + 8'h5a) & 8'hff;
                endcase
            end else
                b = (u + 8'h10*lba + (lba >> 8)) & 8'hff;
            user_byte = b;
        end
    endfunction
    function [7:0] raw_byte(input [31:0] lba, input integer k);
        begin
            if (k < 16) begin                  // MODE1 sync/header
                if (k == 0)       raw_byte = 8'h00;
                else if (k <= 10) raw_byte = 8'hff;
                else if (k == 15) raw_byte = 8'h01;
                else              raw_byte = 8'h00;
            end else
                raw_byte = user_byte(lba, k - 16);
        end
    endfunction

    // ======================================================================
    // Host BFM -- reactive CUECHD sd-block server, a CLOCKED FSM so that a reset
    // (rst OR ide_rst) instantly ABORTS an in-flight transfer, exactly as a real
    // IDE reset aborts the drive's command. Swept ack/word latency; a `host_stall`
    // knob truncates a sector mid-stream (models a transient HPS/f2sdram wedge).
    // Purely request-driven: it serves ONLY when cdimg asserts cd_req, so a wedged
    // cdimg (cd_req stuck low in S_STREAM) is never spuriously refilled.
    // ======================================================================
    reg  [31:0] host_ack_delay   = 32'd0;    // clks from cd_req to cd_ack
    reg  [31:0] host_word_gap    = 32'd0;    // idle clks between streamed words (0 = back-to-back)
    reg         host_stall       = 1'b0;     // 1 = truncate the next sector at host_stall_words
    reg  [31:0] host_stall_words = 32'd500;  // words streamed before the wedge (< 1176 -> stuck)
    reg  [31:0] host_fetches     = 32'd0;    // diag: sectors the host has fully streamed

    localparam [1:0] H_IDLE=2'd0, H_ACK=2'd1, H_STREAM=2'd2;
    reg  [1:0]  hstate = H_IDLE;
    reg  [31:0] hlba, hcnt, hwords, hackc, hgap;

    always @(negedge clk) begin
        if (rst || ide_rst) begin
            hstate <= H_IDLE; cd_ack <= 1'b0; cd_wr <= 1'b0;
        end else begin
            cd_ack <= 1'b0; cd_wr <= 1'b0;
            case (hstate)
                H_IDLE: if (cd_req === 1'b1) begin
                    hlba   <= cd_lba;
                    hwords <= host_stall ? host_stall_words : 32'd1176;
                    hcnt   <= 32'd0;
                    hackc  <= host_ack_delay;
                    hstate <= H_ACK;
                end
                H_ACK: if (hackc == 32'd0) begin
                    cd_ack <= 1'b1;                 // 1-clk accept (cdimg samples at posedge)
                    hgap   <= 32'd0;
                    hstate <= H_STREAM;
                end else
                    hackc <= hackc - 32'd1;
                H_STREAM: begin
                    if (hgap == 32'd0) begin
                        cd_data <= (hlba < PREGAP) ? 16'h0000   // psx.cpp:479-481 zero zone
                                 : {raw_byte(hlba - PREGAP, 2*hcnt + 1),
                                    raw_byte(hlba - PREGAP, 2*hcnt)};
                        cd_wr <= 1'b1;
                        hgap  <= host_word_gap;
                        if (hcnt == hwords - 32'd1) begin
                            // sector fully streamed (hwords==1176) -> back to idle;
                            // OR truncated (hwords<1176) -> cdimg is left stuck in
                            // S_STREAM (the injected wedge). Either way the host idles
                            // and will NOT re-request; only a fresh cd_req re-arms it.
                            if (hwords == 32'd1176) host_fetches <= host_fetches + 32'd1;
                            hstate <= H_IDLE;
                        end else
                            hcnt <= hcnt + 32'd1;
                    end else
                        hgap <= hgap - 32'd1;
                end
            endcase
        end
    end

    // ---- ch5 DMA BFM: drain one 512-word sector per the patched dma.vhd ----
    // (== tb_cdboot.v's dma_drain_sector, validated cycle-for-cycle against the
    // real VHDL engine by sim/nvc/tb_dma_ch5.vhd). `full`=1 checks every word;
    // `full`=0 checks the first 2 words of every sector (LBA-sensitive: still
    // catches a stale/wrong-LBA sector) -- keeps the 450-sector reads affordable.
    integer db, dw, didx;
    reg [15:0] dlo, dhi;
    reg [15:0] samp_w [0:3];          // first 4 words of the last-drained sector
    task dma_drain_sector(input [31:0] lba, input integer full, input [255:0] tag);
        begin
            for (db = 0; db < 16; db = db + 1) begin        // 16 bursts x 32 words
                for (dw = 0; dw < 32; dw = dw + 1) begin
                    @(negedge clk); dma_rd = 1'b1; #1 dlo = dma_dout;   // low half
                    @(negedge clk);                #1 dhi = dma_dout;   // high half
                    didx = (db*32 + dw)*4;
                    if (db == 0 && dw < 2) begin
                        samp_w[dw*2]   = dlo;
                        samp_w[dw*2+1] = dhi;
                    end
                    if (full || (db == 0 && dw < 2)) begin
                        chk(dlo, {user_byte(lba, didx + 1), user_byte(lba, didx)},   tag);
                        chk(dhi, {user_byte(lba, didx + 3), user_byte(lba, didx + 2)}, tag);
                    end
                end
                @(negedge clk); dma_rd = 1'b0;              // chop pause
                repeat (8) @(negedge clk);
            end
        end
    endtask

    // ---- bus + check helpers (== tb_cdboot.v) ----
    task io_write(input [3:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; addr=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task io_read(input [3:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; addr=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 30)
                    $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                else if (errors == 31)
                    $display("FAIL: (further mismatches counted silently)");
            end
        end
    endtask
    // bounded INTRQ wait. Returns got_irq=1 if INTRQ arrived within maxc; on
    // timeout it counts an error (a STALL that never completes -- the gate-5 RED)
    // and returns 0 so the caller can move on instead of hanging the whole sim.
    integer wcnt;
    task wait_irq(input integer maxc, input [255:0] what, output got_irq);
        begin
            wcnt = 0;
            while (intrq !== 1'b1 && wcnt < maxc) begin @(posedge clk); wcnt = wcnt + 1; end
            if (intrq !== 1'b1) begin
                $display("FAIL: IRQ/completion timeout after %0d clks (%0s)", maxc, what);
                errors = errors + 1;
                got_irq = 1'b0;
            end else
                got_irq = 1'b1;
        end
    endtask

    // ---- reset both DUTs + the host between sub-tests (test isolation) ----
    // A top-level rst pulse resets atapi + cdimg + the host FSM to a known clean
    // state. (In the RED build this is the ONLY thing that can free a cdimg wedged
    // by a prior sub-test -- ide_rst can't, which is the bug.) cdtoc is untouched.
    task reset_duts;
        begin
            @(negedge clk); rst = 1; ide_rst = 0; sel = 0; we = 0; re = 0; dma_rd = 0;
            host_ack_delay = 0; host_word_gap = 0; host_stall = 0; host_stall_words = 500;
            repeat (6) @(negedge clk); rst = 0; repeat (4) @(negedge clk);
        end
    endtask

    // ---- PACKET dispatch prologue (features=0, bc limit 0x0800 -- BIOS order) ----
    task packet_prologue;
        reg [15:0] v;
        begin
            io_write(4'd1, 16'h0000);                  // features = 0
            io_write(4'd4, 16'h0000);                  // byte count limit lo
            io_write(4'd5, 16'h0008);                  // byte count limit hi (0x0800)
            io_write(4'd7, 16'h00A0);                  // PACKET
            io_read (4'd7, v); chk(v & 16'h00ff, 16'h0008, "PACKET DRQ");
            io_read (4'd2, v); chk(v & 16'h00ff, 16'h0001, "PACKET ireason C/D");
        end
    endtask

    // READ(12) dispatch, 16-bit transfer length (the oracle log has len up to 450).
    // CDB bytes: [0]=A8 [2..5]=LBA big-endian [8..9]=len big-endian. `garbage`
    // reproduces the BIOS's stack-garbage in bytes 1/10/11 (log: fd/0b/80) -- the
    // drive must ignore them. Word writes to reg0 pack {high_byte, low_byte}.
    task read12_dispatch(input [31:0] lba, input [15:0] len, input integer garbage);
        begin
            packet_prologue;
            io_write(4'd0, garbage ? 16'hFDA8 : 16'h00A8);          // pkt[0]=A8, pkt[1]=garb
            io_write(4'd0, {lba[23:16], lba[31:24]});               // pkt[2],pkt[3]
            io_write(4'd0, {lba[7:0],   lba[15:8]});                // pkt[4],pkt[5]
            io_write(4'd0, 16'h0000);                               // pkt[6],pkt[7] (len[31:16]=0)
            io_write(4'd0, {len[7:0], len[15:8]});                  // pkt[8]=len hi, pkt[9]=len lo
            io_write(4'd0, garbage ? 16'h800B : 16'h0000);          // pkt[10],pkt[11]
        end
    endtask

    // START/STOP UNIT (0x1b) -- the per-song ritual opcode (oracle n=541/545/546..).
    // A real CR-589 + MAME answer GOOD (non-data completion, no ERR); the current
    // RTL falls to the default CHECK-CONDITION arm -> this asserts GOOD -> RED now.
    task stop_unit(input [255:0] tag);
        reg [15:0] v; reg gi;
        begin
            packet_prologue;
            io_write(4'd0, 16'h001B); io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000);
            io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000);
            wait_irq(20000, tag, gi);
            if (gi) begin
                io_read(4'd7, v);
                if ((v & 16'h0001) !== 16'h0000) begin      // ERR must be clear (GOOD, not CHECK COND)
                    $display("FAIL: %0s CHECK CONDITION status=%02h (want GOOD, ERR clear)", tag, v[7:0]);
                    errors = errors + 1;
                end
                chk(v & 16'h00ff, 16'h0050, tag);           // DRDY|DSC good completion
                io_read(4'd1, v); chk(v & 16'h00ff, 16'h0000, "STOP UNIT error=0");
            end
        end
    endtask

    // ---- drive re-init handshake (oracle workload part (a): the re-init bundle
    //      the game interleaves with the READ storm, log n=13..20). Models the
    //      subset that needs no disc metadata -- IDENTIFY (the settle path) +
    //      SET FEATURES + TEST UNIT READY -- and asserts the drive stays
    //      responsive through it (a wedge here would show as a bounded timeout).
    //      The full TOC/CAPACITY content path is covered exhaustively by tb_cdboot.v.
    task reinit_lite(input [255:0] tag);
        reg [15:0] v; reg gi; integer kk;
        begin
            // IDENTIFY PACKET DEVICE (0xA1): 512-byte data-in after the BSY settle
            io_write(4'd6, 16'h00A0); io_write(4'd8, 16'h0008);
            io_write(4'd1, 16'h0000); io_write(4'd4, 16'h0000); io_write(4'd5, 16'h0008);
            io_write(4'd7, 16'h00A1);
            wait_irq(8000, tag, gi);
            if (gi) begin
                io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "reinit IDENTIFY status DRDY|DRQ");
                for (kk = 0; kk < 256; kk = kk + 1) io_read(4'd0, v);   // drain 256 words
                wait_irq(8000, tag, gi);
                if (gi) begin io_read(4'd7, v); chk(v & 16'h0089, 16'h0000, "reinit IDENTIFY done"); end
            end
            // SET FEATURES 0xEF: accept-and-succeed (the CD-init transfer-mode set)
            io_write(4'd1, 16'h0003); io_write(4'd2, 16'h0021); io_write(4'd7, 16'h00EF);
            wait_irq(4000, tag, gi);
            if (gi) begin
                io_read(4'd7, v);
                if (v[0] !== 1'b0 || (v & 16'h0040) !== 16'h0040) begin
                    $display("FAIL: %0s SET FEATURES status=%02h (want DRDY, no ERR)", tag, v[7:0]);
                    errors = errors + 1;
                end
            end
            // TEST UNIT READY: non-data good completion (the drive is alive)
            packet_prologue;
            io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000);
            io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000); io_write(4'd0, 16'h0000);
            wait_irq(8000, tag, gi);
            if (gi) begin io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "reinit TUR completion"); end
        end
    endtask

    // ---- one multi-sector READ(12): dispatch, drain N sectors, ONE completion ----
    // Bounded at every wait (no hang). Asserts per-sector data == commanded LBA
    // (sampled: first 2 words of every sector, full-checked on the boundary
    // sectors). `bound` is the per-phase INTRQ timeout (>= the host's worst latency).
    integer secs_done, guard;
    reg [31:0] rd_lba;
    reg [15:0] rv;
    reg        got;
    task read12_run(input [31:0] lba0, input [15:0] nsec, input integer bound,
                    input [255:0] tag, input integer garbage);
        integer remaining, fullck;
        begin
            read12_dispatch(lba0, nsec, garbage);
            remaining = nsec;
            secs_done = 0;
            rd_lba    = lba0;
            guard     = 0;
            while (remaining > 0 && guard < 100000) begin
                guard = guard + 1;
                wait_irq(bound, tag, got);
                if (!got) begin remaining = 0; end       // stall -> error counted, bail this cmd
                else begin
                    io_read(4'd7, rv);                   // ISR latches STATUS (clears INTRQ)
                    if ((rv & 16'h0008) === 16'h0008) begin      // DRQ: a data phase
                        // full-check the first + last sector; sample the rest
                        fullck = (secs_done == 0) || (remaining == 1);
                        dma_drain_sector(rd_lba, fullck, tag);
                        remaining = remaining - 1;
                        secs_done = secs_done + 1;
                        rd_lba    = rd_lba + 1;
                    end else begin                                // completion arrived early?
                        if (remaining != 0) begin
                            $display("FAIL: %0s completion with %0d sectors remaining", tag, remaining);
                            errors = errors + 1;
                        end
                        remaining = 0;
                    end
                end
            end
            // ONE completion phase after the LAST sector
            if (secs_done == nsec) begin
                wait_irq(bound, tag, got);
                if (got) begin
                    io_read(4'd7, rv); chk(rv & 16'h00ff, 16'h0050, "completion status DRDY|DSC");
                    io_read(4'd2, rv); chk(rv & 16'h00ff, 16'h0003, "completion ireason CD|IO");
                    io_read(4'd1, rv); chk(rv & 16'h00ff, 16'h0000, "completion error=0");
                end
            end
        end
    endtask

    integer r;
    reg [15:0] v;
    reg        recovered;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);
        reset_duts;

        // ================================================================
        // [A] swept-latency READ(12) storm -- the happy path (GREEN on both
        //     builds; proves the bench never false-REDs and the fix keeps the
        //     normal path working). HPS ack latency swept fast -> ms-slow.
        // ================================================================
        $display("===== [A1] single-sector READ(12), ms-slow host (BSY data-ready gate) =====");
        host_ack_delay = 20000;                       // ms-scale HPS latency
        read12_dispatch(32'd16, 16'd1, 0);            // PVD sector
        // the BSY gate: no DRQ / no INTRQ until s573_cdimg raises sec_ready
        io_read(4'd7, v);
        if ((v & 16'h0088) !== 16'h0080) begin
            $display("FAIL: [A1] post-dispatch STATUS=%02h (want BSY=1,DRQ=0)", v[7:0]);
            errors = errors + 1;
        end
        if (intrq === 1'b1) begin
            $display("FAIL: [A1] INTRQ before sec_ready (stale-data window)");
            errors = errors + 1;
        end
        wait_irq(60000, "[A1] LBA16 data phase", got);
        if (got) begin
            io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "[A1] data status DRDY|DRQ");
            dma_drain_sector(32'd16, 1, "[A1] PVD sector");
            chk(samp_w[0], 16'h4301, "[A1] PVD word0 (0x01,'C')");
            chk(samp_w[1], 16'h3044, "[A1] PVD word1 ('D','0')");
            chk(samp_w[2], 16'h3130, "[A1] PVD word2 ('0','1')");
            wait_irq(20000, "[A1] LBA16 completion", got);
            if (got) begin io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "[A1] completion status"); end
        end

        // [A2] the re-init bundle interleaved with a fast len=64 storm read
        // (workload part (a); LBA + garbage CDB per oracle log n=12: a80a..71e1..0040).
        $display("===== [A2] re-init bundle + back-to-back READ(12) len=64, fast host (storm) =====");
        reset_duts; host_ack_delay = 0;   host_word_gap = 0;
        reinit_lite("[A2] re-init bundle");
        read12_run(32'd29153, 16'd64, 40000, "[A2] READ12 lba29153 len64 (fast)", 1);

        $display("===== [A3] re-init bundle + READ(12) len=64, medium host latency (sweep) =====");
        reset_duts; host_ack_delay = 256; host_word_gap = 1;
        reinit_lite("[A3] re-init bundle");
        read12_run(32'd3920, 16'd64, 80000, "[A3] READ12 lba3920 len64 (medium)", 1);

        // ================================================================
        // [B] the per-song ritual VERBATIM (oracle log n=542..546): preload
        //     READ12 lba=2086 len=1, lba=862 len=57, lba=42911 len=450, then
        //     START/STOP UNIT x2. The reads are GREEN; the STOP UNIT x2 is the
        //     H2a RED (default CHECK-CONDITION arm vs GOOD).
        // ================================================================
        // CDBs verbatim from the oracle log n=542..544: lba2086 clean, lba862 +
        // lba42911 carry the BIOS stack-garbage bytes 1/10/11 (fd/0b/80) the drive
        // must ignore -- so these reads also EXERCISE the garbage-ignore property.
        $display("===== [B] per-song ritual (preload 2086/862/42911 + STOP UNIT x2) =====");
        reset_duts; host_ack_delay = 8; host_word_gap = 0;
        read12_run(32'd2086,  16'd1,   40000,  "[B] preload READ12 lba2086 len1",   0);
        read12_run(32'd862,   16'd57,  60000,  "[B] preload READ12 lba862 len57",   1);
        read12_run(32'd42911, 16'd450, 200000, "[B] preload READ12 lba42911 len450", 1);
        stop_unit("[B] STOP UNIT #1");
        stop_unit("[B] STOP UNIT #2");

        // ================================================================
        // [C] the game's RECOVERY RITUAL -- the primary gate-5 RED. A fetch
        //     wedges mid-stream (transient HPS/f2sdram hiccup: host truncates the
        //     sector); the game then resets the drive (ide_rst) and RE-ISSUES the
        //     IDENTICAL READ(12), x3 (docs: the stall survives 2-3 resets). The
        //     bridge has recovered by the retries. A correct drive completes on
        //     the first retry; the current RTL leaves cdimg wedged in S_STREAM
        //     (ide_rst unwired) so every retry's sec_req is dropped -> BSY forever.
        // ================================================================
        // The bridge has HEALED by the retries (host_stall=0): a correct drive must
        // complete the re-issue. This is the exact silicon scenario -- the game's
        // resets fail even though the transport recovered, because cdimg is not
        // reset by ide_rst. `recovered` is load-bearing: it demands a REAL data
        // phase (DRQ) + LBA-correct drain + a good completion IRQ; a bare completion
        // with no data phase (a 1-sector READ that returned nothing) counts an error.
        $display("===== [C] recovery ritual: wedge mid-stream, ide_rst + re-issue x3 =====");
        reset_duts;
        host_ack_delay = 4; host_word_gap = 0;
        host_stall = 1; host_stall_words = 500;       // stream 500/1176 then wedge
        read12_dispatch(32'd42911, 16'd1, 0);         // an oracle per-song region (log n=544)
        repeat (4000) @(negedge clk);                 // let the host stream its 500 words + wedge
        if (intrq === 1'b1) begin
            $display("FAIL: [C] unexpected completion of a truncated fetch");
            errors = errors + 1;
        end
        host_stall = 0;                               // the transport recovers for the retries
        recovered = 1'b0;
        for (r = 1; r <= 3 && !recovered; r = r + 1) begin
            $display("       [C] drive reset + re-issue, attempt %0d", r);
            @(negedge clk); ide_rst = 1; repeat (8) @(negedge clk); ide_rst = 0;
            repeat (4) @(negedge clk);
            read12_dispatch(32'd42911, 16'd1, 0);
            wait_irq(40000, "[C] recovery retry", got);
            if (got) begin
                io_read(4'd7, v);
                if ((v & 16'h0008) === 16'h0008) begin        // a REAL data phase
                    dma_drain_sector(32'd42911, 1, "[C] recovered sector data==LBA42911");
                    wait_irq(20000, "[C] recovery completion", got);
                    if (got) begin
                        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "[C] recovery completion status");
                        recovered = 1'b1;                     // data + good completion == truly recovered
                    end
                end else begin
                    $display("FAIL: [C] retry %0d IRQ with no data phase (status=%02h) -- read returned nothing", r, v[7:0]);
                    errors = errors + 1;
                end
            end
        end
        if (!recovered) $display("       [C] READ never recovered across 3 drive resets (the -1N stall)");

        // ================================================================
        // [D] STALE-SECTOR variant -- untagged sec_ready. The ISR aborts a fetch
        //     for LBA X (via ide_rst) mid-request and re-issues for a DIFFERENT
        //     LBA Y. The current RTL drops Y's sec_req (cdimg not in S_IDLE) and
        //     later serves X's buffered data as Y (sec_ready carries no LBA) ->
        //     the data check fires. A correct drive serves Y.
        // ================================================================
        $display("===== [D] stale-sector: abort LBA X mid-request, re-issue LBA Y =====");
        reset_duts;
        host_ack_delay = 400; host_word_gap = 0;      // slow ack -> inject during S_REQ
        read12_dispatch(32'd20, 16'd1, 0);            // READ X=20; cdimg -> S_REQ (cd_req=1)
        wcnt = 0; while (cd_req !== 1'b1 && wcnt < 2000) begin @(negedge clk); wcnt = wcnt + 1; end
        if (cd_req !== 1'b1) begin
            $display("FAIL: [D] cdimg never reached S_REQ");
            errors = errors + 1;
        end else begin
            repeat (20) @(negedge clk);               // sit in S_REQ (before cd_ack)
            @(negedge clk); ide_rst = 1; repeat (8) @(negedge clk); ide_rst = 0;
            repeat (4) @(negedge clk);
            read12_dispatch(32'd4378, 16'd1, 0);      // re-issue for Y=4378 (different LBA)
            wait_irq(40000, "[D] re-issue data phase", got);
            if (got) begin
                io_read(4'd7, v);
                if ((v & 16'h0008) === 16'h0008) begin        // a REAL data phase (required)
                    dma_drain_sector(32'd4378, 1, "[D] data==LBA4378 (not stale X)");
                    wait_irq(20000, "[D] re-issue completion", got);
                    if (got) begin io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "[D] completion status"); end
                end else begin
                    // no data phase -> the LBA-correctness check was skipped; a
                    // 1-sector READ must serve data. Fail loud (never a silent pass).
                    $display("FAIL: [D] re-issue completed with no data phase (status=%02h) -- LBA check skipped", v[7:0]);
                    errors = errors + 1;
                end
            end
        end

        $display("-----------------------------------------");
        if (errors == 0) $display("RESULT: PASS (gate5_replay)");
        else             $display("RESULT: FAIL (gate5_replay, %0d errors)", errors);
        $finish;
    end

    // absolute backstop (the bounded waits above should always reach the end first)
    initial begin #900000000; $display("RESULT: FAIL (gate5_replay wall-clock timeout)"); $finish; end
endmodule
