// -----------------------------------------------------------------------------
// s573_bus.v - System 573 EXP1 address decoder
//
// Decodes a PlayStation EXP1 access (physical address masked into the
// 0x1f000000 page, i.e. addr[23:0]) into one-hot chip selects for each 573
// peripheral window. Pure combinational; this is the spine the rest of the core
// hangs off. Window addresses are from docs/MEMORY_MAP.md.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_bus (
    input  wire [23:0] addr,     // offset within the 0x1f000000 page
    input  wire        access,   // 1 = a read or write to this page is happening

    output wire        sel_flash,    // 0x000000-0x3fffff bank-switched flash/PCMCIA
    output wire        sel_asic,     // 0x400000-0x40000f Konami ASIC I/O
    output wire        sel_ide0,     // 0x480000-0x48000f ATAPI bank 0
    output wire        sel_ide1,     // 0x4c0000-0x4c000f ATAPI bank 1
    output wire        sel_bankctl,  // 0x500000 bank switch / security control
    output wire        sel_jvsclr,   // 0x520000 JVS ready clear
    output wire        sel_idereset, // 0x560000 IDE reset
    output wire        sel_wdog,     // 0x5c0000 watchdog clear
    output wire        sel_digout,   // 0x600000 external digital outputs
    output wire        sel_rtc,      // 0x620000-0x623fff M48T58 RTC + NVRAM
    output wire        sel_digio,    // 0x640000-0x6400ff digital I/O board
    output wire        sel_jvsdata,  // 0x680000 JVS MCU data output
    output wire        sel_seclatch, // 0x6a0000 security cartridge output latch

    output wire [3:0]  asic_off,     // byte offset within the ASIC window
    output wire [13:0] rtc_off       // byte offset within the RTC window (0..8191 after >>1)
);
    wire [7:0] page = addr[23:16];

    assign sel_flash    = access & (page <= 8'h3f);
    assign sel_asic     = access & (page == 8'h40);
    assign sel_ide0     = access & (page == 8'h48);
    assign sel_ide1     = access & (page == 8'h4c);
    assign sel_bankctl  = access & (page == 8'h50);
    assign sel_jvsclr   = access & (page == 8'h52);
    assign sel_idereset = access & (page == 8'h56);
    assign sel_wdog     = access & (page == 8'h5c);
    assign sel_digout   = access & (page == 8'h60);
    assign sel_rtc      = access & (page == 8'h62);
    assign sel_digio    = access & (page == 8'h64);
    assign sel_jvsdata  = access & (page == 8'h68);
    assign sel_seclatch = access & (page == 8'h6a);

    assign asic_off = addr[3:0];
    // Software accesses the RTC 16-bit-wide using only the low byte, so the
    // halfword index addr[14:1] is the flat byte address into the M48T58.
    assign rtc_off  = addr[14:1];
endmodule
