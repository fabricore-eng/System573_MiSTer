// -----------------------------------------------------------------------------
// adc0838.v - National Semiconductor ADC0838 8-channel serial ADC (slave model)
//
// The System 573 analog I/O board (and the XI security cassette) reads analog
// inputs through an ADC0838, the 8-channel sibling of the ADC0834. Same serial
// link, but the MUX address word is 5 bits and selects one of eight channels.
//
// Protocol (ADC0838, single-ended MUX mode):
//   * Activate with /CS low.
//   * Clock in 5 bits on DI, MSB first, sampled on the rising edge of CLK:
//       start(1), SGL/DIF, ODD/SIGN, SELECT1, SELECT0
//     The single-ended channel is  {SELECT1, SELECT0, ODD/SIGN}  (CH0..CH7).
//   * One "dummy"/SARS low clock, then the 8-bit result shifts out MSB first,
//     changing on the falling edge of CLK.
//   * Raising /CS ends the conversion.
//
// Channel conversion values are supplied through the ch* ports.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module adc0838 (
    input  wire       clk,
    input  wire       rst,
    input  wire       cs_n,
    input  wire       adc_clk,
    input  wire       di,
    output reg        do_o,
    output reg        sars,
    input  wire [7:0] ch0, ch1, ch2, ch3, ch4, ch5, ch6, ch7
);
    reg adc_clk_d;
    wire clk_rise = (adc_clk & ~adc_clk_d);
    wire clk_fall = (~adc_clk & adc_clk_d);

    localparam [2:0] S_IDLE=3'd0, S_ADDR=3'd1, S_SARS=3'd2, S_DATA=3'd3;

    reg [2:0] state;
    reg [2:0] addr_cnt;   // counts address bits clocked in (need 5)
    reg [4:0] addr_sh;    // start, SGL/DIF, ODD, SEL1, SEL0
    reg [3:0] data_cnt;
    reg [7:0] data_sh;

    // single-ended channel = {SEL1, SEL0, ODD/SIGN}
    function [7:0] sel_channel(input [4:0] a);
        case ({a[1], a[0], a[2]})
            3'd0: sel_channel = ch0;
            3'd1: sel_channel = ch1;
            3'd2: sel_channel = ch2;
            3'd3: sel_channel = ch3;
            3'd4: sel_channel = ch4;
            3'd5: sel_channel = ch5;
            3'd6: sel_channel = ch6;
            3'd7: sel_channel = ch7;
        endcase
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            adc_clk_d <= 1'b0; state <= S_IDLE; do_o <= 1'b0; sars <= 1'b0;
            addr_cnt <= 0; addr_sh <= 0; data_cnt <= 0; data_sh <= 0;
        end else begin
            adc_clk_d <= adc_clk;
            if (cs_n) begin
                state <= S_IDLE; do_o <= 1'b0; sars <= 1'b0;
                addr_cnt <= 0; data_cnt <= 0;
            end else begin
                case (state)
                    S_IDLE: begin state <= S_ADDR; addr_cnt <= 0; sars <= 1'b0; end
                    S_ADDR: if (clk_rise) begin
                        addr_sh  <= {addr_sh[3:0], di};      // MSB first
                        addr_cnt <= addr_cnt + 3'd1;
                        if (addr_cnt == 3'd4) state <= S_SARS;   // 5th bit captured
                    end
                    S_SARS: begin
                        sars <= 1'b1;
                        if (clk_fall) begin
                            data_sh  <= sel_channel(addr_sh);
                            data_cnt <= 0;
                            state    <= S_DATA;
                        end
                    end
                    S_DATA: if (clk_fall) begin
                        do_o     <= data_sh[7];
                        data_sh  <= {data_sh[6:0], 1'b0};
                        data_cnt <= data_cnt + 4'd1;
                        if (data_cnt == 4'd7) begin sars <= 1'b0; state <= S_IDLE; end
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
