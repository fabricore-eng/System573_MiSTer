`timescale 1ns/1ps
// tb_drivecheck.v - replays the System 573 BIOS GX700 POST "DRIVE CHECK" register
// sequence (reverse-engineered from dumps/bios/573.bin: ide_reset @0x803cb69c,
// signature-detect @0x803cb6d8, IDENTIFY @0x803cb7c4) against system573_top with a
// drive present (cd_present=1). This isolates the bus + atapi path from the CPU/IRQ,
// to confirm whether the drive check's register-level handshake passes in our fabric.
//
// EXP1 addresses are the low 24 bits of the CPU physical address (0x1f48000e ->
// 0x48000e). IDE bank0 = 0x48xxxx, bank1/control = 0x4cxxxx, IDE reset = 0x56xxxx.
module tb_drivecheck;
    reg clk = 0, rst = 1;
    reg [23:0] exp1_addr = 0;
    reg [1:0]  exp1_reqsize = 2'b01;   // lh pass-through (these checks read full halfwords)
    reg [15:0] exp1_wdata = 0;
    reg        exp1_we = 0, exp1_re = 0;
    wire [15:0] exp1_rdata;

    reg [3:0]  dip_sw = 4'h7;          // SW4=0 -> Flash boot (as emu.sv)
    wire [1:0] coin_counter;
    wire audio_amp_en, audio_mute, spu_dac_en, wdog_reset, cdrom_irq;
    wire [31:0] lamp_out;
    integer errors = 0;

    system573_top #(.CLK_FREQ_HZ(1_000_000), .WDOG_TIMEOUT(100000)) dut (
        .clk(clk), .rst(rst),
        .exp1_addr(exp1_addr), .exp1_reqsize(exp1_reqsize), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .dip_sw(dip_sw), .p1_ctrl(8'h00), .p2_ctrl(8'h00),
        .coin_sw(2'b00), .service_btn(1'b0), .test_btn(1'b0),
        .pcmcia_present(2'b00),
        .cd_present(1'b1),
        .cd_image(1'b0), .cd_hps_req(), .cd_hps_lba(),
        .cd_hps_ack(1'b0), .cd_hps_write(1'b0), .cd_hps_data(16'h0000),
        .cd_ti_write(1'b0), .cd_ti_addr(9'd0), .cd_ti_data(32'd0),
        .cd_img_mounted(1'b0), .cd_img_size(64'd0),
        .atapi_dma_req(), .atapi_dma_rd(1'b0), .atapi_dma_dout(),
        .adc_ch0(8'h00), .adc_ch1(8'h00), .adc_ch2(8'h00), .adc_ch3(8'h00),
        .coin_counter(coin_counter), .audio_amp_en(audio_amp_en),
        .audio_mute(audio_mute), .spu_dac_en(spu_dac_en), .wdog_reset(wdog_reset),
        .cdrom_irq(cdrom_irq), .lamp_out(lamp_out),
        .flash_wait(), .flash_mem_req(), .flash_mem_addr(),
        .flash_mem_q(128'd0), .flash_mem_ready(1'b0),
        .nvram_we(1'b0), .nvram_addr(13'd0), .nvram_din(8'd0),
        .sec_cart_type(2'd0),
        .sec_eep_we(1'b0), .sec_eep_addr(10'd0), .sec_eep_din(8'd0),
        .sec_ser_we(1'b0), .sec_ser_addr(3'd0), .sec_ser_din(8'd0)
    );

    always #5 clk = ~clk;

    task exp1_write(input [23:0] a, input [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_wdata = d; exp1_we = 1; exp1_re = 0;
            @(posedge clk);
            @(negedge clk); exp1_we = 0;
        end
    endtask
    task exp1_read(input [23:0] a, output [15:0] d);
        begin
            @(negedge clk); exp1_addr = a; exp1_reqsize = 2'b01; exp1_re = 0; exp1_we = 0;
            @(posedge clk);
            @(negedge clk); exp1_re = 1;
            @(posedge clk);
            @(negedge clk); exp1_re = 0;
            repeat (2) @(posedge clk);
            #1; d = exp1_rdata;
        end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end else
                $display("  ok: %0s = %04h", what, got);
        end
    endtask

    // issue a PACKET (0xA0) command + 12-byte CDB (only CDB[0]=opcode matters to atapi.v)
    task packet_send(input [7:0] op);
        integer w; begin
            exp1_write(24'h48000e, 16'h00A0);          // PACKET command
            exp1_write(24'h480000, {8'h00, op});       // CDB word0 (opcode in low byte)
            for (w = 0; w < 5; w = w + 1) exp1_write(24'h480000, 16'h0000);
        end
    endtask

    // bounded BSY-clear poll, like the BIOS's 0xf690-loop status wait (trace pc
    // 0x803cb304): commands with a response-build window (READ TOC's metadata
    // lookup) legally show BSY for a few cycles before raising DRQ.
    task wait_not_busy(input [255:0] what);
        integer p; reg [15:0] s; begin
            s = 16'h0080;
            for (p = 0; p < 64 && (s & 16'h0080) !== 16'h0000; p = p + 1)
                exp1_read(24'h48000e, s);
            if ((s & 16'h0080) !== 16'h0000) begin
                $display("FAIL: BSY stuck (%0s)", what);
                errors = errors + 1;
            end
        end
    endtask

    reg [15:0] v;
    integer i;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- ide_reset() : write 0 then 1 to 0x1f560000 ----
        exp1_write(24'h560000, 16'h0000);
        repeat (4) @(posedge clk);
        exp1_write(24'h560000, 16'h0001);
        repeat (4) @(posedge clk);

        // ---- signature-detect (0x803cb6d8) ----
        // STATUS @0x48000e must have BSY (bit7) clear -- THE gate that times out on HW.
        exp1_read(24'h48000e, v);
        if (v[7] !== 1'b0) begin $display("FAIL: STATUS BSY stuck (%04h) -- signature-detect would time out", v); errors=errors+1; end
        else $display("  ok: STATUS BSY clear (%04h)", v);
        // signature: ERROR&0xf==1, bclo==0x14, bchi==0xEB  (0xEB14 ATAPI)
        exp1_read(24'h480002, v); chk(v & 16'h000f, 16'h0001, "sig ERROR&0xf");
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h0014, "sig bclo");
        exp1_read(24'h48000a, v); chk(v & 16'h00ff, 16'h00eb, "sig bchi");

        // ---- IDENTIFY (0x803cb7c4): device select, devctl, features, byte count, 0xA1 ----
        exp1_write(24'h48000c, 16'h00a0);   // reg6 device/head = 0xA0
        exp1_write(24'h4c000c, 16'h0008);   // control block: device control = 8
        exp1_write(24'h480002, 16'h0000);   // features = 0
        exp1_write(24'h48000a, 16'h0008);   // byte count hi (BIOS sets 0x0800 limit)
        exp1_write(24'h480008, 16'h0000);   // byte count lo
        exp1_write(24'h48000e, 16'h00a1);   // command = 0xA1 IDENTIFY PACKET DEVICE

        // after 0xA1: DRQ (bit3) set, ERR (bit0) clear; byte count 0x0200
        exp1_read(24'h48000e, v);
        chk({12'd0, v[3], 3'd0} & 16'h0008, 16'h0008, "IDENT DRQ set");
        if (v[0] !== 1'b0) begin $display("FAIL: IDENT ERR set (%04h)", v); errors=errors+1; end
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h0000, "IDENT bclo");
        exp1_read(24'h48000a, v); chk(v & 16'h00ff, 16'h0002, "IDENT bchi");

        // read the 256-word identify block from the data register
        for (i = 0; i < 256; i = i + 1) exp1_read(24'h480000, v);

        // completion: STATUS back to DRDY|DSC (0x50), ERR clear
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0050, "IDENT done STATUS");

        // ---- the previously-missing CD-ROM init PACKET commands (Tier A) ----
        // REQUEST SENSE (0x03): 16-byte data-in, sense key 0; BIOS requires byte-count==0x10.
        packet_send(8'h03);
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0048, "REQSENSE DRQ");
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h0010, "REQSENSE byte count");
        exp1_read(24'h480000, v); chk(v, 16'h0070, "REQSENSE word0");                 // {resp[1],resp[0]} = 0x0070
        exp1_read(24'h480000, v); chk(v & 16'h00ff, 16'h0000, "REQSENSE key=0");       // {resp[3],resp[2]} low = key 0
        for (i = 2; i < 8; i = i + 1) exp1_read(24'h480000, v);                        // 8 data words total = 16 bytes
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0050, "REQSENSE done");

        // READ TOC (0x43): 12-byte data-in; BIOS requires byte-count==12.
        // (the dynamic TOC build holds BSY for the s573_cdtoc lookup - poll like the BIOS)
        packet_send(8'h43);
        wait_not_busy("READTOC");
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0048, "READTOC DRQ");
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h000C, "READTOC byte count");
        for (i = 0; i < 6; i = i + 1) exp1_read(24'h480000, v);                        // 6 words = 12 bytes
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0050, "READTOC done");

        // MODE SENSE(10) (0x5A): 24-byte data-in; BIOS requires byte-count==0x18.
        packet_send(8'h5A);
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0048, "MODESENSE DRQ");
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h0018, "MODESENSE byte count");
        for (i = 0; i < 12; i = i + 1) exp1_read(24'h480000, v);                       // 12 words = 24 bytes
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0050, "MODESENSE done");

        // MODE SELECT(10) (0x55): 24-byte data-OUT; BIOS requires byte-count==0x18, ireason data-out.
        packet_send(8'h55);
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0048, "MODESEL DRQ");
        exp1_read(24'h480004, v); chk(v & 16'h00ff, 16'h0000, "MODESEL ireason dataout"); // C/D=0,I/O=0
        exp1_read(24'h480008, v); chk(v & 16'h00ff, 16'h0018, "MODESEL byte count");
        for (i = 0; i < 12; i = i + 1) exp1_write(24'h480000, 16'h0000);               // host writes 24 bytes
        exp1_read(24'h48000e, v); chk(v & 16'h00ff, 16'h0050, "MODESEL done");

        if (errors == 0) $display("RESULT: PASS (drivecheck)");
        else             $display("RESULT: FAIL (drivecheck, %0d errors)", errors);
        $finish;
    end
endmodule
