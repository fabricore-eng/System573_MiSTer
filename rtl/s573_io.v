// -----------------------------------------------------------------------------
// s573_io.v - Konami ASIC I/O register block (0x1f400000)
//
// The central I/O latch of the System 573. Holds the write-only control register
// and muxes the read-only input words (DIP/JVS/security status, misc inputs,
// JAMMA player controls, extra buttons). Bit assignments are from
// docs/MEMORY_MAP.md. The 16-bit register read is selected by the byte offset
// from s573_bus (offsets 0,4,6,8,c,e).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_io (
    input  wire        clk,
    input  wire        rst,

    // Bus side
    input  wire        sel,        // ASIC window selected
    input  wire [3:0]  off,        // byte offset within the window
    input  wire        we,         // 16-bit write strobe (1 cycle)
    input  wire        re,         // 16-bit read strobe (1 cycle)
    input  wire [15:0] din,
    output reg  [15:0] dout,

    // ---- inputs from the rest of the board / MiSTer host ----
    input  wire [3:0]  dip_sw,         // DIP switches
    input  wire [7:0]  p1_ctrl,        // JAMMA player 1 -- ACTIVE-LOW (pressed=0); inverted in
                                       // emu.sv (~joy) to mirror MAME IN2. (Stale "active high"
                                       // comment removed -- the inversion happens upstream.)
    input  wire [7:0]  p2_ctrl,        // JAMMA player 2 (active-low, see p1_ctrl)
    input  wire [1:0]  coin_sw,        // coin switches
    input  wire        service_btn,
    input  wire        test_btn,
    input  wire        btn5_p1,        // extra-button header, P1 button 5 (active-low)
    input  wire        btn5_p2,        // extra-button header, P2 button 5 (active-low)
    input  wire [1:0]  pcmcia_present,
    // security cartridge read-back
    input  wire [7:0]  sec_in,         // I0-I7
    input  wire        sec_io0,        // IO0 tristate state
    input  wire        sec_irdy,
    input  wire        sec_drdy,
    // ADC0834
    input  wire        adc_do,
    input  wire        adc_sars,

    // ---- control-register outputs to the board ----
    output reg         adc_di,
    output reg         adc_cs_n,
    output reg         adc_clk,
    output reg  [1:0]  coin_counter,   // energize signals
    output reg         audio_amp_en,
    output reg         audio_mute,
    output reg         spu_dac_en,
    output reg         jvs_mcu_rst_n
);
    // --- write-only control register (0x1f400000) ---
    reg [15:0] ctrl;

    always @(posedge clk) begin
        if (rst) begin
            ctrl <= 16'h0000;
        end else if (sel && we && (off == 4'h0)) begin
            ctrl <= din;
        end
    end

    always @(*) begin
        adc_di        = ctrl[0];
        adc_cs_n      = ctrl[1];
        adc_clk       = ctrl[2];
        coin_counter  = ctrl[4:3];
        audio_amp_en  = ctrl[5];
        audio_mute    = ctrl[6];
        spu_dac_en    = ctrl[7];
        jvs_mcu_rst_n = ctrl[8];
    end

    // --- read mux ---
    // 0x04 H8 (18E) response nibble + security + DIP
    // Bits [7:4] are the H8/3644 MCU (board location 18E) response nibble. The GX700
    // power-on self-test pulses the H8 response clock (control reg bit 8) to step an
    // index through the H8's internal 64-byte response ROM and compares bits [7:4] at
    // each step; a mismatch fails the 18E check and the BIOS gates boot there. For the
    // 700A BIOS the response ROM (dumps/bios/h8a01.bin) is 64x 0x0C, so the constant
    // nibble 0xC passes at every index. (These bits were previously mislabelled "JVS
    // error/status" -- the JVS serial-packet I/O path is a separate thing; see
    // 0x1f680000.) TODO multi-BIOS: 700B's h8b01.bin varies, so it needs a
    // clock-stepped ROM-backed shift register here instead of this constant.
    // [15:8] high byte = the MAME IN1 (0x1f400004) bit map, konami/ksys573.cpp
    // PORT_START("IN1"): [8]=cassette ADC0834 DO, [9]=cassette ADC0834 SARS (NO cassette
    // ADC on a DIGITAL cart -> 0), [12]="Network?"=1 (Off; no network board present),
    // [14]=cassette DS2401 serial (read_line_ds2401) = sec_in[0] = the .u6 1-wire line.
    // The DS2401 was previously placed on [8] (the whole sec_in byte) -- a REAL bug: per
    // MAME these bits ARE the cassette DS2401 / network / cassette-ADC lines, and the old
    // mapping returned 0 on all of them. hyperbbc was unaffected (no cassette DS2401; it
    // reads X76 SDA on bit18 = 0x1f400006[2] = sec_io0, unchanged). Keep as a correctness fix.
    // CORRECTION (supersedes commit bcaf9a4's message, which billed this as "the ddrsbm
    // BOOT CHECK gate" -- it is NOT): disassembling the installer (tools/trace/dump_code.lua
    // + capstone) showed its input routine reads 0x1f400004 but uses only `& 0xf` (the DIP
    // nibble) -- never this high byte. The real ddrsbm BOOT CHECK gate is the DRIVE CHECK /
    // CD-ATAPI path (bracketed via the DBG_FORCE_BARS bands: atapi_seen+idecmd_seen=1,
    // bankctl_wr=0 -> issues a CD command then spins, never reaching flash).
    wire [15:0] r_status =
        { 1'b0,                   // [15]
          sec_in[0],              // [14] cassette DS2401 1-wire serial line (read_line_ds2401)
          1'b0,                   // [13]
          1'b1,                   // [12] "Network?" = Off (no network board present)
          2'b00,                  // [11:10]
          2'b00,                  // [9:8]  cassette ADC SARS/DO (absent on a digital cart)
          4'b1100,                // [7:4]  H8/18E response nibble = 0xC (h8a01.bin)
          dip_sw };               // [3:0]  DIP switches

    // 0x06 misc inputs
    wire [15:0] r_misc =
        { 3'b000,                 // [15:13] reserved
          service_btn,            // [12]
          pcmcia_present,         // [11:10]
          coin_sw,                // [9:8]
          sec_drdy, sec_irdy,     // [7:6]
          2'b00,                  // [5:4] JVS rx-ready(.4)/tx-write-ready(.5) = 0: keeps the
                                  //       JVS send+recv timing out like MAME (received_packet()
                                  //       =0 / IPT_UNKNOWN). Do NOT drive .5=1 -- a "send OK"
                                  //       makes the game block on a JVS reply that never comes.
          1'b1,                   // [3]   JVS port sense = 1 (no JVS I/O board attached; MAME
                                  //       jvs_sense_r = !address_set_line = 1). The game's I/O
                                  //       detect (flash 0x8017153c) require-1 ENTERs on this; its
                                  //       JVS send then times out -> returns -3 (negative) -> the
                                  //       boot gate treats it as "I/O board absent" and CONTINUES
                                  //       (gameplay inputs come from JAMMA reg 0x1f400008, below).
                                  //       Was 1'b0, which dead-ended detect OFF the graceful-skip
                                  //       path -> hyperbbc hung on its red "NG" self-test screen.
          sec_io0,                // [2]
          adc_sars,               // [1]
          adc_do };               // [0]

    // 0x08 JAMMA player controls (P1 high byte, P2 low byte)
    wire [15:0] r_jamma = { p1_ctrl, p2_ctrl };

    // 0x0c / 0x0e extra buttons. Bits: [11]=button6, [10]=test/RAM-layout, [9]=button5,
    // [8]=button4 (all ACTIVE-LOW, idle high). Audit IO-001/002: button 4/5/6 were hardwired
    // to 0 (read as permanently PRESSED) and 0x0e bit10 wrongly returned test_btn.
    // Audit IO-004: IO-001 fixed the POLARITY of buttons 4/5/6 but gave them no DRIVER.
    // Harmless on a standard cab (JAMMA carries three buttons per player), fatal on a DDR
    // Solo cab: MAME's ddrsolo PORT_MODIFY("IN3") maps P1 BUTTON5 -> "P1 Select L"
    // (0x00000200) and P2 BUTTON5 -> "P1 Select R" (0x02000000) -- the song-wheel buttons.
    // Pinned at 1'b1 they read permanently RELEASED, so song selection was unreachable by
    // ANY control and only START could move a menu. Buttons 4/6 stay idle: ddrsolo declares
    // them IPT_UNUSED. Bits [15:12]/[7:0] stay 0 -- MAME leaves 0xf0fff0ff unallocated and
    // unallocated ioport bits read back 0, so 0 is the MATCH, not a stub.
    //   0x0c (IN3 low,  P1): bit10 = TEST button; bit9 = button5 (Solo "Select L").
    wire [15:0] r_extra_c = { 4'b0000, 1'b1, test_btn, btn5_p1, 1'b1, 8'b00000000 };
    //   0x0e (IN3 high, P2): bit10 = main-RAM-layout strap (0 = new 2x2MB, the layout this
    //   core implements -> 700B BIOS picks 0x1f801060 = 0x4788). MAME declares that bit
    //   IPT_UNKNOWN and reads 1 -- our 0 is a DELIBERATE psx-spx-sourced divergence, do NOT
    //   "correct" it toward MAME or a 700B01 BIOS programs the wrong RAM layout.
    //   bit9 = button5 (Solo "Select R").
    wire [15:0] r_extra_e = { 4'b0000, 1'b1, 1'b0,      btn5_p2, 1'b1, 8'b00000000 };

    always @(*) begin
        case (off)
            4'h4:    dout = r_status;
            4'h6:    dout = r_misc;
            4'h8:    dout = r_jamma;
            4'hc:    dout = r_extra_c;
            4'he:    dout = r_extra_e;
            default: dout = 16'h0000;
        endcase
    end
endmodule
