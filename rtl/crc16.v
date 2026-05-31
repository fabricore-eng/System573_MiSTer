// -----------------------------------------------------------------------------
// crc16.v - CRC-16/CCITT engine (polynomial 0x1021), MSB-first, no reflection
//
// The System 573 ZS01 (NS2K001) security cartridge attaches a 16-bit CRC to
// every 12-byte command/response packet: the CRC is computed over the first ten
// bytes (poly 0x1021) and stored big-endian in the last two. The same CRC-16
// also shows up around the ATAPI / Digital-I/O data paths, so it lives here as a
// small reusable streaming engine rather than being buried in one peripheral.
//
// Parameterized by polynomial and initial value so the same module covers both
// the common CRC-CCITT variants (XMODEM: init 0x0000; CCITT-FALSE: init 0xFFFF)
// and, once its exact seed is confirmed against hardware, the ZS01 packet CRC.
// Bytes are fed in MSB-first; assert `load` to (re)seed, then pulse `stb` once
// per byte. `crc` holds the running remainder.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module crc16 #(
    parameter [15:0] POLY = 16'h1021,
    parameter [15:0] INIT = 16'hFFFF
)(
    input  wire        clk,
    input  wire        load,       // synchronous reseed to INIT
    input  wire        stb,        // process one byte on `data`
    input  wire [7:0]  data,
    output reg  [15:0] crc
);
    // One byte of CRC-16 update: xor the byte into the high half, then run
    // eight shifts, xoring the polynomial whenever the top bit falls out.
    function [15:0] crc_byte(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? ((x << 1) ^ POLY) : (x << 1);
            crc_byte = x;
        end
    endfunction

    always @(posedge clk) begin
        if (load)
            crc <= INIT;
        else if (stb)
            crc <= crc_byte(crc, data);
    end
endmodule
