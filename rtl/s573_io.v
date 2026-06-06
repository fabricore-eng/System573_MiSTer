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
    wire [15:0] r_status =
        { sec_in,                 // [15:8] security I0-I7
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
    //   0x0c (IN3 low,  P1): bit10 = TEST button; buttons 4/5/6 idle high.
    wire [15:0] r_extra_c = { 4'b0000, 1'b1, test_btn, 1'b1, 1'b1, 8'b00000000 };
    //   0x0e (IN3 high, P2): bit10 = main-RAM-layout strap (0 = new 2x2MB, the layout this
    //   core implements -> 700B BIOS picks 0x1f801060 = 0x4788); buttons 4/5/6 idle high.
    wire [15:0] r_extra_e = { 4'b0000, 1'b1, 1'b0,      1'b1, 1'b1, 8'b00000000 };

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
