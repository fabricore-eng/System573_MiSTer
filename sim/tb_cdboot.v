`timescale 1ns/1ps
// tb_cdboot.v - the BIOS CD-boot ATAPI/DMA-ch5 contract replay (red-green gate).
//
// The disassembled 573 BIOS (dumps/bios/573.bin) is the spec:
//   * CD-init (0x803cb9e0): SET FEATURES 0xEF, wait IRQ, fail (-1) if STATUS.ERR.
//   * Sector reads (reader 0x803cc9f0 -> 0x803cc2b0, mode byte 0x803d228f = 2):
//     PACKET + READ(12), then the ISR data-phase dispatcher (0x803cb418) arms DMA
//     channel 5 per data IRQ (helper 0x803cddb8): DPCR|=0x00800000, MADR5=buf,
//     BCR5=latched_bytecount>>2 (plain word count, BA=0), CHCR5=0x11050100 --
//     trigger(28)+start(24)+chopping(8), chop window 32 words, syncmode 0. There
//     is NO PIO sector fallback in the BIOS (the only PIO sector loop, 0x803cb284,
//     requires mode==1 which no sector-read caller selects).
//   * The ISR does per-IRQ remaining-byte accounting and errors (-8) if the
//     completion phase arrives while remaining != 0.
//
// This TB drives ONLY bus-visible behavior (no DUT internals): task-file register
// reads/writes, INTRQ, and the ch5 dma_req/dma_rd/dma_dout port contract. The ch5
// DMA engine is a Verilog BFM faithful to the PATCHED psx/rtl/dma.vhd (the suite
// is iverilog-only; the VHDL core cannot co-simulate here -- it is gated by NVC
// elaboration + the boot harness): per data IRQ it "arms" BCR=bc>>2 32-bit words
// and drains them as 32-word chopped bursts -- dma_rd high for 64 consecutive
// ce-rate cycles (one 16-bit halfword per cycle, LOW half first, exactly the
// SPU-pattern accumulate the patch clones), then a chop-pause gap (the bit28
// re-trigger window), then the next burst.
//
// The MiSTer HPS sector fetch is ms-scale: the host BFM delays HOST_DELAY clks
// before serving every sector, proving the drive holds BSY (DRQ clear, no IRQ)
// until the sector is REALLY buffered -- the pre-fix RTL raised DRQ+INTRQ on the
// dispatch cycle and a ch5 drain would have pulled stale BRAM.
//
// RED (pre-fix RTL): compile with -DPREFIX_RTL against the OLD rtl/atapi.v (no
// sec_ready/dma ports; PIO drain). Records the three failure modes: 0xEF abort,
// instant-DRQ stale-data window, completion-with-remaining!=0 (-8).
// GREEN: the fixed RTL passes every check below.
module tb_cdboot;
    reg         clk = 0, rst = 1;
    reg         sel = 0, we = 0, re = 0;
    reg  [3:0]  addr = 0;
    reg  [15:0] din = 0;
    wire [15:0] dout;
    wire        intrq;
    integer     errors = 0;

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

`ifdef PREFIX_RTL
    // pre-fix RTL: no sec_ready / dma ports
    atapi dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sel(sel), .addr(addr), .we(we), .re(re),
        .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b1),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q)
    );
    assign dma_dout = 16'h0000;
    assign dma_req  = 1'b0;
`else
    atapi dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sel(sel), .addr(addr), .we(we), .re(re),
        .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b1),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready),
        .dma_req(dma_req), .dma_rd(dma_rd), .dma_dout(dma_dout)
    );
`endif

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
    // HOST_DELAY models the ms-scale HPS sd-block latency (a real ms at 33.8688 MHz
    // is ~33869 clk1x; 20000 keeps the sim quick while being 4 orders of magnitude
    // beyond the pre-fix same-cycle stale window). PACE_NS asserts the ~4096-clk1x
    // inter-sector data-IRQ floor (10 ns/clk): 4000 clks allows for the ~10-cycle
    // slop between the DUT's floor start (the last consume) and where this TB can
    // observe it (after the BFM's chop-pause tail).
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
                b = (u + 8'h10*lba) & 8'hff;
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
    // host_slow=1: every sector waits HOST_DELAY (proves the BSY data-ready gate).
    // host_slow=0: served at stream speed (~2.4k clks < the 4096-clk pace floor),
    // so in the multi-sector test the DUT's PACING is the inter-IRQ limiter and
    // the floor assertion below actually bites.
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
    // BCR=0x200 words, CHCR=0x11050100: 32-word chop bursts. Each 32-bit word =
    // 2 back-to-back dma_rd cycles (low halfword consumed first -- the cycle the
    // patch latches DMA_ATA_read_accu -- then the high half written to the fifo).
    // Between bursts dma_rd drops for the chop-pause (bit28 re-trigger) window.
    integer db, dw;
    reg [15:0] dlo, dhi;
    task dma_drain_sector(input [31:0] lba);
        begin
            for (db = 0; db < 16; db = db + 1) begin        // 16 bursts x 32 words
                for (dw = 0; dw < 32; dw = dw + 1) begin
                    @(negedge clk); dma_rd = 1'b1; #1 dlo = dma_dout;   // low half
                    @(negedge clk);                #1 dhi = dma_dout;   // high half
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

    // ---- PIO drain of one sector (the fallback path; also the PREFIX drain) ----
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

    // ---- PACKET + READ(12) dispatch (features=0, bc limit 0x0800 -- BIOS order) ----
    task read12_dispatch(input [31:0] lba, input [7:0] nsec);
        reg [15:0] v;
        begin
            io_write(4'd1, 16'h0000);                  // features = 0
            io_write(4'd4, 16'h0000);                  // byte count limit lo
            io_write(4'd5, 16'h0008);                  // byte count limit hi (0x0800)
            io_write(4'd7, 16'h00A0);                  // PACKET
            io_read (4'd7, v); chk(v & 16'h00ff, 16'h0008, "PACKET DRQ");
            io_read (4'd2, v); chk(v & 16'h00ff, 16'h0001, "PACKET ireason C/D");
            io_write(4'd0, {8'h00, 8'hA8});            // pkt[0]=0xA8 READ(12)
            io_write(4'd0, {lba[23:16], lba[31:24]});  // pkt[2],pkt[3]
            io_write(4'd0, {lba[7:0],   lba[15:8]});   // pkt[4],pkt[5]
            io_write(4'd0, 16'h0000);                  // pkt[6],pkt[7] (len[31:16]=0)
            io_write(4'd0, {nsec, 8'h00});             // pkt[8]=0, pkt[9]=len lo
            io_write(4'd0, 16'h0000);                  // pkt[10..11] -> dispatch
        end
    endtask

    // ---- the BIOS ISR model: one multi-sector READ(12) with remaining-byte
    //      accounting; -8 if completion arrives with remaining != 0 ----
    integer remaining;          // bytes outstanding
    integer secs_done;
    reg [31:0] rd_lba;
    reg [15:0] v;
    realtime   t_consumed;      // when the previous sector finished draining
    task read12_run(input [31:0] lba0, input [7:0] nsec, input integer use_dma);
        integer guard;
        begin
            read12_dispatch(lba0, nsec);
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
`ifndef PREFIX_RTL
                    // pacing floor: sector N+1's data IRQ never tailgates sector N
                    if (secs_done > 0 && ($realtime - t_consumed) < PACE_NS) begin
                        $display("FAIL: data IRQ pacing %g ns < %0d ns", $realtime - t_consumed, PACE_NS);
                        errors = errors + 1;
                    end
`endif
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

        // ===== [1] SET FEATURES 0xEF: the BIOS CD-init gate (0x803cb9e0) =====
        io_write(4'd1, 16'h0003);                  // features: set transfer mode
        io_write(4'd2, 16'h0021);                  // sector count: mode value
        io_write(4'd7, 16'h00EF);
        wait_irq(1000, "SET FEATURES");
        io_read(4'd7, v);
        if (v[0] !== 1'b0) begin
            $display("FAIL: SET FEATURES aborted (STATUS=%02h ERR set -> BIOS returns -1)", v[7:0]);
            errors = errors + 1;
        end
        if ((v & 16'h0040) !== 16'h0040) begin
            $display("FAIL: SET FEATURES status DRDY clear (%02h)", v[7:0]);
            errors = errors + 1;
        end

        // ===== [2] data-ready gating: DRQ/IRQ must NOT fire before sec_ready =====
        // The host BFM sits on the request for HOST_DELAY clks; right after
        // dispatch the drive must show BSY with DRQ clear and no INTRQ. (Pre-fix:
        // DRQ+INTRQ on the dispatch write -> ch5 would drain stale BRAM.)
        read12_dispatch(32'd16, 8'd1);
        io_read(4'd7, v);
        if ((v & 16'h0088) !== 16'h0080) begin
            $display("FAIL: post-dispatch STATUS=%02h (want BSY=1,DRQ=0: stale-data window)", v[7:0]);
            errors = errors + 1;
        end
        if (intrq === 1'b1) begin
            $display("FAIL: INTRQ before sec_ready (stale-data window)");
            errors = errors + 1;
        end
        // now run the BIOS ISR loop on it (1 sector, DMA drain on the green build)
        remaining = 2048; secs_done = 0; rd_lba = 32'd16; t_consumed = $realtime;
        wait_irq(HOST_DELAY + 200000, "LBA16 data phase");
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "LBA16 data status DRDY|DRQ");
        io_read(4'd4, v); chk(v & 16'h00ff, 16'h0000, "LBA16 bc lo");
        io_read(4'd5, v); chk(v & 16'h00ff, 16'h0008, "LBA16 bc hi");
`ifdef PREFIX_RTL
        pio_drain_sector(32'd16);
`else
        if (dma_req !== 1'b1) begin
            $display("FAIL: dma_req not asserted in the data phase");
            errors = errors + 1;
        end
        dma_drain_sector(32'd16);
        if (dma_req !== 1'b0) begin
            $display("FAIL: dma_req still asserted after the sector drained");
            errors = errors + 1;
        end
`endif
        wait_irq(200000, "LBA16 completion");
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "LBA16 completion status");
        io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "LBA16 completion ireason");

        // ===== [3] multi-sector READ(12) x3 + remaining-byte accounting (-8) =====
        // fast host: the DUT's pace floor becomes the inter-IRQ limiter (measured)
        host_slow = 0;
`ifdef PREFIX_RTL
        read12_run(32'd16, 8'd3, 0);
`else
        read12_run(32'd16, 8'd3, 1);
`endif

        // ===== [4] zero-length READ(12) -> immediate good completion =====
        read12_dispatch(32'd20, 8'd0);
        wait_irq(1000, "zero-length completion");
        io_read(4'd7, v);
        if ((v & 16'h0008) !== 16'h0000) begin
            $display("FAIL: zero-length READ raised a data phase (STATUS=%02h)", v[7:0]);
            errors = errors + 1;
            io_write(4'd7, 16'h0008);              // DEVICE RESET to recover (pre-fix path)
        end else begin
            chk(v & 16'h00ff, 16'h0050, "zero-length completion status");
            io_read(4'd2, v); chk(v & 16'h00ff, 16'h0003, "zero-length completion ireason");
        end

        // ===== [5] drive identity: Matsushita CR-589 + IDENTIFY DMA bit =====
        io_write(4'd7, 16'h00A0);
        io_write(4'd0, {8'h00, 8'h12});            // INQUIRY
        for (k = 0; k < 5; k = k + 1) io_write(4'd0, 16'h0000);
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "INQUIRY status");
        for (k = 0; k < 4; k = k + 1) io_read(4'd0, w0);   // words 0..3
        io_read(4'd0, w0); chk(w0, 16'h414D, "INQUIRY vendor 'MA'");   // bytes 8,9
        io_read(4'd0, w0); chk(w0, 16'h5354, "INQUIRY vendor 'TS'");   // bytes 10,11
        io_read(4'd0, w0); chk(w0, 16'h4948, "INQUIRY vendor 'HI'");   // bytes 12,13
        io_read(4'd0, w0); chk(w0, 16'h4154, "INQUIRY vendor 'TA'");   // bytes 14,15
        for (k = 8; k < 18; k = k + 1) io_read(4'd0, w0);  // drain to completion
        io_write(4'd7, 16'h00A1);                  // IDENTIFY PACKET DEVICE
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0048, "IDENTIFY status");
        for (k = 0; k < 49; k = k + 1) io_read(4'd0, w0);  // words 0..48
        io_read(4'd0, w0);
        if ((w0 & 16'h0400) !== 16'h0400) begin
            $display("FAIL: IDENTIFY word49=%04h (DMA-supported bit clear)", w0);
            errors = errors + 1;
        end
        for (k = 50; k < 256; k = k + 1) io_read(4'd0, w0);
        io_read(4'd7, v); chk(v & 16'h00ff, 16'h0050, "IDENTIFY done status");

        // ===== [6] PIO fallback stays alive (green): 1 sector via PIO =====
`ifndef PREFIX_RTL
        read12_run(32'd17, 8'd1, 0);
`endif

        if (errors == 0) $display("RESULT: PASS (cdboot)");
        else             $display("RESULT: FAIL (cdboot, %0d errors)", errors);
        $finish;
    end

    initial begin #80000000; $display("RESULT: FAIL (cdboot timeout)"); $finish; end
endmodule
