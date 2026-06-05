// -----------------------------------------------------------------------------
// s573_flash.v - System 573 bank-switched flash / PCMCIA window + control latch
//
// The 573 sees a single 4 MB window at 0x1f000000 into a much larger backing
// store, selected by the bank field of the control register at 0x1f500000:
//
//   bits 0-3 : bank low field  (set_bank_lo, BIOS 0x803ca108: ctl[3:0])
//   bits 4-5 : internal onboard-flash bank index 0-3 (set_bank_hi, BIOS
//              0x803ca188: ctl[5:4] = idx<<4 -> raw bank 0x00/0x10/0x20/0x30)
//   bit  6   : security-cart IO0 direction (0 = input; set_bit6, BIOS 0x803ca20c)
//   bit  7   : CPLD signal
//
// AUTHORITATIVE SOURCE = the 700A BIOS. `set_bank` (RAM 0x803ca188) selects an
// internal onboard-flash bank by writing the index into control bits [5:4]:
// `andi v0,0xffcf` (clear [5:4]) ; `andi a0,3` ; `sll a0,4` ; OR -> ctl[5:0] =
// 0x00/0x10/0x20/0x30 for index 0/1/2/3. The body-copy loader (0x803c2210)
// iterates set_bank(2),(1),(0) to walk the four banks. So the internal bank is
// `bank[5:4]`, NOT a flat `bank[1:0]` -- only index 0 worked before this fix.
// (The old MEMORY_MAP "16-31/32-47 PCMCIA" flat numbering conflicts with the
// BIOS and is wrong for this encoding.) PCMCIA presence is reported separately
// via 0x1f400006[11:10] (s573_io), never by a flash-window read in this boot,
// so the onboard banks decode internal while any non-onboard selector (any value
// with bank[3:0] != 0) still reads all-ones (absent).
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
//     word address `{bank[5:4], win_addr[20:0]}` (23 bits = 8 M words = 16 MB)
//     indexes it -- bank[5:4] is the BIOS internal-bank index (see header above).
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

    // DEBUG (HW bring-up): observe WHY the fill FSM does/doesn't trigger. Round-2
    // bars proved flash_mem_req never pulses (req_cnt=0) -> the array_read trigger
    // never fires. Expose the trigger inputs so the next bar-decode pins the cause:
    //   [23:18] bank   [17] win_sel_seen  [16] internal_seen  [15] winwe_seen
    //   [14] idread_seen [13] arrayread_seen [12] tag_hit_seen [11:10] fstate_max
    //   [9:0] = low 10 bits of the last win_addr observed during a flash read
    output wire [23:0] dbg_flash
);
    // Internal onboard flash is selected by the BIOS via control bits [5:4]
    // (set_bank_hi writes idx<<4 -> raw bank 0x00/0x10/0x20/0x30). The four clean
    // onboard-bank selector values all have bank[3:0]==0; any other value is a
    // non-onboard/PCMCIA selector and reads all-ones (absent). NUM_BANKS is fixed
    // at 4 by this 2-bit [5:4] index, so this gate is independent of it.
    wire internal = (bank[3:0] == 4'b0000);
    wire [1:0] bank_idx = bank[5:4];   // internal onboard-flash bank index 0-3

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
            flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                        .BACKING_EXTERNAL(0)) chip (
                .clk(clk), .rst(rst),
                // select internal bank by ctl[5:4] (BIOS set_bank_hi index)
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

        // SDRAM fill port unused in behavioral mode (held at their reset values).
        always @(posedge clk) begin
            flash_mem_req  <= 1'b0;
            flash_mem_addr <= 27'd0;
        end
    end else begin : g_sdram
        // ----- HW path: 16 MB SDRAM-backed flash with a 16-word line buffer -----
        //
        // Flat 16-bit WORD address into the 16 MB image:
        //   flash_word = {bank[5:4], win_addr[20:0]}   (23 bits = 8 M words)
        // bank[5:4] = the BIOS internal-bank index 0-3 (set_bank_hi). Line buffer
        // = 16 words (32 bytes): index = flash_word[3:0] (16 words), tag =
        // flash_word[22:4] (19 bits). One 128-bit SDRAM burst is 8 words, so two
        // bursts (line base, line base+8) fill the 16-word line.
        wire [22:0] flash_word = {bank_idx, win_addr[20:0]};

        // Line buffer storage + valid tag.
        reg [15:0] line [0:15];
        reg [18:0] line_tag;          // flash_word[22:4]
        reg        line_valid;

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
        wire [15:0] line_word = line[req_idx];
        flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                    .BACKING_EXTERNAL(1)) cmd (
            .clk(clk), .rst(rst),
            .ce(win_sel && internal),
            .we(win_we),
            .addr(win_addr[15:0]),
            .din(win_din),
            .dout(cmd_dout),
            .ext_rd_data(line_word),
            .id_read(id_read)
        );

        // A pending array read that needs the backing store: selected internal
        // bank, a read access (not a write), not an ID read.
        wire array_read = win_sel && internal && !win_we && !id_read;

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
        reg [1:0]  fstate;
        reg [18:0] fill_tag;     // tag being filled
        integer    k;
        always @(posedge clk) begin
            if (rst) begin
                fstate        <= F_IDLE;
                line_valid    <= 1'b0;
                line_tag      <= 19'h7FFFF;
                flash_mem_req <= 1'b0;
                flash_mem_addr<= 27'd0;
            end else begin
                flash_mem_req <= 1'b0;
                case (fstate)
                    F_IDLE: begin
                        if (array_read && !tag_hit) begin
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

        // Ready: ID reads + writes + line-buffer HITs are ready immediately; an
        // array read that misses stalls until the line is valid for its tag.
        assign flash_ready = !array_read || id_read || tag_hit;

        // Read mux: absent PCMCIA bank / unselected -> all ones; otherwise the
        // command-FSM output (which returns the line-buffer word on array reads
        // and the MFR/DEV ID in autoselect).
        always @(*) begin
            if (win_sel && internal)
                win_dout = cmd_dout;
            else
                win_dout = 16'hFFFF;
        end
    end
    endgenerate
endmodule
