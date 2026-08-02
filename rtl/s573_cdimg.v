// -----------------------------------------------------------------------------
// s573_cdimg.v - System 573 CD sector reader (mounted-image -> ATAPI READ data)
//
// Feature B, deliverable 1: feed REAL 2048-byte data sectors from a mounted CD
// image into rtl/atapi.v so the Konami BIOS reads disc data instead of zeros.
//
// The 573 has a Sony CR-589 ATAPI CD-ROM on its IDE bus (0x1f480000, IRQ10). The
// BIOS issues an ATAPI READ(10)/READ(12) PACKET command; atapi.v dispatches it and
// raises sec_req with the requested LBA. This module fetches that sector from the
// MiSTer host and presents its 2048 user-data bytes back to atapi.v as a 1024x16
// sector buffer (sbuf_q indexed by sbuf_addr), then pulses sec_ready.
//
// HOST INTERFACE -- the MiSTer "CUECHD" sd-block stream (the SAME channel the
// upstream PSX cd_top consumed; freed by psx_patches/0011 when cd_top was removed,
// reclaimed here). It is the contract in psx/rtl/cd_top.vhd's SFETCH state machine:
//   * cd_req=1 with cd_lba = the sector LBA in MAIN'S MSF SPACE (user LBA + 150,
//     see PREGAP_LBA below); hold until cd_ack=1, then drop req.
//   * the host then streams the RAW 2352-byte sector as 1176 16-bit words, one per
//     cd_wr pulse (cd_data valid on each). 1176 words = 2352 bytes.
//   * MODE1/MODE2-form2 sectors carry a 16-byte sync+header, then 2048 user bytes,
//     then 288 EDC/ECC -- redump/.bin store raw 2352; chdman extractcd yields the
//     same. We keep only user bytes [16 .. 2063] (word indices 8 .. 1031), which is
//     exactly the 2048-byte data the ATAPI READ(10) returns. (cd_top likewise reads
//     the full raw sector and discards sync/header; see RAW_SECTOR_SIZE=2352.)
//
// SIM: drive cd_ack/cd_wr/cd_data from a host BFM that streams real extracted image
// bytes (see sim/tb_s573_cdimg.v / tb_atapi_cdread.v). No DDR3/HPS dependency in the
// data path -- this is pure logic + one 2 KB sector BRAM.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_cdimg (
    input  wire        clk,
    input  wire        rst,
    input  wire        ide_rst,      // board IDE reset line (0x1f560000), in lockstep with atapi.v

    // ---- from atapi.v: a READ(10/12) was dispatched ----
    input  wire        sec_req,      // 1-clk strobe: fetch the sector at sec_lba
    input  wire [31:0] sec_lba,      // requested raw sector LBA

    // ---- to atapi.v: the 2048-byte user-data sector buffer ----
    input  wire [10:0] sbuf_addr,    // word index 0..1023 (byte = addr*2) into user data
    output wire [15:0] sbuf_q,       // sector buffer read data (registered, 1-clk latency)
    output reg         sec_ready,    // level: the requested sector is buffered + valid
    output reg         sec_busy,     // level: a fetch is in flight

    // ---- MiSTer CUECHD sd-block host stream (= emu.sv sd_lba1/sd_rd[1]/...) ----
    output reg         cd_req,       // request a sector  -> sd_rd[1]
    output reg  [31:0] cd_lba,       // MSF-space LBA (user+150) -> sd_lba1
    input  wire        cd_ack,       // host accepted req  <- sd_ack[1]
    input  wire        cd_wr,        // host data strobe   <- sd_buff_wr
    input  wire [15:0] cd_data       // host word          <- sd_buff_dout
);
    // 2 KB sector buffer: 1024 x 16-bit user-data words (byte [16..2063] of the raw
    // sector). Synchronous-read so Quartus infers block RAM, not LUT RAM.
    reg [15:0] sbuf [0:1023];
    reg [15:0] sbuf_qr;
    always @(posedge clk) sbuf_qr <= sbuf[sbuf_addr[9:0]];
    assign sbuf_q = sbuf_qr;

    // Raw-sector framing: skip the 16-byte sync/header (8 words), keep the next 1024
    // words (2048 bytes user data), ignore the remaining 288 bytes of EDC/ECC.
    localparam [10:0] HDR_WORDS  = 11'd8;      // 16 bytes
    localparam [10:0] USER_WORDS = 11'd1024;   // 2048 bytes
    localparam [10:0] RAW_WORDS  = 11'd1176;   // 2352 bytes

    // USER -> MSF LBA conversion at the host request boundary. MiSTer Main's PSX
    // CD service (support/psx/psx.cpp, Main 250828 ae6dc92) expects MSF-space
    // LBAs on sd_lba1, the way the consumer PSX core sends them: it fakes a
    // 150-sector track-1 pregap (load_chd psx.cpp:142-146 indexes[1]=150,
    // start=150; load_cue psx.cpp:250 likewise), serves ZEROS for any request
    // below 150 WITHOUT touching the image (psx_read_cd psx.cpp:479-481), and
    // reads the image at read_lba = lba - 150 (psx.cpp:517). The ATAPI/BIOS
    // world stays USER space (sec_lba); the +150 happens HERE, in exactly one
    // place. Without it the BIOS's PVD read (user LBA 16) lands in Main's zero
    // zone -> 'CD001' check fails -> -11 -> CDR BAD.
    localparam [31:0] PREGAP_LBA = 32'd150;

    localparam [1:0] S_IDLE=2'd0, S_REQ=2'd1, S_STREAM=2'd2, S_DONE=2'd3;
    reg [1:0]  state;
    reg [10:0] wcnt;       // raw word counter 0..1175

    always @(posedge clk) begin
        if (rst || ide_rst) begin
            // ide_rst (board IDE reset, 0x1f560000) resets the sector reader in
            // lockstep with atapi.v. Without it the game's drive-reset recovery
            // ritual -- assert ide_rst, re-issue the identical READ -- leaves a
            // fetch wedged here in S_REQ/S_STREAM (S_STREAM needs 1176 cd_wr the
            // wedged host never delivers); the re-issued sec_req was then dropped
            // and atapi held BSY forever -> the gate-5 `-1N` CDROM DRIVE TIMEOUT.
            // (docs/2026-07-03-gate5-red-bench.md sub-tests [C]/[D].)
            state     <= S_IDLE;
            cd_req    <= 1'b0;
            cd_lba    <= 32'd0;
            wcnt      <= 11'd0;
            sec_ready <= 1'b0;
            sec_busy  <= 1'b0;
        end else if (sec_req) begin
            // Accept a (re-)request in ANY state, not just S_IDLE (defense-in-depth
            // for a retry that lands mid-fetch WITHOUT an ide_rst): latch the new
            // LBA, restart the fetch, and drop sec_ready. Re-fetching on every fresh
            // sec_req is what tags sec_ready to the CURRENT request -- an aborted
            // earlier LBA's buffer can never be served as the new (different) LBA.
            cd_lba    <= sec_lba + PREGAP_LBA;  // user -> Main MSF space (see above)
            cd_req    <= 1'b1;
            sec_ready <= 1'b0;                  // invalidate the old sector
            sec_busy  <= 1'b1;
            wcnt      <= 11'd0;
            state     <= S_REQ;
        end else begin
            case (state)
                S_IDLE: sec_busy <= 1'b0;
                S_REQ: begin                  // wait for the host to accept the request
                    if (cd_ack) begin
                        cd_req <= 1'b0;
                        state  <= S_STREAM;
                    end
                end
                S_STREAM: begin               // collect 1176 raw words; keep user [8..1031]
                    if (cd_wr) begin
                        if (wcnt >= HDR_WORDS && wcnt < (HDR_WORDS + USER_WORDS))
                            sbuf[wcnt - HDR_WORDS] <= cd_data;
                        if (wcnt == RAW_WORDS - 1'b1)
                            state <= S_DONE;
                        else
                            wcnt <= wcnt + 1'b1;
                    end
                end
                S_DONE: begin
                    sec_ready <= 1'b1;
                    sec_busy  <= 1'b0;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
