`timescale 1ns/1ps
// =============================================================================
// tb_s573_nvram_blocksave.v - red-green proof for the 8 KB M48T58 NVRAM SAVE/LOAD
// block engine (rtl/s573_nvram_blocksave.v). This is the persistence path that
// closes the game-#2 hole: the .mgl CD-install signature lives in the M48T58, but
// the console .mgl has no <nvram> tag so the arcade ioctl save-back never fires --
// this module persists the NVRAM via the SD block protocol (a mounted .sav), the
// same way s573_flash_saver persists the 16 MB flash.
//
// FULL SIZE: the whole NVRAM is 8 KB = 8 one-KB blocks (4096 16-bit words), small
// enough to model at HW size (no scaling). The top 8 bytes are the m48t58 live RTC
// clock registers: the SAVE port reads them (so they ARE written to the .sav) but
// the LOAD port (like the real m48t58, addr < RTC_BASE) must NOT write them back.
//
// HW-realistic models:
//   * m48t58 SAVE read port: a flat byte array m48[] with a 1-cycle registered read
//     (nv_sav_dout valid the cycle after nv_sav_addr) and nv_sav_rd_ok (=1 here; no
//     game-write collisions modeled in the basic test).
//   * m48t58 LOAD write port: commits m48[nv_ld_addr] <= nv_ld_din on nv_ld_we ONLY
//     when nv_ld_addr < RTC_BASE (the real m48t58's ldw gate) -- so the RTC bytes
//     stay at their wiped value after a LOAD, which the round-trip check asserts.
//   * SD block protocol = what Main/hps_io drive (identical to tb_s573_flash_saver).
//
// RED-GREEN:
//   * default (no defines)  -> PASS, byte-diff == 0 (array bytes) over every block.
//   * -DBUG_ADDRSWAP        -> the SAVE-port model returns m48[addr^1] (even/odd
//                              byte swap); SAVE produces mis-packed words -> FAIL.
//   * -DBUG_LBASTEP         -> the SD write file-seek uses lba*511 (overlapping
//                              blocks) -> the round-trip mismatches -> FAIL.
// =============================================================================
module tb_s573_nvram_blocksave;
    localparam integer NUM_BLOCKS     = 8;
    localparam integer WORDS_PER_BLK  = 512;
    localparam integer NWORDS         = NUM_BLOCKS * WORDS_PER_BLK;   // 4096
    localparam integer NBYTES         = NWORDS * 2;                   // 8192
    localparam integer RTC_BASE       = 8184;                         // top 8 = RTC
    localparam integer AUTOSAVE_THRESH = 300;

    reg clk = 0, reset = 1;
    always #5 clk = ~clk;

    // ---- triggers ----
    reg  save_trigger = 0;
    reg  nvram_act    = 0;
    reg  load_arm     = 0;
    wire busy, saving, save_done, auto_saved;

    // ---- SD block protocol ----
    wire        sd_rd, sd_wr;
    wire [31:0] sd_lba;
    reg         sd_ack       = 0;
    reg         sd_buff_wr   = 0;
    reg  [8:0]  sd_buff_addr = 0;
    reg  [15:0] sd_buff_dout = 0;
    wire [15:0] sd_buff_din;

    // ---- m48t58 ports ----
    wire [12:0] nv_sav_addr;
    wire [7:0]  nv_sav_dout;
    wire        nv_sav_rd_ok;
    wire        nv_ld_we;
    wire [12:0] nv_ld_addr;
    wire [7:0]  nv_ld_din;

    // ---- models ----
    reg [7:0]  m48     [0:NBYTES-1];   // the M48T58 byte array (game-side store)
    reg [15:0] savefile[0:NWORDS-1];   // the .sav on the SD card
    reg [7:0]  ref_img [0:NBYTES-1];   // golden pattern

    integer errors = 0;
    integer i;

    // toast / auto-save pulse monitors
    integer save_done_cnt  = 0;
    integer auto_saved_cnt = 0;
    always @(posedge clk) begin
        if (save_done)  save_done_cnt  = save_done_cnt  + 1;
        if (auto_saved) auto_saved_cnt = auto_saved_cnt + 1;
    end

    s573_nvram_blocksave #(.NUM_BLOCKS(NUM_BLOCKS), .RTC_BASE(RTC_BASE),
                           .AUTOSAVE_THRESH(AUTOSAVE_THRESH)) dut (
        .clk(clk), .reset(reset),
        .save_trigger(save_trigger), .nvram_act(nvram_act), .autosave_en(1'b1),
        .auto_saved(auto_saved), .load_arm(load_arm),
        .busy(busy), .saving(saving), .save_done(save_done),
        .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_lba(sd_lba), .sd_ack(sd_ack),
        .sd_buff_wr(sd_buff_wr), .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .nv_sav_addr(nv_sav_addr), .nv_sav_dout(nv_sav_dout), .nv_sav_rd_ok(nv_sav_rd_ok),
        .nv_ld_we(nv_ld_we), .nv_ld_addr(nv_ld_addr), .nv_ld_din(nv_ld_din)
    );

    // -------------------------------------------------------------------------
    // m48t58 SAVE read port model: 1-cycle registered read; rd_ok always 1.
    // -------------------------------------------------------------------------
    reg [7:0] nv_sav_dout_r = 0;
    reg       nv_sav_rd_ok_r = 0;
    always @(posedge clk) begin
`ifdef BUG_ADDRSWAP
        nv_sav_dout_r <= m48[nv_sav_addr ^ 13'd1];   // even/odd byte swap defect
`else
        nv_sav_dout_r <= m48[nv_sav_addr];
`endif
        nv_sav_rd_ok_r <= 1'b1;
    end
    assign nv_sav_dout  = nv_sav_dout_r;
    assign nv_sav_rd_ok = nv_sav_rd_ok_r;

    // -------------------------------------------------------------------------
    // m48t58 LOAD write port model: commit only when addr < RTC_BASE.
    // -------------------------------------------------------------------------
    always @(posedge clk)
        if (nv_ld_we && (nv_ld_addr < RTC_BASE))
            m48[nv_ld_addr] <= nv_ld_din;

    // -------------------------------------------------------------------------
    // Main/hps_io SD WRITE servicer (save): one block transfer per sd_wr.
    // -------------------------------------------------------------------------
    integer base, wa;
    task svc_sd_write;
        begin
`ifdef BUG_LBASTEP
            base = sd_lba * (WORDS_PER_BLK - 1);   // off-by-one LBA step
`else
            base = sd_lba * WORDS_PER_BLK;
`endif
            @(negedge clk); sd_ack = 1;
            sd_buff_addr = 0;
            @(posedge clk);                         // DUT registers buf_mem[0] -> din_q
            for (wa = 0; wa < WORDS_PER_BLK; wa = wa + 1) begin
                @(negedge clk);
                savefile[base + wa] = sd_buff_din;  // word presented for addr `wa`
                sd_buff_addr = (wa == WORDS_PER_BLK-1) ? wa[8:0] : (wa[8:0] + 9'd1);
                @(posedge clk);
            end
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main/hps_io SD READ servicer (load): one block transfer per sd_rd.
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
                @(posedge clk);
                @(negedge clk); sd_buff_wr = 0;
            end
            @(negedge clk); sd_ack = 0;
            @(posedge clk);
        end
    endtask

    task run_save_service(input integer nblocks);
        integer b;
        begin
            for (b = 0; b < nblocks; b = b + 1) begin
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
        // golden pattern: adjacent (even/odd) bytes always differ so a byte-pair
        // swap is detectable; mix the byte index + a parity flip + a coarse field.
        for (i = 0; i < NBYTES; i = i + 1)
            ref_img[i] = i[7:0] ^ 8'(i >> 4) ^ (i[0] ? 8'h5A : 8'hA5);
        // a recognizable signature-like head (cosmetic; the compare is exact)
        ref_img[0]="G"; ref_img[1]="Q"; ref_img[2]="8"; ref_img[3]="7"; ref_img[4]="6";

        for (i = 0; i < NBYTES; i = i + 1) m48[i] = ref_img[i];
        for (i = 0; i < NWORDS; i = i + 1) savefile[i] = 16'hDEAD;   // junk: SAVE overwrites

        repeat (4) @(negedge clk);
        reset = 0;
        @(negedge clk);

        // ============================================================
        // PHASE 1 -- SAVE: m48[] -> savefile, all blocks, byte-exact.
        // ============================================================
        fork
            run_save_service(NUM_BLOCKS);
            begin @(negedge clk); save_trigger = 1; @(negedge clk); save_trigger = 0; end
        join
        wait (busy == 0);
        repeat (3) @(negedge clk);   // let the completion-cycle save_done pulse be counted

        diff = 0;
        for (i = 0; i < NWORDS; i = i + 1) begin : p1
            reg [15:0] exp;
            exp = {ref_img[i*2+1], ref_img[i*2]};   // {odd, even}
            if (savefile[i] !== exp) begin
                if (diff < 8) $display("FAIL save: word %0d got %04h exp %04h", i, savefile[i], exp);
                diff = diff + 1;
            end
        end
        if (diff != 0) begin
            $display("FAIL: SAVE word-diff = %0d (of %0d)", diff, NWORDS);
            errors = errors + diff;
        end else $display("  SAVE ok: %0d blocks streamed byte-exact (diff=0)", NUM_BLOCKS);

        if (save_done_cnt != 1) begin
            $display("FAIL: PHASE1 save_done pulses = %0d (exp 1)", save_done_cnt);
            errors = errors + 1;
        end else $display("  TOAST ok: PHASE1 SAVE fired save_done x1");

        // ============================================================
        // PHASE 2 -- ROUND-TRIP: wipe m48[] (0x00), LOAD savefile back, assert the
        // ARRAY bytes (addr < RTC_BASE) restored and the RTC bytes (>= RTC_BASE)
        // stay wiped (the load port must NOT write the clock).
        // ============================================================
        for (i = 0; i < NBYTES; i = i + 1) m48[i] = 8'h00;

        fork
            run_load_service(NUM_BLOCKS);
            begin @(negedge clk); load_arm = 1; end
        join
        wait (busy == 0);
        @(negedge clk); load_arm = 0;
        @(negedge clk);

        diff = 0;
        for (i = 0; i < RTC_BASE; i = i + 1)
            if (m48[i] !== ref_img[i]) begin
                if (diff < 8) $display("FAIL load: byte %0d got %02h exp %02h", i, m48[i], ref_img[i]);
                diff = diff + 1;
            end
        if (diff != 0) begin
            $display("FAIL: ROUND-TRIP array byte-diff = %0d (of %0d)", diff, RTC_BASE);
            errors = errors + diff;
        end else $display("  ROUND-TRIP ok: array restored after wipe+LOAD (diff=0)");

        for (i = RTC_BASE; i < NBYTES; i = i + 1)
            if (m48[i] !== 8'h00) begin
                $display("FAIL: RTC byte %0d was overwritten by LOAD (got %02h, exp wiped 00)", i, m48[i]);
                errors = errors + 1;
            end
        if (errors == 0) $display("  RTC-SKIP ok: load left the 8 clock bytes untouched");

        // ============================================================
        // PHASE 3 -- AUTO-SAVE: nvram_act burst then quiet past AUTOSAVE_THRESH
        // self-fires ONE byte-correct SAVE; idle must NOT re-fire; a new act RE-ARMS.
        // m48[] still holds ref_img (round-trip restored it) -> auto-save streams it.
        // Restore the RTC bytes the LOAD intentionally skipped, so the full-image
        // auto-save compares clean over all 4096 words (incl. the RTC save path).
        // ============================================================
        for (i = RTC_BASE; i < NBYTES; i = i + 1) m48[i] = ref_img[i];
        for (i = 0; i < NWORDS; i = i + 1) savefile[i] = 16'hBEEF;   // junk: SAVE overwrites

        // (3a) simulate writes: a burst of nvram_act strobes (gaps < THRESH).
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk); nvram_act = 1;
            @(negedge clk); nvram_act = 0;
            repeat (3) @(negedge clk);
        end
        if (save_done_cnt != 1 || auto_saved_cnt != 0 || busy) begin
            $display("FAIL: auto-save fired DURING activity (save=%0d auto=%0d busy=%0d)",
                     save_done_cnt, auto_saved_cnt, busy);
            errors = errors + 1;
        end

        // (3b) go quiet -> idle crosses THRESH -> auto-save fires once.
        fork
            run_save_service(NUM_BLOCKS);
            begin while (!busy) @(negedge clk); end
        join
        wait (busy == 0);
        repeat (3) @(negedge clk);

        diff = 0;
        for (i = 0; i < NWORDS; i = i + 1) begin : p3
            reg [15:0] exp;
            exp = {ref_img[i*2+1], ref_img[i*2]};
            if (savefile[i] !== exp) diff = diff + 1;
        end
        if (diff != 0) begin
            $display("FAIL: AUTO-SAVE word-diff = %0d (of %0d)", diff, NWORDS);
            errors = errors + diff;
        end else $display("  AUTO-SAVE ok: act->quiet self-fired a byte-exact SAVE (diff=0)");

        if (auto_saved_cnt != 1) begin
            $display("FAIL: auto_saved pulses = %0d (exp 1)", auto_saved_cnt);
            errors = errors + 1;
        end else $display("  AUTO-SAVE ok: fired EXACTLY once (auto_saved x1)");
        if (save_done_cnt != 2) begin
            $display("FAIL: save_done total = %0d (exp 2: PHASE1 + 1 auto)", save_done_cnt);
            errors = errors + 1;
        end

        // (3c) NO re-fire while idle.
        repeat (AUTOSAVE_THRESH*3 + 50) @(negedge clk);
        if (auto_saved_cnt != 1 || save_done_cnt != 2 || busy) begin
            $display("FAIL: auto-save RE-FIRED while idle (auto=%0d save=%0d busy=%0d)",
                     auto_saved_cnt, save_done_cnt, busy);
            errors = errors + 1;
        end else $display("  AUTO-SAVE ok: did NOT re-fire during idle");

        // (3d) RE-ARM: a new nvram_act -> quiet -> a SECOND auto-save.
        savefile[0] = 16'hBEEF;
        @(negedge clk); nvram_act = 1;
        @(negedge clk); nvram_act = 0;
        fork
            run_save_service(NUM_BLOCKS);
            begin while (!busy) @(negedge clk); end
        join
        wait (busy == 0);
        repeat (3) @(negedge clk);
        if (auto_saved_cnt != 2) begin
            $display("FAIL: re-arm auto_saved = %0d (exp 2)", auto_saved_cnt);
            errors = errors + 1;
        end else $display("  AUTO-SAVE ok: a new nvram_act RE-ARMED a 2nd auto-save");

        if (errors == 0) $display("RESULT: PASS (s573_nvram_blocksave)");
        else             $display("RESULT: FAIL (s573_nvram_blocksave, %0d errors)", errors);
        $finish;
    end

    // global watchdog
    initial begin
        #20_000_000;
        $display("FAIL: timeout (FSM hung)");
        $display("RESULT: FAIL (s573_nvram_blocksave, timeout)");
        $finish;
    end
endmodule
