// -----------------------------------------------------------------------------
// ps1_stub.v - PlayStation 1 core integration placeholder
//
// !!! THIS IS NOT A PLAYSTATION. !!!
//
// The System 573 is a PS1, and a real core must sit on top of an actual
// PlayStation core (e.g. MiSTer-devel/PSX_MiSTer: R3000A + GTE + DMA + GPU +
// SPU). Re-implementing that is out of scope for this repository. This module
// documents the interface that core is expected to expose so the 573 glue can be
// wired and elaborated, and stands in as an idle placeholder: it drives no EXP1
// transactions and produces a black screen / silence.
//
// Replacing this with the real core is Phase 1 in docs/ROADMAP.md.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module ps1_stub (
    input  wire        clk,         // ~33.8688 MHz PS1 clock (here: core clk)
    input  wire        rst,

    // EXP1 master: the CPU's window into 573 peripherals. A real PS1 core would
    // drive these from R3000A loads/stores to 0x1f000000-0x1f6fffff.
    output wire [23:0] exp1_addr,
    output wire [15:0] exp1_wdata,
    output wire        exp1_we,
    output wire        exp1_re,
    input  wire [15:0] exp1_rdata,   // returned by the 573 fabric

    // Video (placeholder: forced blank)
    output wire        vid_hs,
    output wire        vid_vs,
    output wire        vid_de,
    output wire [7:0]  vid_r,
    output wire [7:0]  vid_g,
    output wire [7:0]  vid_b,

    // Audio (placeholder: silence)
    output wire [15:0] aud_l,
    output wire [15:0] aud_r
);
    // Idle EXP1 master - issues no transactions.
    assign exp1_addr  = 24'h000000;
    assign exp1_wdata = 16'h0000;
    assign exp1_we    = 1'b0;
    assign exp1_re    = 1'b0;

    // Blank video / silent audio.
    assign vid_hs = 1'b0;
    assign vid_vs = 1'b0;
    assign vid_de = 1'b0;
    assign vid_r  = 8'h00;
    assign vid_g  = 8'h00;
    assign vid_b  = 8'h00;
    assign aud_l  = 16'h0000;
    assign aud_r  = 16'h0000;

    // Keep the unused input from being optimized into a warning storm.
    wire _unused = &{1'b0, exp1_rdata, clk, rst};
endmodule
