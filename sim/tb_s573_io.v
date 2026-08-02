`timescale 1ns/1ps
// Testbench for s573_io.v - control register decode and input read muxing.
module tb_s573_io;
    reg clk = 0, rst = 1;
    reg sel = 0, we = 0, re = 0;
    reg [3:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;

    reg [3:0]  dip_sw = 4'hA;
    reg [7:0]  p1_ctrl = 8'h5A, p2_ctrl = 8'hC3;
    reg [1:0]  coin_sw = 2'b10;
    reg        service_btn = 1, test_btn = 1;
    reg        btn5_p1 = 1, btn5_p2 = 1;     // active-low, idle (not pressed)
    reg [1:0]  pcmcia_present = 2'b01;
    reg [7:0]  sec_in = 8'hE7;
    reg        sec_io0 = 1, sec_irdy = 1, sec_drdy = 0;
    reg        adc_do = 1, adc_sars = 0;

    wire adc_di, adc_cs_n, adc_clk;
    wire [1:0] coin_counter;
    wire audio_amp_en, audio_mute, spu_dac_en, jvs_mcu_rst_n;
    integer errors = 0;

    s573_io dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout),
        .dip_sw(dip_sw), .p1_ctrl(p1_ctrl), .p2_ctrl(p2_ctrl),
        .coin_sw(coin_sw), .service_btn(service_btn), .test_btn(test_btn),
        .btn5_p1(btn5_p1), .btn5_p2(btn5_p2),
        .pcmcia_present(pcmcia_present),
        .sec_in(sec_in), .sec_io0(sec_io0), .sec_irdy(sec_irdy), .sec_drdy(sec_drdy),
        .adc_do(adc_do), .adc_sars(adc_sars),
        .adc_di(adc_di), .adc_cs_n(adc_cs_n), .adc_clk(adc_clk),
        .coin_counter(coin_counter), .audio_amp_en(audio_amp_en),
        .audio_mute(audio_mute), .spu_dac_en(spu_dac_en),
        .jvs_mcu_rst_n(jvs_mcu_rst_n)
    );

    always #5 clk = ~clk;

    task wr_ctrl(input [15:0] d);
        begin
            @(negedge clk); sel = 1; off = 4'h0; din = d; we = 1;
            @(posedge clk);
            @(negedge clk); we = 0; sel = 0;
        end
    endtask

    task rd_reg(input [3:0] o, output [15:0] d);
        begin
            sel = 1; re = 1; off = o; #1; d = dout;
            @(negedge clk); re = 0; sel = 0;
        end
    endtask

    task chk(input [15:0] g, input [15:0] e, input [127:0] name);
        begin
            if (g !== e) begin
                $display("FAIL: %0s got %04h expected %04h", name, g, e);
                errors = errors + 1;
            end
        end
    endtask

    // Executable oracle for the hyperbbc JVS/H8 boot decision (no CPU): models ONLY the
    // boot-relevant branch of the game's I/O detect (flash 0x8017153c). A regression that
    // flips JVS sense back to 0 OR drives tx-write-ready to 1 FAILS here instead of silently
    // re-hanging hyperbbc on hardware.
    task detect_decision;
        reg [15:0] m;
        reg sense, rx_ready, tx_wr_ready;
        begin
            rd_reg(4'h6, m);
            sense       = m[3];
            rx_ready    = m[4];
            tx_wr_ready = m[5];
            if (sense !== 1'b1) begin
                $display("FAIL: detect_decision -- jvs_sense=0 dead-ends detect OFF the graceful-skip path (hyperbbc hangs on NG)");
                errors = errors + 1;
            end else if (tx_wr_ready === 1'b1) begin
                $display("FAIL: detect_decision -- tx-write-ready=1 lets JVS send 'succeed'; game then blocks on a JVS reply that never comes");
                errors = errors + 1;
            end else begin
                if (rx_ready !== 1'b0)
                    $display("NOTE: detect_decision -- rx_ready=1 unexpected (would enter RX path)");
                $display("INFO: detect_decision -- sense=1, tx/rx idle -> detect returns negative -> graceful skip -> hyperbbc BOOTS");
            end
        end
    endtask

    reg [15:0] r;
    initial begin
        repeat (3) @(posedge clk); @(negedge clk); rst = 0;

        // Control register: drive a pattern and check decoded outputs.
        // bit0 DI, bit1 /CS, bit2 CLK, bits4:3 coin, bit5 amp, bit6 mute,
        // bit7 dac, bit8 jvs_rst_n
        wr_ctrl(16'b1_0101_1101);  // = 0x015D
        if ({jvs_mcu_rst_n, spu_dac_en, audio_mute, audio_amp_en, coin_counter,
             adc_clk, adc_cs_n, adc_di} !== 9'b1_0_1_0_11_1_0_1) begin
            $display("FAIL: control decode = %b", {jvs_mcu_rst_n, spu_dac_en,
                     audio_mute, audio_amp_en, coin_counter, adc_clk, adc_cs_n, adc_di});
            errors = errors + 1;
        end

        // 0x04 status -- MAME IN1 (konami/ksys573.cpp) low half: [14] = cassette
        // DS2401 (read_line_ds2401 = sec_in[0]), [12] = "Network?" = Off(1),
        // [9:8] = cassette ADC0834 SARS/DO (absent on a digital cart -> 0),
        // [7:4] = H8/18E response nibble 0xC, [3:0] = DIP. (bcaf9a4 remapped the
        // RTL to this layout; this check previously expected the pre-fix
        // {sec_in, 0xC, dip} placement.)
        rd_reg(4'h4, r);
        chk(r, {1'b0, sec_in[0], 1'b0, 1'b1, 2'b00, 2'b00, 4'b1100, dip_sw}, "status");
        // explicit 18E gate: bits[7:4] must read the H8 response nibble 0xC (h8a01.bin)
        chk({12'h0, r[7:4]}, 16'h000C, "h8_18E_nibble");

        // 0x08 JAMMA: {p1, p2}
        rd_reg(4'h8, r); chk(r, {p1_ctrl, p2_ctrl}, "jamma");

        // 0x06 misc: service@12, pcmcia@11:10, coin@9:8, drdy@7, irdy@6, io0@2,
        //            sars@1, do@0
        rd_reg(4'h6, r);
        chk(r, {3'b000, service_btn, pcmcia_present, coin_sw, sec_drdy, sec_irdy,
                2'b00, 1'b1, sec_io0, adc_sars, adc_do}, "misc");
        // --- hyperbbc JVS/H8 boot-handshake contract: the I/O detect reads these EXACT bits;
        //     they must match MAME so detect returns NEGATIVE -> graceful "I/O board absent"
        //     skip instead of the red "NG" hang. ---
        chk({15'h0, r[3]}, 16'h0001, "jvs_sense=1");         // .06[3] sense MUST be 1
        chk({15'h0, r[4]}, 16'h0000, "jvs_rx_ready=0");      // .06[4] rx-ready stays 0
        chk({15'h0, r[5]}, 16'h0000, "jvs_tx_writeready=0"); // .06[5] tx-ready stays 0
        rd_reg(4'h4, r);
        chk({14'h0, r[5:4]}, 16'h0000, "jvs_tx_start_ready"); // .04[5:4]=0 (low of 0xC nibble)
        chk({14'h0, r[7:6]}, 16'h0003, "h8_hi_classifier");   // .04[7:6]=11 (hi of 0xC)
        detect_decision;

        // 0x0c extra (P1): test@bit10; button5@bit9 (Solo "Select L"); 4/6 idle HIGH
        rd_reg(4'hc, r); chk(r, {4'b0, 1'b1, test_btn, btn5_p1, 1'b1, 8'b0}, "extra 0x0c");
        // 0x0e extra (P2): bit10 = RAM-layout strap (0=new); button5@bit9 ("Select R")
        rd_reg(4'he, r); chk(r, {4'b0, 1'b1, 1'b0,      btn5_p2, 1'b1, 8'b0}, "extra 0x0e");

        // --- IO-004 SEPARATION CONTRACT ---------------------------------------------
        // On a DDR Solo cabinet the song wheel and the dance panels live in DIFFERENT
        // registers: the wheel is IN3 bit9 (0x0c / 0x0e), the panels are the JAMMA word
        // (0x08). Each must move ONLY its own. This is the whole IO-004 bug expressed as
        // assertions -- with the Select lines pinned to a constant, pressing them moved
        // nothing at all, so the first two checks below are the discriminators.
        begin : io004_separation
            reg [15:0] b08, b0c, b0e;
            rd_reg(4'h8, b08); rd_reg(4'hc, b0c); rd_reg(4'he, b0e);

            btn5_p1 = 0; #1;                                   // press "Select L"
            rd_reg(4'hc, r); chk(r ^ b0c, 16'h0200, "selL->IN3lo b9");
            rd_reg(4'h8, r); chk(r ^ b08, 16'h0000, "selL !JAMMA");
            rd_reg(4'he, r); chk(r ^ b0e, 16'h0000, "selL !IN3hi");
            btn5_p1 = 1; #1;

            btn5_p2 = 0; #1;                                   // press "Select R"
            rd_reg(4'he, r); chk(r ^ b0e, 16'h0200, "selR->IN3hi b9");
            rd_reg(4'h8, r); chk(r ^ b08, 16'h0000, "selR !JAMMA");
            rd_reg(4'hc, r); chk(r ^ b0c, 16'h0000, "selR !IN3lo");
            btn5_p2 = 1; #1;

            // converse: stepping on a panel must move ONLY the JAMMA word
            p1_ctrl = 8'hA5; #1;
            rd_reg(4'hc, r); chk(r ^ b0c, 16'h0000, "panel !IN3lo");
            rd_reg(4'he, r); chk(r ^ b0e, 16'h0000, "panel !IN3hi");
            p1_ctrl = 8'h5A; #1;                               // restore
        end

        if (errors == 0) $display("RESULT: PASS (s573_io)");
        else             $display("RESULT: FAIL (s573_io, %0d errors)", errors);
        $finish;
    end
endmodule
