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
    output wire        wdog_reset,      // watchdog bite (board reset request)
    output wire        cdrom_irq,       // ATAPI INTRQ (IRQ10)
    output wire [31:0] lamp_out,        // BEMANI Digital I/O lamp lines
    output wire [7:0]  dio_mp3_byte,    // descrambled MP3 byte stream -> MAS3507D
    output wire        dio_mp3_valid
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

    // --- bank-switched flash / PCMCIA window + control latch ---
    wire [15:0] flash_dout;
    wire [5:0]  flash_bank;
    wire        sec_io0_dir, flash_cpld;
    s573_flash u_flash (
        .clk(clk), .rst(rst),
        .ctl_we(sel_bankctl & exp1_we), .ctl_din(exp1_wdata),
        .bank(flash_bank), .sec_io0_dir(sec_io0_dir), .cpld_sig(flash_cpld),
        .win_sel(sel_flash), .win_addr(exp1_addr[16:1]),
        .win_we(sel_flash & exp1_we), .win_din(exp1_wdata), .win_dout(flash_dout)
    );

    // --- security cartridge (EEPROM + board DS2401) via the D0-D7 latch ---
    wire        sec_io0, sec_drdy, sec_irdy;
    wire [7:0]  sec_in;
    s573_seccart #(.DS_SERIAL(CART_SERIAL), .DS_CLK_HZ(CLK_FREQ_HZ)) u_seccart (
        .clk(clk), .rst(rst),
        .latch_we(sel_seclatch & exp1_we), .d_latch(exp1_wdata[7:0]),
        .io0_dir(sec_io0_dir),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    // --- ATAPI CD-ROM (IDE bank 0 = command block, bank 1 = control block) ---
    wire [15:0] atapi_dout;
    wire        atapi_sel = sel_ide0 | sel_ide1;
    wire [3:0]  atapi_addr = sel_ide1 ? 4'd8 : exp1_addr[3:1];
    atapi u_atapi (
        .clk(clk), .rst(rst), .ide_rst(sel_idereset & exp1_we),
        .sel(atapi_sel), .addr(atapi_addr),
        .we(atapi_sel & exp1_we), .re(atapi_sel & exp1_re),
        .din(exp1_wdata), .dout(atapi_dout), .intrq(cdrom_irq)
    );

    // --- BEMANI Digital I/O board ---
    wire [15:0] digio_dout;
    k573dio #(.DS_SERIAL(CART_SERIAL + 48'd1), .DS_CLK_HZ(CLK_FREQ_HZ)) u_digio (
        .clk(clk), .rst(rst),
        .sel(sel_digio), .off(exp1_addr[7:0]),
        .we(sel_digio & exp1_we), .re(sel_digio & exp1_re),
        .din(exp1_wdata), .dout(digio_dout), .lamp(lamp_out),
        .crypto_key1(), .crypto_key2(), .crypto_key3(),
        .mp3_start(), .mp3_end(), .fpga_ctrl(), .network_id(),
        .mp3_out_byte(dio_mp3_byte), .mp3_out_valid(dio_mp3_valid)
    );

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
        .sec_in(sec_in), .sec_io0(sec_io0),
        .sec_irdy(sec_irdy), .sec_drdy(sec_drdy),
        .adc_do(adc_do), .adc_sars(adc_sars),
        .adc_di(adc_di), .adc_cs_n(adc_cs_n), .adc_clk(adc_clk),
        .coin_counter(coin_counter),
        .audio_amp_en(audio_amp_en), .audio_mute(audio_mute),
        .spu_dac_en(spu_dac_en), .jvs_mcu_rst_n()
    );

    // --- read data mux back to the CPU ---
    // Combinational select of the addressed peripheral's read word.
    reg [15:0] rdata_mux;
    always @(*) begin
        if (sel_asic)            rdata_mux = asic_dout;
        else if (sel_rtc)        rdata_mux = {8'h00, rtc_dout};
        else if (sel_flash)      rdata_mux = flash_dout;
        else if (sel_ide0 | sel_ide1) rdata_mux = atapi_dout;
        else if (sel_digio)      rdata_mux = digio_dout;
        else                     rdata_mux = 16'h0000;
    end

    // Registered EXP1 read data. The PlayStation memory controller's external-bus
    // FSM (PSX_MiSTer memorymux.vhd) asserts the read strobe during EXT_READ_NEXT
    // and samples the returned data one cycle later, in EXT_READ, *after* the
    // strobe has deasserted. It therefore expects a REGISTERED slave, exactly like
    // the PSX core's own EXP2/SPU/CD slaves -- a combinational read would collapse
    // to 0 the moment exp1_re drops and the FSM would capture garbage (POST hang).
    // We latch the mux while exp1_re is asserted and HOLD it afterwards, rather
    // than clearing to 0 like exp2.vhd: this fabric is driven free-running on the
    // PSX clk1x with no clock-enable, so a clear-default would lose the value
    // during the PSX core's ce gaps before the FSM's EXT_READ capture edge.
    always @(posedge clk) begin
        if (rst)          exp1_rdata <= 16'h0000;
        else if (exp1_re) exp1_rdata <= rdata_mux;
    end
endmodule
