// -----------------------------------------------------------------------------
// s573_flash.v - System 573 bank-switched flash / PCMCIA window + control latch
//
// The 573 sees a single 4 MB window at 0x1f000000 into a much larger backing
// store, selected by the bank field of the control register at 0x1f500000:
//
//   bits 0-5 : bank  (0-3 = internal onboard flash, 16-31 = PCMCIA slot 1,
//                     32-47 = PCMCIA slot 2)
//   bit  6   : security-cart IO0 direction (0 = input)
//   bit  7   : CPLD signal
//
// This module latches that control register (exposing the bank and the two
// security/CPLD bits to the rest of the board) and maps the 4 MB window onto a
// flat backing memory: effective word = bank*WIN_WORDS + window offset. The
// internal onboard-flash banks are backed by writable memory; absent PCMCIA
// banks read all-ones. For simulation the window/backing are parameterized
// small; the geometry (banking) is what matters and is what the tests check.
//
// Note: the JEDEC NOR program/erase command sequencing of the real flash chips
// is not modeled here - writes land directly in the backing store, as they would
// in a flash image loaded from MiSTer storage. (See docs/ROADMAP.md.)
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_flash #(
    parameter integer WIN_WORDS  = 256,   // 16-bit words per bank window (sim-sized)
    parameter integer NUM_BANKS  = 4      // internal onboard-flash banks backed by RAM
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
    input  wire [15:0] win_addr,      // word offset within the 4 MB window
    input  wire        win_we,
    input  wire [15:0] win_din,
    output reg  [15:0] win_dout
);
    localparam integer AW = $clog2(WIN_WORDS);

    reg [15:0] mem [0:NUM_BANKS*WIN_WORDS-1];

    wire internal = (bank < NUM_BANKS);
    wire [31:0] idx = bank * WIN_WORDS + win_addr[AW-1:0];

    integer i;
    initial for (i = 0; i < NUM_BANKS*WIN_WORDS; i = i + 1) mem[i] = 16'hFFFF;

    always @(posedge clk) begin
        if (rst) begin
            bank <= 6'd0; sec_io0_dir <= 1'b0; cpld_sig <= 1'b0;
        end else begin
            if (ctl_we) begin
                bank        <= ctl_din[5:0];
                sec_io0_dir <= ctl_din[6];
                cpld_sig    <= ctl_din[7];
            end
            if (win_sel && win_we && internal)
                mem[idx[$clog2(NUM_BANKS*WIN_WORDS)-1:0]] <= win_din;
        end
    end

    always @(*) begin
        if (win_sel && internal)
            win_dout = mem[idx[$clog2(NUM_BANKS*WIN_WORDS)-1:0]];
        else
            win_dout = 16'hFFFF;       // absent PCMCIA bank / unselected
    end
endmodule
