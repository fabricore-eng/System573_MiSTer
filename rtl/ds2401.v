// -----------------------------------------------------------------------------
// ds2401.v - Dallas/Maxim DS2401 silicon serial number (1-Wire slave)
//
// System 573 security cartridges (and the Digital I/O board) carry a DS2401
// whose 64-bit ROM the BIOS bit-bangs out over a single open-drain line and
// verifies. The 64-bit ROM is:  family(8'h01) | serial(48) | CRC8(8).
//
// This is a 1-Wire *slave*: it answers the reset/presence handshake and the
// Read-ROM (0x33) command, streaming the 64-bit ROM LSB-first. The CRC8 (Maxim
// polynomial, 0x8C reflected) is computed internally from the family+serial.
//
// The line is modeled as a wired-AND: the environment drives `dq_in` with the
// resolved level (pulled up to 1 by default, low if either side pulls), and the
// slave asserts `dq_pd` to pull it low. Timing is in microseconds derived from
// CLK_FREQ_HZ (set low in simulation for speed; 1 MHz => 1 cycle/us).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module ds2401 #(
    parameter [47:0]  SERIAL      = 48'h0000_0000_0001,
    parameter integer CLK_FREQ_HZ = 1_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire dq_in,    // resolved 1-Wire level (1 = high / idle)
    output reg  dq_pd     // 1 = slave pulls the line low
);
    // Cycles per microsecond (>=1).
    localparam integer CPUS = (CLK_FREQ_HZ >= 1_000_000) ? CLK_FREQ_HZ/1_000_000 : 1;

    // 1-Wire timing thresholds (microseconds).
    localparam integer RESET_MIN      = 300; // master reset low is >=480us
    localparam integer PRESENCE_DELAY = 30;
    localparam integer PRESENCE_WIDTH = 120;
    localparam integer WR_SAMPLE      = 20;  // sample point within a write slot
    localparam integer WR_SLOT_END    = 60;  // fixed write-slot length
    localparam integer RD_DRIVE       = 30;  // how long the slave holds a 0 bit low
    localparam integer RD_SLOT_END    = 60;  // fixed read-slot length

    // ----- ROM contents (family | serial | CRC), built once. -----
    localparam [7:0] FAMILY = 8'h01;
    reg [63:0] rom;

    function [7:0] crc8(input [55:0] data);
        integer i; reg [7:0] c; reg b;
        begin
            c = 8'h00;
            for (i = 0; i < 56; i = i + 1) begin
                b = data[i] ^ c[0];
                c = c >> 1;
                if (b) c = c ^ 8'h8C;
            end
            crc8 = c;
        end
    endfunction

    initial begin
        rom = {crc8({SERIAL, FAMILY}), SERIAL, FAMILY};
    end

    // ----- microsecond time base -----
    reg [15:0] us_div;
    reg        us_tick;
    always @(posedge clk) begin
        if (rst) begin
            us_div  <= 16'd0;
            us_tick <= 1'b0;
        end else if (us_div >= (CPUS-1)) begin
            us_div  <= 16'd0;
            us_tick <= 1'b1;
        end else begin
            us_div  <= us_div + 16'd1;
            us_tick <= 1'b0;
        end
    end

    // ----- FSM (advanced on us_tick) -----
    localparam [2:0] ST_RESET    = 3'd0,
                     ST_PRESENCE = 3'd1,
                     ST_RX_CMD   = 3'd2,
                     ST_TX_ROM   = 3'd3;

    reg [2:0]  state;
    reg        dq_prev;
    reg [9:0]  low_us;
    reg        reset_pending;
    reg [15:0] tmr;
    reg        in_slot;
    reg        captured;
    reg [6:0]  bitcnt;
    reg [7:0]  cmd;

    always @(posedge clk) begin
        if (rst) begin
            state         <= ST_RESET;
            dq_pd         <= 1'b0;
            dq_prev       <= 1'b1;
            low_us        <= 10'd0;
            reset_pending <= 1'b0;
            tmr           <= 16'd0;
            in_slot       <= 1'b0;
            captured      <= 1'b0;
            bitcnt        <= 7'd0;
            cmd           <= 8'd0;
        end else if (us_tick) begin
            // Edge detection at microsecond resolution.
            // (master holds each level for many us, so us-resolution is fine)
            // fell = high->low, rose = low->high
            // computed from dq_prev vs dq_in
            dq_prev <= dq_in;

            // continuous low-time counter for reset detection
            if (!dq_in) low_us <= low_us + 10'd1;
            else        low_us <= 10'd0;

            if (!dq_in && (low_us + 10'd1 >= RESET_MIN[9:0]))
                reset_pending <= 1'b1;

            if (reset_pending && dq_in && !dq_prev) begin
                // line released after a reset pulse -> emit presence
                state         <= ST_PRESENCE;
                reset_pending <= 1'b0;
                tmr           <= 16'd0;
                dq_pd         <= 1'b0;
                in_slot       <= 1'b0;
                bitcnt        <= 7'd0;
                cmd           <= 8'd0;
            end else begin
                case (state)
                    ST_RESET: begin
                        dq_pd <= 1'b0;
                    end

                    ST_PRESENCE: begin
                        tmr <= tmr + 16'd1;
                        if (tmr < PRESENCE_DELAY)
                            dq_pd <= 1'b0;
                        else if (tmr < (PRESENCE_DELAY + PRESENCE_WIDTH))
                            dq_pd <= 1'b1;
                        else begin
                            dq_pd    <= 1'b0;
                            state    <= ST_RX_CMD;
                            in_slot  <= 1'b0;
                            bitcnt   <= 7'd0;
                        end
                    end

                    ST_RX_CMD: begin
                        dq_pd <= 1'b0;
                        if (!in_slot) begin
                            if (dq_prev && !dq_in) begin // falling edge: slot start
                                in_slot  <= 1'b1;
                                tmr      <= 16'd0;
                                captured <= 1'b0;
                            end
                        end else begin
                            tmr <= tmr + 16'd1;
                            if (!captured && tmr >= WR_SAMPLE) begin
                                cmd      <= {dq_in, cmd[7:1]}; // sample, LSB first
                                captured <= 1'b1;
                            end
                            if (tmr >= WR_SLOT_END) begin     // fixed-time slot end
                                in_slot <= 1'b0;
                                bitcnt  <= bitcnt + 7'd1;
                                if (bitcnt == 7'd7) begin
                                    // 8 command bits received
                                    if (cmd == 8'h33) begin
                                        state  <= ST_TX_ROM;
                                        bitcnt <= 7'd0;
                                    end else begin
                                        state  <= ST_RESET;
                                    end
                                end
                            end
                        end
                    end

                    ST_TX_ROM: begin
                        if (!in_slot) begin
                            dq_pd <= 1'b0;
                            if (dq_prev && !dq_in) begin // falling edge: read slot
                                in_slot <= 1'b1;
                                tmr     <= 16'd0;
                                // present the bit immediately (0 => pull low)
                                dq_pd   <= (rom[bitcnt] == 1'b0);
                            end
                        end else begin
                            tmr <= tmr + 16'd1;
                            if (tmr >= RD_DRIVE)
                                dq_pd <= 1'b0;       // release after the drive window
                            if (tmr >= RD_SLOT_END) begin    // fixed-time slot end
                                in_slot <= 1'b0;
                                dq_pd   <= 1'b0;
                                bitcnt  <= bitcnt + 7'd1;
                                if (bitcnt == 7'd63)
                                    state <= ST_RESET;
                            end
                        end
                    end

                    default: state <= ST_RESET;
                endcase
            end
        end
    end
endmodule
