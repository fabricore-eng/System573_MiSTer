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

        // 0x04 status: {sec_in, H8/18E response nibble = 0xC, dip}
        rd_reg(4'h4, r); chk(r, {sec_in, 4'b1100, dip_sw}, "status");
        // explicit 18E gate: bits[7:4] must read the H8 response nibble 0xC (h8a01.bin)
        chk({12'h0, r[7:4]}, 16'h000C, "h8_18E_nibble");

        // 0x08 JAMMA: {p1, p2}
        rd_reg(4'h8, r); chk(r, {p1_ctrl, p2_ctrl}, "jamma");

        // 0x06 misc: service@12, pcmcia@11:10, coin@9:8, drdy@7, irdy@6, io0@2,
        //            sars@1, do@0
        rd_reg(4'h6, r);
        chk(r, {3'b000, service_btn, pcmcia_present, coin_sw, sec_drdy, sec_irdy,
                2'b00, 1'b0, sec_io0, adc_sars, adc_do}, "misc");

        // 0x0c extra: test button at bit 10
        rd_reg(4'hc, r); chk(r, {5'b0, test_btn, 10'b0}, "extra");

        if (errors == 0) $display("RESULT: PASS (s573_io)");
        else             $display("RESULT: FAIL (s573_io, %0d errors)", errors);
        $finish;
    end
endmodule
