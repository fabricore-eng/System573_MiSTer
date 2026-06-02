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
    input  wire [7:0]  p1_ctrl,        // JAMMA player 1 (active high here)
    input  wire [7:0]  p2_ctrl,        // JAMMA player 2
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
          2'b00,                  // [5:4] JVSDRDY/JVSIRDY (unused here)
          1'b0,                   // [3]   JVS port sense
          sec_io0,                // [2]
          adc_sars,               // [1]
          adc_do };               // [0]

    // 0x08 JAMMA player controls (P1 high byte, P2 low byte)
    wire [15:0] r_jamma = { p1_ctrl, p2_ctrl };

    // 0x0c / 0x0e extra buttons (test button at bit 10)
    wire [15:0] r_extra = { 5'b00000, test_btn, 10'b0000000000 };

    always @(*) begin
        case (off)
            4'h4:    dout = r_status;
            4'h6:    dout = r_misc;
            4'h8:    dout = r_jamma;
            4'hc:    dout = r_extra;
            4'he:    dout = r_extra;
            default: dout = 16'h0000;
        endcase
    end
endmodule
