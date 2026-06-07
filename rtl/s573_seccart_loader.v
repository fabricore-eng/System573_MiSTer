// -----------------------------------------------------------------------------
// s573_seccart_loader.v - WIDE(1) ioctl -> security-cart byte-stream loader
//
// emu.sv instantiates hps_io with .WIDE(1), so an ioctl image download delivers a
// FULL 16-bit word on every ioctl_wr strobe (ioctl_dout[7:0]=file[2k],
// ioctl_dout[15:8]=file[2k+1]) and ioctl_addr increments by 2. The security devices
// (x76f041 / ds2401) take a byte-wide load port, so each downloaded word must become
// TWO byte writes (even then odd) -- exactly the unpack s573_nvram_loader does for
// the M48T58. This is that loader, parameterized on the byte-address width.
//
// It also reports the highest byte index written (`max_addr`) so emu.sv can infer the
// security cart type from the EEPROM image SIZE (548 = X76F041, 4116 = ZS01,
// 112 = X76F100) without a separate config part.
//
// Like the nvram loader, it raises nv_hi for the cycle the odd byte is committed so
// emu.sv can hold hps_io one extra cycle via ioctl_wait (the proven back-pressure).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_seccart_loader #(
    parameter integer AW = 10        // byte-address width (10 bits covers 0..1023)
)(
    input  wire           clk,
    input  wire           load_en,      // download active for the whole ioctl stream
    input  wire           ioctl_wr,     // 1-cycle strobe per WIDE halfword
    input  wire [AW-1:0]  ioctl_addr,   // low ioctl_addr bits (byte addr, steps by 2)
    input  wire [15:0]    ioctl_dout,   // WIDE word: [7:0]=file[2k], [15:8]=file[2k+1]
    output reg            byte_we,       // 1-cycle write strobe to the device load port
    output reg [AW-1:0]   byte_addr,     // byte address
    output reg [7:0]      byte_data,     // byte data
    output reg            nv_hi,         // high on the cycle the odd (high) byte writes
    output reg [AW-1:0]   max_addr       // highest byte index seen (for size/type infer)
);
    reg [AW-1:0] hi_addr;
    reg [7:0]    hi_byte;

    initial begin
        byte_we   = 1'b0;
        nv_hi     = 1'b0;
        max_addr  = {AW{1'b0}};
        byte_addr = {AW{1'b0}};
        byte_data = 8'h00;
    end

    always @(posedge clk) begin
        byte_we <= 1'b0;            // default: no write
        if (!load_en) begin
            nv_hi <= 1'b0;          // idle / between downloads
        end else if (nv_hi) begin
            // Cycle 2: commit the odd (high) byte.
            byte_addr <= hi_addr;
            byte_data <= hi_byte;
            byte_we   <= 1'b1;
            nv_hi     <= 1'b0;
            if (hi_addr > max_addr) max_addr <= hi_addr;
        end else if (ioctl_wr) begin
            // Cycle 1: commit the even (low) byte; latch the odd byte for cycle 2.
            byte_addr <= {ioctl_addr[AW-1:1], 1'b0};
            byte_data <= ioctl_dout[7:0];
            byte_we   <= 1'b1;
            hi_addr   <= {ioctl_addr[AW-1:1], 1'b1};
            hi_byte   <= ioctl_dout[15:8];
            nv_hi     <= 1'b1;
            if ({ioctl_addr[AW-1:1], 1'b0} > max_addr) max_addr <= {ioctl_addr[AW-1:1], 1'b0};
        end
    end
endmodule
