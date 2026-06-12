`timescale 1ns/1ps
// Integration smoke test for system573_top.v - drives the EXP1 master bus the
// way a PS1 CPU would and checks the peripherals respond through the fabric.
module tb_system573_top;
    reg clk = 0, rst = 1;
    reg [23:0] exp1_addr = 0;
    reg [1:0]  exp1_reqsize = 2'b01;   // default lh (pass-through); byte tests set 00
    reg [15:0] exp1_wdata = 0;
    reg        exp1_we = 0, exp1_re = 0;
    wire [15:0] exp1_rdata;

    reg [3:0]  dip_sw = 4'h0;
    reg [7:0]  p1_ctrl = 8'h5A, p2_ctrl = 8'hC3;
    reg [1:0]  coin_sw = 0;
    reg        service_btn = 0, test_btn = 0;
    reg [1:0]  pcmcia_present = 0;
    reg [7:0]  adc_ch0 = 0, adc_ch1 = 0, adc_ch2 = 0, adc_ch3 = 0;

    wire [1:0] coin_counter;
    wire audio_amp_en, audio_mute, spu_dac_en, wdog_reset, cdrom_irq;
    wire [31:0] lamp_out;
    integer errors = 0, bites = 0;

    system573_top #(.CLK_FREQ_HZ(1_000_000), .WDOG_TIMEOUT(20)) dut (
        .clk(clk), .rst(rst),
        .exp1_addr(exp1_addr), .exp1_reqsize(exp1_reqsize), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .dip_sw(dip_sw), .p1_ctrl(p1_ctrl), .p2_ctrl(p2_ctrl),
        .coin_sw(coin_sw), .service_btn(service_btn), .test_btn(test_btn),
        .pcmcia_present(pcmcia_present),
        .cd_present(1'b1),   // this integration test exercises the ATAPI/CD path, so model a drive present
        .cd_image(1'b0), .cd_hps_req(), .cd_hps_lba(),
        .cd_hps_ack(1'b0), .cd_hps_write(1'b0), .cd_hps_data(16'h0000),
        .cd_ti_write(1'b0), .cd_ti_addr(9'd0), .cd_ti_data(32'd0),
        .cd_img_mounted(1'b0), .cd_img_size(64'd0),
        .atapi_dma_req(), .atapi_dma_rd(1'b0), .atapi_dma_dout(),
        .adc_ch0(adc_ch0), .adc_ch1(adc_ch1), .adc_ch2(adc_ch2), .adc_ch3(adc_ch3),
        .coin_counter(coin_counter), .audio_amp_en(audio_amp_en),
        .audio_mute(audio_mute), .spu_dac_en(spu_dac_en), .wdog_reset(wdog_reset),
        .cdrom_irq(cdrom_irq), .lamp_out(lamp_out),
        // SIM_BACKING defaults to 1: inline flash; flash_wait stays 0, SDRAM unused.
        .flash_wait(), .flash_mem_req(), .flash_mem_addr(),
        .flash_mem_q(128'd0), .flash_mem_ready(1'b0),
        .nvram_we(1'b0), .nvram_addr(13'd0), .nvram_din(8'd0),
        .sec_cart_type(2'd0),
        .sec_eep_we(1'b0), .sec_eep_addr(10'd0), .sec_eep_din(8'd0),
        .sec_ser_we(1'b0), .sec_ser_addr(3'd0), .sec_ser_din(8'd0)
    );

    always #5 clk = ~clk;
    always @(posedge clk) if (!rst && wdog_reset) bites = bites + 1;

    task exp1_write(input [23:0] a, input [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_wdata = d; exp1_we = 1; exp1_re = 0;
            @(posedge clk);
            @(negedge clk); exp1_we = 0;
        end
    endtask

    // EXP1 read modelled after the single-beat read latency of the PSX
    // external-bus FSM (PSX_MiSTer memorymux.vhd). The FSM holds the address stable
    // for an R-delay cycle (EXT_READ_WAIT) BEFORE asserting the strobe in
    // EXT_READ_NEXT, so synchronous EXP1 slaves (e.g. the M48T58 NVRAM, a registered
    // M10K read) have valid data when the slave latches rdata_mux on that edge; the
    // FSM then samples the data later in EXT_READ -- *after* the strobe has
    // deasserted, and possibly several free-running clk edges later (the PSX core's
    // ce gates the FSM but not this fabric). We present the address with re low for a
    // settle cycle, assert re for one beat, deassert it, hold for a couple of clk
    // edges, then sample. This fails if the fabric regresses to an exp2-style
    // clear-to-0 default (loses the value across the ce-gap cycles modelled here).
    // It deliberately does NOT model multi-beat / wait-state transactions or the
    // 8/16-bit byte stepping -- that is exercised end-to-end by the full-system
    // sim (see docs/PHASE1_PSX.md).
    task exp1_read(input [23:0] a, output [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_reqsize = 2'b01; exp1_re = 0; exp1_we = 0; // EXT_READ_WAIT: addr settles (lh pass-through)
            @(posedge clk);                 // synchronous slaves register their read here
            @(negedge clk); exp1_re = 1;     // EXT_READ_NEXT: assert read strobe
            @(posedge clk);                 // slave latches rdata_mux on this edge
            @(negedge clk); exp1_re = 0;     // strobe deasserts (entering EXT_READ)
            repeat (2) @(posedge clk);       // ce-gap: registered value must hold
            #1; d = exp1_rdata;              // FSM's EXT_READ sample: must still hold
        end
    endtask

    // Byte read (lb/lbu, reqsize=00) -- exercises the EXP1 slave byte-lane rotate
    // (psx_patches/0010). The addressed byte must land in exp1_rdata[7:0] regardless
    // of address parity, since the PSX external byte load-align is unconditional [7:0].
    task exp1_readb(input [23:0] a, output [7:0] d);
        reg [15:0] full;
        begin
            @(negedge clk); exp1_addr = a; exp1_reqsize = 2'b00; exp1_re = 0; exp1_we = 0;
            @(posedge clk);
            @(negedge clk); exp1_re = 1;
            @(posedge clk);
            @(negedge clk); exp1_re = 0;
            repeat (2) @(posedge clk);
            #1; full = exp1_rdata; d = full[7:0];
        end
    endtask

    // 32-bit EXP1 read, modelling how the widened memorymux external-bus FSM
    // handles a word access on the 16-bit 573 bus: two halfword beats, the second
    // at byte address +2 (ext_byteStep "00" then "10", addr[1] stepped). Assembles
    // low halfword from beat 0 and high halfword from beat 1. This exercises the
    // fabric's stepped-address decode (peripherals decode exp1_addr[N:1]).
    task exp1_read32(input [23:0] a, output [31:0] d);
        reg [15:0] lo, hi;
        begin
            exp1_read(a,            lo);    // beat 0: halfword at a
            exp1_read(a | 24'h000002, hi);  // beat 1: halfword at a+2 (addr[1] stepped)
            d = {hi, lo};
        end
    endtask

    // NOR flash program through the EXP1 window (unlock 0x555/0x2AA, cmd 0xA0)
    task flash_prog(input [23:0] waddr, input [15:0] d);
        begin
            exp1_write(24'h000AAA, 16'h00AA);   // word 0x555
            exp1_write(24'h000554, 16'h0055);   // word 0x2AA
            exp1_write(24'h000AAA, 16'h00A0);
            exp1_write(waddr, d);
        end
    endtask

    reg [15:0] r;
    integer i;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0;

        // 1) ASIC control write -> board outputs. 0x28 = amp(5)+coin1(3).
        exp1_write(24'h400000, 16'h0028);
        if (coin_counter !== 2'b01 || audio_amp_en !== 1'b1) begin
            $display("FAIL: asic ctrl coin=%b amp=%b", coin_counter, audio_amp_en);
            errors = errors + 1;
        end

        // 2) NVRAM write/read through the RTC window (byte 0x10).
        exp1_write(24'h620020, 16'h00AB);
        exp1_read(24'h620020, r);
        if (r[7:0] !== 8'hAB) begin
            $display("FAIL: nvram readback %02h expected AB", r[7:0]);
            errors = errors + 1;
        end

        // 3) ASIC JAMMA read.
        exp1_read(24'h400008, r);
        if (r !== {p1_ctrl, p2_ctrl}) begin
            $display("FAIL: jamma %04h expected %04h", r, {p1_ctrl, p2_ctrl});
            errors = errors + 1;
        end

        // 3b) Bank-switched flash: per-bank isolation, programmed through the
        //     NOR command sequences across the fabric (word 8 = byte 0x10).
        //     Internal onboard-flash bank index is the raw control value ctl[1:0]
        //     (MAME: onboard banks are control 0-3), so bank 1 = bankctl 0x01.
        exp1_write(24'h500000, 16'h0000);   // bank 0 (ctl 0x00)
        flash_prog(24'h000010, 16'h1234);
        exp1_write(24'h500000, 16'h0001);   // bank 1 (ctl 0x01)
        flash_prog(24'h000010, 16'h5678);
        exp1_write(24'h500000, 16'h0000);   // back to bank 0
        exp1_read(24'h000010, r);
        if (r !== 16'h1234) begin
            $display("FAIL: flash bank0 readback %04h expected 1234", r); errors = errors + 1;
        end
        exp1_write(24'h500000, 16'h0001);   // bank 1 again -> its own value
        exp1_read(24'h000010, r);
        if (r !== 16'h5678) begin
            $display("FAIL: flash bank1 readback %04h expected 5678", r); errors = errors + 1;
        end
        exp1_write(24'h500000, 16'h0000);   // leave on bank 0 for the next steps

        // 3b-2) Multi-beat 32-bit stepped read: program two adjacent flash words
        //       (byte 0x10 and 0x12), then read them as one 32-bit word the way the
        //       widened memorymux does -- two halfword beats with addr[1] stepped.
        //       Confirms the fabric returns the correct halfword per stepped address
        //       and that a non-zero UPPER halfword is assembled correctly.
        begin : multibeat
            reg [31:0] r32;
            flash_prog(24'h000012, 16'hABCD);   // word 9 (byte 0x12), bank 0
            exp1_read32(24'h000010, r32);        // -> {word9, word8} = {ABCD, 1234}
            if (r32 !== 32'hABCD1234) begin
                $display("FAIL: 32-bit stepped read %08h expected ABCD1234", r32);
                errors = errors + 1;
            end
        end

        // 3b-3) Byte-lane rotate (psx_patches/0010): the BIOS reads the flash signature
        //       + CRC BYTE-BY-BYTE (lb/lbu, reqsize=00). The addressed byte must land in
        //       exp1_rdata[7:0] for BOTH even (low) and odd (high) byte addresses, since
        //       the PSX external byte load-align is an unconditional [7:0] extraction.
        //       Flash bank 0: word8(byte 0x10)=0x1234, word9(byte 0x12)=0xABCD.
        begin : bytelane
            reg [7:0] b;
            exp1_readb(24'h000010, b);            // even -> low byte of 0x1234 = 0x34
            if (b !== 8'h34) begin $display("FAIL: lb 0x10 = %02h expected 34", b); errors = errors + 1; end
            exp1_readb(24'h000011, b);            // odd  -> high byte of 0x1234 = 0x12
            if (b !== 8'h12) begin $display("FAIL: lb 0x11 = %02h expected 12", b); errors = errors + 1; end
            exp1_readb(24'h000012, b);            // even -> low byte of 0xABCD = 0xCD
            if (b !== 8'hCD) begin $display("FAIL: lb 0x12 = %02h expected CD", b); errors = errors + 1; end
            exp1_readb(24'h000013, b);            // odd  -> high byte of 0xABCD = 0xAB
            if (b !== 8'hAB) begin $display("FAIL: lb 0x13 = %02h expected AB", b); errors = errors + 1; end
        end

        // 3c) ATAPI device signature through the IDE window.
        exp1_read(24'h480004, r);           // interrupt reason / sector count
        if (r[7:0] !== 8'h01) begin $display("FAIL: atapi sig reg2 %02h", r[7:0]); errors=errors+1; end
        exp1_read(24'h48000a, r);           // byte count high (signature 0xEB)
        if (r[7:0] !== 8'hEB) begin $display("FAIL: atapi sig reg5 %02h", r[7:0]); errors=errors+1; end
        exp1_write(24'h560000, 16'h0000);   // IDE reset -> device signature reloads
        exp1_read(24'h480004, r);
        if (r[7:0] !== 8'h01) begin $display("FAIL: atapi after ide-reset %02h", r[7:0]); errors=errors+1; end

        // 3d) Digital I/O lamp output through the fabric.
        exp1_write(24'h6400e2, 16'hA000);   // output register 0
        if (lamp_out[3:0] !== 4'b1100) begin
            $display("FAIL: digio lamp %b", lamp_out[3:0]); errors = errors + 1;
        end

        // 4) Watchdog: kick, confirm no early bite, then let it bite.
        exp1_write(24'h5c0000, 16'h0000);   // kick
        bites = 0;
        repeat (15) @(posedge clk);
        if (bites != 0) begin
            $display("FAIL: watchdog bit early (%0d)", bites); errors = errors + 1;
        end
        repeat (15) @(posedge clk);
        if (bites < 1) begin
            $display("FAIL: watchdog never bit"); errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (system573_top)");
        else             $display("RESULT: FAIL (system573_top, %0d errors)", errors);
        $finish;
    end
endmodule
