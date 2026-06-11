`timescale 1ns/1ps
// tb_cdboot.v - the GX700 BIOS CD-boot replay, MAME-EXACT (the trace is the spec).
//
// The spec is local/cd_adjudication/atapi_trace.txt: a register-level MAME trace
// of the REAL 573 BIOS CD-booting hypbbc2p. The full traced sequence, replayed
// here verbatim (every CDB byte, including the BIOS's stack-garbage bytes):
//
//   IDE reset (0x1f560000 0->1)  -> ATAPI signature (ireason 01, lba 01, 0xEB14)
//   IDENTIFY PACKET DEVICE 0xA1  -> 256 words, word0 masks (w0&0xDF00)==0x8500,
//                                   (w0&0x60) in {0,0x40}
//   TEST UNIT READY              -> non-data completion
//   REQUEST SENSE (alloc 16)     -> 16 bytes, resp code 0x70, sense key 0
//   READ TOC (start 0, alloc 12) -> header len 0x0012, first/last 01/01,
//                                   descriptor: ADR/CTRL 0x14 track 01 LBA 0
//   READ TOC (start 0xAA)        -> descriptor: track 0xAA (lead-out), LBA 16680
//                                   (the hypbbc2p fixture) <- TOC CONTENT gate
//   READ TOC (start 0) again
//   MODE SENSE(10) page 0x0E (alloc 24)
//   READ CAPACITY                -> last LBA 16679 (= lead-out - 1), block 2048
//   READ(12) LBA16    x1         -> the ISO9660 PVD sector: buf[0]==1 && "CD001"
//   READ(12) LBA18    x1         -> CDB stack-garbage bytes 1/10/11 = 64/3D/80
//   READ(12) LBA20    x4         -> multi-sector, garbage bytes 64/../3F/80
//   READ(12) LBA16405 x1         -> the boot-binary region
//   READ(12) LBA16406 x124       -> the boot binary burst (replayed in full)
//
// NOT in the sequence: SET FEATURES 0xEF - the adjudication trace proves it is
// NOT on the CD-boot path (it remains in the RTL + a supplementary check below).
//
// Every sector read is mode 2 (DMA): the BIOS's ONLY sector data path is DMA
// channel 5 (ISR helper 0x803cddb8: DPCR|=0x00800000, MADR5=buf, BCR5=bc>>2,
// CHCR5=0x11050100 - 32-word chopping). The ch5 BFM below follows the PATCHED
// psx/rtl/dma.vhd - and that BFM is itself validated against the REAL VHDL
// engine by sim/nvc/run_dma_ch5.sh (tb_dma_ch5: the S1 discriminator, PASS).
//
// TOC/READ CAPACITY content comes from the mounted-disc metadata: s573_cdtoc
// latches the Main 250828 disk_t blob (ioctl index 251: word0 track_count,
// word1 total_lba, track records at word 4t) and answers atapi.v's track-start
// queries; the TB feeds it the hypbbc2p fixture (1 track, lead-out 16680) the
// way emu.sv streams a real download. RED HISTORY: before the s573_cdtoc fix
// the RTL served a fixed track-01/LBA-0 TOC and a placeholder capacity - the
// [5]/[8] content checks here were the true-red gate (see git history).
module tb_cdboot;
    reg         clk = 0, rst = 1;
    reg         ide_rst = 0;
    reg         sel = 0, we = 0, re = 0;
    reg  [3:0]  addr = 0;
    reg  [15:0] din = 0;
    wire [15:0] dout;
    wire        intrq;
    integer     errors = 0;

    // ---- the hypbbc2p disc fixture (MAME adjudication numbers) ----
    localparam [31:0] LEADOUT_LBA = 32'd16680;   // READ TOC(0xAA) lead-out
    localparam [7:0]  TRACK_COUNT = 8'd1;

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

    atapi dut (
        .clk(clk), .rst(rst), .ide_rst(ide_rst),
        .sel(sel), .addr(addr), .we(we), .re(re),
        .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b1),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready),
        .dma_req(dma_req), .dma_rd(dma_rd), .dma_dout(dma_dout)
    );

    s573_cdimg cdimg (
        .clk(clk), .rst(rst),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready), .sec_busy(sec_busy),
        .cd_req(cd_req), .cd_lba(cd_lba),
        .cd_ack(cd_ack), .cd_wr(cd_wr), .cd_data(cd_data)
    );

    always #5 clk = ~clk;

    // ---- timing model ----
    // HOST_DELAY models the ms-scale HPS sd-block latency on the FIRST sector
    // (proves the BSY data-ready gate); the boot-binary burst then runs with the
    // host at stream speed so the DUT's ~4096-clk1x pace floor is the limiter.
    localparam integer HOST_DELAY = 20000;
    localparam integer PACE_NS    = 4000 * 10;

    // ---- bus helpers ----
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
                if (errors <= 24)
                    $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                else if (errors == 25)
                    $display("FAIL: (further mismatches counted silently)");
            end
        end
    endtask
    // bounded INTRQ wait (the BIOS's IRQ10 path; bounded like its 0xf690 polls)
    integer wcnt;
    task wait_irq(input integer maxc, input [255:0] what);
        begin
            wcnt = 0;
            while (intrq !== 1'b1 && wcnt < maxc) begin @(posedge clk); wcnt = wcnt + 1; end
            if (intrq !== 1'b1) begin
                $display("FAIL: IRQ timeout (%0s)", what);
                errors = errors + 1;
            end
        end
    endtask

    // ---- synthetic disc oracle (deterministic; ISO9660 PVD at LBA 16) ----
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

    // ---- host BFM: ms-scale-late sector service ----
    reg host_slow = 1;
    integer hw;
    reg [31:0] hlba;
    initial forever begin
        wait (cd_req === 1'b1);
        hlba = cd_lba;
        if (host_slow) repeat (HOST_DELAY) @(negedge clk);  // the HPS takes its time
        @(negedge clk); cd_ack = 1'b1;
        @(negedge clk); cd_ack = 1'b0;
        for (hw = 0; hw < 1176; hw = hw + 1) begin
            @(negedge clk);
            cd_data = {raw_byte(hlba, 2*hw+1), raw_byte(hlba, 2*hw)};
            cd_wr   = 1'b1;
            @(negedge clk); cd_wr = 1'b0;
        end
    end

    // ---- ch5 DMA BFM: drain one 512-word sector per the patched dma.vhd ----
    // BCR=0x200 words, CHCR=0x11050100: 32-word chop bursts, one 16-bit halfword
    // per dma_rd cycle (LOW half first - the SPU-pattern accumulate), chop-pause
    // gaps between bursts. This BFM is validated cycle-for-cycle against the
    // REAL patched dma.vhd by sim/nvc/tb_dma_ch5.vhd (S1 discriminator: PASS).
    integer db, dw;
    reg [15:0] dlo, dhi;
    reg [15:0] pvd_w [0:3];          // first 4 words of the last-drained sector
    task dma_drain_sector(input [31:0] lba);
        begin
            for (db = 0; db < 16; db = db + 1) begin        // 16 bursts x 32 words
                for (dw = 0; dw < 32; dw = dw + 1) begin
                    @(negedge clk); dma_rd = 1'b1; #1 dlo = dma_dout;   // low half
                    @(negedge clk);                #1 dhi = dma_dout;   // high half
                    if (db == 0 && dw < 2) begin
                        pvd_w[dw*2]   = dlo;
                        pvd_w[dw*2+1] = dhi;
                    end
                    chk(dlo, {user_byte(lba, (db*32+dw)*4 + 1), user_byte(lba, (db*32+dw)*4)},
                        "DMA word low half");
                    chk(dhi, {user_byte(lba, (db*32+dw)*4 + 3), user_byte(lba, (db*32+dw)*4 + 2)},
                        "DMA word high half");
                end
                @(negedge clk); dma_rd = 1'b0;              // chop pause
                repeat (8) @(negedge clk);
            end
        end
    endtask

    // ---- PIO drain of one sector (the fallback path) ----
    integer pw;
    reg [15:0] pv;
    task pio_drain_sector(input [31:0] lba);
        begin
            for (pw = 0; pw < 1024; pw = pw + 1) begin
                io_read(4'd0, pv);
                chk(pv, {user_byte(lba, 2*pw+1), user_byte(lba, 2*pw)}, "PIO sector word");
            end
        end
    endtask

    // ---- PACKET dispatch prologue (features=0, bc limit 0x0800 - BIOS order) ----
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

    // READ(12) - MAME-exact CDB option: the BIOS's reader leaves stack garbage in
    // CDB bytes 1/10/11 (trace: 0x64 / 0x3D / 0x80); the drive must ignore them.
    task read12_dispatch(input [31:0] lba, input [7:0] nsec, input integer garbage);
        begin
            packet_prologue;
            io_write(4'd0, garbage ? 16'h64A8 : {8'h00, 8'hA8});  // pkt[0]=A8, pkt[1]=garbage
            io_write(4'd0, {lba[23:16], lba[31:24]});  // pkt[2],pkt[3]
            io_write(4'd0, {lba[7:0],   lba[15:8]});   // pkt[4],pkt[5]
            io_write(4'd0, 16'h0000);                  // pkt[6],pkt[7] (len[31:16]=0)
            io_write(4'd0, {nsec, 8'h00});             // pkt[8]=0, pkt[9]=len lo
            io_write(4'd0, garbage ? 16'h803D : 16'h0000);        // pkt[10],pkt[11]
        end
    endtask

    // fixed-response data-in PACKET command: send CDB, wait the data IRQ, check
    // byte count, return (drain + completion handled by the caller)
    task packet_send6(input [15:0] w0, input [15:0] w1, input [15:0] w2,
                      input [15:0] w3, input [15:0] w4, input [15:0] w5);
        begin
            packet_prologue;
            io_write(4'd0, w0); io_write(4'd0, w1); io_write(4'd0, w2);
            io_write(4'd0, w3); io_write(4'd0, w4); io_write(4'd0, w5);
        end
    endtask

    task expect_datain(input [7:0] bc_lo, input [7:0] bc_hi, input [255:0] what);
        reg [15:0] v;
        begin
            wait_irq(20000, what);
            io_read(4'd7, v); chk(v & 16'h0088, 16'h0008, what);          // DRQ, not BSY
            io_read(4'd2, v); chk(v & 16'h00ff, 16'h0002, "data ireason IO");
            io_read(4'd4, v); chk(v & 16'h00ff, {8'h00, bc_lo}, "data bc lo");
            io_read(4'd5, v); chk(v & 16'h00ff, {8'h00, bc_hi}, "data bc hi");
        end
    endtask

    task expect_completion(input [255:0] what);
        reg [15:0] v;
        begin
            wait_irq(20000, what);
            io_read(4'd7, v);
            if ((v & 16'h0089) !== 16'h0000) begin   // BSY/DRQ/ERR all clear
                $display("FAIL: %0s completion status=%02h (BSY/DRQ/ERR)", what, v[7:0]);
                errors = errors + 1;
            end
            io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "completion ireason CD|IO");
            io_read(4'd1, v); chk(v & 16'h00ff, 16'h0000, "completion error=0");
        end
    endtask

    // ---- the BIOS ISR model: one multi-sector READ(12) with remaining-byte
    //      accounting; -8 if completion arrives with remaining != 0 ----
    integer remaining;          // bytes outstanding
    integer secs_done;
    reg [31:0] rd_lba;
    reg [15:0] v;
    realtime   t_consumed;      // when the previous sector finished draining
    task read12_run(input [31:0] lba0, input [7:0] nsec, input integer use_dma,
                    input integer garbage);
        integer guard;
        begin
            read12_dispatch(lba0, nsec, garbage);
            remaining  = nsec * 2048;
            secs_done  = 0;
            rd_lba     = lba0;
            t_consumed = $realtime;
            guard      = 0;
            while (remaining > 0 && guard < 1000) begin
                guard = guard + 1;
                wait_irq(HOST_DELAY + 200000, "data/completion phase");
                io_read(4'd7, v);                       // ISR latches STATUS (clears INTRQ)
                if ((v & 16'h0008) === 16'h0008) begin  // DRQ: a data phase
                    // pacing floor: sector N+1's data IRQ never tailgates sector N
                    if (secs_done > 0 && ($realtime - t_consumed) < PACE_NS) begin
                        $display("FAIL: data IRQ pacing %g ns < %0d ns", $realtime - t_consumed, PACE_NS);
                        errors = errors + 1;
                    end
                    io_read(4'd2, v); chk(v & 16'h00ff, 16'h0002, "data ireason IO");
                    io_read(4'd4, v); chk(v & 16'h00ff, 16'h0000, "data bc lo");
                    io_read(4'd5, v); chk(v & 16'h00ff, 16'h0008, "data bc hi (0x0800)");
                    if (use_dma) dma_drain_sector(rd_lba);
                    else         pio_drain_sector(rd_lba);
                    t_consumed = $realtime;
                    remaining  = remaining - 2048;
                    secs_done  = secs_done + 1;
                    rd_lba     = rd_lba + 1;
                end else begin                           // no DRQ: the completion phase
                    io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "completion ireason CD|IO");
                    if (remaining != 0) begin
                        $display("FAIL: completion with remaining=%0d (BIOS -8)", remaining);
                        errors = errors + 1;
                    end
                    remaining = 0;                       // exit (error already counted)
                end
            end
            // ONE completion phase after the LAST sector
            if (secs_done == nsec) begin
                wait_irq(200000, "completion");
                io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "completion status DRDY|DSC");
                io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "completion ireason");
                io_read(4'd1, v); chk(v & 16'h00ff, 16'h0000, "completion error=0");
            end
        end
    endtask

    integer k;
    reg [15:0] w0;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ===== [0] IDE reset (WRST 0x1f560000 0->1) -> ATAPI signature =====
        $display("===== [0] IDE reset + ATAPI signature =====");
        @(negedge clk); ide_rst = 1;
        repeat (8) @(negedge clk); ide_rst = 0;
        repeat (4) @(negedge clk);
        io_read(4'd2, v); chk(v & 16'h00ff, 16'h0001, "signature ireason");
        io_read(4'd3, v); chk(v & 16'h00ff, 16'h0001, "signature lba low");
        io_read(4'd4, v); chk(v & 16'h00ff, 16'h0014, "signature bc lo (0x14)");
        io_read(4'd5, v); chk(v & 16'h00ff, 16'h00EB, "signature bc hi (0xEB)");
        io_read(4'd7, v); chk(v & 16'h0089, 16'h0000, "signature status idle");

        // ===== [1] IDENTIFY PACKET DEVICE (0xA1): word0 masks =====
        $display("===== [1] IDENTIFY PACKET DEVICE =====");
        io_write(4'd6, 16'h00A0);                  // drive select (trace pc 803cc7a0)
        io_write(4'd8, 16'h0008);                  // device control (trace Wc 0x08)
        io_write(4'd1, 16'h0000);                  // features = 0
        io_write(4'd4, 16'h0000);                  // bc limit 0x0800
        io_write(4'd5, 16'h0008);
        io_write(4'd7, 16'h00A1);
        io_read (4'd7, v); chk(v & 16'h00ff, 16'h0048, "IDENTIFY status DRDY|DRQ");
        io_read (4'd2, v); chk(v & 16'h00ff, 16'h0002, "IDENTIFY ireason IO");
        io_read (4'd4, v); chk(v & 16'h00ff, 16'h0000, "IDENTIFY bc lo");
        io_read (4'd5, v); chk(v & 16'h00ff, 16'h0002, "IDENTIFY bc hi (0x0200)");
        io_read (4'd0, w0);                        // word 0: general configuration
        if ((w0 & 16'hDF00) !== 16'h8500) begin    // ATAPI, CD-ROM, 12-byte packet
            $display("FAIL: IDENTIFY word0=%04h ((w0&DF00)!=8500)", w0);
            errors = errors + 1;
        end
        if ((w0 & 16'h0060) !== 16'h0000 && (w0 & 16'h0060) !== 16'h0040) begin
            $display("FAIL: IDENTIFY word0=%04h (DRQ-type bits %02h not in {0,40})", w0, w0 & 16'h60);
            errors = errors + 1;
        end
        for (k = 1; k < 49; k = k + 1) io_read(4'd0, w0);
        io_read(4'd0, w0);                         // word 49: capabilities
        if ((w0 & 16'h0400) !== 16'h0400) begin
            $display("FAIL: IDENTIFY word49=%04h (DMA-supported bit clear)", w0);
            errors = errors + 1;
        end
        for (k = 50; k < 256; k = k + 1) io_read(4'd0, w0);
        io_read(4'd7, v); chk(v & 16'h0089, 16'h0000, "IDENTIFY done status");

        // ===== [2] TEST UNIT READY (no 0xEF on the CD-boot path!) =====
        $display("===== [2] TEST UNIT READY =====");
        packet_send6(16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0000);
        expect_completion("TUR");

        // ===== [3] REQUEST SENSE (alloc 16) =====
        $display("===== [3] REQUEST SENSE =====");
        packet_send6(16'h0003, 16'h0000, 16'h0010, 16'h0000, 16'h0000, 16'h0000);
        expect_datain(8'h10, 8'h00, "REQUEST SENSE data phase");
        io_read(4'd0, w0); chk(w0 & 16'h00ff, 16'h0070, "sense resp code 0x70");
        io_read(4'd0, w0); chk(w0 & 16'h00ff, 16'h0000, "sense key 0 (ready)");
        for (k = 2; k < 8; k = k + 1) io_read(4'd0, w0);
        expect_completion("REQUEST SENSE");

        // ===== [4] READ TOC (start 0) - trace CDB 43 00 00 00 00 00 00 00 0C =====
        $display("===== [4] READ TOC (start track 0) =====");
        packet_send6(16'h0043, 16'h0000, 16'h0000, 16'h0000, 16'h000C, 16'h0000);
        expect_datain(8'h0C, 8'h00, "READ TOC(0) data phase");
        io_read(4'd0, w0); chk(w0, 16'h1200, "TOC(0) length 0x0012");
        io_read(4'd0, w0); chk(w0, 16'h0101, "TOC(0) first/last 01/01");
        io_read(4'd0, w0); chk(w0, 16'h1400, "TOC(0) ADR/CTRL 0x14");
        io_read(4'd0, w0); chk(w0, 16'h0001, "TOC(0) track 01");
        io_read(4'd0, w0); chk(w0, 16'h0000, "TOC(0) LBA hi");
        io_read(4'd0, w0); chk(w0, 16'h0000, "TOC(0) LBA lo (track 1 at 0)");
        expect_completion("READ TOC(0)");

        // ===== [5] READ TOC (start 0xAA): the LEAD-OUT - the TOC content gate ====
        // MAME (the spec): descriptor track 0xAA, LBA 16680. Pre-fix RTL served a
        // fixed track-01/LBA-0 TOC -> this was the true-red content assertion.
        $display("===== [5] READ TOC (start track 0xAA, lead-out) =====");
        packet_send6(16'h0043, 16'h0000, 16'h0000, 16'h00AA, 16'h000C, 16'h0000);
        expect_datain(8'h0C, 8'h00, "READ TOC(AA) data phase");
        io_read(4'd0, w0); chk(w0, 16'h0A00, "TOC(AA) length 0x000A");
        io_read(4'd0, w0); chk(w0, 16'h0101, "TOC(AA) first/last 01/01");
        io_read(4'd0, w0); chk(w0, 16'h1400, "TOC(AA) ADR/CTRL 0x14");
        io_read(4'd0, w0); chk(w0, 16'h00AA, "TOC(AA) track 0xAA (lead-out)");
        // LBA 16680 = 0x4128 big-endian in bytes 8..11 -> words {b9,b8}, {b11,b10}
        io_read(4'd0, w0); chk(w0, {LEADOUT_LBA[23:16], LEADOUT_LBA[31:24]}, "TOC(AA) LBA hi");
        io_read(4'd0, w0); chk(w0, {LEADOUT_LBA[7:0],  LEADOUT_LBA[15:8]},  "TOC(AA) LBA 16680");
        expect_completion("READ TOC(AA)");

        // ===== [6] READ TOC (start 0) again - trace repeats it =====
        $display("===== [6] READ TOC (start track 0) again =====");
        packet_send6(16'h0043, 16'h0000, 16'h0000, 16'h0000, 16'h000C, 16'h0000);
        expect_datain(8'h0C, 8'h00, "READ TOC(0) #2 data phase");
        io_read(4'd0, w0); chk(w0, 16'h1200, "TOC(0)#2 length");
        io_read(4'd0, w0); chk(w0, 16'h0101, "TOC(0)#2 first/last");
        for (k = 2; k < 6; k = k + 1) io_read(4'd0, w0);
        expect_completion("READ TOC(0) #2");

        // ===== [7] MODE SENSE(10) page 0x0E (alloc 24) =====
        $display("===== [7] MODE SENSE(10) page 0x0E =====");
        packet_send6(16'h005A, 16'h000E, 16'h0000, 16'h0000, 16'h0018, 16'h0000);
        expect_datain(8'h18, 8'h00, "MODE SENSE data phase");
        io_read(4'd0, w0); chk(w0, 16'h1600, "MODE SENSE data length 0x0016");
        for (k = 1; k < 12; k = k + 1) io_read(4'd0, w0);
        expect_completion("MODE SENSE");

        // ===== [8] READ CAPACITY: last LBA = lead-out - 1, block 2048 =====
        // MAME (the spec): 16679 / 0x800. Pre-fix RTL served a placeholder LBA.
        $display("===== [8] READ CAPACITY =====");
        packet_send6(16'h0025, 16'h0000, 16'h0000, 16'h0000, 16'h0000, 16'h0000);
        expect_datain(8'h08, 8'h00, "READ CAPACITY data phase");
        io_read(4'd0, w0); chk(w0, 16'h0000, "CAPACITY last-LBA bytes 0,1");
        io_read(4'd0, w0); chk(w0, {(LEADOUT_LBA[7:0]-8'd1), LEADOUT_LBA[15:8]},
                               "CAPACITY last-LBA 16679");
        io_read(4'd0, w0); chk(w0, 16'h0000, "CAPACITY blklen bytes 0,1");
        io_read(4'd0, w0); chk(w0, 16'h0008, "CAPACITY blklen 0x0800");
        expect_completion("READ CAPACITY");

        // ===== [9] READ(12) LBA16 x1: the ISO9660 PVD sector (ch5 DMA) =====
        // First sector: the host BFM is ms-late -> proves the BSY data-ready gate
        // (DRQ clear, no INTRQ until sec_ready; pre-fix RTL raised DRQ at dispatch
        // and ch5 would have drained stale BRAM).
        $display("===== [9] READ(12) LBA 16 (PVD) =====");
        read12_dispatch(32'd16, 8'd1, 0);
        io_read(4'd7, v);
        if ((v & 16'h0088) !== 16'h0080) begin
            $display("FAIL: post-dispatch STATUS=%02h (want BSY=1,DRQ=0: stale-data window)", v[7:0]);
            errors = errors + 1;
        end
        if (intrq === 1'b1) begin
            $display("FAIL: INTRQ before sec_ready (stale-data window)");
            errors = errors + 1;
        end
        wait_irq(HOST_DELAY + 200000, "LBA16 data phase");
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "LBA16 data status DRDY|DRQ");
        io_read(4'd4, v); chk(v & 16'h00ff, 16'h0000, "LBA16 bc lo");
        io_read(4'd5, v); chk(v & 16'h00ff, 16'h0008, "LBA16 bc hi");
        if (dma_req !== 1'b1) begin
            $display("FAIL: dma_req not asserted in the data phase");
            errors = errors + 1;
        end
        dma_drain_sector(32'd16);
        if (dma_req !== 1'b0) begin
            $display("FAIL: dma_req still asserted after the sector drained");
            errors = errors + 1;
        end
        // the GX700 PVD check: buf[0]==1 && buf[1..5]=="CD001"
        chk(pvd_w[0], 16'h4301, "PVD word0 (0x01,'C')");
        chk(pvd_w[1], 16'h3044, "PVD word1 ('D','0')");
        chk(pvd_w[2], 16'h3130, "PVD word2 ('0','1')");
        wait_irq(200000, "LBA16 completion");
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "LBA16 completion status");
        io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "LBA16 completion ireason");

        // ===== [10] READ(12) LBA18 x1 - CDB stack-garbage bytes 64/3D/80 =====
        $display("===== [10] READ(12) LBA 18 (garbage CDB bytes) =====");
        host_slow = 0;
        read12_run(32'd18, 8'd1, 1, 1);

        // ===== [11] READ(12) LBA20 x4 - multi-sector + garbage bytes =====
        $display("===== [11] READ(12) LBA 20 x4 =====");
        read12_run(32'd20, 8'd4, 1, 1);

        // ===== [12] READ(12) LBA16405 x1 - the boot-binary region =====
        $display("===== [12] READ(12) LBA 16405 =====");
        read12_run(32'd16405, 8'd1, 1, 0);

        // ===== [13] READ(12) LBA16406 x124 - the boot binary burst (FULL) =====
        $display("===== [13] READ(12) LBA 16406 x124 (boot binary) =====");
        read12_run(32'd16406, 8'd124, 1, 0);

        // ===== supplementary (off the traced path, RTL kept alive) =====
        // SET FEATURES 0xEF: NOT on the CD-boot path (adjudication), but the
        // flash-boot drive probe still issues it - keep it answering clean.
        $display("===== [S1] SET FEATURES 0xEF (supplementary) =====");
        io_write(4'd1, 16'h0003);
        io_write(4'd2, 16'h0021);
        io_write(4'd7, 16'h00EF);
        wait_irq(1000, "SET FEATURES");
        io_read(4'd7, v);
        if (v[0] !== 1'b0 || (v & 16'h0040) !== 16'h0040) begin
            $display("FAIL: SET FEATURES status=%02h (want DRDY, no ERR)", v[7:0]);
            errors = errors + 1;
        end
        // zero-length READ(12) -> immediate good completion
        $display("===== [S2] zero-length READ(12) (supplementary) =====");
        read12_dispatch(32'd20, 8'd0, 0);
        wait_irq(1000, "zero-length completion");
        io_read(4'd7, v);
        if ((v & 16'h0008) !== 16'h0000) begin
            $display("FAIL: zero-length READ raised a data phase (STATUS=%02h)", v[7:0]);
            errors = errors + 1;
            io_write(4'd7, 16'h0008);              // DEVICE RESET to recover
        end else begin
            chk(v & 16'h00ff, 16'h0050, "zero-length completion status");
            io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "zero-length completion ireason");
        end
        // PIO fallback stays alive: 1 sector via PIO
        $display("===== [S3] PIO sector fallback (supplementary) =====");
        read12_run(32'd17, 8'd1, 0, 0);

        if (errors == 0) $display("RESULT: PASS (cdboot)");
        else             $display("RESULT: FAIL (cdboot, %0d errors)", errors);
        $finish;
    end

    initial begin #80000000; $display("RESULT: FAIL (cdboot timeout)"); $finish; end
endmodule
