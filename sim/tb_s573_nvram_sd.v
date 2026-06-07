`timescale 1ns/1ps
// Testbench for s573_nvram_sd.v wired to m48t58.v -- the M48T58 NVRAM <-> SD-card
// PERSISTENCE round-trip (high-score / operator-settings save-back).
//
// What it proves, end to end, with EXACT byte/address asserts:
//   A) SAVE:  CPU writes NVRAM -> m48t58 raises `dirty` -> a save_req pulse makes
//             s573_nvram_sd stream all 8 KB out. The tb plays the hps_io SD side
//             (asserts sd_ack, walks sd_buff_addr 0..511 per block, captures
//             sd_buff_din) and asserts the captured bytes EQUAL what the CPU wrote,
//             at the right LBA*1024 + word*2 offsets. `dirty` must drop after.
//   B) LOAD:  an img_mounted pulse makes the FSM raise sd_rd; the tb feeds 8 blocks
//             of a known SD image in on sd_buff_wr/sd_buff_dout; the bytes must land
//             in the NVRAM (read back through the m48t58 CPU read port), reconstructing
//             BOTH the even and odd byte of every WIDE word (the odd-byte-drop class
//             of bug the loader testbench guards -- re-asserted here for the SD path).
//
// Geometry: WIDE(1) + BLKSZ(3) => 8 blocks of 1 KB = 512 words; byte addr =
// (lba<<10)|(word<<1); even byte = sd_buff_dout[7:0], odd = sd_buff_dout[15:8].
module tb_s573_nvram_sd;
    reg clk = 0, rst = 1;

    // --- m48t58 CPU bus side (used to seed/read-back NVRAM) ---
    reg  [12:0] addr = 0;
    reg  [7:0]  din  = 0;
    reg         we   = 0;
    wire [7:0]  dout;

    // --- save/dirty handshake ---
    wire        dirty;
    wire        dirty_clr;
    reg         save_req = 0;
    wire        saving;

    // --- m48t58 byte load port (from the SD FSM) ---
    wire        nvram_we;
    wire [12:0] nvram_addr;
    wire [7:0]  nvram_din;
    // --- m48t58 readout port (to the SD FSM) ---
    wire [12:0] sav_rd_addr;
    wire [7:0]  sav_rd_dout;

    // --- hps_io SD channel (driven by THIS tb playing the HPS) ---
    reg         img_mounted = 0;
    reg  [63:0] img_size    = 0;
    wire [3:0]  sd_lba;
    wire        sd_rd;
    wire        sd_wr;
    reg         sd_ack       = 0;
    reg  [8:0]  sd_buff_addr = 0;
    reg  [15:0] sd_buff_dout = 0;
    wire [15:0] sd_buff_din;
    reg         sd_buff_wr   = 0;

    integer errors = 0;
    integer i;
    reg [7:0] got;

    // SD backing store the tb models (8 KB). The save FSM writes INTO this; the load
    // path reads OUT of it.
    reg [7:0] sdmem [0:8191];

    s573_nvram_sd dut (
        .clk(clk), .rst(rst),
        .dirty(dirty), .dirty_clr(dirty_clr),
        .save_req(save_req), .saving(saving),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .sav_rd_addr(sav_rd_addr), .sav_rd_dout(sav_rd_dout),
        .img_mounted(img_mounted), .img_size(img_size),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
        .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
    );

    m48t58 #(.CLK_FREQ_HZ(1)) nv (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .sav_rd_addr(sav_rd_addr), .sav_rd_dout(sav_rd_dout),
        .dirty(dirty), .dirty_clr(dirty_clr)
    );

    always #5 clk = ~clk;

    // CPU bus write (sets the dirty flag when below RTC_BASE).
    task cpu_wr(input [12:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; din = d; we = 1;
            @(posedge clk);
            @(negedge clk); we = 0;
        end
    endtask

    // CPU bus read (synchronous M10K read).
    task cpu_rd(input [12:0] a, output [7:0] d);
        begin
            addr = a; @(posedge clk); #1 d = dout;
        end
    endtask

    task check(input [7:0] g, input [7:0] e, input [255:0] name);
        begin
            if (g !== e) begin
                $display("FAIL: %0s got %02h expected %02h", name, g, e);
                errors = errors + 1;
            end
        end
    endtask

    // ---- HPS model: service ONE save (sd_wr) block, capturing into sdmem ----
    // Real hps_io: on sd_wr it raises sd_ack, then over the block walks sd_buff_addr
    // 0..511 sampling sd_buff_din (registered 1-cycle from the address), then drops
    // sd_ack. blockCnt is read from sd_lba (the FSM presents it with sd_wr).
    task hps_service_save_block;
        reg [3:0] lba;
        integer w;
        reg [15:0] word;
        begin
            // sd_wr is asserted by the FSM; latch the LBA, raise ack.
            lba = sd_lba;
            @(negedge clk); sd_ack = 1;
            @(posedge clk);          // FSM drops sd_wr on ack
            // Walk the 512 words. Present addr, wait the 1-cycle blkbuf latency, sample.
            for (w = 0; w < 512; w = w + 1) begin
                @(negedge clk); sd_buff_addr = w[8:0];
                @(posedge clk);                       // blkbuf_q registers blkbuf[w]
                @(negedge clk); #1 word = sd_buff_din; // sample settled word
                sdmem[(lba<<10) | (w<<1)]       = word[7:0];   // even byte
                sdmem[((lba<<10) | (w<<1)) + 1]  = word[15:8];  // odd byte
            end
            @(negedge clk); sd_ack = 0;   // block done
            @(posedge clk);
        end
    endtask

    // ---- HPS model: service ONE load (sd_rd) block, feeding sdmem in ----
    // Real hps_io: on sd_rd it raises sd_ack, then drives 512 sd_buff_wr pulses with
    // sd_buff_addr 0..511 and sd_buff_dout = the SD word, then drops sd_ack.
    task hps_service_load_block;
        reg [3:0] lba;
        integer w;
        begin
            lba = sd_lba;
            @(negedge clk); sd_ack = 1;
            @(posedge clk);          // FSM drops sd_rd on ack
            for (w = 0; w < 512; w = w + 1) begin
                @(negedge clk);
                sd_buff_addr = w[8:0];
                sd_buff_dout = {sdmem[((lba<<10)|(w<<1))+1], sdmem[(lba<<10)|(w<<1)]};
                sd_buff_wr   = 1;
                @(posedge clk);      // FSM commits even byte; latches odd for next cycle
                @(negedge clk); sd_buff_wr = 0;
                @(posedge clk);      // FSM commits odd byte
            end
            @(negedge clk); sd_ack = 0;   // block done
            @(posedge clk);
        end
    endtask

    initial begin
        for (i = 0; i < 8192; i = i + 1) sdmem[i] = 8'h00;

        // Release reset.
        repeat (3) @(posedge clk); @(negedge clk); rst = 0;
        repeat (2) @(posedge clk);

        // dirty must be 0 at a clean boot (nothing written yet).
        if (dirty !== 1'b0) begin $display("FAIL: dirty set before any CPU write"); errors = errors + 1; end

        // ===================== B) LOAD round-trip (first: seeds all 8 KB) ===========
        // Build a fully-known SD image: a deterministic per-byte ramp plus a few
        // recognizable markers (incl. ODD-lane bytes -- the lane the original loader
        // dropped). Mount it; the FSM must stream all 8 KB into the NVRAM so EVERY
        // byte is defined (this also models the boot ioctl baseline).
        for (i = 0; i < 8192; i = i + 1) sdmem[i] = i[7:0] ^ 8'h5A;   // ramp pattern
        sdmem[0]    = 8'h11;  sdmem[1]    = 8'h22;   // word0: lo,hi (odd byte = 22)
        sdmem[4]    = 8'h37;  sdmem[5]    = 8'h38;   // '7','8' (odd byte = 38)
        sdmem[1024] = 8'hDE;  sdmem[1025] = 8'hAD;   // block1 word0 (odd = AD)
        sdmem[8183] = 8'h99;                          // top NVRAM byte (odd of block7 word507)

        @(negedge clk); img_mounted = 1; img_size = 64'd8192;   // mount pulse -> load
        @(posedge clk);
        @(negedge clk); img_mounted = 0;

        for (i = 0; i < 8; i = i + 1) begin
            while (sd_rd !== 1'b1) @(posedge clk);
            hps_service_load_block;
        end
        repeat (6) @(posedge clk);   // let LOAD_DONE -> IDLE + last write settle

        // Read back through the CPU read port; assert BOTH lanes of every checked word.
        cpu_rd(13'd0,    got); check(got, 8'h11, "load nvram[0]");
        cpu_rd(13'd1,    got); check(got, 8'h22, "load nvram[1] ODD lane");
        cpu_rd(13'd4,    got); check(got, 8'h37, "load nvram[4]");
        cpu_rd(13'd5,    got); check(got, 8'h38, "load nvram[5] ODD lane");
        cpu_rd(13'd1024, got); check(got, 8'hDE, "load nvram[1024] block1");
        cpu_rd(13'd1025, got); check(got, 8'hAD, "load nvram[1025] block1 ODD");
        cpu_rd(13'd8183, got); check(got, 8'h99, "load nvram[8183] top byte block7");
        // A ramp byte (even + odd lane) must match exactly -> full coverage, not just markers.
        cpu_rd(13'd200,  got); check(got, (8'((200  % 256)) ^ 8'h5A), "load nvram[200] ramp even");
        cpu_rd(13'd201,  got); check(got, (8'((201  % 256)) ^ 8'h5A), "load nvram[201] ramp ODD");
        cpu_rd(13'd5000, got); check(got, (8'((5000 % 256)) ^ 8'h5A), "load nvram[5000] ramp mid");

        // A mount-load is NOT a CPU edit -> dirty must stay clean afterward.
        if (dirty !== 1'b0) begin $display("FAIL: dirty set by mount-load (should stay clean)"); errors = errors + 1; end

        // ===================== A) SAVE round-trip =====================
        // CPU edits a handful of recognizable NVRAM bytes (operator settings / scores)
        // on top of the loaded baseline. The save must persist BOTH the edits AND the
        // untouched baseline bytes -- i.e. the whole NVRAM, byte-exact.
        cpu_wr(13'd0,    8'h47);   // 'G'  (overwrite a loaded byte)
        cpu_wr(13'd1,    8'h51);   // 'Q'  (ODD byte -- proves odd lane saves)
        cpu_wr(13'd2,    8'h38);   // '8'
        cpu_wr(13'd100,  8'hAB);
        cpu_wr(13'd101,  8'hCD);   // ODD
        cpu_wr(13'd1024, 8'h12);   // block1
        cpu_wr(13'd1025, 8'h34);   // block1 ODD
        cpu_wr(13'd2047, 8'h33);   // last byte of block1 (ODD)
        cpu_wr(13'd7168, 8'h5A);   // block7
        cpu_wr(13'd8183, 8'hC3);   // last persistable NVRAM byte (odd of word 507)

        if (dirty !== 1'b1) begin $display("FAIL: dirty not set after CPU NVRAM writes"); errors = errors + 1; end

        // Trigger a save (edge-detected save_req pulse).
        @(negedge clk); save_req = 1;
        @(posedge clk);
        @(negedge clk); save_req = 0;

        // Service all 8 save blocks as the HPS would (captures into sdmem).
        for (i = 0; i < 8; i = i + 1) begin
            while (sd_wr !== 1'b1) @(posedge clk);
            hps_service_save_block;
        end

        // The save snapshot cleared dirty when it started; with no further CPU writes,
        // dirty must read back 0.
        repeat (4) @(posedge clk);
        if (dirty !== 1'b0) begin $display("FAIL: dirty not cleared after save"); errors = errors + 1; end

        // The CPU edits must be in the SD image at the right LBA*1024 + word*2 offsets.
        check(sdmem[0],    8'h47, "save sdmem[0]");
        check(sdmem[1],    8'h51, "save sdmem[1] ODD lane");
        check(sdmem[2],    8'h38, "save sdmem[2]");
        check(sdmem[100],  8'hAB, "save sdmem[100]");
        check(sdmem[101],  8'hCD, "save sdmem[101] ODD lane");
        check(sdmem[1024], 8'h12, "save sdmem[1024] block1");
        check(sdmem[1025], 8'h34, "save sdmem[1025] block1 ODD");
        check(sdmem[2047], 8'h33, "save sdmem[2047] block1 last ODD");
        check(sdmem[7168], 8'h5A, "save sdmem[7168] block7");
        check(sdmem[8183], 8'hC3, "save sdmem[8183] last NVRAM byte");
        // Bytes the CPU did NOT touch must be saved as their loaded baseline (ramp),
        // NOT zeroed -- proves the save streams the WHOLE NVRAM, not just dirty bytes.
        check(sdmem[3],    (8'((3    % 256)) ^ 8'h5A), "save sdmem[3] baseline preserved");
        check(sdmem[300],  (8'((300  % 256)) ^ 8'h5A), "save sdmem[300] baseline preserved");
        check(sdmem[6000], (8'((6000 % 256)) ^ 8'h5A), "save sdmem[6000] baseline preserved");
        check(sdmem[8182], (8'((8182 % 256)) ^ 8'h5A), "save sdmem[8182] baseline preserved");

        if (errors == 0) $display("RESULT: PASS (s573_nvram_sd)");
        else             $display("RESULT: FAIL (s573_nvram_sd, %0d errors)", errors);
        $finish;
    end

    // Watchdog: never hang the suite.
    initial begin
        #5000000;
        $display("RESULT: FAIL (s573_nvram_sd TIMEOUT)");
        $finish;
    end
endmodule
