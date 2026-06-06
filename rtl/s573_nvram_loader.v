// -----------------------------------------------------------------------------
// s573_nvram_loader.v - WIDE(1) ioctl -> M48T58 byte-array image loader
//
// emu.sv instantiates hps_io with .WIDE(1), so an ioctl image download delivers a
// FULL 16-bit word on every ioctl_wr strobe (ioctl_dout[7:0]=file[2k],
// ioctl_dout[15:8]=file[2k+1]) and ioctl_addr increments by 2. The M48T58 model
// (m48t58.v) backs its 8 KB NVRAM as a byte array with a single byte-wide write
// port, so each downloaded word must become TWO byte writes (even then odd).
//
// The original wiring (nvram_din = ioctl_dout[7:0], nvram_addr = ioctl_addr[12:0])
// wrote only the LOW byte at the even address and silently dropped ioctl_dout[15:8]
// -> every ODD ram[] byte stayed 0. hyperbbc's boot self-test reads the M48T58
// signature at ram indices {0,1,4,5,8,9,...} (7 even + 7 ODD); the zeroed odd bytes
// failed the "GQ876..1998EAA" compare -> status |= 0x40 -> the red "N" self-loop.
//
// This loader unpacks each WIDE word into two byte writes. It raises nv_hi for the
// cycle in which the second (odd-byte) write is committed; emu.sv uses nv_hi to hold
// hps_io one extra cycle via ioctl_wait (the same registered back-pressure the
// proven bios/exe/flash download path relies on). Both bytes of the word are latched
// on the trigger cycle, so a held/changing ioctl_dout during the wait is harmless.
//
// Pulling this out of emu.sv makes the WIDE-unpack behaviour unit-testable
// (sim/tb_s573_nvram_loader.v) -- the prior bug escaped sim precisely because
// tb_m48t58.v modelled a byte-contiguous load and never exercised the WIDE
// step-2 / low-byte-only front-end.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_nvram_loader (
    input  wire        clk,
    input  wire        load_en,      // nvram_download: high for the whole ioctl stream
    input  wire        ioctl_wr,     // 1-cycle strobe per WIDE halfword
    input  wire [12:0] ioctl_addr,   // low ioctl_addr bits (byte addr, steps by 2 in WIDE)
    input  wire [15:0] ioctl_dout,   // WIDE word: [7:0]=file[2k], [15:8]=file[2k+1]
    output reg         nvram_we,     // 1-cycle write strobe to the m48t58 load port
    output reg  [12:0] nvram_addr,   // byte address into the m48t58 NVRAM array
    output reg  [7:0]  nvram_din,    // byte data
    output reg         nv_hi         // high on the cycle the odd (high) byte is written
);
    reg [12:0] nv_hi_addr;
    reg [7:0]  nv_hi_byte;

    always @(posedge clk) begin
        nvram_we <= 1'b0;            // default: no write
        if (!load_en) begin
            nv_hi <= 1'b0;           // idle / between downloads
        end else if (nv_hi) begin
            // Cycle 2: commit the odd (high) byte that the old wiring dropped.
            nvram_addr <= nv_hi_addr;
            nvram_din  <= nv_hi_byte;
            nvram_we   <= 1'b1;
            nv_hi      <= 1'b0;
        end else if (ioctl_wr) begin
            // Cycle 1: commit the even (low) byte; latch the odd byte for cycle 2.
            nvram_addr <= {ioctl_addr[12:1], 1'b0};
            nvram_din  <= ioctl_dout[7:0];
            nvram_we   <= 1'b1;
            nv_hi_addr <= {ioctl_addr[12:1], 1'b1};
            nv_hi_byte <= ioctl_dout[15:8];
            nv_hi      <= 1'b1;
        end
    end
endmodule
