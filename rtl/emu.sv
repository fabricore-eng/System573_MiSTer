//============================================================================
//  Konami System 573 - MiSTer core top level (emu)
//
//  This is the module the MiSTer framework (sys/sys_top.v) instantiates. It is
//  a WIRING SCAFFOLD: it brings up the core clock, instantiates the PlayStation
//  core placeholder (ps1_stub) and the System 573 fabric (system573_top), and
//  shows where host I/O, video and audio connect. It will not produce a picture
//  until ps1_stub is replaced by a real PS1 core (see docs/ROADMAP.md, Phase 1).
//
//  Port list follows the MiSTer Template_MiSTer `emu` convention (trimmed to the
//  signals this scaffold actually uses). Released under the GNU GPL v2.
//============================================================================
module emu (
    input         CLK_50M,
    input         RESET,

    inout  [48:0] HPS_BUS,

    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,
    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output  [1:0] VGA_SL,

    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    input  [31:0] joystick_0,
    input  [31:0] joystick_1
);
    //------------------------------------------------------------------
    // Clocking. A real build derives ~33.8688 MHz (and pixel clocks) from
    // a PLL in sys/. Here we run the fabric from CLK_50M as a placeholder.
    //------------------------------------------------------------------
    wire clk_sys = CLK_50M;
    wire reset   = RESET;

    //------------------------------------------------------------------
    // EXP1 bus between the PS1 core (placeholder) and the 573 fabric.
    //------------------------------------------------------------------
    wire [23:0] exp1_addr;
    wire [15:0] exp1_wdata;
    wire        exp1_we;
    wire        exp1_re;
    wire [15:0] exp1_rdata;

    wire [7:0] vid_r, vid_g, vid_b;
    wire       vid_hs, vid_vs, vid_de;
    wire [15:0] aud_l, aud_r;

    ps1_stub u_ps1 (
        .clk(clk_sys), .rst(reset),
        .exp1_addr(exp1_addr), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_de(vid_de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .aud_l(aud_l), .aud_r(aud_r)
    );

    //------------------------------------------------------------------
    // Map MiSTer joysticks onto the JAMMA inputs (placeholder bit order).
    //------------------------------------------------------------------
    wire [7:0] p1_ctrl = joystick_0[7:0];
    wire [7:0] p2_ctrl = joystick_1[7:0];

    wire [1:0] coin_counter;
    wire       audio_amp_en, audio_mute, spu_dac_en, wdog_reset;

    system573_top u_s573 (
        .clk(clk_sys), .rst(reset),
        .exp1_addr(exp1_addr), .exp1_wdata(exp1_wdata),
        .exp1_we(exp1_we), .exp1_re(exp1_re), .exp1_rdata(exp1_rdata),
        .dip_sw(4'h0), .p1_ctrl(p1_ctrl), .p2_ctrl(p2_ctrl),
        .coin_sw(2'b00), .service_btn(1'b0), .test_btn(1'b0),
        .pcmcia_present(2'b00),
        .adc_ch0(8'h00), .adc_ch1(8'h00), .adc_ch2(8'h00), .adc_ch3(8'h00),
        .coin_counter(coin_counter),
        .audio_amp_en(audio_amp_en), .audio_mute(audio_mute),
        .spu_dac_en(spu_dac_en), .wdog_reset(wdog_reset)
    );

    //------------------------------------------------------------------
    // Video / audio out (driven by the placeholder: blank + silence).
    //------------------------------------------------------------------
    assign CLK_VIDEO = clk_sys;
    assign CE_PIXEL  = 1'b1;
    assign VIDEO_ARX = 13'd4;
    assign VIDEO_ARY = 13'd3;
    assign VGA_R  = vid_r;
    assign VGA_G  = vid_g;
    assign VGA_B  = vid_b;
    assign VGA_HS = vid_hs;
    assign VGA_VS = vid_vs;
    assign VGA_DE = vid_de;
    assign VGA_F1 = 1'b0;
    assign VGA_SL = 2'b00;

    assign AUDIO_L   = (audio_amp_en & ~audio_mute) ? aud_l : 16'h0000;
    assign AUDIO_R   = (audio_amp_en & ~audio_mute) ? aud_r : 16'h0000;
    assign AUDIO_S   = 1'b1;   // signed
    assign AUDIO_MIX = 2'b00;

    // Tie off unused HPS bus bits in the scaffold.
    wire _unused = &{1'b0, HPS_BUS, spu_dac_en, coin_counter, wdog_reset, joystick_0[31:8], joystick_1[31:8]};
endmodule
