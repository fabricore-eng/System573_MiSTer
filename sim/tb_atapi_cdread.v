`timescale 1ns/1ps
// tb_atapi_cdread.v - END-TO-END ATAPI READ(10) from a mounted CD image.
//
// This is the Feature-B GATE: it wires atapi.v + s573_cdimg.v exactly as
// system573_top does (cd_attached=1), models the MiSTer CUECHD sd-block HOST, and
// drives atapi through the BIOS's PACKET / READ(10) sequence -- then asserts the
// bytes atapi returns on the PIO data register are the disc's ACTUAL sector data,
// NOT zeros (the old presence-only behaviour).
//
// Disc data source:
//   * REAL: sim/cddata/hypbbc2p_raw.hex (raw MODE1/2352 sectors 0..NSEC-1, generated
//     from the hypbbc2p CHD by gen_cddata.sh). The known assertion is the ISO9660
//     Primary Volume Descriptor at LBA 16: user bytes 01 'C' 'D' '0' '0' '1' ...
//   * If that fixture is absent, the host BFM synthesises a MODE1/2352 sector whose
//     user area is a deterministic pattern with the SAME ISO9660 PVD signature at
//     LBA 16, so the full data path is still exercised and `make` stays green.
module tb_atapi_cdread;
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
    // cdimg <-> host (CUECHD sd-block) interface
    wire        cd_req;
    wire [31:0] cd_lba;
    reg         cd_ack = 0, cd_wr = 0;
    reg  [15:0] cd_data = 0;

    wire        sec_ready, sec_busy;
    atapi dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sel(sel), .addr(addr), .we(we), .re(re),
        .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b1),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready),
        .toc_track_count(8'd1), .toc_leadout(32'd16680),
        .toc_qtrack(), .toc_qstart(32'd0), .toc_qaudio(1'b0),
        .dma_req(), .dma_rd(1'b0), .dma_dout()
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

    // ---- bus helpers (same shape as tb_atapi.v) ----
    task io_write(input [3:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; addr=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task io_read(input [3:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; addr=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- disc image ----
    // raw[] holds NSEC*2352 raw bytes (one /line in the hex). When the fixture is
    // absent we synthesise on the fly in raw_byte().
    localparam integer NSEC_MAX = 64;
    reg [7:0] raw [0:NSEC_MAX*2352-1];
    integer   have_fixture;     // 1 if the real hex loaded
    integer   nsec;

    // synthetic raw byte for LBA/k when no fixture: MODE1 header, then a PVD-flavoured
    // user area at LBA 16 and a deterministic pattern elsewhere.
    function [7:0] synth_byte(input [31:0] lba, input integer k);
        reg [7:0] b;
        integer   u;
        begin
            b = 8'h00;
            if (k < 16) begin                 // 16-byte sync/header (MODE1)
                if (k == 0)                 b = 8'h00;
                else if (k <= 10)           b = 8'hff;
                else if (k == 11)           b = 8'h00;
                else if (k == 15)           b = 8'h01;     // mode 1
                else                        b = 8'h00;     // MSF placeholders
            end else begin                    // user area (byte index u = k-16)
                u = k - 16;
                if (lba == 16) begin                       // ISO9660 PVD signature
                    case (u)
                        0: b = 8'h01;                      // volume descriptor type
                        1: b = "C"; 2: b = "D"; 3: b = "0"; 4: b = "0"; 5: b = "1";
                        6: b = 8'h01;                      // version
                        default: b = (u + 8'h5a) & 8'hff;  // deterministic filler
                    endcase
                end else
                    b = (u + 8'h10*lba) & 8'hff;
            end
            synth_byte = b;
        end
    endfunction

    // unified raw-byte accessor (real fixture or synthetic)
    function [7:0] disc_raw(input [31:0] lba, input integer k);
        begin
            if (have_fixture) disc_raw = raw[lba*2352 + k];
            else              disc_raw = synth_byte(lba, k);
        end
    endfunction

    // ---- host BFM: serve one raw 2352-byte sector when the reader requests it ----
    integer w;
    task host_serve_one;
        reg [31:0] lba;
        begin
            wait (cd_req === 1'b1);
            lba = cd_lba;
            @(negedge clk); cd_ack = 1'b1;
            @(negedge clk); cd_ack = 1'b0;
            for (w = 0; w < 1176; w = w + 1) begin
                @(negedge clk);
                cd_data = {disc_raw(lba, 2*w+1), disc_raw(lba, 2*w)};
                cd_wr   = 1'b1;
                @(negedge clk); cd_wr = 1'b0;
            end
        end
    endtask
    // free-running host: serves every request the reader makes
    initial forever host_serve_one;

    // ---- run a full ATAPI READ(10) of `lba`; the BIOS issues PACKET then the 12-byte
    // CDB, then PIO-reads 1024 words. Returns nothing; assertions inline. ----
    integer poll;
    task atapi_read10(input [31:0] lba);
        reg [15:0] v;
        begin
            io_write(4'd7, 16'h00A0);                 // PACKET
            // CDB: 0x28 READ(10), LBA big-endian in bytes 2..5, length in 7..8.
            io_write(4'd0, {8'h00, 8'h28});           // pkt[0]=0x28, pkt[1]=0
            io_write(4'd0, {lba[23:16], lba[31:24]}); // pkt[2]=LBA[31:24], pkt[3]=LBA[23:16]
            io_write(4'd0, {lba[7:0],  lba[15:8]});   // pkt[4]=LBA[15:8],  pkt[5]=LBA[7:0]
            io_write(4'd0, {8'h00, 8'h00});           // pkt[6]=0, pkt[7]=len hi
            io_write(4'd0, {8'h00, 8'h01});           // pkt[8]=len lo (1 block), pkt[9]=0
            io_write(4'd0, 16'h0000);                 // pkt[10..11] -> dispatch
            // The drive now holds BSY (DRQ clear) until the sector is REALLY buffered
            // (data-ready gating), so do what the BIOS does: a bounded STATUS poll
            // until BSY drops and DRQ rises. Bus-visible only -- no DUT peeking.
            poll = 0;
            v    = 16'h0080;
            while (poll < 100000 && (v & 16'h0088) !== 16'h0008) begin
                io_read(4'd7, v);
                poll = poll + 1;
            end
            chk(v & 16'h00ff, 16'h0048, "READ status DRDY|DRQ");
            io_read(4'd5, v); chk(v & 16'h00ff, 16'h0008, "READ byte count 0x0800");
        end
    endtask

    reg [15:0] word;
    integer    i, fd;
    reg [255:0] meta_unused;

    initial begin
        // try to load the real fixture
        have_fixture = 0; nsec = 0;
        fd = $fopen("cddata/hypbbc2p.meta", "r");
        if (fd != 0) begin
            // meta present implies the hex is too
            $fclose(fd);
            $readmemh("cddata/hypbbc2p_raw.hex", raw);
            have_fixture = 1;
            $display("tb_atapi_cdread: using REAL disc fixture (hypbbc2p)");
        end else begin
            $display("tb_atapi_cdread: NO fixture -> using SYNTHETIC ISO9660 sector");
        end

        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ===== THE GATE: READ(10) of LBA 16 returns the ISO9660 PVD, not zeros =====
        atapi_read10(32'd16);

        // PIO-read the 2048-byte sector (1024 words) and assert vs the disc image.
        for (i = 0; i < 1024; i = i + 1) begin
            io_read(4'd0, word);
            chk(word, {disc_raw(32'd16, 16 + 2*i + 1), disc_raw(32'd16, 16 + 2*i)},
                "PVD sector word");
        end

        // explicit human-readable checks on the load-bearing bytes
        // word0 = {user[1]='C', user[0]=0x01}; word1 = {'0','D'}; word2 = {'1','0'}
        // (re-read by issuing a fresh READ since the first drained to completion)
        atapi_read10(32'd16);
        io_read(4'd0, word); chk(word, 16'h4301, "PVD word0 (0x01,'C')");
        io_read(4'd0, word); chk(word, 16'h3044, "PVD word1 ('D','0')");
        io_read(4'd0, word); chk(word, 16'h3130, "PVD word2 ('0','1')");
        // prove it is NOT zeros
        if (word === 16'h0000) begin $display("FAIL: PVD read returned zeros"); errors=errors+1; end

        // ===== a SECOND, different LBA to prove per-LBA addressing works =====
        // drain the rest of the LBA16 sector first
        for (i = 3; i < 1024; i = i + 1) io_read(4'd0, word);
        atapi_read10(32'd17);
        io_read(4'd0, word);
        chk(word, {disc_raw(32'd17, 17), disc_raw(32'd17, 16)}, "LBA17 word0");
        for (i = 1; i < 1024; i = i + 1) io_read(4'd0, word);

        if (errors == 0) $display("RESULT: PASS (atapi_cdread)");
        else             $display("RESULT: FAIL (atapi_cdread, %0d errors)", errors);
        $finish;
    end

    initial begin #50000000; $display("RESULT: FAIL (atapi_cdread timeout)"); $finish; end
endmodule
