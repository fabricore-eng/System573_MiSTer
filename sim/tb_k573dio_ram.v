`timescale 1ns/1ps
// Testbench for k573dio.v BACKING_EXTERNAL=1 - the DDR3-backed 32 MiB DIO RAM
// (ddrsbm POST "MEMORY CHECK  22G/22H/22J" gate).
//
// Drives the MAME memcheck SHAPE through the register port: write pointer set
// ONCE per region, then a stream of auto-incrementing b4 writes; read pointer
// set once, then a stream of auto-incrementing b4 reads compared against the
// written pattern -- across all three 8 MB chip regions (22H @0x000000,
// 22J @0x800000, 22G @0x1000000), the 8 KB alias boundary (0x002000, where the
// old inline array wrapped), and the window top. The b4 read emulates the
// patch-0006 memorymux contract: the read strobe is HELD while dio_wait is
// asserted and the pointer must advance EXACTLY once per transaction.
//
// The DDR3 side is a behavioral 4-phase responder over a real (non-aliasing)
// 32 MiB beat store with varying latency (tb_s573_flash_sdram precedent).
//
// RED/GREEN: `make DIO_RAM_STUB=1 k573dio_ram` forces the pre-fix 8 KB aliasing
// inline array -- the region-distinctness checks then FAIL (everything aliases
// mod 8 KB), proving the test exercises the fix without hand-reverting RTL.
module tb_k573dio_ram;
    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [7:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire        dio_wait;
    wire        mem_rd_req;
    wire [21:0] mem_rd_addr;
    wire        mem_wr_req;
    wire [23:0] mem_wr_addr;
    wire [15:0] mem_wr_data;
    wire        dbg_ovf;
    wire        dbg_hi_write;
    wire [7:0]  mp3_out_byte;
    wire        mp3_out_valid;
    integer errors = 0;

    // responder-side registers (declared before the DUT port map uses them)
    reg [63:0] rd_q_r  = 64'd0;
    reg        rd_ack_r = 1'b0;
    reg        wr_ack_r = 1'b0;

    k573dio #(.BACKING_EXTERNAL(1), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(),
        .dio_wait(dio_wait), .cfg_ddrsbm(1'b0),
        .mem_rd_req(mem_rd_req), .mem_rd_addr(mem_rd_addr),
        .mem_rd_q(rd_q_r), .mem_rd_ack(rd_ack_r),
        .mem_wr_req(mem_wr_req), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_ack(wr_ack_r),
        .dbg_wfifo_ovf(dbg_ovf),
        .dbg_dio_hi_write(dbg_hi_write),
        .crypto_key1(), .crypto_key2(), .crypto_key3(),
        .mp3_start(), .mp3_end(), .fpga_ctrl(), .network_id(),
        .mp3_out_ready(1'b1),   // datapath test: always-ready sink (pacing is tb_k573_mp3stream)
        .mp3_out_byte(mp3_out_byte), .mp3_out_valid(mp3_out_valid),
        .dec_frame_sync(1'b0), .dec_frame_idle(1'b0), .pcm_sample_tick(1'b0)  // no decode counters here
    );

    always #5 clk = ~clk;

    // ---- behavioral DDR3 beat store (32 MiB, REAL -- no aliasing) ----
    reg [63:0] beats [0:4194303];
    integer    r_lat = 0, r_cnt = 0, w_lat = 0, w_cnt = 0;
    reg        wr_stall = 1'b0;   // TB control: freeze write acks (part 8)

    always @(posedge clk) begin
        // read server: 4-phase, latency rotating 0..10 cycles
        if (mem_rd_req && !rd_ack_r) begin
            if (r_cnt >= r_lat) begin
                rd_q_r   <= beats[mem_rd_addr];
                rd_ack_r <= 1'b1;
                r_cnt    <= 0;
                r_lat    <= (r_lat + 3) % 11;
            end else
                r_cnt <= r_cnt + 1;
        end else if (!mem_rd_req)
            rd_ack_r <= 1'b0;
        // write server: 16-bit lane into the beat, latency rotating 0..3
        if (mem_wr_req && !wr_ack_r && !wr_stall) begin
            if (w_cnt >= w_lat) begin
                case (mem_wr_addr[1:0])
                    2'd0: beats[mem_wr_addr[23:2]][15:0]  <= mem_wr_data;
                    2'd1: beats[mem_wr_addr[23:2]][31:16] <= mem_wr_data;
                    2'd2: beats[mem_wr_addr[23:2]][47:32] <= mem_wr_data;
                    2'd3: beats[mem_wr_addr[23:2]][63:48] <= mem_wr_data;
                endcase
                wr_ack_r <= 1'b1;
                w_cnt    <= 0;
                w_lat    <= (w_lat + 1) % 4;
            end else
                w_cnt <= w_cnt + 1;
        end else if (!mem_wr_req)
            wr_ack_r <= 1'b0;
    end

    // ---- bus tasks ----
    task wr_reg(input [7:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; off=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task set_wp(input [24:0] a);
        begin wr_reg(8'hb0, {7'd0, a[24:16]}); wr_reg(8'hb2, a[15:0]); end
    endtask
    task set_rp(input [24:0] a);
        begin wr_reg(8'hb6, {7'd0, a[24:16]}); wr_reg(8'hb8, a[15:0]); end
    endtask
    // b4 write at a given EXP1-ish pace (gap cycles between writes)
    task wr_b4(input [15:0] d, input integer gap);
        begin wr_reg(8'hb4, d); repeat (gap) @(negedge clk); end
    endtask
    // b4 read with the patch-0006 memorymux contract: assert the strobe, HOLD
    // it while dio_wait stalls, sample dout in the completion cycle, release
    // after exactly one more posedge (the consume edge).
    task rd_b4(output [15:0] d);
        begin
            @(negedge clk); sel=1; re=1; off=8'hb4;
            #1;
            while (dio_wait) begin @(negedge clk); #1; end
            d = dout;
            @(negedge clk); sel=0; re=0;
        end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [24:0] where);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("FAIL: [%07h] = %04h (expected %04h)", where, got, exp);
            end
        end
    endtask

    // ---- descramble reference (mirrors k573_mp3dec) for the MP3-port test ----
    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d; begin
            d = 16'd0;
            for (i=0;i<8;i=i+1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555); end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r=s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2];
        r_derive=r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7];
        r_spread=r; end
    endfunction
    reg [7:0] sgot [0:7];
    integer   sgi = 0;
    always @(posedge clk) if (!rst && mp3_out_valid) begin sgot[sgi]=mp3_out_byte; sgi=sgi+1; end

    // global timeout: a lost handshake must fail, not hang the suite
    initial begin
        #40_000_000;
        $display("RESULT: FAIL (timeout -- a b4 read stalled forever?)");
        $finish;
    end

    // region loci: the three chips' bases (MAME memcheck sweep), the 8 KB alias
    // boundary of the old inline array, and the top of the 32 MiB window
    reg [24:0] locus [0:4];
    reg [15:0] seed  [0:4];

    integer i, l;
    reg [15:0] v;
    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [15:0] smem [0:3];
    reg [7:0]  sexp [0:7];

    initial begin
        locus[0] = 25'h0000000; seed[0] = 16'hA100;   // 22H
        locus[1] = 25'h0800000; seed[1] = 16'hB200;   // 22J
        locus[2] = 25'h1000000; seed[2] = 16'hC300;   // 22G
        locus[3] = 25'h0002000; seed[3] = 16'hD400;   // 8 KB alias of locus[0]
        locus[4] = 25'h1FFFFC0; seed[4] = 16'hE500;   // window top
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; repeat (4) @(posedge clk);

        // ---- 1: MEMORY CHECK shape -- write all loci first (counter pattern,
        //         one pointer set per locus), then read all back. Distinctness
        //         across loci is the alias kill-shot (RED under DIO_RAM_STUB).
        for (l = 0; l < 5; l = l + 1) begin
            set_wp(locus[l]);
            for (i = 0; i < 32; i = i + 1) wr_b4(seed[l] + i[15:0], 6);
        end
        for (l = 0; l < 5; l = l + 1) begin
            set_rp(locus[l]);
            for (i = 0; i < 32; i = i + 1) begin
                rd_b4(v); chk(v, seed[l] + i[15:0], locus[l] + {i[23:0],1'b0});
            end
        end
        if (errors == 0) $display("  part 1 (3-chip loci + alias + top): ok");

        // ---- 2: sequential sweep, 512 halfwords -- the auto-increment must be
        //         exact across beat boundaries and prefetch promotions ----
        set_wp(25'h0100000);
        for (i = 0; i < 512; i = i + 1) wr_b4(16'h4000 + i[15:0], 6);
        set_rp(25'h0100000);
        for (i = 0; i < 512; i = i + 1) begin
            rd_b4(v); chk(v, 16'h4000 + i[15:0], 25'h0100000 + {i[23:0],1'b0});
        end
        if (errors == 0) $display("  part 2 (512-halfword sequential sweep): ok");

        // ---- 3: read-pointer jump mid-stream (phase-2 style re-read) ----
        set_rp(25'h0100000 + 25'd256*2);
        for (i = 256; i < 288; i = i + 1) begin
            rd_b4(v); chk(v, 16'h4000 + i[15:0], 25'h0100000 + {i[23:0],1'b0});
        end
        if (errors == 0) $display("  part 3 (read-pointer jump): ok");

        // ---- 4: burst absorb -- a full 0x200-halfword burst at a pace faster
        //         than the drain; the posted-write FIFO must absorb it ----
        set_wp(25'h0040000);
        for (i = 0; i < 512; i = i + 1) wr_b4(16'h7000 + i[15:0], 1);
        if (dbg_ovf !== 1'b0) begin
            $display("FAIL: posted-write FIFO overflowed on a 0x200 burst");
            errors = errors + 1;
        end
        set_rp(25'h0040000);   // reads stall until the backlog drains
        for (i = 0; i < 512; i = i + 1) begin
            rd_b4(v); chk(v, 16'h7000 + i[15:0], 25'h0040000 + {i[23:0],1'b0});
        end
        if (errors == 0) $display("  part 4 (0x200 burst absorb + drain-before-read): ok");

        // ---- 5: write-read-write coherency on one address (line invalidation
        //         + drain-before-read after a cached line goes stale) ----
        set_wp(25'h0900000); wr_b4(16'h1111, 6);
        set_rp(25'h0900000); rd_b4(v); chk(v, 16'h1111, 25'h0900000);
        set_wp(25'h0900000); wr_b4(16'h2222, 6);   // invalidates the cached line
        set_rp(25'h0900000); rd_b4(v); chk(v, 16'h2222, 25'h0900000);
        if (errors == 0) $display("  part 5 (coherency after re-write): ok");

        // ---- 6: MP3 streamer through the external backing (own line) ----
        wr_reg(8'ha8, 16'h1357); wr_reg(8'hea, 16'h2468); wr_reg(8'hec, 16'h9BDF);
        wr_reg(8'ha0, 16'h0012); wr_reg(8'ha2, 16'h3400);   // mp3_start = 0x123400
        wr_reg(8'ha4, 16'h0012); wr_reg(8'ha6, 16'h3408);   // mp3_end   = +4 words
        set_wp(25'h0123400);
        wr_b4(16'h1234, 6); wr_b4(16'h5678, 6); wr_b4(16'h9ABC, 6); wr_b4(16'hDEF0, 6);
        sk1 = 16'h1357; sk2 = 16'h2468; sk3 = 16'h9BDF;
        smem[0]=16'h1234; smem[1]=16'h5678; smem[2]=16'h9ABC; smem[3]=16'hDEF0;
        for (i = 0; i < 4; i = i + 1) begin
            dk   = r_derive(sk1 ^ sk2);
            dval = r_common(smem[i], dk) ^ r_spread(sk3);
            sexp[2*i]   = dval[15:8];
            sexp[2*i+1] = dval[7:0];
            if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
            sk1 = {sk1[15], sk1[13:0], sk1[14]};
            sk3 = sk3 + 16'd1;
        end
        sgi = 0;
        wr_reg(8'hae, 16'h6000);            // MP3_ENABLE | STREAMING_ENABLE
        repeat (400) @(posedge clk);        // fills + handshakes included
        // MAME feeds 2N-1 bytes for an N-word window (final word's low byte dropped)
        if (sgi !== 7) begin $display("FAIL: streamed %0d bytes (expected 7 = 2N-1)", sgi); errors=errors+1; end
        for (i = 0; i < 7 && i < sgi; i = i + 1)
            if (sgot[i] !== sexp[i]) begin
                $display("FAIL: mp3 byte[%0d]=%02h expected %02h", i, sgot[i], sexp[i]);
                errors = errors + 1;
            end
        if (errors == 0) $display("  part 6 (MP3 stream via DDR3 backing): ok");

        // ---- 7: MP3 line coherency -- lineM holds the beat just streamed;
        //         a CPU b4 rewrite of that word must invalidate it, so a
        //         stream restart returns the NEW data, not the cached word ----
        wr_reg(8'hae, 16'h0000);                          // stream off
        wr_reg(8'ha4, 16'h0012); wr_reg(8'ha6, 16'h3402); // window = 1 word
        set_wp(25'h0123400); wr_b4(16'h55AA, 6);          // rewrite word 0
        // reference: keys reseed from the (unchanged) latches at stream start
        sk1 = 16'h1357; sk2 = 16'h2468; sk3 = 16'h9BDF;
        dk   = r_derive(sk1 ^ sk2);
        dval = r_common(16'h55AA, dk) ^ r_spread(sk3);
        sgi = 0;
        wr_reg(8'hae, 16'h6000);                          // restart stream
        repeat (200) @(posedge clk);
        // 1-word window -> 2N-1 = 1 byte (MAME drops the last word's low byte); the
        // high byte proves the cached MP3 line was invalidated and the word re-read.
        if (sgi !== 1) begin $display("FAIL: part7 streamed %0d bytes (expected 1 = 2N-1)", sgi); errors=errors+1; end
        else begin
            if (sgot[0] !== dval[15:8]) begin
                $display("FAIL: part7 byte0=%02h expected %02h (stale MP3 line?)", sgot[0], dval[15:8]); errors=errors+1;
            end
        end
        wr_reg(8'hae, 16'h0000);
        if (errors == 0) $display("  part 7 (MP3 line invalidated by CPU write): ok");

        // ---- 8: posted-write FIFO at EXACTLY full -- freeze the responder,
        //         post 1025 writes (1 in flight + 1024 queued = full, no
        //         overflow), release, drain, verify every word ----
        wr_stall = 1'b1;
        set_wp(25'h0200000);
        for (i = 0; i < 1025; i = i + 1) wr_b4(16'h9000 + i[15:0], 0);
        if (dbg_ovf !== 1'b0) begin
            $display("FAIL: part8 overflow flagged at exactly-full occupancy");
            errors = errors + 1;
        end
        wr_stall = 1'b0;
        set_rp(25'h0200000);   // reads stall until the 1025-deep backlog drains
        for (i = 0; i < 1025; i = i + 1) begin
            rd_b4(v); chk(v, 16'h9000 + i[15:0], 25'h0200000 + {i[23:0],1'b0});
        end
        if (errors == 0) $display("  part 8 (FIFO exactly-full boundary + drain): ok");

        if (dbg_ovf !== 1'b0) begin
            $display("FAIL: sticky FIFO overflow flag set");
            errors = errors + 1;
        end

        // ---- P8: PCM-ring guard (P4b must-fix #2) ----
        // The GX894 has only 24 MiB of DRAM (3x8 MiB), but our window is a flat
        // 32 MiB and the HPS PCM ring sits at offset 0x1F10000 -- 7 MiB above
        // anything the real board can address, so a game cannot reach it. That is
        // an assumption about SOFTWARE, so it is OBSERVED, not trusted.
        // Threshold is the RING base, not the 24 MiB DRAM top: the 24-32 MiB space
        // is legitimately exercised (this bench writes at 0x1800000 earlier), and
        // only the ring region is actually harmful.
        if (dbg_hi_write !== 1'b0) begin
            $display("FAIL: P8 ring guard set by ordinary in-range traffic");
            errors = errors + 1;
        end
        set_wp(25'h1F10000);                 // the PCM ring base
        wr_b4(16'hDEAD, 0);
        repeat (8) @(posedge clk);
        if (dbg_hi_write !== 1'b1) begin
            $display("FAIL: P8 a write into the PCM ring did NOT raise the guard");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (k573dio_ram)");
        else             $display("RESULT: FAIL (k573dio_ram, %0d errors)", errors);
        $finish;
    end
endmodule
