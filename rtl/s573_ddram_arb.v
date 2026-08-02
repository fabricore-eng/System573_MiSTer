// -----------------------------------------------------------------------------
// s573_ddram_arb.v - DDR3 (f2sdram) port arbiter: PSX master + 573 DIO-RAM client
//
// The MiSTer DDRAM port out of emu.sv has ONE master today: the vendored PSX
// core (psx_mister.vhd pins DDRAM_ADDR[28:25]="0011", i.e. everything it does
// lives in the 0x30000000..0x3FFFFFFF byte window: VRAM at +0, memcard staging
// at +1M/+2M, SPU RAM at +3M, GPU display framebuffers at +4M, the savestate
// rewind buffer at +128M and the savestate slots at +224M).
//
// This arbiter inserts a second, strictly lower-priority client: the BEMANI
// Digital I/O board's 32 MiB sample RAM (k573dio BACKING_EXTERNAL mode), windowed
// at byte 0x32000000..0x33FFFFFF (see PLATFORM.md "DDR3 map") -- clear of every
// PSX region above.
//
// Policy (lean -- the ALM budget is tight):
//   * The PSX master ALWAYS wins. Its port is a combinational passthrough; the
//     DIO client gets the bus only in a cycle where the PSX side is completely
//     idle: no command asserted, zero outstanding read beats, not mid write-burst.
//   * A DIO op is always a SINGLE beat (BURSTCNT=1). While its command is on the
//     bus the PSX side sees a fake DDRAM_BUSY -- legal Avalon (the real f2sdram
//     port asserts BUSY arbitrarily anyway, it is shared with the scaler/HPS).
//   * Read-return routing needs no tags: a DIO read is only issued with zero PSX
//     beats outstanding, and no PSX read command can be ACCEPTED before the DIO
//     command (fake BUSY holds it), so the first DDRAM_DOUT_READY after a DIO
//     read command is the DIO beat; it is eaten from the PSX side (masked).
//   * A 16-bit DIO write is a native byte-enable write (BE = 2 lanes) -- no
//     read-modify-write.
//
// The DIO channel is a pair of 4-phase level handshakes driven from the clk_1x
// 573 fabric; this module runs in the DDRAM_CLK (clk_2x) domain. clk_1x/clk_2x
// are same-PLL, edge-aligned, so level sampling across is an ordinary related-
// clock path (the PSX core relies on the same relationship throughout).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_ddram_arb #(
    // 64-bit-beat base of the DIO RAM window: byte 0x32000000 >> 3. Must be
    // 32 MiB aligned (low 22 beat-index bits zero) so the window index ORs in.
    parameter [28:0] DIO_BASE_BEAT = 29'h0640_0000
)(
    input  wire        clk,             // DDRAM_CLK domain (clk_2x)
    input  wire        rst,

    // ---- upstream: the real MiSTer DDRAM port ----
    input  wire        ddr_busy,
    output wire [7:0]  ddr_burstcnt,
    output wire [28:0] ddr_addr,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output wire        ddr_rd,
    output wire [63:0] ddr_din,
    output wire [7:0]  ddr_be,
    output wire        ddr_we,

    // ---- PSX master (priority; combinational passthrough) ----
    output wire        psx_busy,
    input  wire [7:0]  psx_burstcnt,
    input  wire [28:0] psx_addr,
    output wire [63:0] psx_dout,
    output wire        psx_dout_ready,
    input  wire        psx_rd,
    input  wire [63:0] psx_din,
    input  wire [7:0]  psx_be,
    input  wire        psx_we,

    // ---- DIO client (4-phase level handshakes from the clk_1x fabric) ----
    // read: one 64-bit beat
    input  wire        dio_rd_req,
    input  wire [21:0] dio_rd_addr,     // beat index within the 32 MiB window
    output reg  [63:0] dio_rd_data,
    output reg         dio_rd_ack,
    // write: one 16-bit word, posted by the client's FIFO
    input  wire        dio_wr_req,
    input  wire [23:0] dio_wr_addr,     // 16-bit word index within the window
    input  wire [15:0] dio_wr_data,
    output reg         dio_wr_ack
);
    localparam [1:0] D_IDLE = 2'd0,  // passthrough; watch for a grantable DIO op
                     D_CMD  = 2'd1,  // DIO command on the bus, awaiting !ddr_busy
                     D_DATA = 2'd2,  // DIO read issued, awaiting its DOUT_READY
                     D_END  = 2'd3;  // ack held, waiting for the req to drop

    reg [1:0] dstate;
    reg       d_rd;                  // current DIO op is a read

    // PSX-side transaction tracking. rd_pend counts read beats issued-but-not-
    // returned (+= BURSTCNT per accepted read command, -= 1 per routed beat).
    // wr_rem counts the write-burst beats still owed after an accepted WE (Avalon
    // masters may gap WE mid-burst, and the slave counts beats from the first
    // command's burstcount -- a DIO op interleaved mid-burst would corrupt it).
    reg [11:0] rd_pend;
    reg [7:0]  wr_rem;

    wire psx_rd_acc = psx_rd & ~psx_busy;
    wire psx_wr_acc = psx_we & ~psx_busy;
    wire psx_rdy    = ddr_dout_ready & (dstate != D_DATA);

    // A DIO op may start only when the whole PSX side is quiescent.
    wire dio_wr_pend = dio_wr_req & ~dio_wr_ack;
    wire dio_rd_pend = dio_rd_req & ~dio_rd_ack;
    wire psx_idle    = ~psx_rd & ~psx_we & (rd_pend == 12'd0) & (wr_rem == 8'd0);

    // ---- downstream mux ----
    wire        dio_own  = (dstate == D_CMD);
    wire [21:0] dio_beat = d_rd ? dio_rd_addr : dio_wr_addr[23:2];
    // 16-bit lane byte-enables: word index bits [1:0] = byte address [2:1]
    wire [7:0]  dio_wbe  = 8'h03 << {dio_wr_addr[1:0], 1'b0};

    assign ddr_addr     = dio_own ? (DIO_BASE_BEAT | {7'd0, dio_beat}) : psx_addr;
    assign ddr_burstcnt = dio_own ? 8'd1                : psx_burstcnt;
    assign ddr_din      = dio_own ? {4{dio_wr_data}}    : psx_din;
    assign ddr_be       = dio_own ? (d_rd ? 8'hFF : dio_wbe) : psx_be;
    assign ddr_rd       = dio_own ? d_rd                : psx_rd;
    assign ddr_we       = dio_own ? ~d_rd               : psx_we;

    assign psx_busy       = ddr_busy | dio_own;
    assign psx_dout       = ddr_dout;
    assign psx_dout_ready = ddr_dout_ready & (dstate != D_DATA);

    always @(posedge clk) begin
        if (rst) begin
            dstate      <= D_IDLE;
            d_rd        <= 1'b0;
            rd_pend     <= 12'd0;
            wr_rem      <= 8'd0;
            dio_rd_ack  <= 1'b0;
            dio_wr_ack  <= 1'b0;
            dio_rd_data <= 64'd0;
        end else begin
            // PSX transaction tracking (accept and return can coincide)
            rd_pend <= rd_pend + (psx_rd_acc ? {4'd0, psx_burstcnt} : 12'd0)
                               - (psx_rdy    ? 12'd1                : 12'd0);
            if (psx_wr_acc)
                wr_rem <= (wr_rem == 8'd0) ? (psx_burstcnt - 8'd1) : (wr_rem - 8'd1);

            case (dstate)
                D_IDLE: if ((dio_wr_pend | dio_rd_pend) && psx_idle) begin
                    d_rd   <= ~dio_wr_pend;      // drain writes first
                    dstate <= D_CMD;
                end
                D_CMD: if (!ddr_busy) begin      // command accepted this cycle
                    if (d_rd)
                        dstate <= D_DATA;
                    else begin
                        dio_wr_ack <= 1'b1;
                        dstate     <= D_END;
                    end
                end
                D_DATA: if (ddr_dout_ready) begin
                    dio_rd_data <= ddr_dout;
                    dio_rd_ack  <= 1'b1;
                    dstate      <= D_END;
                end
                D_END: if (d_rd ? ~dio_rd_req : ~dio_wr_req) begin
                    dio_rd_ack <= 1'b0;
                    dio_wr_ack <= 1'b0;
                    dstate     <= D_IDLE;
                end
            endcase
        end
    end
endmodule
