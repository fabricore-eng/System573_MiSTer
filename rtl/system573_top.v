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
    parameter integer WDOG_TIMEOUT     = 32'd1_000_000,
    // SIM_BACKING=1 (default, iverilog): inline flash_nor BRAM (flash_wait=0).
    // 0 (Quartus/HW, set from emu.sv): 16 MB SDRAM-backed flash line buffer.
    parameter integer FLASH_SIM_BACKING = 1
)(
    input  wire        clk,
    input  wire        rst,

    // EXP1 master (from the PS1 core / CPU)
    input  wire [23:0] exp1_addr,
    // CPU load width (psx_patches/0010: memorymux reqsize_buf). 00=lb/lbu, 01=lh/lhu,
    // 10=lw. The PSX external-bus byte/halfword load-align is UNCONDITIONAL [7:0]/[15:0]
    // (cpu.vhd) with no addr-rotate, so a byte read needs the addressed byte already in
    // exp1_rdata[7:0]. This slave is halfword-native, so we rotate by addr[0] for lb/lbu.
    input  wire [1:0]  exp1_reqsize,
    input  wire [15:0] exp1_wdata,
    input  wire        exp1_we,
    input  wire        exp1_re,
    output reg  [15:0] exp1_rdata,

    // EXP1 read wait handshake (-> psx memorymux bus_exp1_wait, psx_patches/0006).
    // High while a flash array read is stalled on its SDRAM line fill; the PSX
    // external-bus FSM holds in its read-strobe state until this drops. Always 0
    // for every non-flash EXP1 access and for flash ID reads / HITs.
    output wire        flash_wait,

    // SDRAM flash line-fill port (used only when FLASH_SIM_BACKING=0; driven by
    // emu.sv's SDRAM read client into the 16 MB onboard-flash image).
    output wire        flash_mem_req,
    output wire [26:0] flash_mem_addr,
    input  wire [127:0] flash_mem_q,
    input  wire        flash_mem_ready,

    // SDRAM flash single-word WRITE-BACK port (FLASH_SIM_BACKING=0): NOR program
    // makes the onboard flash writable for a CD game's installer. emu.sv muxes this
    // into the free SDRAM ch3 writer and returns the ch3 completion on flash_wr_ack.
    output wire        flash_wr_req,
    output wire        flash_wr_busy,
    output wire [26:0] flash_wr_addr,
    output wire [15:0] flash_wr_data,
    input  wire        flash_wr_ack,

    // DEBUG passthrough: s573_flash trigger-state observers (HW bring-up).
    output wire [23:0] flash_dbg,

    // M48T58 NVRAM image load (e.g. hyperbbc 876ea.22h), streamed in at reset.
    input  wire        nvram_we,
    input  wire [12:0] nvram_addr,
    input  wire [7:0]  nvram_din,

    // M48T58 NVRAM image SAVE-BACK (hps_io ioctl upload -> config/nvram/*.nvm).
    // Read port into the timekeeper (write-port idle cycles, 1-cycle latency,
    // sav_rd_ok=0 -> the saver retries) + a "game wrote the timekeeper" strobe
    // for emu.sv's dirty flag -> ioctl_upload_req (OSD autosave request).
    input  wire [12:0] nvram_sav_addr,
    output wire [7:0]  nvram_sav_dout,
    output wire        nvram_sav_rd_ok,
    output wire        nvram_written,

    // Security-cartridge image load (e.g. pnchmn2 gqa09ja.u1 / .u6), streamed in at
    // reset. cart_type selects the EEPROM model: 0 = X76F100, 1 = X76F041.
    input  wire [1:0]  sec_cart_type,
    input  wire        sec_eep_we,    // EEPROM (.u1: 548 B x76f041 / 4116 B zs01) byte write
    input  wire [12:0] sec_eep_addr,  // 13-bit covers the padded 4116-byte ZS01 .u1
    input  wire [7:0]  sec_eep_din,
    input  wire        sec_ser_we,    // DS2401 (.u6, 8-byte serial image) byte write
    input  wire [2:0]  sec_ser_addr,
    input  wire [7:0]  sec_ser_din,

    // Board inputs (JAMMA / coins / DIP) from the MiSTer host
    input  wire [3:0]  dip_sw,
    input  wire [7:0]  p1_ctrl,
    input  wire [7:0]  p2_ctrl,
    input  wire [1:0]  coin_sw,
    input  wire        service_btn,
    input  wire        test_btn,
    input  wire [1:0]  pcmcia_present,
    input  wire        cd_present,      // 1 = ATAPI CD drive attached; 0 = no_cdrom flash config (MAME konami573 no_cdrom)

    // ---- mounted CD-image sector stream (Feature B) ----
    // cd_image=1 routes ATAPI READ(10/12) data from a mounted CD image (via the
    // s573_cdimg reader on the MiSTer CUECHD sd-block host stream) instead of the
    // SIM-only disc[] store. The cd_* ports below are emu.sv's sd_lba1/sd_rd[1]/
    // sd_ack[1]/sd_buff_wr/sd_buff_dout (the same channel cd_top used pre-patch-0011).
    input  wire        cd_image,        // 1 = a CD image is mounted (drive READ from it)
    output wire        cd_hps_req,      // -> sd_rd[1]      (request a raw sector)
    output wire [31:0] cd_hps_lba,      // -> sd_lba1       (raw sector LBA)
    input  wire        cd_hps_ack,      // <- sd_ack[1]
    input  wire        cd_hps_write,    // <- sd_buff_wr    (one 16-bit word per pulse)
    input  wire [15:0] cd_hps_data,     // <- sd_buff_dout

    // ---- mounted-disc metadata (s573_cdtoc): Main disk_t (ioctl index 251) +
    //      the img_size/2352 single-track fallback. atapi.v serves READ TOC /
    //      READ CAPACITY content from this (the GX700 CD-boot path reads both).
    input  wire        cd_ti_write,     // <- ramdownload_wr && cdinfo_download
    input  wire [8:0]  cd_ti_addr,      // <- ramdownload_wraddr[10:2] (32-bit word index)
    input  wire [31:0] cd_ti_data,      // <- ramdownload_wrdata
    input  wire        cd_img_mounted,  // <- img_mounted[1] (pulse)
    input  wire [63:0] cd_img_size,     // <- img_size (bytes; raw 2352-byte sectors)

    // ---- PSX DMA channel 5 drain of the ATAPI data phase (psx_patches/0023) ----
    // The BIOS's only sector-read data path: the ISR arms ch5 and the DMA pulls the
    // 2048-byte sector as 16-bit halfwords straight from atapi.v's prefetch register.
    output wire        atapi_dma_req,   // -> psx atapi_dmaRequest (data-phase request)
    input  wire        atapi_dma_rd,    // <- psx DMA_ATA_readEna (halfword consume)
    output wire [15:0] atapi_dma_dout,  // -> psx DMA_ATA_read

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
    wire        flash_ready;
    // exp1_addr[21:1] = the full 21-bit (2 M-word = 4 MB) window offset. The old
    // [16:1] slice exposed only 128 KB of each 4 MB bank (a real bug).
    s573_flash #(.SIM_BACKING(FLASH_SIM_BACKING)) u_flash (
        .clk(clk), .rst(rst),
        .ctl_we(sel_bankctl & exp1_we), .ctl_din(exp1_wdata),
        .bank(flash_bank), .sec_io0_dir(sec_io0_dir), .cpld_sig(flash_cpld),
        .win_sel(sel_flash), .win_addr(exp1_addr[21:1]),
        .win_we(sel_flash & exp1_we), .win_din(exp1_wdata), .win_dout(flash_dout),
        .flash_ready(flash_ready),
        .flash_mem_req(flash_mem_req), .flash_mem_addr(flash_mem_addr),
        .flash_mem_q(flash_mem_q), .flash_mem_ready(flash_mem_ready),
        .flash_wr_req(flash_wr_req), .flash_wr_busy(flash_wr_busy),
        .flash_wr_addr(flash_wr_addr),
        .flash_wr_data(flash_wr_data), .flash_wr_ack(flash_wr_ack),
        .dbg_flash(flash_dbg)
    );
    // The EXP1 wait is asserted ONLY while a flash access is not ready (a missed
    // array read filling its line). For every non-flash EXP1 select and for flash
    // ID reads / line-buffer HITs flash_ready=1, so flash_wait=0 -- a stuck-high
    // wait would hang the whole 573 bus.
    assign flash_wait = sel_flash & ~flash_ready;

    // --- security cartridge (EEPROM + board DS2401) via the D0-D7 latch ---
    wire        sec_io0, sec_drdy, sec_irdy;
    wire [7:0]  sec_in;
    s573_seccart #(.DS_SERIAL(CART_SERIAL), .DS_CLK_HZ(CLK_FREQ_HZ)) u_seccart (
        .clk(clk), .rst(rst),
        .cart_type(sec_cart_type),
        .latch_we(sel_seclatch & exp1_we), .d_latch(exp1_wdata[7:0]),
        .io0_dir(sec_io0_dir),
        .load_eep_we(sec_eep_we), .load_eep_addr(sec_eep_addr), .load_eep_data(sec_eep_din),
        .load_ser_we(sec_ser_we), .load_ser_addr(sec_ser_addr), .load_ser_data(sec_ser_din),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    // --- ATAPI CD-ROM (IDE bank 0 = command block, bank 1 = control block) ---
    wire [15:0] atapi_dout;
    wire        atapi_intrq;
    wire        atapi_sel = sel_ide0 | sel_ide1;
    wire [3:0]  atapi_addr = sel_ide1 ? 4'd8 : exp1_addr[3:1];
    // CD-image sector path (Feature B): atapi.v dispatches a READ -> sec_req/sec_lba;
    // s573_cdimg fetches the raw sector from the mounted image and presents its 2048
    // user-data bytes back as the sbuf buffer that atapi.v streams to the host.
    wire        atapi_sec_req;
    wire [31:0] atapi_sec_lba;
    wire [10:0] atapi_sbuf_addr;
    wire [15:0] atapi_sbuf_q;
    wire        atapi_sec_ready;
    wire        atapi_dma_req_int;
    // disc metadata (s573_cdtoc <-> atapi)
    wire [7:0]  atapi_toc_track_count;
    wire [31:0] atapi_toc_leadout;
    wire [6:0]  atapi_toc_qtrack;
    wire [31:0] atapi_toc_qstart;
    wire        atapi_toc_qaudio;
    // ide_rst polarity: 0x1f560000 bit0 is the drive's ACTIVE-LOW reset line
    // (psx-spx / MAME konami573: write 0 = assert reset, write 1 = release).
    // The old `sel_idereset & exp1_we` reset on ANY write -- including the
    // BIOS's release-write of 1, which re-reset the drive it had just reset.
    atapi u_atapi (
        .clk(clk), .rst(rst), .ide_rst(sel_idereset & exp1_we & ~exp1_wdata[0]),
        .sel(atapi_sel), .addr(atapi_addr),
        .we(atapi_sel & exp1_we), .re(atapi_sel & exp1_re),
        .din(exp1_wdata), .dout(atapi_dout), .intrq(atapi_intrq),
        .cd_attached(cd_image),
        .sec_req(atapi_sec_req), .sec_lba(atapi_sec_lba),
        .sbuf_addr(atapi_sbuf_addr), .sbuf_q(atapi_sbuf_q),
        .sec_ready(atapi_sec_ready),
        .toc_track_count(atapi_toc_track_count), .toc_leadout(atapi_toc_leadout),
        .toc_qtrack(atapi_toc_qtrack), .toc_qstart(atapi_toc_qstart),
        .toc_qaudio(atapi_toc_qaudio),
        .dma_req(atapi_dma_req_int), .dma_rd(atapi_dma_rd), .dma_dout(atapi_dma_dout)
    );

    // --- mounted-CD-image sector reader (Feature B) ---
    s573_cdimg u_cdimg (
        .clk(clk), .rst(rst),
        .sec_req(atapi_sec_req), .sec_lba(atapi_sec_lba),
        .sbuf_addr(atapi_sbuf_addr), .sbuf_q(atapi_sbuf_q),
        .sec_ready(atapi_sec_ready), .sec_busy(),
        .cd_req(cd_hps_req), .cd_lba(cd_hps_lba),
        .cd_ack(cd_hps_ack), .cd_wr(cd_hps_write), .cd_data(cd_hps_data)
    );

    // --- mounted-disc metadata (TOC + capacity) for the drive's READ TOC /
    //     READ CAPACITY responses: Main disk_t (ioctl 251) or img_size fallback ---
    s573_cdtoc u_cdtoc (
        .clk(clk), .rst(rst),
        .ti_write(cd_ti_write), .ti_addr(cd_ti_addr), .ti_data(cd_ti_data),
        .img_mounted(cd_img_mounted), .img_size(cd_img_size),
        .toc_track_count(atapi_toc_track_count), .toc_leadout(atapi_toc_leadout),
        .toc_qtrack(atapi_toc_qtrack), .toc_qstart(atapi_toc_qstart),
        .toc_qaudio(atapi_toc_qaudio)
    );
    // ch5 request follows the same drive-present gate as INTRQ.
    assign atapi_dma_req = cd_present ? atapi_dma_req_int : 1'b0;
    // cd_present gates the IDE read mux + INTRQ. CORRECTION (HW-verified 2026-06-03):
    // a real 573 -- even for no_cdrom flash games (gchgchmp/hyperbbc) -- carries a CR-589
    // CD-ROM on the IDE bus, and the GX700 POST "DRIVE CHECK" probes it UNCONDITIONALLY
    // (it is NOT gated by the boot-device DIP). With cd_present=0 the bus floats to 0xFFFF,
    // so STATUS reads BSY-stuck (0xFF), the BIOS's BSY-clear wait times out, and CDR reads
    // BAD -> "HARDWARE ERROR... RESET". emu.sv therefore drives cd_present=1 to present an
    // empty drive; atapi.v answers the 0xEB14 signature + IDENTIFY PACKET DEVICE (0xA1) so
    // the UNMODIFIED Konami BIOS passes CDR. (The earlier "0xFFFF makes the BIOS skip CDR"
    // claim was wrong: the BIOS does not skip it -- it fails it.)
    assign cdrom_irq = cd_present ? atapi_intrq : 1'b0;

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
        .dout(rtc_dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .sav_addr(nvram_sav_addr), .sav_dout(nvram_sav_dout), .sav_rd_ok(nvram_sav_rd_ok)
    );

    // Dirty strobe for the SD save-back: any game-side write into the timekeeper
    // (NVRAM array or clock registers -- both belong to the persisted 8 KB image).
    // The ioctl image LOAD (nvram_we) deliberately does NOT count: restoring the
    // .nvm at boot must not mark the content dirty.
    assign nvram_written = sel_rtc & exp1_we;

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
        else if (sel_ide0 | sel_ide1) rdata_mux = cd_present ? atapi_dout : 16'hFFFF;
        else if (sel_digio)      rdata_mux = digio_dout;
        else                     rdata_mux = 16'h0000;
    end

    // EXP1 byte-lane alignment (psx_patches/0010 plumbs exp1_reqsize here).
    // This fabric is a 16-bit, HALFWORD-NATIVE slave: rdata_mux holds the halfword
    // for exp1_addr[N:1]. The PSX CPU's EXTERNAL byte/halfword load-align is an
    // UNCONDITIONAL [7:0]/[15:0] extraction (cpu.vhd ~2537/2549) -- unlike RAM it
    // does NOT re-rotate by addr[1:0], and memorymux hands the EXP1 read straight to
    // ext_data_new with no external rotate. So for a byte load (lb/lbu) the addressed
    // byte must already sit in [7:0]: select the high byte for an odd address and
    // replicate it into [7:0]. (The 700A BIOS reads the flash signature + CRC
    // BYTE-BY-BYTE; without this, odd-byte reads return the wrong byte -> sig/CRC
    // fail.) For lh/lhu/lw (reqsize != 00) pass the true halfword through unchanged so
    // ext_data_new[15:0] is correct and a word read's 2nd beat fills [31:16] normally.
    reg [15:0] exp1_rdata_aligned;
    always @(*) begin
        if (exp1_reqsize == 2'b00)                 // lb / lbu
            exp1_rdata_aligned = exp1_addr[0] ? {rdata_mux[15:8], rdata_mux[15:8]}
                                              : {rdata_mux[7:0],  rdata_mux[7:0]};
        else                                       // lh / lhu / lw
            exp1_rdata_aligned = rdata_mux;
    end

    // Registered EXP1 read data. The PlayStation memory controller's external-bus
    // FSM (PSX_MiSTer memorymux.vhd) asserts the read strobe during EXT_READ_NEXT
    // and samples the returned data one cycle later, in EXT_READ, *after* the
    // strobe has deasserted. It therefore expects a REGISTERED slave, exactly like
    // the PSX core's own EXP2/SPU/CD slaves -- a combinational read would collapse
    // to 0 the moment exp1_re drops and the FSM would capture garbage (POST hang).
    // We latch the (byte-aligned) mux while exp1_re is asserted and HOLD it
    // afterwards, rather than clearing to 0 like exp2.vhd: this fabric is driven
    // free-running on the PSX clk1x with no clock-enable, so a clear-default would
    // lose the value during the PSX core's ce gaps before the FSM's EXT_READ capture.
    always @(posedge clk) begin
        if (rst)          exp1_rdata <= 16'h0000;
        else if (exp1_re) exp1_rdata <= exp1_rdata_aligned;
    end
endmodule
