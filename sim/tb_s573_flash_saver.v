`timescale 1ns/1ps
// =============================================================================
// tb_s573_flash_saver.v - red-green proof for the 16 MB onboard-flash SAVE/LOAD
// block engine (rtl/s573_flash_saver.v), per gate-0 plan E
// (docs/audits/2026-06-12-flash-persistence-gate0.md).
//
// SCALING NOTE (gate-0 plan E permits this): the HW image is 16 MB = 16384 one-KB
// blocks. A 16 MB model SDRAM (8 M 16-bit words) is too large to $readmem/compare
// fast in iverilog, so the TB scales the image to NUM_BLOCKS=64 (64 KB = 32768
// words). The 32-bit sd_lba, the 1 KB (512-word / 64-burst) block geometry, and
// the SD/SDRAM handshakes are BYTE-FOR-BYTE IDENTICAL to the 16384-block HW case
// -- only the block COUNT differs. The DUT is parameterized (NUM_BLOCKS) so the
// exact same RTL runs at both sizes.
//
// HW-realistic models:
//   * SDRAM: a flat word array sdram[] indexed by flat 16-bit word index (the
//     parent's FLASH_START offset is outside the DUT, so the TB drives word index
//     directly, base 0). A ch4-style 128-bit burst READ port (8 words, 1-cycle
//     ready) and a ch3-style single-16-bit-word WRITE port (busy .. ack), each
//     with a few cycles of modelled latency -- exactly the emu ch3/ch4 contract.
//   * SD block protocol = what Main/hps_io drive (hps_io.sv:329-412):
//       - WRITE (save): on sd_wr, raise sd_ack, then step sd_buff_addr 0..511 and
//         SAMPLE sd_buff_din one cycle after presenting each address (the DUT's
//         registered din_q latency), writing each word to the model save-file;
//         drop sd_ack.
//       - READ (load): on sd_rd, raise sd_ack, then step sd_buff_addr 0..511,
//         present sd_buff_dout from the save-file and pulse sd_buff_wr; drop ack.
//
// RED-GREEN (mirrors s573_nvram_saver's "fails on the byte-drop" discipline):
//   * default (no defines)        -> must PASS, byte-diff == 0 over every block.
//   * -DBUG_BYTELANE              -> the model SDRAM read swaps each word's bytes
//                                    (a byte-lane defect); SAVE must produce a
//                                    file that mismatches the reference -> FAIL.
//   * -DBUG_LBASTEP               -> the model SD write file-seek uses lba*511
//                                    (an off-by-one LBA step / overlapping blocks)
//                                    -> the round-trip mismatches -> FAIL.
//
// Coverage:
//   1. SAVE: every one of NUM_BLOCKS blocks streamed out == the SDRAM pattern,
//      in LBA order, byte-exact (catches byte-lane swaps, LBA slips, word skips).
//   2. LOAD: the mounted file written back into SDRAM @ base, byte-exact.
//   3. ROUND-TRIP: preload SDRAM -> SAVE to the file model -> WIPE SDRAM blank ->
//      LOAD -> assert SDRAM == original, byte-diff count == 0.
// =============================================================================
module tb_s573_flash_saver;
    // Scaled image. KEEP the geometry constants; only NUM_BLOCKS shrinks vs HW.
    localparam integer NUM_BLOCKS     = 64;
    localparam integer WORDS_PER_BLK  = 512;
    localparam integer NWORDS         = NUM_BLOCKS * WORDS_PER_BLK;   // 32768

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    // ---- triggers ----
    reg  save_trigger = 0;
    reg  load_arm     = 0;
    wire busy, saving;

    // ---- SD block protocol ----
    wire        sd_rd, sd_wr;
    wire [31:0] sd_lba;
    reg         sd_ack      = 0;
    reg         sd_buff_wr  = 0;
    reg  [8:0]  sd_buff_addr= 0;
    reg  [15:0] sd_buff_dout= 0;
    wire [15:0] sd_buff_din;

    // ---- SDRAM 128-bit burst read port ----
    wire        mem_req;
    wire [26:0] mem_addr;
    reg  [127:0] mem_q     = 0;
    reg         mem_ready  = 0;

    // ---- SDRAM 16-bit word write port ----
    wire        wr_req;
    wire        wr_busy;
    wire [26:0] wr_addr;
    wire [15:0] wr_data;
    reg         wr_ack     = 0;

    // ---- models ----
    reg [15:0] sdram   [0:NWORDS-1];   // the FPGA SDRAM flash region
    reg [15:0] savefile[0:NWORDS-1];   // the file on the SD card (saves/.../*.sav)
    reg [15:0] ref_img [0:NWORDS-1];   // the golden pattern

    integer errors = 0;
    integer i, j;

    s573_flash_saver #(.NUM_BLOCKS(NUM_BLOCKS)) dut (
        .clk(clk), .reset(reset),
        .save_trigger(save_trigger), .load_arm(load_arm),
        .busy(busy), .saving(saving),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_q(mem_q), .mem_ready(mem_ready),
        .wr_req(wr_req), .wr_busy(wr_busy), .wr_addr(wr_addr), .wr_data(wr_data),
        .wr_ack(wr_ack)
    );

    // -------------------------------------------------------------------------
    // SDRAM ch4 burst-read model: on mem_req, after a couple cycles assert
    // mem_ready for one cycle with the 8 words at mem_addr..mem_addr+7.
    // mem_addr is a flat word index (base 0 in the TB). Free-running responder.
    // -------------------------------------------------------------------------
    reg [26:0] rd_addr_l = 0;
    reg [2:0]  rd_dly = 0;
    reg        rd_pending = 0;
    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_req) begin
            rd_addr_l  <= mem_addr;
            rd_dly     <= 3'd2;            // a few cycles of read latency
            rd_pending <= 1'b1;
        end else if (rd_pending) begin
            if (rd_dly != 0) rd_dly <= rd_dly - 3'd1;
            else begin
                for (j = 0; j < 8; j = j + 1) begin
`ifdef BUG_BYTELANE
                    // byte-lane defect: swap the two bytes of every word read.
                    mem_q[j*16 +: 16] <= {sdram[rd_addr_l + j][7:0],
                                          sdram[rd_addr_l + j][15:8]};
`else
                    mem_q[j*16 +: 16] <= sdram[rd_addr_l + j];
`endif
                end
                mem_ready  <= 1'b1;
                rd_pending <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // SDRAM ch3 word-write model: while wr_busy, on the wr_req pulse capture the
    // word; after a couple cycles assert wr_ack for one cycle and commit.
    // -------------------------------------------------------------------------
    reg [26:0] w_addr_l = 0;
    reg [15:0] w_data_l = 0;
    reg [2:0]  w_dly = 0;
    reg        w_pending = 0;
    always @(posedge clk) begin
        wr_ack <= 1'b0;
        if (wr_req) begin
            w_addr_l  <= wr_addr;
            w_data_l  <= wr_data;
            w_dly     <= 3'd2;
            w_pending <= 1'b1;
        end else if (w_pending) begin
            if (w_dly != 0) w_dly <= w_dly - 3'd1;
            else begin
                sdram[w_addr_l] <= w_data_l;
                wr_ack    <= 1'b1;
                w_pending <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main/hps_io SD WRITE servicer (save): on sd_wr, run one block transfer.
    // Steps sd_buff_addr 0..511; the DUT presents sd_buff_din one cycle after the
    // address (registered din_q), so we sample on the NEXT cycle. Writes each
    // word into savefile[] at lba*512 + word (lba*511 under the LBA-step bug).
    // -------------------------------------------------------------------------
    integer base;
    integer wa;
    task svc_sd_write;
        begin
            // sd_wr is up; latch the lba.
`ifdef BUG_LBASTEP
            base = sd_lba * (WORDS_PER_BLK - 1);   // off-by-one LBA step
`else
            base = sd_lba * WORDS_PER_BLK;
`endif
            // raise ack (Main: sd_ack <= disk; held while streaming the block)
            @(negedge clk); sd_ack = 1;
            // present address 0, then for each word sample din one cycle later.
            sd_buff_addr = 0;
            @(posedge clk);                  // DUT registers buf_mem[0] -> din_q
            for (wa = 0; wa < WORDS_PER_BLK; wa = wa + 1) begin
                @(negedge clk);
                savefile[base + wa] = sd_buff_din;   // word presented for addr `wa`
                sd_buff_addr = (wa == WORDS_PER_BLK-1) ? wa[8:0] : (wa[8:0] + 9'd1);
                @(posedge clk);              // din_q now holds buf_mem[wa+1]
            end
            // block done -> drop ack.
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main/hps_io SD READ servicer (load): on sd_rd, run one block transfer.
    // Reads savefile[] at lba*512 + word and streams each word to the DUT via
    // sd_buff_dout + sd_buff_wr while sd_ack is high.
    // -------------------------------------------------------------------------
    integer ra;
    task svc_sd_read;
        begin
            base = sd_lba * WORDS_PER_BLK;
            @(negedge clk); sd_ack = 1;
            for (ra = 0; ra < WORDS_PER_BLK; ra = ra + 1) begin
                @(negedge clk);
                sd_buff_addr = ra[8:0];
                sd_buff_dout = savefile[base + ra];
                sd_buff_wr   = 1;
                @(posedge clk);              // DUT captures buf_mem[ra] <= dout
                @(negedge clk); sd_buff_wr = 0;
            end
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask

    // Watchers: a forked process that services each sd_wr / sd_rd request as the
    // FSM raises it, for `nblocks` blocks. (Single-block transfers, one per LBA.)
    task run_save_service(input integer nblocks);
        integer b;
        begin
            for (b = 0; b < nblocks; b = b + 1) begin
                // wait for the DUT to raise sd_wr for this block
                @(posedge clk);
                while (!sd_wr) @(posedge clk);
                svc_sd_write;
            end
        end
    endtask
    task run_load_service(input integer nblocks);
        integer b;
        begin
            for (b = 0; b < nblocks; b = b + 1) begin
                @(posedge clk);
                while (!sd_rd) @(posedge clk);
                svc_sd_read;
            end
        end
    endtask

    integer diff;

    initial begin
        // -------------------------------------------------------------
        // Golden pattern: every word distinct so a byte-lane swap, a word
        // skip, or an LBA slip all change SOME word. Hi byte mixes the block
        // index, lo byte the word index -> no symmetry, no aliasing.
        // -------------------------------------------------------------
        for (i = 0; i < NWORDS; i = i + 1) begin
            ref_img[i] = {8'((i/WORDS_PER_BLK) ^ 8'h5A), 8'((i & 9'h1FF) ^ 8'hA5)};
        end
        // seed a recognizable flash-boot signature head ("PS-X EXE") at word 0..3
        ref_img[0] = 16'h532D;  // 'S','-' (little-endian "PS" pair is 0x5350; we
        ref_img[1] = 16'h5850;  // just need DISTINCT, deterministic head bytes)
        ref_img[2] = 16'h4520;  // any fixed values: the compare is exact.
        ref_img[3] = 16'h4558;

        for (i = 0; i < NWORDS; i = i + 1) begin
            sdram[i]    = ref_img[i];
            savefile[i] = 16'hDEAD;     // junk -- proves LOAD overwrites it
        end

        // reset
        repeat (4) @(negedge clk);
        reset = 0;
        @(negedge clk);

        // ============================================================
        // PHASE 1 -- SAVE: SDRAM(ref) -> savefile, all NUM_BLOCKS blocks.
        // ============================================================
        fork
            run_save_service(NUM_BLOCKS);
            begin
                @(negedge clk); save_trigger = 1;
                @(negedge clk); save_trigger = 0;
            end
        join

        // the save finished when the service loop returned; FSM is back at idle.
        wait (busy == 0);
        @(negedge clk);

        // PHASE 1 check: savefile must equal ref, byte-exact, all blocks.
        diff = 0;
        for (i = 0; i < NWORDS; i = i + 1)
            if (savefile[i] !== ref_img[i]) begin
                if (diff < 8)
                    $display("FAIL save: word %0d (blk %0d w %0d) got %04h exp %04h",
                             i, i/WORDS_PER_BLK, i%WORDS_PER_BLK, savefile[i], ref_img[i]);
                diff = diff + 1;
            end
        if (diff != 0) begin
            $display("FAIL: SAVE byte-diff = %0d words (of %0d)", diff, NWORDS);
            errors = errors + diff;
        end else
            $display("  SAVE ok: %0d blocks streamed byte-exact (diff=0)", NUM_BLOCKS);

        // ============================================================
        // PHASE 2 -- ROUND-TRIP: wipe SDRAM blank, LOAD savefile back in,
        // assert SDRAM == original (byte-diff == 0).
        // ============================================================
        for (i = 0; i < NWORDS; i = i + 1) sdram[i] = 16'hFFFF;   // blank flash

        fork
            run_load_service(NUM_BLOCKS);
            begin
                @(negedge clk); load_arm = 1;
            end
        join

        wait (busy == 0);
        @(negedge clk); load_arm = 0;
        @(negedge clk);

        diff = 0;
        for (i = 0; i < NWORDS; i = i + 1)
            if (sdram[i] !== ref_img[i]) begin
                if (diff < 8)
                    $display("FAIL load: word %0d (blk %0d w %0d) got %04h exp %04h",
                             i, i/WORDS_PER_BLK, i%WORDS_PER_BLK, sdram[i], ref_img[i]);
                diff = diff + 1;
            end
        if (diff != 0) begin
            $display("FAIL: ROUND-TRIP byte-diff = %0d words (of %0d)", diff, NWORDS);
            errors = errors + diff;
        end else
            $display("  ROUND-TRIP ok: SDRAM == original after wipe+LOAD (diff=0)");

        // signature head check (the BIOS flash-boot reads word 0..3 @ FLASH_START)
        for (i = 0; i < 4; i = i + 1)
            if (sdram[i] !== ref_img[i]) begin
                $display("FAIL: flash-boot signature word %0d not restored", i);
                errors = errors + 1;
            end

        if (errors == 0) $display("RESULT: PASS (s573_flash_saver)");
        else             $display("RESULT: FAIL (s573_flash_saver, %0d errors)", errors);
        $finish;
    end

    // global watchdog
    initial begin
        #20_000_000;
        $display("FAIL: timeout (FSM hung)");
        $display("RESULT: FAIL (s573_flash_saver, timeout)");
        $finish;
    end
endmodule
