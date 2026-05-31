// -----------------------------------------------------------------------------
// system573_top.v - System 573 core fabric
//
// Wires the EXP1 address decoder and the 573 peripherals together. The EXP1
// master bus is brought out as ports here, representing the PlayStation core's
// CPU window (driven by ps1_stub in a real build, or by a testbench for the
// integration smoke test). This module is plain Verilog so it elaborates and
// simulates without the MiSTer sys/ framework.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module system573_top #(
    parameter integer CLK_FREQ_HZ      = 33_868_800,
    parameter [47:0]  CART_SERIAL      = 48'h0000_0000_0001,
    parameter integer WDOG_TIMEOUT     = 32'd1_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // EXP1 master (from the PS1 core / CPU)
    input  wire [23:0] exp1_addr,
    input  wire [15:0] exp1_wdata,
    input  wire        exp1_we,
    input  wire        exp1_re,
    output reg  [15:0] exp1_rdata,

    // Board inputs (JAMMA / coins / DIP) from the MiSTer host
    input  wire [3:0]  dip_sw,
    input  wire [7:0]  p1_ctrl,
    input  wire [7:0]  p2_ctrl,
    input  wire [1:0]  coin_sw,
    input  wire        service_btn,
    input  wire        test_btn,
    input  wire [1:0]  pcmcia_present,
    input  wire [7:0]  adc_ch0,
    input  wire [7:0]  adc_ch1,
    input  wire [7:0]  adc_ch2,
    input  wire [7:0]  adc_ch3,

    // Board control outputs
    output wire [1:0]  coin_counter,
    output wire        audio_amp_en,
    output wire        audio_mute,
    output wire        spu_dac_en,
    output wire        wdog_reset       // watchdog bite (board reset request)
);
    wire access = exp1_we | exp1_re;

    // --- address decode ---
    wire sel_flash, sel_asic, sel_ide0, sel_ide1, sel_bankctl, sel_jvsclr;
    wire sel_idereset, sel_wdog, sel_digout, sel_rtc, sel_digio;
    wire sel_jvsdata, sel_seclatch;
    wire [3:0]  asic_off;
    wire [13:0] rtc_off;

    s573_bus u_bus (
        .addr(exp1_addr), .access(access),
        .sel_flash(sel_flash), .sel_asic(sel_asic),
        .sel_ide0(sel_ide0), .sel_ide1(sel_ide1),
        .sel_bankctl(sel_bankctl), .sel_jvsclr(sel_jvsclr),
        .sel_idereset(sel_idereset), .sel_wdog(sel_wdog),
        .sel_digout(sel_digout), .sel_rtc(sel_rtc),
        .sel_digio(sel_digio), .sel_jvsdata(sel_jvsdata),
        .sel_seclatch(sel_seclatch),
        .asic_off(asic_off), .rtc_off(rtc_off)
    );

    // --- watchdog ---
    wire wdog_kick = sel_wdog & exp1_we;
    watchdog #(.TIMEOUT_CYCLES(WDOG_TIMEOUT)) u_wdog (
        .clk(clk), .rst(rst), .kick(wdog_kick), .reset_out(wdog_reset)
    );

    // --- ADC0834 (bit-banged from the ASIC control register) ---
    wire adc_di, adc_cs_n, adc_clk, adc_do, adc_sars;
    adc0834 u_adc (
        .clk(clk), .rst(rst),
        .cs_n(adc_cs_n), .adc_clk(adc_clk), .di(adc_di),
        .do_o(adc_do), .sars(adc_sars),
        .ch0(adc_ch0), .ch1(adc_ch1), .ch2(adc_ch2), .ch3(adc_ch3)
    );

    // --- security cartridge DS2401 (bit-banged 1-Wire) ---
    // The security latch D0 / status IO0 model the open-drain 1-Wire line.
    reg  sec_latch_d0;       // last value written to 0x1f6a0000 bit0 (master pull-low)
    wire ds_pd;              // slave pull-down
    wire onewire_level = ~(sec_latch_d0 | ds_pd); // wired-AND, pulled up
    ds2401 #(.SERIAL(CART_SERIAL), .CLK_FREQ_HZ(CLK_FREQ_HZ)) u_ds2401 (
        .clk(clk), .rst(rst), .dq_in(onewire_level), .dq_pd(ds_pd)
    );
    always @(posedge clk) begin
        if (rst)                    sec_latch_d0 <= 1'b0;
        else if (sel_seclatch & exp1_we) sec_latch_d0 <= exp1_wdata[0];
    end

    // --- M48T58 RTC + NVRAM ---
    wire [7:0] rtc_dout;
    m48t58 #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_rtc (
        .clk(clk), .rst(rst),
        .addr(rtc_off[12:0]),
        .din(exp1_wdata[7:0]),
        .we(sel_rtc & exp1_we),
        .dout(rtc_dout)
    );

    // --- Konami ASIC I/O ---
    wire [15:0] asic_dout;
    s573_io u_io (
        .clk(clk), .rst(rst),
        .sel(sel_asic), .off(asic_off),
        .we(sel_asic & exp1_we), .re(sel_asic & exp1_re),
        .din(exp1_wdata), .dout(asic_dout),
        .dip_sw(dip_sw), .p1_ctrl(p1_ctrl), .p2_ctrl(p2_ctrl),
        .coin_sw(coin_sw), .service_btn(service_btn), .test_btn(test_btn),
        .pcmcia_present(pcmcia_present),
        .sec_in(8'h00), .sec_io0(onewire_level),
        .sec_irdy(1'b1), .sec_drdy(1'b1),
        .adc_do(adc_do), .adc_sars(adc_sars),
        .adc_di(adc_di), .adc_cs_n(adc_cs_n), .adc_clk(adc_clk),
        .coin_counter(coin_counter),
        .audio_amp_en(audio_amp_en), .audio_mute(audio_mute),
        .spu_dac_en(spu_dac_en), .jvs_mcu_rst_n()
    );

    // --- read data mux back to the CPU ---
    always @(*) begin
        if (sel_asic)     exp1_rdata = asic_dout;
        else if (sel_rtc) exp1_rdata = {8'h00, rtc_dout};
        else              exp1_rdata = 16'h0000;
    end
endmodule
