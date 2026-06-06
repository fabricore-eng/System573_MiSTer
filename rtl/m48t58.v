// -----------------------------------------------------------------------------
// m48t58.v - ST M48T58 timekeeper (8 KB battery-backed SRAM + BCD RTC)
//
// On the System 573 this lives at 0x1f620000-0x1f623fff. Software accesses it
// 16 bits at a time using only the low byte, so the bus wrapper presents a flat
// byte address 0..8191 here. The real-time clock occupies the top 8 bytes:
//
//   8184 control   bit6 = READ freeze, bit7 = WRITE freeze, bits0-5 calibration
//   8185 seconds   bits0-6 (BCD), bit7 = STOP oscillator
//   8186 minutes   bits0-6 (BCD)
//   8187 hours     bits0-5 (BCD, 24h)
//   8188 day-of-week bits0-2, bit4 century
//   8189 date      bits0-5 (BCD)
//   8190 month     bits0-4 (BCD)
//   8191 year      bits0-7 (BCD)
//
// Freeze semantics (as on the real part):
//   * READ freeze: reads return a coherent snapshot taken when the bit was set,
//     while the oscillator keeps ticking underneath.
//   * WRITE freeze: ticking pauses and software writes go straight into the
//     clock registers; clearing the bit resumes ticking from those values.
//
// A 1 Hz tick is derived from CLK_FREQ_HZ (kept low in simulation for speed).
// Month-length / leap rules are intentionally simplified (date wraps at 31) and
// documented as such.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module m48t58 #(
    parameter integer CLK_FREQ_HZ = 33_868_800
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [12:0] addr,    // byte address 0..8191
    input  wire [7:0]  din,
    input  wire        we,      // 1-cycle write strobe
    output reg  [7:0]  dout,     // async read data
    // NVRAM image load port (e.g. hyperbbc 876ea.22h via ioctl). Streams the 8 KB
    // image into the lower NVRAM array. The load is rst-INDEPENDENT (handled in the
    // dedicated ram[] write block below): emu.sv holds the core reset HIGH for the
    // entire NVRAM ioctl download (reset_or includes nvram_download), so the load MUST
    // land while rst is asserted -- gating it behind rst==0 silently dropped it and the
    // game read a blank NVRAM. Lower priority than a (post-reset) bus write, which never
    // coincides with the download.
    input  wire        nvram_we,
    input  wire [12:0] nvram_addr,
    input  wire [7:0]  nvram_din
);
    localparam [12:0] RTC_BASE = 13'd8184;
    localparam integer DIVMAX  = (CLK_FREQ_HZ > 1) ? CLK_FREQ_HZ - 1 : 0;

    // Plain NVRAM for the lower 8184 bytes.
    reg [7:0] ram [0:8183];

    // Control + live clock registers.
    reg [7:0] ctrl;
    reg [7:0] tsec, tmin, thour, tdow, tdom, tmonth, tyear;
    // Read-freeze snapshot.
    reg [7:0] ssec, smin, shour, sdow, sdom, smonth, syear;

    reg [31:0] divcnt;
    reg        tick;

    wire read_mode  = ctrl[6];
    wire write_mode = ctrl[7];
    wire stopped    = tsec[7];

    wire       addr_is_rtc = (addr >= RTC_BASE);
    wire [2:0] rtc_idx     = addr[2:0]; // 0..7 within RTC bytes

    // BCD increment within [minv..maxv]; returns {carry, next}.
    function [8:0] inc_field(input [7:0] v, input [7:0] minv, input [7:0] maxv);
        begin
            if (v >= maxv)
                inc_field = {1'b1, minv};
            else if (v[3:0] >= 4'd9)
                inc_field = {1'b0, {v[7:4] + 4'd1, 4'd0}};
            else
                inc_field = {1'b0, {v[7:4], v[3:0] + 4'd1}};
        end
    endfunction

    // The 8 KB NVRAM is read synchronously (registered output) so it infers an M10K
    // block RAM instead of ~65k logic registers (Cyclone V block RAM has no async
    // read port). EXP1 is a wait-stated bus: memorymux holds the address stable for
    // an R-delay cycle (EXT_READ_WAIT) before asserting the read strobe, so the
    // 1-cycle NVRAM read latency is absorbed and system573_top captures the settled
    // value while the strobe is asserted. The small RTC register file (top 8 bytes)
    // stays combinational.
    //
    // PRECONDITION: this holds only when the BIOS-programmed EXP1 R-delay >= 1
    // (ext_memctrl(7:4) > 0). The PSX reset default is 3 and the 573 BIOS only
    // raises EXP1 timing for its slow ASIC/flash/RTC, so it is satisfied in
    // practice; if EXP1 R-delay were ever 0, EXT_IDLE -> EXT_READ_NEXT has no
    // settle cycle and a same-cycle read would latch stale NVRAM. The unit test
    // (tb_system573_top exp1_read) models the >=1 settle explicitly.
    reg [7:0] ram_q;
    always @(posedge clk) ram_q <= ram[addr];

    // ----- lower-NVRAM array write port (single write port -> M10K) -----
    // A post-reset bus write takes priority over the ioctl image load. CRITICAL: the
    // image load is rst-INDEPENDENT. emu.sv asserts the core reset for the ENTIRE NVRAM
    // ioctl download stream (reset_or includes nvram_download), so the OLD code -- which
    // gated this write inside the rst==0 branch -- silently DROPPED every load write: the
    // M10K powered up to zeros, and hyperbbc's boot self-test read a blank NVRAM, failed
    // its "GQ876..1998EAA" signature compare (M48T58 @ 0x1f620000), set status bit 0x40,
    // and hung on the red "NG". Loading regardless of rst fixes it. (The flash/BIOS loads
    // worked on HW because their ramdownload path is not gated by the core reset.)
    always @(posedge clk) begin
        if (!rst && we && !addr_is_rtc)
            ram[addr] <= din;                   // bus write to lower NVRAM (post-reset)
        else if (nvram_we && nvram_addr < RTC_BASE)
            ram[nvram_addr] <= nvram_din;        // ioctl image load (any rst state)
    end

    // Read mux (snapshot when READ freeze is active).
    always @(*) begin
        if (addr_is_rtc) begin
            case (rtc_idx)
                3'd0: dout = ctrl;
                3'd1: dout = read_mode ? ssec   : tsec;
                3'd2: dout = read_mode ? smin   : tmin;
                3'd3: dout = read_mode ? shour  : thour;
                3'd4: dout = read_mode ? sdow   : tdow;
                3'd5: dout = read_mode ? sdom   : tdom;
                3'd6: dout = read_mode ? smonth : tmonth;
                3'd7: dout = read_mode ? syear  : tyear;
            endcase
        end else begin
            dout = ram_q;
        end
    end

    reg [8:0] c_sec, c_min, c_hour, c_dom, c_dow, c_month;

    always @(posedge clk) begin
        if (rst) begin
            ctrl  <= 8'h00;
            tsec  <= 8'h00; tmin  <= 8'h00; thour  <= 8'h00;
            tdow  <= 8'h01; tdom  <= 8'h01; tmonth <= 8'h01; tyear <= 8'h00;
            ssec  <= 8'h00; smin  <= 8'h00; shour  <= 8'h00;
            sdow  <= 8'h01; sdom  <= 8'h01; smonth <= 8'h01; syear <= 8'h00;
            divcnt <= 32'd0; tick <= 1'b0;
        end else begin
            // 1 Hz strobe.
            if (divcnt >= DIVMAX[31:0]) begin divcnt <= 32'd0;          tick <= 1'b1; end
            else                        begin divcnt <= divcnt + 32'd1; tick <= 1'b0; end

            // Bus writes to the CLOCK registers (RTC top 8 bytes). The lower-NVRAM
            // array (ram[]) bus write + the ioctl image load live in the dedicated,
            // rst-independent write block above.
            if (we && addr_is_rtc) begin
                case (rtc_idx)
                    3'd0: ctrl   <= din;
                    3'd1: tsec   <= din;
                    3'd2: tmin   <= din;
                    3'd3: thour  <= din;
                    3'd4: tdow   <= din;
                    3'd5: tdom   <= din;
                    3'd6: tmonth <= din;
                    3'd7: tyear  <= din;
                endcase
            end

            // Advance the oscillator (paused in write freeze or when stopped).
            if (tick && !stopped && !write_mode) begin
                c_sec = inc_field(tsec & 8'h7f, 8'h00, 8'h59);
                tsec <= {1'b0, c_sec[6:0]};
                if (c_sec[8]) begin
                    c_min = inc_field(tmin, 8'h00, 8'h59);
                    tmin <= c_min[7:0];
                    if (c_min[8]) begin
                        c_hour = inc_field(thour, 8'h00, 8'h23);
                        thour <= c_hour[7:0];
                        if (c_hour[8]) begin
                            c_dow = inc_field(tdow, 8'h01, 8'h07);
                            c_dom = inc_field(tdom, 8'h01, 8'h31);
                            tdow <= c_dow[7:0];
                            tdom <= c_dom[7:0];
                            if (c_dom[8]) begin
                                c_month = inc_field(tmonth, 8'h01, 8'h12);
                                tmonth <= c_month[7:0];
                                if (c_month[8])
                                    tyear <= inc_field(tyear, 8'h00, 8'h99);
                            end
                        end
                    end
                end
            end

            // Refresh the read snapshot while READ freeze is inactive.
            if (!read_mode) begin
                ssec   <= tsec;  smin  <= tmin;  shour  <= thour;
                sdow   <= tdow;  sdom  <= tdom;  smonth <= tmonth; syear <= tyear;
            end
        end
    end
endmodule
