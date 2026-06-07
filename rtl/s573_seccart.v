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
// The EEPROM variant is chosen by CART_TYPE: 0 = X76F100 (112 B, e.g. hyperbbc-class
// carts), 1 = X76F041 (512 B + separate read/write/config passwords, e.g. pnchmn2).
// Both wire SDA/SCL/CS/RST identically to D0..D3 / IO0; the ZS01 (a future type 2)
// would use the same glue with the separate SDA path. Writing the latch sets DRDY.
//
// The cartridge EEPROM contents and the DS2401 serial can be LOADED at boot from the
// host ioctl stream (the real game's gqa09ja.u1 / .u6 dumps) instead of relying on
// the compile-time params. The 548-byte EEPROM image and the 8-byte serial image are
// streamed in through (load_eep_we/addr/data) and (load_ser_we/addr/data); when
// nothing is loaded the params stay in effect, so existing sims pass unchanged.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_seccart #(
    parameter integer CART_TYPE      = 0,  // 0 = X76F100, 1 = X76F041 (zs01 = 2, future)
    parameter [63:0]  READ_PASSWORD  = 64'h0000_0000_0000_0000,
    parameter [63:0]  WRITE_PASSWORD = 64'h0000_0000_0000_0000,
    parameter [47:0]  DS_SERIAL      = 48'h0000_0000_0001,
    parameter integer DS_CLK_HZ      = 1_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // cart-type select (overrides CART_TYPE param when used; see emu.sv ioctl).
    // 0 = X76F100, 1 = X76F041. Held stable from boot. Defaults to the param.
    input  wire [1:0]  cart_type,

    // 0x1f6a0000 D0-D7 output latch (write strobe sets DRDY)
    input  wire        latch_we,
    input  wire [7:0]  d_latch,
    input  wire        io0_dir,     // control bit 6 (0 = input); informational

    // ---- boot-time security-cart image load ----
    // EEPROM image (.u1): byte address into the 548-byte x76f041 image (the x76f100
    // ignores addresses outside its 112-byte data range -- see below).
    input  wire        load_eep_we,
    input  wire [9:0]  load_eep_addr,
    input  wire [7:0]  load_eep_data,
    // DS2401 serial image (.u6): 8-byte file index 0..7.
    input  wire        load_ser_we,
    input  wire [2:0]  load_ser_addr,
    input  wire [7:0]  load_ser_data,

    // read-back toward the ASIC status words
    output wire        sec_io0,     // IO0  = EEPROM SDA (device-driven)
    output wire [7:0]  sec_in,      // I0-I7 ; I0 = DS2401 line
    output reg         sec_drdy,
    output wire        sec_irdy
);
    // Effective cart type: the runtime cart_type input wins; if it is left at 0 and
    // CART_TYPE param is non-zero (sim-configured), fall back to the param.
    wire [1:0] eff_type = (cart_type != 2'd0) ? cart_type : CART_TYPE[1:0];

    // ----- EEPROM on D0..D3 : one of X76F100 / X76F041, gated by eff_type -----
    // Both EEPROM models are instantiated; only the selected one's chip-select is
    // driven (the other is held deselected, cs=1) and the read-back SDA is muxed.
    wire sda100_o, sda041_o;
    wire eeprom_cs = d_latch[2];
    wire sel041    = (eff_type == 2'd1);

    x76f100 #(.READ_PASSWORD(READ_PASSWORD), .WRITE_PASSWORD(WRITE_PASSWORD)) eeprom100 (
        .clk(clk), .rst(rst),
        .cs(sel041 ? 1'b1 : eeprom_cs), .sec_rst(d_latch[3]),
        .scl(d_latch[1]), .sda_i(d_latch[0]), .sda_o(sda100_o)
    );

    x76f041 eeprom041 (
        .clk(clk), .rst(rst),
        .cs(sel041 ? eeprom_cs : 1'b1), .sec_rst(d_latch[3]),
        .scl(d_latch[1]), .sda_i(d_latch[0]), .sda_o(sda041_o),
        .load_we(load_eep_we), .load_addr(load_eep_addr), .load_data(load_eep_data)
    );

    wire eeprom_sda_o = sel041 ? sda041_o : sda100_o;

    // ----- board DS2401 on D4 (open-drain, pulled up) -----
    wire ds_pd;
    wire ds_line = ~(d_latch[4] | ds_pd);    // D4=1 pulls the 1-wire line low
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) board_id (
        .clk(clk), .rst(rst), .dq_in(ds_line), .dq_pd(ds_pd),
        .load_we(load_ser_we), .load_addr(load_ser_addr), .load_data(load_ser_data)
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
