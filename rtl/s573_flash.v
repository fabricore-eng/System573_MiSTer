// -----------------------------------------------------------------------------
// s573_flash.v - System 573 bank-switched flash / PCMCIA window + control latch
//
// The 573 sees a single 4 MB window at 0x1f000000 into a much larger backing
// store, selected by the bank field of the control register at 0x1f500000:
//
//   bits 0-5 : bank number  (0-3 = internal onboard flash, 16-31 = PCMCIA slot 1,
//              32-47 = PCMCIA slot 2) -- the RAW value, no shift
//   bit  6   : security-cart IO0 direction (0 = input)
//   bit  7   : CPLD signal
//
// AUTHORITATIVE SOURCE = MAME konami/ksys573.cpp (mame0288, which boots our exact
// dumps): `m_flashbank->set_bank( m_control & 0x3f );`  (no shift) over a 4 MB-
// stride flashbank map: bank 0 -> 29f016a.31m, 1 -> 31l, 2 -> 31j, 3 -> 31h (the
// four onboard 4 MB banks at image offsets 0/4/8/12 MB); banks 16-31 -> pccard1,
// 32-47 -> pccard2. So the BIOS selects onboard bank N by writing the RAW value N
// (0/1/2/3): the internal-bank index is `bank[1:0]` with `bank < 4`, NOT `bank[5:4]`.
// Our own tools/pack_hyperbbc.py lays bank N at image offset N*0x400000, matching.
// (Commit da83148's `bank[5:4]` decode was a REGRESSION: control values 0x01/0x02/
// 0x03 fell through to "absent" -> banks 1/2/3 read 0xFFFF, leaving 12 MB of
// program/gfx/sample data unreadable -> the PROGRAM ROM CHECK self-test stalled.
// Confirmed by the RTL-witness audit + MAME source, 2026-06-06.)
//
// This module latches that control register (exposing the bank and the two
// security/CPLD bits to the rest of the board) and maps the 4 MB window onto a
// flat backing memory: effective word = {bank, window offset}.
//
// Two backing modes (parameter SIM_BACKING):
//
//   SIM_BACKING=1 (default, iverilog):  each internal bank is a small inline
//     AMD/Fujitsu NOR flash_nor chip with its own writable mem[] BRAM. Reads are
//     combinational and `flash_ready` is permanently 1 (no wait handshake, the
//     SDRAM ports are unused). This is the path the unit tests exercise.
//
//   SIM_BACKING=0 (Quartus/HW):  the 16 MB onboard flash lives in SDRAM. A flat
//     word address `{bank[1:0], win_addr[20:0]}` (23 bits = 8 M words = 16 MB)
//     indexes it -- bank[1:0] is the BIOS internal-bank index (see header above).
//     A 16-word (32-byte) line buffer holds the most-recently filled
//     burst; tag = flash_word[22:5]. A HIT returns combinational `win_dout` with
//     `flash_ready=1` (no stall); a MISS drops `flash_ready=0` and kicks one
//     128-bit SDRAM burst fill (flash_mem_req/addr -> flash_mem_q/ready). The
//     EXP1 read FSM (memorymux, psx_patches/0006) holds in its read-strobe state
//     while `flash_ready=0`, so the bus never advances on stale data. The JEDEC
//     autoselect MFR/DEV ID path stays combinational and answers immediately
//     (flash_ready=1, no SDRAM) so POST's flash-ID check is unchanged.
//
// flash_addr (SDRAM byte) = FLASH_START + {flash_word, 1'b0}, with FLASH_START
// (0x02000000) added by the parent (emu.sv) -- this module emits the flat word
// index in flash_mem_addr only (the parent offsets it into the SDRAM map).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_flash #(
    parameter integer WIN_WORDS    = 2048, // 16-bit words per bank in SIM_BACKING
                                           // mode (>=2048 so the NOR unlock
                                           // addresses 0x555/0x2AA fit)
    parameter integer SECTOR_WORDS = 512,
    parameter integer NUM_BANKS    = 4,    // internal onboard-flash chips
    parameter integer ERASE_CHIP_WORDS = 2097152, // CHIP-erase (0x10) span on the SDRAM
                                           // path: 2M 16-bit words = one whole 4 MB
                                           // bank (a .31x/.27x chip pair). Parameter
                                           // ONLY so the TB can shrink the chip-erase
                                           // walk to a simulable length; synthesis
                                           // always uses the real default. SECTOR
                                           // erase geometry is NOT parameterized --
                                           // win_addr[20:16], the real 29F016A pair
                                           // layout (32 sectors x 128 KB per bank).
    parameter integer SIM_BACKING  = 1     // 1 = inline flash_nor BRAM (sim/tests)
                                           // 0 = 16 MB SDRAM-backed line buffer
)(
    input  wire        clk,
    input  wire        rst,

    // control register (0x1f500000, write)
    input  wire        ctl_we,
    input  wire [15:0] ctl_din,
    output reg  [5:0]  bank,
    output reg         sec_io0_dir,   // bit 6
    output reg         cpld_sig,      // bit 7

    // flash window (0x1f000000 region)
    input  wire        win_sel,
    input  wire [20:0] win_addr,      // word offset within the 4 MB window
    input  wire        win_we,
    input  wire [15:0] win_din,
    output reg  [15:0] win_dout,
    output wire        flash_ready,   // 1 = read data valid this cycle (no stall);
                                      // 0 = MISS in progress (drives EXP1 wait)

    // SDRAM line-fill port (used only when SIM_BACKING=0)
    output reg         flash_mem_req,    // pulse: request a 128-bit burst fill
    output reg  [26:0] flash_mem_addr,   // flat 16-bit word index (parent adds base)
    input  wire [127:0] flash_mem_q,     // the 16-byte burst (8 words) returned
    input  wire        flash_mem_ready,  // 1-cycle: flash_mem_q valid

    // SDRAM single-word WRITE-BACK port (used only when SIM_BACKING=0): NOR program
    // and JEDEC ERASE make the 16 MB onboard flash WRITABLE so a CD game's installer
    // can re-program it. On a program data cycle we write the line buffer through (so
    // the verify read HITs the new value immediately) AND emit one 16-bit write-back
    // here; the parent (emu.sv) muxes it into the free SDRAM ch3 writer (cheats
    // engine is disabled, psx_patches/0008). flash_wr_req pulses one cycle;
    // flash_wr_ack (the ch3 completion) ends it. Array reads stall (flash_ready=0)
    // while a PROGRAM write-back is pending (prog_pend below), so the BIOS's
    // post-program AMD data-poll read serialises each program -> SDRAM commit ->
    // next program (no lost writes).
    //
    // ERASE (chip 0x10 / sector 0x30) is REAL on this path: a background walker
    // streams 0xFFFF over the erased region into the SDRAM backing through this same
    // port, while reads of the erasing bank return AMD busy status (see the erase
    // engine below -- the DQ7 data-poll ddrsbm's installer runs). PROGRAM still
    // OVERWRITES the cell rather than applying the faithful NOR AND, deliberately:
    // our blank flash images and slot-4 .savs are 0x00-filled (not the 0xFF of real
    // erased NOR), and hypbbc2p's installer programs WITHOUT erasing first -- a
    // faithful AND against a 0x00-backed cell would commit 0x0000 and corrupt those
    // installs (the exact .sav-vs-MAME-golden corruption signature that motivated
    // the overwrite, tb_s573_flash_sdram #11). Erase-then-program-once (ddrsbm) and
    // program-only-onto-blank (hypbbc2p) installs both reach the correct final
    // image with overwrite.
    output reg         flash_wr_req,     // pulse: request a 16-bit SDRAM write-back
    output reg         flash_wr_busy,    // LEVEL: held high for the whole write-back
                                         // transaction (req pulse .. ack). The parent
                                         // mux selects flash_wr_addr/data onto ch3 with
                                         // THIS, not the req pulse, so the address stays
                                         // presented until the SDRAM controller services
                                         // it (it samples the bus continuously).
    output reg  [26:0] flash_wr_addr,    // flat 16-bit word index (parent adds base)
    output reg  [15:0] flash_wr_data,    // the programmed 16-bit word (overwrite, not NOR-ANDed)
    input  wire        flash_wr_ack,     // 1-cycle: the ch3 write completed

    // DEBUG (HW bring-up): observe WHY the fill FSM does/doesn't trigger. Round-2
    // bars proved flash_mem_req never pulses (req_cnt=0) -> the array_read trigger
    // never fires. Expose the trigger inputs so the next bar-decode pins the cause:
    //   [23:18] bank   [17] win_sel_seen  [16] internal_seen  [15] winwe_seen
    //   [14] idread_seen [13] arrayread_seen [12] tag_hit_seen [11:10] fstate_max
    //   [9:0] = low 10 bits of the last win_addr observed during a flash read
    output wire [23:0] dbg_flash
);
    // Internal onboard flash is selected by the BIOS writing the RAW bank number
    // (0/1/2/3) to the control register (MAME: set_bank(control & 0x3f); onboard
    // banks are values < 4, PCMCIA is 16-31/32-47). So onboard = bank < 4 and the
    // bank index is bank[1:0]; any value >= 4 is a non-onboard/PCMCIA selector and
    // reads all-ones (absent).
    wire internal = (bank[5:2] == 4'b0000);   // bank < 4 -> onboard flash
    wire [1:0] bank_idx = bank[1:0];          // internal onboard-flash bank index 0-3

    always @(posedge clk) begin
        if (rst) begin
            bank <= 6'd0; sec_io0_dir <= 1'b0; cpld_sig <= 1'b0;
        end else if (ctl_we) begin
            bank        <= ctl_din[5:0];
            sec_io0_dir <= ctl_din[6];
            cpld_sig    <= ctl_din[7];
        end
    end

    generate
    if (SIM_BACKING != 0) begin : g_sim
        // ----- iverilog / behavioral path: inline per-bank NOR flash chips -----
        // Each internal bank is a real AMD/Fujitsu NOR flash chip (writes go
        // through the unlock/program/erase command sequences); the selected bank
        // is exposed. flash_ready is permanently asserted (no wait handshake);
        // the SDRAM ports are unused.
        wire [15:0] chip_dout [0:NUM_BANKS-1];
        genvar gi;
        for (gi = 0; gi < NUM_BANKS; gi = gi + 1) begin : chips
            // Two x8 chips (.31x low lane / .27x high lane) form each 16-bit word, so
            // autoselect drives the ID into BOTH lanes: MFR 0x0404, DEV 0xADAD (a single
            // x16 die would read 0x0004/0x00AD). Matches MAME umask16 0x00ff/0xff00 and
            // 573in1's low==high two-x8-chips-per-bank detect.
            flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                        .MFR_ID(16'h0404), .DEV_ID(16'hADAD),
                        .BACKING_EXTERNAL(0)) chip (
                .clk(clk), .rst(rst),
                // select internal bank by the raw control value (BIOS bank index)
                .ce(win_sel && internal && (bank_idx == gi)),
                .we(win_we),
                .addr(win_addr[15:0]),
                .din(win_din),
                .dout(chip_dout[gi]),
                .ext_rd_data(16'hFFFF),
                .id_read()
            );
        end

        integer m;
        always @(*) begin
            win_dout = 16'hFFFF;            // absent PCMCIA bank / unselected
            if (win_sel && internal)
                for (m = 0; m < NUM_BANKS; m = m + 1)
                    if (bank_idx == m) win_dout = chip_dout[m];
        end

        assign flash_ready = 1'b1;          // always ready in behavioral mode
        assign dbg_flash   = 24'd0;         // debug observers unused in behavioral mode

        // SDRAM fill + write-back ports unused in behavioral mode (the inline
        // flash_nor chips have their own writable mem[] BRAM). Held at reset values.
        always @(posedge clk) begin
            flash_mem_req  <= 1'b0;
            flash_mem_addr <= 27'd0;
            flash_wr_req   <= 1'b0;
            flash_wr_busy  <= 1'b0;
            flash_wr_addr  <= 27'd0;
            flash_wr_data  <= 16'd0;
        end
    end else begin : g_sdram
        // ----- HW path: 16 MB SDRAM-backed flash with a 16-word line buffer -----
        //
        // Flat 16-bit WORD address into the 16 MB image:
        //   flash_word = {bank[1:0], win_addr[20:0]}   (23 bits = 8 M words)
        // bank[1:0] = the BIOS internal-bank index 0-3. Line buffer
        // = 16 words (32 bytes): index = flash_word[3:0] (16 words), tag =
        // flash_word[22:4] (19 bits). One 128-bit SDRAM burst is 8 words, so two
        // bursts (line base, line base+8) fill the 16-word line.
        wire [22:0] flash_word = {bank_idx, win_addr[20:0]};

        // Line buffer storage + valid tag.
        reg [15:0] line [0:15];
        reg [18:0] line_tag;          // flash_word[22:4]
        reg        line_valid;
        reg [1:0]  fstate;            // fill-FSM state (declared here so the debug
                                      // block below can read it; assigned in the FSM)

        wire [18:0] req_tag = flash_word[22:4];
        wire [3:0]  req_idx = flash_word[3:0];
        wire        tag_hit = line_valid && (line_tag == req_tag);

        // -- The JEDEC command / autoselect-ID FSM (flash_nor, BACKING_EXTERNAL=1)
        // -- is the single source of truth for command decode. It hands back the
        // -- current line-buffer word on a normal read, the MFR/DEV ID in
        // -- autoselect, and flags ID reads via `id_read` so we can skip the SDRAM
        // -- fill for them (POST's flash-ID check must never stall).
        wire [15:0] cmd_dout;
        wire        id_read;
        wire        prog_now;
        wire        erase_now;
        wire        erase_chip;
        wire [15:0] line_word = line[req_idx];
        // Dual-lane autoselect ID (two x8 chips per 16-bit word): MFR 0x0404, DEV 0xADAD
        // (see the g_sim instance above for the rationale).
        flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                    .MFR_ID(16'h0404), .DEV_ID(16'hADAD),
                    .BACKING_EXTERNAL(1)) cmd (
            .clk(clk), .rst(rst),
            .ce(win_sel && internal),
            .we(win_we),
            .addr(win_addr[15:0]),
            .din(win_din),
            .dout(cmd_dout),
            .ext_rd_data(line_word),
            .id_read(id_read),
            .prog_now(prog_now),
            .erase_now(erase_now),
            .erase_chip(erase_chip)
        );

        // A pending array read that needs the backing store: selected internal
        // bank, a read access (not a write), not an ID read.
        wire array_read = win_sel && internal && !win_we && !id_read;

        // ================= JEDEC ERASE on the SDRAM-backed path =================
        //
        // The contract this must satisfy (ddrsbm installer disasm 2026-07-02 + MAME
        // intelfsh 29F016A as oracle; docs/2026-07-01-ddrsbm-dio-i2c-result.md §4):
        //   * sector erase 0x30 names a 128 KB region of the CURRENT bank
        //     (win_addr[20:16] = sector 0..31 of the 4 MB chip-pair window). The
        //     installer erases the SAME sector index on all 4 banks back-to-back,
        //     DQ7-data-polls each bank's sector base under a 121-VBlank (~2 s)
        //     budget, then read-verifies the whole 128 KB sector expects 0xFFFF.
        //   * while a chip-pair (bank) is erasing, EVERY read of that bank returns
        //     AMD status: DQ7=0, DQ6+DQ2 toggle per read access, DQ3=1, DQ5=0 --
        //     0x4C/0x08 alternating, doubled onto both x8 lanes (MAME FM_ERASEAMD4
        //     + the maker==Fujitsu any-address-returns-status exception). Writes to
        //     a busy chip-pair are ignored, also per MAME/JEDEC.
        //   * the OTHER banks stay fully live meanwhile: the installer runs its
        //     autoselect ID check on bank N+1 while bank N erases -- so busy state
        //     is PER-BANK and idle-bank reads/fills must not be blocked.
        //   * completion is REAL: busy drops only when the walker has committed
        //     0xFFFF over the whole region to SDRAM (never a faked status --
        //     memory/no-mask-fault-with-fake-data.md). The erased array data then
        //     satisfies the DQ7 poll and the read-verify by itself. Walking one
        //     128 KB region takes ~ms against the ~2 s budget ("a faster chip").
        //
        // The walker shares the ch3 write-back port with NOR program below: a
        // pending program always outranks the next walker word, so the AMD
        // program -> data-poll serialisation is unchanged. One region walks at a
        // time; up to 4 banks queue in er_busy.
        reg  [3:0]  er_busy;              // per-bank (chip-pair) erase in progress
        reg  [4:0]  er_sector [0:3];      // captured sector index (win_addr[20:16])
        reg  [3:0]  er_chip_r;            // 1 = chip erase (whole-bank span)
        reg  [3:0]  er_tgl;               // per-bank DQ6/DQ2 toggle state
        reg         ehit_d;               // status-read access edge detect

        // A read of a busy bank returns status instead of array data. It must never
        // stall (the CPU is data-polling) and must never start a line fill.
        wire        erase_hit  = win_sel && internal && !win_we && er_busy[bank_idx];
        wire [7:0]  er_status8 = er_tgl[bank_idx] ? 8'h08 : 8'h4C;

        // Next region for the walker: lowest-numbered busy bank (the installer
        // issues 0,1,2,3 in order; any order completes well inside the budget).
        wire [1:0]  er_nbank  = er_busy[0] ? 2'd0 : er_busy[1] ? 2'd1 :
                                er_busy[2] ? 2'd2 : 2'd3;
        localparam [20:0] CHIP_LAST = ERASE_CHIP_WORDS - 1;
        wire [20:0] er_nstart = er_chip_r[er_nbank] ? 21'd0
                                                    : {er_sector[er_nbank], 16'h0000};
        wire [20:0] er_nlast  = er_chip_r[er_nbank] ? CHIP_LAST
                                                    : {er_sector[er_nbank], 16'hFFFF};

        // Walker / write-back-port owner state.
        reg  [1:0]  wk_bank;              // bank being walked
        reg  [20:0] wk_word;              // current word within the bank window
        reg  [20:0] wk_last;              // last word of the region
        reg         wk_active;
        reg         wr_owner;             // in-flight write: 0 = program, 1 = walker
        reg         prog_pend;            // a program write-back is latched/in flight
        reg  [26:0] prog_addr_r;
        reg  [15:0] prog_data_r;

        // DEBUG: sticky observers of the trigger inputs across the whole boot, so
        // the bar-decode can pin WHY array_read never fires (req_cnt=0 in round 2).
        // NOTE: these are deliberately NOT cleared on `rst` -- the CDR-BAD failure is
        // a WATCHDOG REBOOT LOOP that pulses the core reset every iteration; a
        // reset-cleared observer would only ever show "since the last watchdog reset"
        // and could read 0 even if the flash WAS read in the prior POST. Sticky from
        // power-on (init value) gives the true "ever happened" across the whole run.
        reg        dbg_winsel_seen = 0, dbg_internal_seen = 0, dbg_winwe_seen = 0;
        reg        dbg_idread_seen = 0, dbg_arrayrd_seen = 0, dbg_taghit_seen = 0;
        reg [1:0]  dbg_fstate_max = 0;
        reg [9:0]  dbg_winaddr_last = 0;
        always @(posedge clk) begin
            if (win_sel) begin
                dbg_winsel_seen   <= 1'b1;
                dbg_winaddr_last  <= win_addr[9:0];
                if (internal) dbg_internal_seen <= 1'b1;
                if (win_we)   dbg_winwe_seen    <= 1'b1;
                if (id_read)  dbg_idread_seen   <= 1'b1;
            end
            if (array_read) dbg_arrayrd_seen <= 1'b1;
            if (array_read && tag_hit) dbg_taghit_seen <= 1'b1;
            if (fstate > dbg_fstate_max) dbg_fstate_max <= fstate;
        end
        assign dbg_flash = {bank, dbg_winsel_seen, dbg_internal_seen, dbg_winwe_seen,
                            dbg_idread_seen, dbg_arrayrd_seen, dbg_taghit_seen,
                            dbg_fstate_max, dbg_winaddr_last};

        // Fill FSM: on a MISS, two 128-bit bursts populate the 16-word line.
        localparam F_IDLE=2'd0, F_REQ0=2'd1, F_REQ1=2'd2;
        // (fstate reg declared above with the line-buffer storage)
        reg [18:0] fill_tag;     // tag being filled
        integer    k;
        always @(posedge clk) begin
            if (rst) begin
                fstate        <= F_IDLE;
                line_valid    <= 1'b0;
                line_tag      <= 19'h7FFFF;
                flash_mem_req <= 1'b0;
                flash_mem_addr<= 27'd0;
                flash_wr_req  <= 1'b0;
                flash_wr_busy <= 1'b0;
                flash_wr_addr <= 27'd0;
                flash_wr_data <= 16'd0;
                er_busy       <= 4'b0000;   // a reset mid-erase abandons the walk --
                er_chip_r     <= 4'b0000;   // same as cutting power to a real chip
                er_tgl        <= 4'b0000;   // mid-erase (region left part-blanked)
                ehit_d        <= 1'b0;
                wk_active     <= 1'b0;
                wr_owner      <= 1'b0;
                prog_pend     <= 1'b0;
            end else begin
                flash_mem_req <= 1'b0;
                flash_wr_req  <= 1'b0;

                // ---- NOR program (write-through cache + latched ch3 write-back) ----
                // prog_now is a one-cycle strobe on the program data write. OVERWRITE
                // the target word with the intended data, NOT cell &= data (see the
                // write-back port header above: 0x00-filled blank images/.savs +
                // hypbbc2p's program-without-erase installer make the faithful AND a
                // corruption -- the .sav-vs-MAME-golden diff showed the signature,
                // ~38% of data WORDS a perfect bit-subset dropped to 0x0000). Write
                // the line buffer THROUGH (so the BIOS's verify read HITs the new
                // value) and LATCH one 16-bit write-back (prog_pend); the shared-port
                // logic below issues it with priority over the erase walker. Array
                // reads stall while prog_pend (flash_ready below), so the AMD
                // data-poll read serialises program -> SDRAM commit -> next program,
                // walker or not. prog_pend is 1-deep: the data-poll read blocks until
                // the commit, so the bus cannot legally issue a second program first
                // (sim warns loudly if something does). A program aimed at a busy
                // (erasing) chip-pair is ignored, like the real device. (prog_now
                // never coincides with a fill: the bus is stalled during a fill, so
                // the CPU cannot issue the program store until F_IDLE.) NOTE: the
                // SIM_BACKING=1 inline flash_nor path keeps the faithful NOR AND for
                // the unit tests; only this SDRAM-backed path overwrites.
                if (prog_now && !er_busy[bank_idx]) begin
`ifdef S573_FLASH_OLD_AND
                    // RED reference for the FIX-2 red/green test ONLY (never synthesised
                    // -- no .sdc/.qsf define): the buggy faithful-NOR AND against stale
                    // SDRAM backing that corrupted installs (tb_s573_flash_sdram #11).
                    if (tag_hit) line[req_idx] <= line[req_idx] & win_din;
                    prog_addr_r <= {4'b0000, flash_word};
                    prog_data_r <= (tag_hit ? line[req_idx] : 16'hFFFF) & win_din;
`else
                    if (tag_hit) line[req_idx] <= win_din;          // overwrite cache
                    prog_addr_r <= {4'b0000, flash_word};
                    prog_data_r <= win_din;                         // overwrite SDRAM
`endif
                    prog_pend   <= 1'b1;
                    // synthesis translate_off
                    if (prog_pend)
                        $display("s573_flash: WARNING program while write-back pending -- prior word LOST");
                    // synthesis translate_on
                end

                // ---- JEDEC erase capture (decoded by the shared command FSM) ----
`ifndef S573_FLASH_ERASE_NOOP
                // (S573_FLASH_ERASE_NOOP is the RED reference for the erase red/green
                // test ONLY, never synthesised: it restores the pre-fix no-op erase --
                // command decoded, action dropped -- that left ddrsbm's installer
                // data-polling stale data into its ERASE TIMEOUT. tb_s573_flash_erase.)
                if (erase_now && !er_busy[bank_idx]) begin
                    er_busy[bank_idx]   <= 1'b1;
                    er_chip_r[bank_idx] <= erase_chip;
                    er_sector[bank_idx] <= win_addr[20:16];
                    er_tgl[bank_idx]    <= 1'b0;   // first status read returns 0x4C
                    line_valid          <= 1'b0;   // cached line may die under the walk
                end
                // synthesis translate_off
                // A real 29F016A QUEUES extra sector-erase commands arriving inside
                // the 50us DQ3 window; we drop them (busy chip-pair ignores writes).
                // No 573 title batches sectors (ddrsbm: one per bank) -- warn loudly
                // in sim so a future title doing it is caught, not silently broken.
                if (erase_now && er_busy[bank_idx])
                    $display("s573_flash: WARNING erase to busy bank %0d DROPPED (no sector batching)", bank_idx);
                // synthesis translate_on

                // DQ6/DQ2 toggle: once per status-read ACCESS (win_sel rising edge),
                // so a multi-cycle EXP1 read strobe consumes ONE toggle per access.
                ehit_d <= erase_hit;
                if (erase_hit && !ehit_d) er_tgl[bank_idx] <= ~er_tgl[bank_idx];
`endif

                // ---- shared ch3 write-back port: complete, then issue ----
                if (flash_wr_ack) begin
                    flash_wr_busy <= 1'b0;
                    if (wr_owner) begin
                        // walker word committed to SDRAM
                        if (wk_word == wk_last) begin
                            er_busy[wk_bank] <= 1'b0;  // region really is 0xFF now
                            wk_active        <= 1'b0;
                        end else
                            wk_word <= wk_word + 21'd1;
                    end else
                        prog_pend <= 1'b0;
                end

                // Issue priority: pending program > next walker word > start the
                // next queued region. (An ack cycle never issues -- flash_wr_busy is
                // still high -- so these never fight the completion block above.)
                if (!flash_wr_busy) begin
                    if (prog_pend) begin
                        flash_wr_addr <= prog_addr_r;
                        flash_wr_data <= prog_data_r;
                        flash_wr_req  <= 1'b1;
                        flash_wr_busy <= 1'b1;
                        wr_owner      <= 1'b0;
                    end else if (wk_active) begin
                        flash_wr_addr <= {4'b0000, wk_bank, wk_word};
                        flash_wr_data <= 16'hFFFF;
                        flash_wr_req  <= 1'b1;
                        flash_wr_busy <= 1'b1;
                        wr_owner      <= 1'b1;
                    end else if (er_busy != 4'b0000) begin
                        wk_bank   <= er_nbank;
                        wk_word   <= er_nstart;
                        wk_last   <= er_nlast;
                        wk_active <= 1'b1;
                    end
                end

                case (fstate)
                    F_IDLE: begin
                        if (array_read && !erase_hit && !tag_hit && !prog_pend) begin
                            // start a fill of the missing line
                            fill_tag       <= req_tag;
                            line_valid     <= 1'b0;
                            // word base of the 16-word line: {req_tag, 4'b0}.
                            // First burst covers words [0..7] of the line.
                            flash_mem_addr <= {4'b0000, req_tag, 4'b0000};
                            flash_mem_req  <= 1'b1;
                            fstate         <= F_REQ0;
                        end
                    end
                    F_REQ0: begin
                        if (flash_mem_ready) begin
                            for (k = 0; k < 8; k = k + 1)
                                line[k] <= flash_mem_q[k*16 +: 16];
                            // second burst covers words [8..15]
                            flash_mem_addr <= {4'b0000, fill_tag, 4'b1000};
                            flash_mem_req  <= 1'b1;
                            fstate         <= F_REQ1;
                        end
                    end
                    F_REQ1: begin
                        if (flash_mem_ready) begin
                            for (k = 0; k < 8; k = k + 1)
                                line[8+k] <= flash_mem_q[k*16 +: 16];
                            line_tag   <= fill_tag;
                            line_valid <= 1'b1;
                            fstate     <= F_IDLE;
                        end
                    end
                    default: fstate <= F_IDLE;
                endcase
            end
        end

        // Ready: ID reads + writes are always ready (writes cannot stall on EXP1 --
        // patch 0006 only holds READS). Erase-status reads are always ready too (the
        // CPU is data-polling a busy bank; the answer is the status word, no SDRAM).
        // A line-buffer HIT is ready unless a PROGRAM write-back is pending: while
        // prog_pend, EVERY array read stalls so the BIOS's post-program AMD data-poll
        // read blocks until this word's SDRAM commit lands -- serialising program ->
        // commit -> next program (no lost writes). Walker writes deliberately do NOT
        // stall reads: idle banks must stay live for the installer's interleaved ID
        // checks and polls while another bank erases. An array read that misses still
        // stalls until its line fills.
        assign flash_ready = !array_read || id_read || erase_hit
                             || (tag_hit && !prog_pend);

        // Read mux: absent PCMCIA bank / unselected -> all ones; a busy (erasing)
        // bank -> the AMD status word on both x8 lanes (real Fujitsu parts return
        // status for ANY read of a busy chip, incl. after ignored autoselect writes
        // -- MAME intelfsh maker==Fujitsu exception); otherwise the command-FSM
        // output (the line-buffer word on array reads, MFR/DEV ID in autoselect).
        always @(*) begin
            if (win_sel && internal)
                win_dout = er_busy[bank_idx] ? {er_status8, er_status8} : cmd_dout;
            else
                win_dout = 16'hFFFF;
        end
    end
    endgenerate
endmodule
