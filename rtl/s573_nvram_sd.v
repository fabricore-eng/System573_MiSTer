// -----------------------------------------------------------------------------
// s573_nvram_sd.v - M48T58 NVRAM <-> MiSTer SD-card persistence FSM
//
// Streams the 573's 8 KB M48T58 timekeeper NVRAM to and from a mounted SD save
// file so high scores + operator settings survive power-off. Modelled directly on
// the PSX core's memcard.vhd SD handshake, scaled to the NVRAM geometry.
//
// GEOMETRY: hps_io is WIDE(1) (16-bit sd_buff_*) with BLKSZ=3 (1 KB blocks). The
// NVRAM is 8 KB = 8 blocks of 1 KB = 8 blocks of 512 words. So sd_lba runs 0..7 and
// sd_buff_addr runs 0..511 within a block. Byte address into the NVRAM array =
// (lba << 10) | (word << 1); the low byte is at that address, the high byte at +1.
//
// LOAD (img_mounted pulse, img_size>0): for each of the 8 blocks, raise sd_rd with
// the block LBA, wait for sd_ack, then consume the 512 sd_buff_wr word strobes hps_io
// drives -- splitting each word into two byte writes (even=lo, odd=hi) on the m48t58
// load port. hps_io owns the block-buffer fill; we just unpack the word stream.
//
// SAVE (save_req while dirty): for each block, prefetch its 512 words from the m48t58
// readout port into a small block buffer (1 KB M10K), then raise sd_wr with the LBA
// and feed the buffer words out on sd_buff_din as hps_io walks sd_buff_addr. A
// committed save pulses dirty_clr.
//
// LEAN: the only added storage is one 512x16 (1 KB) block buffer (M10K) -- NO wide
// flop array (the project hit a fit failure from a register-array write mux before).
// All other state is a handful of small counters + a 4-bit FSM register.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_nvram_sd (
    input  wire        clk,
    input  wire        rst,

    // --- save trigger / dirty handshake (to/from m48t58 via system573_top) ---
    input  wire        dirty,        // NVRAM has un-persisted CPU writes
    output reg         dirty_clr,    // 1-cycle: a save was committed -> mark clean
    input  wire        save_req,     // edge-triggered request to flush now (OSD / autosave)
    output reg         saving,       // high while a save block stream is in flight

    // --- m48t58 byte load port (image in) -- muxed with the ioctl loader in emu.sv ---
    output reg         nvram_we,
    output reg  [12:0] nvram_addr,
    output reg  [7:0]  nvram_din,

    // --- m48t58 readout port (image out, registered 1-cycle latency) ---
    output reg  [12:0] sav_rd_addr,
    input  wire [7:0]  sav_rd_dout,

    // --- hps_io SD channel (the NVRAM VD slot) ---
    input  wire        img_mounted,  // 1-cycle pulse: NVRAM save file (re)mounted
    input  wire [63:0] img_size,     // >0 when a real save file is present
    output reg  [3:0]  sd_lba,       // block 0..7
    output reg         sd_rd,
    output reg         sd_wr,
    input  wire        sd_ack,
    input  wire [8:0]  sd_buff_addr, // word index within the block (0..511)
    input  wire [15:0] sd_buff_dout, // SD -> core word (load)
    output wire [15:0] sd_buff_din,  // core -> SD word (save)
    input  wire        sd_buff_wr    // word strobe from hps_io (load fill)
);
    localparam [3:0] LAST_LBA = 4'd7;   // 8 blocks (0..7)

    localparam [3:0]
        IDLE        = 4'd0,
        LOAD_REQ    = 4'd1,
        LOAD_ACKHI  = 4'd2,   // wait sd_ack high
        LOAD_ACKLO  = 4'd3,   // wait sd_ack low (block filled)
        LOAD_DONE   = 4'd4,
        SAVE_RDEVEN = 4'd5,   // present even-byte readout address
        SAVE_RDODD  = 4'd6,   // present odd-byte address; even data in flight
        SAVE_CAPLO  = 4'd7,   // capture even (low) byte
        SAVE_CAPHI  = 4'd8,   // capture odd (high) byte, store word
        SAVE_REQ    = 4'd9,
        SAVE_ACKHI  = 4'd10,  // wait sd_ack high
        SAVE_ACKLO  = 4'd11,  // wait sd_ack low (block written)
        SAVE_DONE   = 4'd12;

    // mount/save edge latches (a mount or save can arrive while busy; remember it).
    // Power-up cleared (NOT reset-cleared -- see the rst note below) so a mount that
    // happens during the boot reset window is not lost.
    reg load_pending = 1'b0;
    reg save_pending = 1'b0;
    reg save_req_d   = 1'b0;
    reg [3:0] state  = IDLE;

    // 512-word (1 KB) block buffer for the save stream. M10K-inferred dual port:
    //   port A = prefetch write (FSM fills from the m48t58 readout, one word/2 cycles)
    //   port B = hps_io read    (sd_buff_addr -> sd_buff_din)
    reg  [15:0] blkbuf [0:511];
    reg  [15:0] blkbuf_q;
    always @(posedge clk) blkbuf_q <= blkbuf[sd_buff_addr];
    assign sd_buff_din = blkbuf_q;

    reg  [8:0] word_idx;   // prefetch word counter 0..511
    reg  [7:0] cap_lo;     // captured even byte while waiting for the odd byte read

    // --- LOAD word-unpack pipeline (each sd_buff_wr word -> two byte writes) ---
    reg        ld_hi;
    reg [12:0] ld_hi_addr;
    reg [7:0]  ld_hi_byte;

    always @(posedge clk) begin
        nvram_we   <= 1'b0;     // default: no NVRAM byte write
        dirty_clr  <= 1'b0;     // default: 1-cycle pulse only
        sd_rd      <= sd_rd & ~sd_ack;   // memcard idiom: drop request on ack
        sd_wr      <= sd_wr & ~sd_ack;

        // Latch a fresh mount (load request) -- only when a real file exists.
        if (img_mounted && img_size > 0) load_pending <= 1'b1;

        // Edge-detect the save request; remember it (serviced when dirty & idle).
        save_req_d <= save_req;
        if (save_req & ~save_req_d) save_pending <= 1'b1;

        if (rst) begin
            // Reset only the in-flight transfer state -- NOT load_pending/save_pending.
            // MiSTer mounts the .NVM image (img_mounted[4]) around core load, while the
            // ioctl NVRAM download holds the core in reset; clearing load_pending here
            // would drop that mount. The latches are consumed only from IDLE, which is
            // unreachable until rst drops, so deferring them across reset is safe and
            // means a mount/save requested during reset is serviced once boot completes.
            state        <= IDLE;
            sd_rd        <= 1'b0;
            sd_wr        <= 1'b0;
            saving       <= 1'b0;
            ld_hi        <= 1'b0;
        end else begin
            // LOAD byte-unpack: independent of the main FSM phase, but only fires
            // while a load block is being filled (LOAD_ACKHI/LOAD_ACKLO).
            if (ld_hi) begin
                nvram_addr <= ld_hi_addr;
                nvram_din  <= ld_hi_byte;
                nvram_we   <= 1'b1;
                ld_hi      <= 1'b0;
            end else if ((state == LOAD_ACKHI || state == LOAD_ACKLO) && sd_buff_wr) begin
                nvram_addr <= {sd_lba[2:0], sd_buff_addr, 1'b0};   // even byte
                nvram_din  <= sd_buff_dout[7:0];
                nvram_we   <= 1'b1;
                ld_hi_addr <= {sd_lba[2:0], sd_buff_addr, 1'b1};   // odd byte
                ld_hi_byte <= sd_buff_dout[15:8];
                ld_hi      <= 1'b1;
            end

            case (state)
                // -------------------------------------------------------------
                IDLE: begin
                    saving <= 1'b0;
                    if (load_pending) begin
                        load_pending <= 1'b0;
                        sd_lba       <= 4'd0;
                        state        <= LOAD_REQ;
                    end else if (save_pending && dirty) begin
                        save_pending <= 1'b0;
                        saving       <= 1'b1;
                        // Snapshot now: clear dirty so writes landing DURING the save
                        // re-arm it for the next flush (no lost write).
                        dirty_clr    <= 1'b1;
                        sd_lba       <= 4'd0;
                        word_idx     <= 9'd0;
                        state        <= SAVE_RDEVEN;
                    end else if (save_pending) begin
                        save_pending <= 1'b0;   // nothing dirty -> drop request
                    end
                end

                // ---------------- LOAD: SD -> NVRAM --------------------------
                LOAD_REQ: begin
                    sd_rd <= 1'b1;
                    state <= LOAD_ACKHI;
                end

                LOAD_ACKHI: if (sd_ack) state <= LOAD_ACKLO;

                LOAD_ACKLO: if (!sd_ack) begin
                    if (sd_lba == LAST_LBA) state <= LOAD_DONE;
                    else begin
                        sd_lba <= sd_lba + 4'd1;
                        state  <= LOAD_REQ;
                    end
                end

                LOAD_DONE: begin
                    dirty_clr <= 1'b1;   // image == SD copy -> clean
                    state     <= IDLE;
                end

                // ---------------- SAVE: NVRAM -> SD --------------------------
                SAVE_RDEVEN: begin
                    sav_rd_addr <= {sd_lba[2:0], word_idx, 1'b0};   // even byte addr
                    state       <= SAVE_RDODD;
                end

                SAVE_RDODD: begin
                    sav_rd_addr <= {sd_lba[2:0], word_idx, 1'b1};   // odd byte addr
                    state       <= SAVE_CAPLO;
                end

                SAVE_CAPLO: begin
                    cap_lo <= sav_rd_dout;   // even byte valid now
                    state  <= SAVE_CAPHI;
                end

                SAVE_CAPHI: begin
                    blkbuf[word_idx] <= {sav_rd_dout, cap_lo};   // {hi,lo}
                    if (word_idx == 9'd511) begin
                        state <= SAVE_REQ;
                    end else begin
                        word_idx <= word_idx + 9'd1;
                        state    <= SAVE_RDEVEN;
                    end
                end

                SAVE_REQ: begin
                    sd_wr <= 1'b1;
                    state <= SAVE_ACKHI;
                end

                SAVE_ACKHI: if (sd_ack) state <= SAVE_ACKLO;

                SAVE_ACKLO: if (!sd_ack) begin
                    if (sd_lba == LAST_LBA) state <= SAVE_DONE;
                    else begin
                        sd_lba   <= sd_lba + 4'd1;
                        word_idx <= 9'd0;
                        state    <= SAVE_RDEVEN;
                    end
                end

                SAVE_DONE: begin
                    saving <= 1'b0;
                    state  <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
