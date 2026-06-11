`timescale 1ns/1ps
// tb_s573_cdtoc.v - unit test for the mounted-CD disc-metadata latch.
//
// Covers the three legs atapi.v's READ TOC / READ CAPACITY depend on:
//   [1] fallback: img_mounted + img_size -> the serial img_size/2352 divider
//       (exact and truncating), single data track at LBA 0
//   [2] the Main 250828 disk_t download (ioctl 251) OVERRIDES the fallback:
//       track_count, total_lba (lead-out), per-track start/isAudio commits
//   [3] the registered track-start query port
//   [4] remount clears stale cdinfo back to the fallback
module tb_s573_cdtoc;
    reg         clk = 0, rst = 1;
    reg         ti_write = 0;
    reg  [8:0]  ti_addr = 0;
    reg  [31:0] ti_data = 0;
    reg         img_mounted = 0;
    reg  [63:0] img_size = 0;
    wire [7:0]  track_count;
    wire [31:0] leadout;
    reg  [6:0]  qtrack = 1;
    wire [31:0] qstart;
    wire        qaudio;
    integer     errors = 0;

    s573_cdtoc dut (
        .clk(clk), .rst(rst),
        .ti_write(ti_write), .ti_addr(ti_addr), .ti_data(ti_data),
        .img_mounted(img_mounted), .img_size(img_size),
        .toc_track_count(track_count), .toc_leadout(leadout),
        .toc_qtrack(qtrack), .toc_qstart(qstart), .toc_qaudio(qaudio)
    );

    always #5 clk = ~clk;

    task chk32(input [31:0] got, input [31:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: %0s = %08h (expected %08h)", what, got, exp);
            end
        end
    endtask

    task mount(input [63:0] size);
        begin
            @(negedge clk); img_size = size; img_mounted = 1;
            @(negedge clk); img_mounted = 0;
            repeat (50) @(negedge clk);          // divider: 40 cycles + settle
        end
    endtask

    task ti_word(input [8:0] a, input [31:0] d);
        begin @(negedge clk); ti_addr=a; ti_data=d; ti_write=1; @(negedge clk); ti_write=0; end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0;

        // ===== [1] fallback divider =====
        mount(64'd16680 * 64'd2352);             // hypbbc2p: exact multiple
        chk32(leadout, 32'd16680, "fallback lead-out (exact)");
        chk32({24'd0, track_count}, 32'd1, "fallback track count");
        mount(64'd16680 * 64'd2352 + 64'd1000);  // ragged tail -> truncate
        chk32(leadout, 32'd16680, "fallback lead-out (truncating)");
        mount(64'd333000 * 64'd2352);            // 74-minute disc
        chk32(leadout, 32'd333000, "fallback lead-out (74 min)");

        // query the fallback track 1
        qtrack = 7'd1; @(negedge clk); @(negedge clk);
        chk32(qstart, 32'd0, "fallback track 1 start");
        chk32({31'd0, qaudio}, 32'd0, "fallback track 1 is data");

        // ===== [2] disk_t download overrides =====
        ti_word(9'd0, 32'h00000202);             // 2 tracks (BCD 02)
        ti_word(9'd1, 32'd16680);                // lead-out
        ti_word(9'd2, 32'h00000342);
        ti_word(9'd3, 32'd0);
        ti_word(9'd4, 32'd0);                    // track 1: start 0
        ti_word(9'd5, 32'd11999);
        ti_word(9'd6, 32'h00000002);             //          data
        ti_word(9'd7, 32'd0);                    //          commit
        ti_word(9'd8, 32'd12000);                // track 2: start 12000
        ti_word(9'd9, 32'd16679);
        ti_word(9'd10, 32'h00010151);            //          isAudio (bit16)
        ti_word(9'd11, 32'd0);                   //          commit
        repeat (3) @(negedge clk);
        chk32({24'd0, track_count}, 32'd2, "cdinfo track count");
        chk32(leadout, 32'd16680, "cdinfo lead-out");

        // ===== [3] track queries =====
        qtrack = 7'd1; @(negedge clk); @(negedge clk);
        chk32(qstart, 32'd0, "track 1 start");
        chk32({31'd0, qaudio}, 32'd0, "track 1 data");
        qtrack = 7'd2; @(negedge clk); @(negedge clk);
        chk32(qstart, 32'd12000, "track 2 start");
        chk32({31'd0, qaudio}, 32'd1, "track 2 audio");

        // a LATE divider result must NOT clobber cdinfo: remount, then send
        // cdinfo immediately (before the 40-cycle divider finishes)
        @(negedge clk); img_size = 64'd99 * 64'd2352; img_mounted = 1;
        @(negedge clk); img_mounted = 0;
        ti_word(9'd1, 32'd55555);                // cdinfo lead-out wins
        repeat (60) @(negedge clk);
        chk32(leadout, 32'd55555, "cdinfo wins over a late divider result");

        // ===== [4] remount clears stale cdinfo =====
        mount(64'd1000 * 64'd2352);
        chk32(leadout, 32'd1000, "remount lead-out");
        chk32({24'd0, track_count}, 32'd1, "remount track count reset");
        qtrack = 7'd1; @(negedge clk); @(negedge clk);
        chk32(qstart, 32'd0, "remount track 1 start reset");

        if (errors == 0) $display("RESULT: PASS (s573_cdtoc)");
        else             $display("RESULT: FAIL (s573_cdtoc, %0d errors)", errors);
        $finish;
    end

    initial begin #2000000; $display("RESULT: FAIL (s573_cdtoc timeout)"); $finish; end
endmodule
