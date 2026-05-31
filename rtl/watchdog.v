// -----------------------------------------------------------------------------
// watchdog.v - Konami System 573 board watchdog
//
// The 573 has a hardware watchdog that resets the board unless the CPU strobes
// the clear window (0x1f5c0000) regularly. This models it as a free-running
// counter: every `kick` pulse reloads the counter; if the counter reaches the
// timeout the `reset_out` pulse is asserted (and the counter reloads, so the
// board would be held in/through reset by an external reset controller).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module watchdog #(
    parameter integer TIMEOUT_CYCLES = 32'd1_000_000  // clk_sys cycles before bite
)(
    input  wire clk,
    input  wire rst,        // synchronous reset, active high
    input  wire kick,       // 1-cycle pulse: CPU wrote the watchdog clear window
    output reg  reset_out   // 1-cycle pulse when the watchdog bites
);
    // Width sized to hold TIMEOUT_CYCLES.
    localparam integer CW = 32;
    reg [CW-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt       <= {CW{1'b0}};
            reset_out <= 1'b0;
        end else begin
            reset_out <= 1'b0;
            if (kick) begin
                cnt <= {CW{1'b0}};
            end else if (cnt >= (TIMEOUT_CYCLES - 1)) begin
                cnt       <= {CW{1'b0}};
                reset_out <= 1'b1;   // bite
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
