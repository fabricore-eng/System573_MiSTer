`timescale 1ns/1ps
// Testbench for s573_cdimg.v - the mounted-CD-image sector reader.
//
// Models the MiSTer CUECHD sd-block HOST: when the reader pulses cd_req it ACKs,
// then streams a synthetic RAW 2352-byte sector (1176 16-bit words) over cd_wr/
// cd_data, exactly like the upstream PSX cd_top SFETCH state machine receives it.
// Asserts: (1) the reader requests the LBA atapi handed it CONVERTED to Main's
// MSF space (sd_lba1 = user LBA + 150: Main's PSX CD service fakes a 150-sector
// track-1 pregap and serves zeros below it - support/psx/psx.cpp 250828:142-146,
// 479-481, 517); (2) it keeps ONLY the 2048 user-data bytes (raw word index
// 8..1031, i.e. byte offset 16) in its sector buffer, dropping the 16-byte
// sync/header AND the 288-byte EDC/ECC tail; (3) sec_ready rises when the
// sector is buffered.
module tb_s573_cdimg;
    reg         clk = 0, rst = 1;
    reg         sec_req = 0;
    reg  [31:0] sec_lba = 0;
    reg  [10:0] sbuf_addr = 0;
    wire [15:0] sbuf_q;
    wire        sec_ready, sec_busy;
    wire        cd_req;
    wire [31:0] cd_lba;
    reg         cd_ack = 0;
    reg         cd_wr  = 0;
    reg  [15:0] cd_data = 0;
    integer     errors = 0;

    s573_cdimg dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sec_req(sec_req), .sec_lba(sec_lba),
        .sbuf_addr(sbuf_addr), .sbuf_q(sbuf_q),
        .sec_ready(sec_ready), .sec_busy(sec_busy),
        .cd_req(cd_req), .cd_lba(cd_lba),
        .cd_ack(cd_ack), .cd_wr(cd_wr), .cd_data(cd_data)
    );

    always #5 clk = ~clk;

    // Deterministic synthetic RAW sector: raw byte k = (k + 7*LBA) & 0xff. The host
    // delivers it word-by-word (little-endian within each 16-bit word, matching the
    // sd_buff 16-bit stream). 1176 words = 2352 bytes.
    function [7:0] raw_byte(input [31:0] lba, input integer k);
        raw_byte = (k + 7*lba) & 8'hff;
    endfunction

    integer w;
    // Stream one raw sector to the reader, mimicking the HPS handshake. The
    // argument is the EXPECTED MSF-space request (user LBA + 150); content is
    // served indexed at (lba - 150), exactly like Main's psx_read_cd
    // (psx.cpp:517 read_lba = lba - 150; zeros below 150 per psx.cpp:479-481).
    task host_serve(input [31:0] lba);
        begin
            // wait for the reader's request
            wait (cd_req === 1'b1);
            if (cd_lba !== lba) begin
                $display("FAIL: cd_lba = %0d (expected MSF-space %0d)", cd_lba, lba);
                errors = errors + 1;
            end
            @(negedge clk); cd_ack = 1'b1;       // accept the request
            @(negedge clk); cd_ack = 1'b0;       // (reader drops cd_req on ack)
            // stream 1176 words
            for (w = 0; w < 1176; w = w + 1) begin
                @(negedge clk);
                cd_data = (lba < 32'd150) ? 16'h0000
                        : {raw_byte(lba - 32'd150, 2*w+1), raw_byte(lba - 32'd150, 2*w)};
                cd_wr   = 1'b1;
                @(negedge clk);
                cd_wr   = 1'b0;
                // a few idle cycles between words (host is not back-to-back)
                @(negedge clk);
            end
        end
    endtask

    // read a buffered user word (synchronous buffer: addr now, data next clk)
    task buf_read(input [10:0] a, output [15:0] d);
        begin @(negedge clk); sbuf_addr = a; @(posedge clk); #1 d = sbuf_q; end
    endtask

    reg [15:0] v;
    integer i;
    reg [31:0] LBA;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        LBA = 32'd16;            // ISO9660 PVD LBA (USER space) -- a realistic request
        // kick a fetch
        @(negedge clk); sec_lba = LBA; sec_req = 1'b1;
        @(negedge clk); sec_req = 1'b0;

        // the host must see the request in Main's MSF space: user + 150
        host_serve(LBA + 32'd150);

        // reader should signal the sector is ready
        wait (sec_ready === 1'b1);
        if (sec_busy !== 1'b0) begin $display("FAIL: sec_busy still high after ready"); errors=errors+1; end

        // buffer word j must equal raw user byte (16 + 2j), i.e. header skipped.
        // raw byte index for user word j = 16 + 2*j.
        for (i = 0; i < 1024; i = i + 1) begin
            buf_read(i[10:0], v);
            if (v !== {raw_byte(LBA, 16 + 2*i + 1), raw_byte(LBA, 16 + 2*i)}) begin
                $display("FAIL: user word %0d = %04h (expected %04h)", i, v,
                         {raw_byte(LBA, 16+2*i+1), raw_byte(LBA, 16+2*i)});
                errors = errors + 1;
            end
        end

        // spot-check a couple explicitly: word 0 = raw bytes 16,17 ; word 1023 = raw 2062,2063
        buf_read(11'd0, v);
        if (v[7:0] !== raw_byte(LBA,16)) begin $display("FAIL: word0 lo"); errors=errors+1; end
        buf_read(11'd1023, v);
        if (v[15:8] !== raw_byte(LBA,2063)) begin $display("FAIL: word1023 hi"); errors=errors+1; end

        if (errors == 0) $display("RESULT: PASS (s573_cdimg)");
        else             $display("RESULT: FAIL (s573_cdimg, %0d errors)", errors);
        $finish;
    end

    // global timeout
    initial begin #2000000; $display("RESULT: FAIL (s573_cdimg timeout)"); $finish; end
endmodule
