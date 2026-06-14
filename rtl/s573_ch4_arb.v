// -----------------------------------------------------------------------------
// s573_ch4_arb.v - SDRAM ch4 (onboard-flash read) two-client arbiter
//
// The single SDRAM ch4 port serves TWO read clients:
//   A = the flash SAVE read-back (s573_flash_saver, 128-bit burst per save word)
//   B = the BIOS onboard-flash line-fill (s573_flash, 128-bit burst per cache line)
//
// Originally emu.sv shared ch4 with a bare combinational mux:
//     ch4_addr = a_req ? a_addr : b_addr;   // priority on the 1-cycle req pulse
//     ch4_req  = a_req | b_req;             // OR'd, single shared ch4_ready
// That assumed A and B never overlap (a SAVE fired at OSD-open with the CPU idle).
// The install-complete AUTO-SAVE broke that assumption: it fires while the CPU is
// LIVE (its INITIALIZE-COMPLETE wait loop reads onboard flash), so A and B genuinely
// contend. Two failures resulted, both confirmed on silicon (the .sav came back a
// deterministic ~38%-zeroed bit-subset of the MAME golden, bank-3 worst):
//
//   1) ADDRESS NOT HELD TO SERVICE TIME. The SDRAM controller samples ch4_addr at
//      *service* time (sdram.sv: `... <= {..., ch4_addr[25:1]}` in the ch4 service
//      arm), which is gated behind ch1/ch2/ch3 + refresh and so lands many cycles
//      after the 1-cycle req pulse. The mux presented A's address only DURING a_req,
//      so by service time it had reverted to b_addr -> A's burst read the wrong
//      offset.
//   2) READY CROSS-LATCH. The lone ch4_ready fanned to BOTH clients, so each latched
//      whatever single burst returned regardless of which one had asked for it.
//
// This arbiter owns ch4. It serialises the two clients (at most one outstanding
// transaction), HOLDS the chosen client's address on ch4_addr for the whole
// transaction (req .. ready), and routes ch4_ready back to ONLY the owner. A wins
// ties: a coherent 16 MB save must read every word from its true offset, whereas a
// BIOS line-fill that loses a turn simply re-fills the (briefly) evicted line. The
// CPU is NOT paused -- a 16 MB save spans seconds of SD block writes, and a CPU
// stall that long would trip the 573 watchdog; arbitration keeps the CPU running
// (kicking the watchdog) while each ch4 read stays coherent.
//
// The 128-bit read data (ch4_dout) is NOT carried through here: it is shared
// straight to both clients, each of which latches it only on its own *_ready, so a
// shared data bus is safe given the serialisation above.
//
// Addresses are the final SDRAM BYTE addresses (the parent has already added
// FLASH_START + (word << 1)); the arbiter only holds/selects them.
//
// Each client issues at most one outstanding request: it pulses *_req then waits
// for *_ready before the next, so a single pending slot per client never overflows.
//
// Verified red/green by sim/tb_s573_flash_saver?  no -- by sim/tb_s573_ch4_arb.v
// against a faithful ch4 model that samples the address at service time (the exact
// HW behaviour). The TB FAILs with -DS573_CH4_NOARB (the old bare mux) and PASSes
// with the arbiter. Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_ch4_arb (
    input  wire        clk,
    input  wire        rst,            // synchronous reset (parent: RESET | status[0])

    // ---- client A: flash SAVE read-back (priority) ----
    input  wire        a_req,          // 1-cycle: request a burst
    input  wire [26:0] a_addr,         // SDRAM byte address (parent pre-offset)
    output wire        a_ready,        // 1-cycle: ch4_dout holds A's burst

    // ---- client B: BIOS onboard-flash line-fill ----
    input  wire        b_req,          // 1-cycle: request a burst
    input  wire [26:0] b_addr,         // SDRAM byte address (parent pre-offset)
    output wire        b_ready,        // 1-cycle: ch4_dout holds B's burst

    // ---- shared SDRAM ch4 port ----
    output wire [26:0] ch4_addr,       // held stable req .. ready (service-time safe)
    output wire        ch4_req,        // 1-cycle request into the SDRAM controller
    input  wire        ch4_ready       // 1-cycle: ch4_dout valid (raw, un-routed)
);
    localparam [1:0] ST_IDLE = 2'd0, ST_OWN_A = 2'd1, ST_OWN_B = 2'd2;

    reg [1:0]  own   = ST_IDLE;
    reg [26:0] hold  = 27'd0;          // address presented to ch4 for this transaction
    reg        issue = 1'b0;           // 1-cycle ch4 request

    // one pending slot per client (set on its req pulse, consumed when it wins ch4).
    reg        a_pend = 1'b0;
    reg [26:0] a_hold = 27'd0;
    reg        b_pend = 1'b0;
    reg [26:0] b_hold = 27'd0;

    always @(posedge clk) begin
        issue <= 1'b0;

        // capture incoming requests + their addresses (addr valid during the pulse).
        if (a_req) begin a_pend <= 1'b1; a_hold <= a_addr; end
        if (b_req) begin b_pend <= 1'b1; b_hold <= b_addr; end

        case (own)
            ST_IDLE: begin
                // A wins ties (coherent save) over B (re-fillable line).
                if (a_pend) begin
                    hold   <= a_hold;
                    a_pend <= 1'b0;
                    issue  <= 1'b1;
                    own    <= ST_OWN_A;
                end else if (b_pend) begin
                    hold   <= b_hold;
                    b_pend <= 1'b0;
                    issue  <= 1'b1;
                    own    <= ST_OWN_B;
                end
            end
            // exactly one outstanding transaction; the SDRAM always eventually
            // services ch4 (lowest priority but finite), so ch4_ready always
            // returns -> own can never deadlock.
            default: if (ch4_ready) own <= ST_IDLE;
        endcase

        if (rst) begin
            own    <= ST_IDLE;
            a_pend <= 1'b0;
            b_pend <= 1'b0;
            issue  <= 1'b0;
        end
    end

    assign ch4_addr = hold;
    assign ch4_req  = issue;
    assign a_ready  = ch4_ready & (own == ST_OWN_A);
    assign b_ready  = ch4_ready & (own == ST_OWN_B);
endmodule
