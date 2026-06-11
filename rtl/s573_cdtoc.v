// -----------------------------------------------------------------------------
// s573_cdtoc.v - mounted-CD disc metadata (TOC + capacity) for the 573 ATAPI drive
//
// The GX700 BIOS CD-boot path reads the disc TOC (READ TOC start-track 0 and
// 0xAA lead-out) and READ CAPACITY before the PVD check (the MAME adjudication
// trace local/cd_adjudication/atapi_trace.txt is the spec). atapi.v must answer
// with REAL disc metadata, not fixtures. Two sources, in priority order:
//
//  1. The MiSTer Main "disk_t" blob (support/psx/psx.cpp send_cue_and_metadata,
//     version 250828): when a .cue/.chd is mounted on the CUECHD slot, Main
//     pushes ioctl index 251 with the parsed cue metadata. 32-bit word layout
//     (= the layout the removed psx cd_top parsed):
//       word 0      : track_count (bits 7:0 binary, 15:8 BCD)
//       word 1      : total_lba   (the lead-out; track 1 start is forced 0,
//                     LBAs carry NO 150-sector pregap offset)
//       word 2      : total MM:SS (BCD)             - unused here
//       word 3      : libcrypt mask / region / reset - unused here
//       word 4t+0   : track t start_lba
//       word 4t+1   : track t end_lba                - unused here
//       word 4t+2   : track t MM:SS BCD, bit16 = isAudio
//       word 4t+3   : (commit word)
//  2. Fallback when no cdinfo arrived (e.g. a frontend that mounts the image
//     without metadata): single data track at LBA 0, lead-out = img_size/2352
//     (raw 2352-byte sectors - redump .bin / chdman extractcd framing, the same
//     framing s573_cdimg consumes). The division runs in a 40-cycle serial
//     divider right after img_mounted; cdinfo (which Main sends AFTER the mount)
//     simply overwrites the result.
//
// The latched metadata intentionally survives core reset: emu.sv holds the core
// in reset through downloads, and the 573 reset (watchdog/dip) must not forget
// the disc. Power-up defaults = 1 data track, lead-out 0 (no disc knowledge).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_cdtoc (
    input  wire        clk,
    input  wire        rst,           // unused by design (see header); kept for symmetry

    // ---- cdinfo (ioctl index 251) download stream (emu.sv ramdownload) ----
    input  wire        ti_write,      // one 32-bit disk_t word
    input  wire [8:0]  ti_addr,       // word index (emu.sv ramdownload_wraddr[10:2])
    input  wire [31:0] ti_data,

    // ---- mounted-image fallback ----
    input  wire        img_mounted,   // pulse (emu.sv img_mounted[1])
    input  wire [63:0] img_size,      // image bytes (0 = unmounted)

    // ---- disc metadata -> atapi.v ----
    output reg  [7:0]  toc_track_count, // tracks on the disc (>= 1)
    output reg  [31:0] toc_leadout,     // lead-out LBA = total sectors

    // track-start lookup, 1-clk latency (index = track number 1..99)
    input  wire [6:0]  toc_qtrack,
    output reg  [31:0] toc_qstart,
    output reg         toc_qaudio
);
    // track table: {isAudio, start_lba[18:0]} indexed by track number (1..99;
    // cdinfo word address 4t..4t+3 -> index ti_addr[8:2] = t, same as cd_top)
    reg [19:0] track_tbl [0:127];

    reg [18:0] pend_start = 19'd0;    // staged per-track fields between words
    reg        pend_audio = 1'b0;
    reg        cdinfo_seen = 1'b0;    // a disk_t arrived since the last mount

    // serial divider: toc_leadout = img_size / 2352 (40-bit / 12-bit restoring)
    reg        div_run = 1'b0;
    reg [5:0]  div_cnt = 6'd0;
    reg [39:0] div_dvd = 40'd0;
    reg [39:0] div_quot = 40'd0;
    reg [12:0] div_rem = 13'd0;
    wire [12:0] rem_shift = {div_rem[11:0], div_dvd[39]};

    integer i;
    initial begin
        toc_track_count = 8'd1;
        toc_leadout     = 32'd0;
        for (i = 0; i < 128; i = i + 1) track_tbl[i] = 20'd0;
    end

    always @(posedge clk) begin
        // ---- registered track-start lookup ----
        toc_qstart <= {13'd0, track_tbl[toc_qtrack][18:0]};
        toc_qaudio <= track_tbl[toc_qtrack][19];

        // ---- mount: reset to the single-track fallback + start the divider ----
        if (img_mounted) begin
            cdinfo_seen     <= 1'b0;
            toc_track_count <= 8'd1;
            track_tbl[1]    <= 20'd0;          // track 1: data, LBA 0
            if (img_size != 64'd0) begin
                div_dvd  <= img_size[39:0];    // CDs are < 1 TB; 40 bits is generous
                div_quot <= 40'd0;
                div_rem  <= 13'd0;
                div_cnt  <= 6'd40;
                div_run  <= 1'b1;
            end else begin
                toc_leadout <= 32'd0;          // unmounted
                div_run     <= 1'b0;
            end
        end else if (div_run) begin
            if (div_cnt != 6'd0) begin
                if (rem_shift >= 13'd2352) begin
                    div_rem  <= rem_shift - 13'd2352;
                    div_quot <= {div_quot[38:0], 1'b1};
                end else begin
                    div_rem  <= rem_shift;
                    div_quot <= {div_quot[38:0], 1'b0};
                end
                div_dvd <= {div_dvd[38:0], 1'b0};
                div_cnt <= div_cnt - 6'd1;
            end else begin
                div_run <= 1'b0;
                if (!cdinfo_seen)
                    toc_leadout <= div_quot[31:0];
            end
        end

        // ---- disk_t download (authoritative; overwrites the fallback) ----
        if (ti_write) begin
            cdinfo_seen <= 1'b1;
            if (ti_addr == 9'd0) begin
                if (ti_data[7:0] != 8'd0)
                    toc_track_count <= ti_data[7:0];
            end else if (ti_addr == 9'd1) begin
                toc_leadout <= ti_data;
            end else if (ti_addr >= 9'd4) begin
                case (ti_addr[1:0])
                    2'd0: pend_start <= ti_data[18:0];
                    2'd2: pend_audio <= ti_data[16];
                    2'd3: track_tbl[ti_addr[8:2]] <= {pend_audio, pend_start};
                    default: ;
                endcase
            end
        end
    end
endmodule
