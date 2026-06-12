// -----------------------------------------------------------------------------
// s573_flash_saver.v - 16 MB onboard-flash <-> SD save-file block engine
//
// Persists the System 573 onboard flash (16 MB, backed in SDRAM @ FLASH_START)
// to the user's SD card so a CD-installed game survives reboot / power-cycle.
// This is the SAVE/LOAD half of the persistence feature designed in
// docs/audits/2026-06-12-flash-persistence-gate0.md (plan A/D/E). We ship only
// the core + a blank flash; the user's install lands in saves/System573/<n>.sav.
//
// It is a direct Verilog clone of psx/rtl/memcard.vhd's block FSM, scaled from a
// 128 KB memcard to a 16 MB flash:
//   * 16 MB / 1 KB = 16384 blocks; sd_lba is the CD-style 32-bit width (the
//     7-bit memcard lba is far too narrow). emu wires sd_lba4 = reg [31:0].
//   * BLKSZ=3, WIDE(1) -> a block is 1024 bytes = 512 16-bit words; sd_buff_addr
//     indexes words 0..511. (sd_buff_addr is [12:0] in WIDE mode; only [8:0] used
//     for a 512-word block.)
//   * 1 KB / 16 bytes = 64 128-bit SDRAM bursts per block (8 words/burst).
//
// SD block protocol the core drives (what hps_io / Main expect, hps_io.sv
// :329-412, user_io.cpp SD poll). Both ops are single-block transfers (well
// inside the (cnt+1)*1024 <= 16384 ceiling, gate-0 fact 2.6):
//   WRITE (save):  raise sd_wr; Main raises sd_ack; for word 0..511 Main steps
//     sd_buff_addr and SAMPLES sd_buff_din (the core must present that word's
//     flash data); Main writes the sector through to disk; sd_ack drops.
//   READ  (load):  raise sd_rd; Main raises sd_ack, reads the sector from disk,
//     then for word 0..511 sets sd_buff_addr + sd_buff_dout and pulses
//     sd_buff_wr; sd_ack drops. The core captures the streamed words.
//
// SDRAM access (reuses the proven installer plumbing, gate-0 fact 4.3):
//   * SAVE read-back: a ch4-style 128-bit burst READ port (mem_req/mem_addr ->
//     mem_q/mem_ready), muxed onto sdram ch4 in emu. ch4 is the BIOS flash
//     line-fill; idle here because the CPU is held in reset during LOAD and the
//     SAVE trigger fires at OSD-open (no live flash reads).
//   * LOAD write: a ch3-style single-16-bit-word WRITE port (wr_req/wr_busy/
//     wr_addr/wr_data -> wr_ack), muxed onto sdram ch3 EXACTLY like the flash
//     program write-back (rtl/emu.sv:1526-1542, 2044-2056). The saver never runs
//     concurrently with a CD install, so ch3 contention is avoided by priority.
//
// Both SDRAM ports carry a FLAT 16-bit WORD index into the 16 MB image (parent
// adds FLASH_START + (word<<1)), identical addressing to s573_flash so a saved
// /loaded word reads back coherently to the BIOS flash path.
//
// ORDERING (gate-0 plan D / RISK R1 -- the most likely "lost install" bug): the
// .mgl loads flash16m_blank.bin (index 2) AND mounts the save (slot 4) at launch.
// The LOAD must run AFTER the blank flash_download completes so it OVERRIDES the
// blank. The parent gates load_arm on (~flash_download & download settle clear &
// img_mounted[4] & img_size>0) and ORs `busy` into the CPU reset hold so the CPU
// can't boot off a half-restored image. First boot (empty save, type=2, nothing
// to read) -> img_size==0 -> no load -> blank stands -> installer runs -> the
// save file is created on the first write-back.
//
// Verified by sim/tb_s573_flash_saver.v (red-green, byte-diff==0). DEBUG ports
// are absent (no synth-time debug to gate). Verilog-2005. GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_flash_saver #(
    // Total image size in 1 KB blocks. 16 MB / 1 KB = 16384 (HW). The TB scales
    // this DOWN (e.g. 64 blocks) to fit iverilog memory; the 32-bit LBA + 1 KB
    // block + 64-burst logic is IDENTICAL at any size (header note in the TB).
    parameter integer NUM_BLOCKS = 16384
)(
    input  wire        clk,
    input  wire        reset,

    // ---- triggers (from emu) ----
    input  wire        save_trigger,   // 1-cycle (or level): start a full SAVE
    input  wire        load_arm,       // LEVEL: armed to LOAD (post-blank, mounted)
    output reg         busy = 1'b0,    // LEVEL: a SAVE or LOAD is in progress
    output reg         saving = 1'b0,  // LEVEL: a SAVE is in progress (OSD status)

    // ---- SD block protocol (to hps_io slot 4) ----
    output reg         sd_rd = 1'b0,
    output reg         sd_wr = 1'b0,
    output reg  [31:0] sd_lba = 32'd0,
    input  wire        sd_ack,
    input  wire        sd_buff_wr,     // Main: a streamed word is valid this cycle
    input  wire [8:0]  sd_buff_addr,   // word index 0..511 within the 1 KB block
    input  wire [15:0] sd_buff_dout,   // Main -> core (read/load data)
    output wire [15:0] sd_buff_din,    // core -> Main (write/save data)

    // ---- SDRAM 128-bit burst READ port (save read-back; emu muxes onto ch4) ----
    output reg         mem_req = 1'b0,    // 1-cycle: request a 128-bit burst
    output reg  [26:0] mem_addr = 27'd0,  // flat 16-bit word index (parent adds base)
    input  wire [127:0] mem_q,           // the 8-word (16-byte) burst returned
    input  wire        mem_ready,        // 1-cycle: mem_q valid

    // ---- SDRAM single-16-bit-word WRITE port (load write; emu muxes onto ch3) ----
    output reg         wr_req = 1'b0,     // 1-cycle: request a 16-bit word write
    output reg         wr_busy = 1'b0,    // LEVEL: held high pulse .. ack (mux select)
    output reg  [26:0] wr_addr = 27'd0,   // flat 16-bit word index (parent adds base)
    output reg  [15:0] wr_data = 16'd0,
    input  wire        wr_ack            // 1-cycle: the ch3 write completed
);
    // 1 KB block geometry.
    localparam integer WORDS_PER_BLOCK  = 512;   // 1024 B / 2
    localparam integer BURSTS_PER_BLOCK = 64;    // 1024 B / 16 B (8 words/burst)

    // Flat word index of block `lba`, word 0 = lba * 512. {lba, 9'b0}.
    // Burst `b` within a block covers words [b*8 .. b*8+7].

    // -------------------------------------------------------------------------
    // 1 KB staging buffer (512 16-bit words). Dual use:
    //   SAVE: filled from SDRAM bursts, then read out word-by-word to sd_buff_din
    //         as Main steps sd_buff_addr.
    //   LOAD: filled from the SD stream (sd_buff_wr/addr/dout), then written into
    //         SDRAM word-by-word via the ch3 writer.
    // -------------------------------------------------------------------------
    reg [15:0] buf_mem [0:WORDS_PER_BLOCK-1];

    // SAVE presents the staged word at Main's current sd_buff_addr. A registered
    // read (1-cycle BRAM latency) is what Main's streamer tolerates (it steps the
    // address every cycle and samples a cycle later, hps_io.sv:411-412). We mirror
    // the memcard's dpram q_b read.
    reg [15:0] din_q = 16'h0000;
    always @(posedge clk) din_q <= buf_mem[sd_buff_addr];
    assign sd_buff_din = din_q;

    // LOAD captures every streamed word into the staging buffer.
    always @(posedge clk) begin
        if (sd_buff_wr) buf_mem[sd_buff_addr] <= sd_buff_dout;
    end

    // -------------------------------------------------------------------------
    // FSM. Mirrors memcard.vhd: an outer block loop (blockCnt = sd_lba) wrapping
    // an inner per-block engine. SAVE = (SDRAM burst-read fill) -> (SD write
    // block). LOAD = (SD read block) -> (SDRAM word-write drain).
    // -------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE          = 4'd0,
        // ---- SAVE ----
        SA_FILL_REQ     = 4'd1,   // request burst `burst_cnt` of the block from SDRAM
        SA_FILL_WAIT    = 4'd2,   // wait mem_ready, latch 8 words into the buffer
        SA_WR_REQ       = 4'd3,   // raise sd_wr for this block
        SA_WR_ACKSTART  = 4'd4,   // wait sd_ack rising (Main streaming the block out)
        SA_WR_ACKDONE   = 4'd5,   // wait sd_ack falling (block written to disk)
        // ---- LOAD ----
        LO_RD_REQ       = 4'd6,   // raise sd_rd for this block
        LO_RD_ACKSTART  = 4'd7,   // wait sd_ack rising (Main read sector from disk)
        LO_RD_ACKDONE   = 4'd8,   // wait sd_ack falling (block fully streamed in)
        LO_DRAIN_REQ    = 4'd9,   // request a 16-bit SDRAM write of buffer word
        LO_DRAIN_WAIT   = 4'd10;  // wait wr_ack, advance word / block

    reg [3:0]  state = S_IDLE;
    reg [31:0] block_cnt = 32'd0;          // current LBA (0..NUM_BLOCKS-1)
    reg [6:0]  burst_cnt = 7'd0;           // 0..63 within a block (save fill)
    reg [9:0]  word_cnt  = 10'd0;          // 0..511 within a block (load drain)
    reg        save_pending = 1'b0;        // a SAVE was triggered while busy/idle

    integer k;

    always @(posedge clk) begin
        // default 1-cycle strobes
        mem_req <= 1'b0;
        wr_req  <= 1'b0;

        // sd_rd/sd_wr self-clear on ack (memcard.vhd:94-97 -- Main latched the
        // request, so we can drop it as soon as ack confirms the transfer began).
        if (sd_ack) begin
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
        end

        // wr_busy is the LEVEL that holds the ch3 address/data presented across
        // the whole write (req pulse .. ack), exactly like flash_wr_busy.
        if (wr_ack) wr_busy <= 1'b0;

        // latch a save request that arrives mid-op (rare: OSD reopened during a
        // load) so it's honored when we return to idle.
        if (save_trigger) save_pending <= 1'b1;

        if (reset) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            saving       <= 1'b0;
            sd_rd        <= 1'b0;
            sd_wr        <= 1'b0;
            mem_req      <= 1'b0;
            wr_req       <= 1'b0;
            wr_busy      <= 1'b0;
            save_pending <= 1'b0;
        end else begin
            case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    busy   <= 1'b0;
                    saving <= 1'b0;
                    if (save_trigger || save_pending) begin
                        // SAVE wins (an explicit user/OSD action). Start the read
                        // -then-write of block 0.
                        save_pending <= 1'b0;
                        busy         <= 1'b1;
                        saving       <= 1'b1;
                        block_cnt    <= 32'd0;
                        burst_cnt    <= 7'd0;
                        state        <= SA_FILL_REQ;
                    end else if (load_arm) begin
                        // LOAD the saved image over the blank flash.
                        busy      <= 1'b1;
                        block_cnt <= 32'd0;
                        state     <= LO_RD_REQ;
                    end
                end

                // ---------------- SAVE: fill the block from SDRAM ------------
                SA_FILL_REQ: begin
                    // burst `burst_cnt` covers words [burst_cnt*8 .. +7] of the
                    // block at word base {block_cnt, 9'b0}.
                    mem_addr <= {block_cnt[17:0], 9'b0} + {burst_cnt, 3'b000};
                    mem_req  <= 1'b1;
                    state    <= SA_FILL_WAIT;
                end
                SA_FILL_WAIT: begin
                    if (mem_ready) begin
                        for (k = 0; k < 8; k = k + 1)
                            buf_mem[{burst_cnt[5:0], 3'b000} + k] <= mem_q[k*16 +: 16];
                        if (burst_cnt == BURSTS_PER_BLOCK-1) begin
                            burst_cnt <= 7'd0;
                            state     <= SA_WR_REQ;
                        end else begin
                            burst_cnt <= burst_cnt + 7'd1;
                            state     <= SA_FILL_REQ;
                        end
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
                            state  <= S_IDLE;
                            busy   <= 1'b0;
                            saving <= 1'b0;
                        end else begin
                            block_cnt <= block_cnt + 32'd1;
                            burst_cnt <= 7'd0;
                            state     <= SA_FILL_REQ;
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
                    // sd_buff_wr stream is captured into buf_mem by the always
                    // block above for the whole ack window. When ack falls the
                    // 512-word block is fully staged.
                    if (!sd_ack) begin
                        word_cnt <= 10'd0;
                        state    <= LO_DRAIN_REQ;
                    end
                end
                // ---------------- LOAD: drain the block into SDRAM ----------
                LO_DRAIN_REQ: begin
                    // one 16-bit word write at {block_cnt, 9'b0} + word_cnt.
                    wr_addr <= {block_cnt[17:0], 9'b0} + word_cnt[8:0];
                    wr_data <= buf_mem[word_cnt[8:0]];
                    wr_req  <= 1'b1;
                    wr_busy <= 1'b1;
                    state   <= LO_DRAIN_WAIT;
                end
                LO_DRAIN_WAIT: begin
                    if (wr_ack) begin
                        if (word_cnt == WORDS_PER_BLOCK-1) begin
                            if (block_cnt == NUM_BLOCKS-1) begin
                                state <= S_IDLE;
                                busy  <= 1'b0;
                            end else begin
                                block_cnt <= block_cnt + 32'd1;
                                state     <= LO_RD_REQ;
                            end
                        end else begin
                            word_cnt <= word_cnt + 10'd1;
                            state    <= LO_DRAIN_REQ;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
