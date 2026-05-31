// -----------------------------------------------------------------------------
// s573_seccart.v - System 573 security-cartridge interface glue
//
// Connects the security devices (modeled in x76f100.v / x76f041.v / zs01.v and
// ds2401.v) to the ASIC register lines. The BIOS bit-bangs the cartridge through
// the D0-D7 output latch at 0x1f6a0000 and reads the result back through the
// 0x1f400004/06 status words. Per MAME's k573cass.cpp the cassette wires the
// latch bits to the device pins as:
//
//   D0 -> EEPROM SDA      D1 -> EEPROM SCL
//   D2 -> EEPROM CS       D3 -> EEPROM RST
//   D4 -> DS2401 (driven low when D4 = 1)
//   read-back: IO0 = EEPROM SDA (device-driven), I0 = DS2401 line
//
// SDA and the 1-Wire line are open-drain: the board drives a level and the device
// pulls low, so the read-back is the device-driven level wired-AND the latch.
//
// This instance is wired for the X76F100 variant plus the board DS2401; the same
// glue shape covers the X76F041 (identical SDA/SCL/CS/RST mapping) and, with the
// separate SDA path, the ZS01. Writing the latch sets DRDY (ready handshake).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_seccart #(
    parameter [63:0]  READ_PASSWORD  = 64'h0000_0000_0000_0000,
    parameter [63:0]  WRITE_PASSWORD = 64'h0000_0000_0000_0000,
    parameter [47:0]  DS_SERIAL      = 48'h0000_0000_0001,
    parameter integer DS_CLK_HZ      = 1_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // 0x1f6a0000 D0-D7 output latch (write strobe sets DRDY)
    input  wire        latch_we,
    input  wire [7:0]  d_latch,
    input  wire        io0_dir,     // control bit 6 (0 = input); informational

    // read-back toward the ASIC status words
    output wire        sec_io0,     // IO0  = EEPROM SDA (device-driven)
    output wire [7:0]  sec_in,      // I0-I7 ; I0 = DS2401 line
    output reg         sec_drdy,
    output wire        sec_irdy
);
    // ----- EEPROM (X76F100) on D0..D3 -----
    wire eeprom_sda_o;
    x76f100 #(.READ_PASSWORD(READ_PASSWORD), .WRITE_PASSWORD(WRITE_PASSWORD)) eeprom (
        .clk(clk), .rst(rst),
        .cs(d_latch[2]), .sec_rst(d_latch[3]),
        .scl(d_latch[1]), .sda_i(d_latch[0]), .sda_o(eeprom_sda_o)
    );

    // ----- board DS2401 on D4 (open-drain, pulled up) -----
    wire ds_pd;
    wire ds_line = ~(d_latch[4] | ds_pd);    // D4=1 pulls the 1-wire line low
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) board_id (
        .clk(clk), .rst(rst), .dq_in(ds_line), .dq_pd(ds_pd)
    );

    assign sec_io0  = eeprom_sda_o;
    assign sec_in   = {7'b0, ds_line};
    assign sec_irdy = 1'b1;                   // bit-banged device is always ready

    // writing the latch raises DRDY (cleared on reset)
    always @(posedge clk) begin
        if (rst)            sec_drdy <= 1'b0;
        else if (latch_we)  sec_drdy <= 1'b1;
    end
endmodule
