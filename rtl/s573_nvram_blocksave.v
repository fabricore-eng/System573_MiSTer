// -----------------------------------------------------------------------------
// s573_nvram_blocksave.v - 8 KB M48T58 NVRAM <-> SD save-file block engine
//
// THE GAME-#2 PERSISTENCE HOLE this closes: a CD-install game (hypbbc2p) writes
// its "installed" signature into the M48T58 NVRAM, but the game launches via a
// console .mgl (no .mra, hence no <nvram> tag) so the arcade ioctl-upload save-
// back (s573_nvram_saver -> config/nvram/<mra>.nvm) has NO destination and never
// fires (config/nvram stays empty). The flash persists fine (s573_flash_saver,
// slot 4), but every boot re-mounts the BLANK nvram8k_blank.bin -> the game reads
// "not installed" -> the install prompt re-appears even though the flash is
// correctly restored. This module persists the 8 KB NVRAM the SAME way the flash
// is persisted: an SD block-protocol mounted .sav (a NEW slot), independent of the
// .mra arcade path. See docs/audits/2026-06-12-flash-persistence-gate0.md (the
// flash design, which explicitly scoped NVRAM OUT) and the 2026-06-11 NVRAM
// save-back audit (the .mra path this replaces for the .mgl case).
//
// It is a SCALED-DOWN sibling of s573_flash_saver.v (same SD block FSM + auto-save
// one-shot) with the SDRAM backing swapped for the m48t58 byte ports:
//   * 8 KB / 1 KB = 8 blocks; BLKSZ=3, WIDE(1) -> 1 block = 1024 B = 512 16-bit
//     words; sd_buff_addr indexes words 0..511.
//   * SAVE fill: read the m48t58 SAVE port (1-cycle registered, write-priority
//     shared) two bytes/word into the 1 KB staging buffer, committing a word only
//     when BOTH byte reads were clean (sav_rd_ok) -- the same collision-safe
//     even/odd discipline as s573_nvram_saver (a game NVRAM write can race a SAVE,
//     which fires during gameplay/OSD-open). The top 8 bytes (RTC clock regs) are
//     read through the SAVE port too (m48t58 muxes them in) and stored, but the
//     LOAD never writes them back (the m48t58 load port ignores addr >= RTC_BASE),
//     so the live clock is untouched on restore.
//   * LOAD drain: write the m48t58 LOAD port (nvram_we/addr/din) two bytes/word.
//     The LOAD runs with the CPU held in reset (emu ORs `busy & ~saving` into the
//     core reset, exactly like the flash saver's flash_loading), so no game write
//     can collide with a load write -- no retry needed on the drain.
//
// SD block protocol (what hps_io / Main drive, identical to s573_flash_saver):
//   WRITE (save): raise sd_wr; Main raises sd_ack; for word 0..511 Main steps
//     sd_buff_addr and SAMPLES sd_buff_din (we present that word a cycle after the
//     address via din_q); sd_ack drops.
//   READ  (load): raise sd_rd; Main raises sd_ack, reads the sector, then for word
//     0..511 sets sd_buff_addr + sd_buff_dout + pulses sd_buff_wr; sd_ack drops.
//
// ORDERING (mirror the flash saver's plan-D): the .mgl loads nvram8k_blank.bin
// (ioctl index 3) AND mounts this .sav (a new slot) at launch. The LOAD must run
// AFTER the blank download settles so it OVERRIDES the blank -- the parent gates
// load_arm on (mounted & size>0 & ~nvram_download & settle clear) and holds the
// CPU in reset on `busy & ~saving`. First boot (empty .sav, size 0) -> no load ->
// blank stands -> the installer runs -> the .sav is created on the first auto-save.
//
// Verified by sim/tb_s573_nvram_blocksave.v (red-green, byte-diff==0, RTC bytes
// excluded from the load compare). Verilog-2005. GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_nvram_blocksave #(
    // Total image size in 1 KB blocks. 8 KB / 1 KB = 8 (HW). The TB keeps 8 (the
    // whole NVRAM is small enough to model at full size).
    parameter integer NUM_BLOCKS = 8,
    // RTC clock-register base (top 8 bytes of the 8 KB image are live clock regs in
    // m48t58.v). The LOAD drain skips writes at/above this byte address so a restore
    // never clobbers the running clock. 8184 = 0x1FF8.
    parameter integer RTC_BASE = 8184,
    // AUTO-SAVE idle threshold in clk_1x cycles (~9 s @ 33.8688 MHz). The NVRAM is
    // written at install-complete (the signature) and during play (scores/credits);
    // we save once the writes go quiet for this long, re-arming on each new write.
    // The TB scales this DOWN; HW uses the default.
    parameter integer AUTOSAVE_THRESH = 305_000_000
)(
    input  wire        clk,
    input  wire        reset,

    // ---- triggers (from emu) ----
    input  wire        save_trigger,   // 1-cycle (or level): start a full SAVE
    input  wire        nvram_act,      // 1-cycle: a game NVRAM write happened (arms auto-save)
    input  wire        autosave_en,    // LEVEL: OSD toggle (default On); 0 disables ONLY the self-fire
    output reg         auto_saved = 1'b0,  // 1-cycle: an AUTO-SAVE just fired (clears emu nvram_dirty)
    input  wire        load_arm,       // LEVEL: armed to LOAD (post-blank, mounted)
    output reg         busy = 1'b0,    // LEVEL: a SAVE or LOAD is in progress
    output reg         saving = 1'b0,  // LEVEL: a SAVE is in progress (OSD status / reset gating)
    output reg         save_done = 1'b0,   // 1-cycle: a SAVE just completed (toast)

    // ---- SD block protocol (to hps_io slot) ----
    output reg         sd_rd = 1'b0,
    output reg         sd_wr = 1'b0,
    output reg  [31:0] sd_lba = 32'd0,
    input  wire        sd_ack,
    input  wire        sd_buff_wr,     // Main: a streamed word is valid this cycle
    input  wire [8:0]  sd_buff_addr,   // word index 0..511 within the 1 KB block
    input  wire [15:0] sd_buff_dout,   // Main -> core (read/load data)
    output wire [15:0] sd_buff_din,    // core -> Main (write/save data)

    // ---- m48t58 SAVE read port (1-cycle registered, write-priority shared) ----
    output reg  [12:0] nv_sav_addr = 13'd0,
    input  wire [7:0]  nv_sav_dout,
    input  wire        nv_sav_rd_ok,

    // ---- m48t58 LOAD write port (byte, 1-cycle strobe) ----
    output reg         nv_ld_we   = 1'b0,
    output reg  [12:0] nv_ld_addr = 13'd0,
    output reg  [7:0]  nv_ld_din  = 8'd0
);
    // 1 KB block geometry.
    localparam integer WORDS_PER_BLOCK = 512;   // 1024 B / 2

    // -------------------------------------------------------------------------
    // 1 KB staging buffer (512 16-bit words). SAVE: filled from the m48t58 SAVE
    // port two bytes/word, then read out to sd_buff_din as Main steps the address.
    // LOAD: filled from the SD stream, then written byte/byte to the m48t58 LOAD
    // port. One WRITE port (single always, block-RAM friendly: SAVE commit OR the
    // SD capture, mutually-exclusive states) + the registered din_q read.
    // -------------------------------------------------------------------------
    reg [15:0] buf_mem [0:WORDS_PER_BLOCK-1];

    reg [15:0] din_q = 16'h0000;
    always @(posedge clk) din_q <= buf_mem[sd_buff_addr];
    assign sd_buff_din = din_q;

    // -------------------------------------------------------------------------
    // FSM.
    // -------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE        = 4'd0,
        // ---- SAVE ---- (m48t58 SAVE port = 2-cycle read latency: addr registered
        // in the DUT, then a 1-cycle registered read in the part, so the data for an
        // address set in A0 is valid in C0 -- the same A0/A1/C0/C1 pipeline as
        // s573_nvram_saver. A 3-state read captures one cycle too early.)
        SA_A0         = 4'd1,   // present even byte address
        SA_A1         = 4'd2,   // present odd address (even read in flight)
        SA_C0         = 4'd3,   // capture even byte (valid now); odd read in flight
        SA_C1         = 4'd12,  // capture odd byte; commit word if both clean, else retry
        SA_WR_REQ     = 4'd4,   // raise sd_wr for this block
        SA_WR_ACKSTART= 4'd5,   // wait sd_ack rising
        SA_WR_ACKDONE = 4'd6,   // wait sd_ack falling
        // ---- LOAD ----
        LO_RD_REQ     = 4'd7,   // raise sd_rd for this block
        LO_RD_ACKSTART= 4'd8,   // wait sd_ack rising
        LO_RD_ACKDONE = 4'd9,   // wait sd_ack falling (block streamed into buf_mem)
        LO_WR_LO      = 4'd10,  // write even byte to m48t58
        LO_WR_HI      = 4'd11;  // write odd byte to m48t58, advance

    reg [3:0]  state = S_IDLE;
    reg [31:0] block_cnt = 32'd0;          // current LBA (0..NUM_BLOCKS-1)
    reg [9:0]  word_cnt  = 10'd0;          // 0..511 within a block
    reg        save_pending = 1'b0;        // a SAVE triggered while busy
    reg        is_auto = 1'b0;             // the in-flight SAVE was self-fired

    // SAVE byte-read scratch.
    reg [7:0]  lo_byte;
    reg        lo_ok;
    // word base byte address of the current block: block_cnt*1024 = {block_cnt,10'b0}.
    // even byte = base + word_cnt*2; odd = +1.
    wire [12:0] even_addr = {block_cnt[2:0], 10'b0} + {word_cnt[8:0], 1'b0};

    // buf_mem SINGLE WRITE PORT (block-RAM friendly: one driver). SAVE commits the
    // freshly-read word IN the SA_C1 state (using the CURRENT word_cnt, before the
    // FSM advances it -- a registered commit strobe would land at the post-advance
    // index); LOAD captures Main's streamed words. The two are mutually-exclusive
    // states, so this mux infers a dual-port M10K (this write + the din_q read).
    // The SD capture is gated on OUR slot's sd_ack: sd_buff_wr/addr/dout are SHARED
    // across all hps_io slots (Main services one at a time), so without the ack gate
    // a concurrent stream to another slot (the flash-save LOAD on slot 4, a memcard,
    // the CD) would corrupt this buffer. sd_ack is high only while Main streams THIS
    // slot's block, so the capture lands exactly our words.
    always @(posedge clk) begin
        if (state == SA_C1 && lo_ok && nv_sav_rd_ok)
            buf_mem[word_cnt[8:0]] <= {nv_sav_dout, lo_byte};
        else if (sd_buff_wr && sd_ack)
            buf_mem[sd_buff_addr] <= sd_buff_dout;
    end

    // -------------------------------------------------------------------------
    // AUTO-SAVE one-shot: identical structure to s573_flash_saver -- arm on the
    // first nvram_act, reset an idle counter on every act, fire once dirty + quiet
    // >= AUTOSAVE_THRESH while idle; a new act re-arms the episode.
    // -------------------------------------------------------------------------
    localparam integer IDLE_W = $clog2(AUTOSAVE_THRESH + 1);
    reg [IDLE_W-1:0] idle_cnt   = {IDLE_W{1'b0}};
    reg              auto_dirty = 1'b0;
    reg              auto_done  = 1'b0;
    wire auto_req = autosave_en & auto_dirty & ~auto_done
                    & (idle_cnt == AUTOSAVE_THRESH[IDLE_W-1:0]);

    always @(posedge clk) begin
        // default 1-cycle strobes
        save_done  <= 1'b0;
        auto_saved <= 1'b0;
        nv_ld_we   <= 1'b0;

        // ---- auto-save idle tracker ----
        if (nvram_act) begin
            auto_dirty <= 1'b1;
            auto_done  <= 1'b0;
            idle_cnt   <= {IDLE_W{1'b0}};
        end else if (idle_cnt != AUTOSAVE_THRESH[IDLE_W-1:0]) begin
            idle_cnt   <= idle_cnt + 1'b1;
        end

        // sd_rd/sd_wr self-clear on ack.
        if (sd_ack) begin
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
        end

        // latch a save request that arrives mid-op.
        if (save_trigger) save_pending <= 1'b1;

        if (reset) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            saving       <= 1'b0;
            sd_rd        <= 1'b0;
            sd_wr        <= 1'b0;
            nv_ld_we     <= 1'b0;
            save_pending <= 1'b0;
            is_auto      <= 1'b0;
            save_done    <= 1'b0;
            auto_saved   <= 1'b0;
            idle_cnt     <= {IDLE_W{1'b0}};
            auto_dirty   <= 1'b0;
            auto_done    <= 1'b0;
        end else begin
            case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    busy   <= 1'b0;
                    saving <= 1'b0;
                    if (save_trigger || save_pending || auto_req) begin
                        save_pending <= 1'b0;
                        // is_auto only when NOTHING explicit asked (a self-fired
                        // auto-save pulses auto_saved so emu clears its own dirty).
                        is_auto <= auto_req & ~(save_trigger | save_pending);
                        if (auto_req & ~(save_trigger | save_pending))
                            auto_done <= 1'b1;
                        busy      <= 1'b1;
                        saving    <= 1'b1;
                        block_cnt <= 32'd0;
                        word_cnt  <= 10'd0;
                        state     <= SA_A0;
                    end else if (load_arm) begin
                        busy      <= 1'b1;
                        block_cnt <= 32'd0;
                        state     <= LO_RD_REQ;
                    end
                end

                // ---------------- SAVE: fill the block from m48t58 -----------
                // Collision-safe even/odd byte read (mirror s573_nvram_saver): a
                // word commits only if BOTH byte reads were clean (nv_sav_rd_ok);
                // a write that stole a cycle -> retry the same word.
                SA_A0: begin
                    nv_sav_addr <= even_addr;          // request even byte
                    state       <= SA_A1;
                end
                SA_A1: begin
                    nv_sav_addr <= even_addr | 13'd1;  // request odd byte (even read in flight)
                    state       <= SA_C0;
                end
                SA_C0: begin
                    lo_byte     <= nv_sav_dout;        // even byte valid now
                    lo_ok       <= nv_sav_rd_ok;
                    state       <= SA_C1;
                end
                SA_C1: begin
                    // odd byte valid now (nv_sav_dout / nv_sav_rd_ok). buf_mem[word_cnt]
                    // is committed by the dedicated write-port block above this cycle.
                    if (lo_ok && nv_sav_rd_ok) begin
                        if (word_cnt == WORDS_PER_BLOCK-1) begin
                            word_cnt <= 10'd0;
                            state    <= SA_WR_REQ;
                        end else begin
                            word_cnt <= word_cnt + 10'd1;
                            state    <= SA_A0;
                        end
                    end else begin
                        state <= SA_A0;                // collision -> retry word
                    end
                end
                SA_WR_REQ: begin
                    sd_lba <= block_cnt;
                    sd_wr  <= 1'b1;
                    state  <= SA_WR_ACKSTART;
                end
                SA_WR_ACKSTART: begin
                    if (sd_ack) state <= SA_WR_ACKDONE;
                end
                SA_WR_ACKDONE: begin
                    if (!sd_ack) begin
                        if (block_cnt == NUM_BLOCKS-1) begin
                            state     <= S_IDLE;
                            busy      <= 1'b0;
                            saving    <= 1'b0;
                            save_done <= 1'b1;
                            auto_dirty<= 1'b0;          // this episode is persisted
                            if (is_auto) auto_saved <= 1'b1;
                        end else begin
                            block_cnt <= block_cnt + 32'd1;
                            word_cnt  <= 10'd0;
                            state     <= SA_A0;
                        end
                    end
                end

                // ---------------- LOAD: read the block from SD --------------
                LO_RD_REQ: begin
                    sd_lba <= block_cnt;
                    sd_rd  <= 1'b1;
                    state  <= LO_RD_ACKSTART;
                end
                LO_RD_ACKSTART: begin
                    if (sd_ack) state <= LO_RD_ACKDONE;
                end
                LO_RD_ACKDONE: begin
                    // sd_buff_wr stream captured into buf_mem above for the ack
                    // window. When ack falls the 512-word block is staged.
                    if (!sd_ack) begin
                        word_cnt <= 10'd0;
                        state    <= LO_WR_LO;
                    end
                end
                // ---------------- LOAD: drain the block into m48t58 ---------
                // CPU held in reset (emu) for the whole LOAD, so no game write can
                // race these load writes. The m48t58 ignores addr >= RTC_BASE, so
                // the top-8 RTC bytes in the .sav are silently skipped.
                LO_WR_LO: begin
                    nv_ld_addr <= even_addr;                  // even byte
                    nv_ld_din  <= buf_mem[word_cnt[8:0]][7:0];
                    nv_ld_we   <= 1'b1;
                    state      <= LO_WR_HI;
                end
                LO_WR_HI: begin
                    nv_ld_addr <= even_addr | 13'd1;          // odd byte
                    nv_ld_din  <= buf_mem[word_cnt[8:0]][15:8];
                    nv_ld_we   <= 1'b1;
                    if (word_cnt == WORDS_PER_BLOCK-1) begin
                        if (block_cnt == NUM_BLOCKS-1) begin
                            state <= S_IDLE;
                            busy  <= 1'b0;
                        end else begin
                            block_cnt <= block_cnt + 32'd1;
                            word_cnt  <= 10'd0;
                            state     <= LO_RD_REQ;
                        end
                    end else begin
                        word_cnt <= word_cnt + 10'd1;
                        state    <= LO_WR_LO;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
