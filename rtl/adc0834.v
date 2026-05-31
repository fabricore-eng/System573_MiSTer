// -----------------------------------------------------------------------------
// adc0834.v - National Semiconductor ADC0834 4-channel serial ADC (slave model)
//
// The System 573 reads analog inputs through an ADC0834 that is bit-banged on
// the Konami ASIC control register (DI/`/CS`/CLK at 0x1f400000 bits 0-2, DO read
// back at 0x1f400006 bit 0). This module models the ADC side of that serial
// link so the rest of the core (and software) can talk to it exactly as on real
// hardware.
//
// Protocol (ADC0834, MUX mode):
//   * Activate with /CS low.
//   * Clock in 4 bits on DI, MSB first, sampled on the rising edge of CLK:
//       start(1), SGL/DIF, ODD/SIGN, SELECT1   (SELECT0 is fixed 0 on the '0834)
//   * After the address, DO leaves hi-Z; one "dummy"/SARS low clock, then the
//     8-bit result is shifted out MSB first, changing on the falling edge of CLK.
//   * Raising /CS ends the conversion.
//
// The conversion result for each channel is supplied through the `ch*` ports so
// a testbench (or, later, the MiSTer analog/host side) can drive real values.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module adc0834 (
    input  wire       clk,        // sample clock (oversamples the bit-banged lines)
    input  wire       rst,
    // Serial interface from the Konami ASIC control register
    input  wire       cs_n,       // /CS  (active low)
    input  wire       adc_clk,    // CLK  (bit-bang clock)
    input  wire       di,         // DI   (mux address in)
    output reg        do_o,       // DO   (result out)
    output reg        sars,       // SAR status (high during conversion)
    // Channel conversion values (8-bit) supplied by the host/testbench
    input  wire [7:0] ch0,
    input  wire [7:0] ch1,
    input  wire [7:0] ch2,
    input  wire [7:0] ch3
);
    // Edge-detect the bit-banged clock in the sample-clock domain.
    reg adc_clk_d;
    wire clk_rise = (adc_clk & ~adc_clk_d);
    wire clk_fall = (~adc_clk & adc_clk_d);

    localparam [2:0] S_IDLE  = 3'd0,  // /CS high
                     S_ADDR  = 3'd1,  // shifting in 4 address bits
                     S_SARS  = 3'd2,  // one dummy clock, DO goes active
                     S_DATA  = 3'd3;  // shifting out 8 result bits

    reg [2:0] state;
    reg [2:0] addr_cnt;   // counts address bits clocked in (need 4)
    reg [3:0] addr_sh;    // start, SGL/DIF, ODD, SEL1
    reg [3:0] data_cnt;   // result bits shifted out (need 8)
    reg [7:0] data_sh;

    // Select the channel from the captured address bits.
    // addr_sh = {start, sgl_dif, odd_sign, sel1}; channel = {odd_sign, sel1}.
    function [7:0] sel_channel(input [3:0] a);
        case ({a[1], a[0]})
            2'b00: sel_channel = ch0;
            2'b01: sel_channel = ch2;
            2'b10: sel_channel = ch1;
            2'b11: sel_channel = ch3;
        endcase
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            adc_clk_d <= 1'b0;
            state     <= S_IDLE;
            do_o      <= 1'b0;
            sars      <= 1'b0;
            addr_cnt  <= 3'd0;
            addr_sh   <= 4'd0;
            data_cnt  <= 4'd0;
            data_sh   <= 8'd0;
        end else begin
            adc_clk_d <= adc_clk;

            if (cs_n) begin
                // Deselected: reset the transaction, DO hi-z (model as 0).
                state    <= S_IDLE;
                do_o     <= 1'b0;
                sars     <= 1'b0;
                addr_cnt <= 3'd0;
                data_cnt <= 4'd0;
            end else begin
                case (state)
                    S_IDLE: begin
                        // /CS just went low; begin clocking in the address.
                        state    <= S_ADDR;
                        addr_cnt <= 3'd0;
                        sars     <= 1'b0;
                    end

                    S_ADDR: begin
                        if (clk_rise) begin
                            addr_sh  <= {addr_sh[2:0], di}; // MSB first
                            addr_cnt <= addr_cnt + 3'd1;
                            if (addr_cnt == 3'd3) begin
                                // 4th address bit captured this edge.
                                state <= S_SARS;
                            end
                        end
                    end

                    S_SARS: begin
                        // One dummy clock; latch the selected channel, raise SARS.
                        sars <= 1'b1;
                        if (clk_fall) begin
                            data_sh  <= sel_channel(addr_sh);
                            data_cnt <= 4'd0;
                            state    <= S_DATA;
                        end
                    end

                    S_DATA: begin
                        // Result shifts out MSB first, updated on falling edge.
                        if (clk_fall) begin
                            do_o     <= data_sh[7];
                            data_sh  <= {data_sh[6:0], 1'b0};
                            data_cnt <= data_cnt + 4'd1;
                            if (data_cnt == 4'd7) begin
                                sars  <= 1'b0;
                                state <= S_IDLE;
                            end
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
