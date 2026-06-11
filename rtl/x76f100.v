// -----------------------------------------------------------------------------
// x76f100.v - Xicor X76F100 secure serial flash EEPROM (security cartridge)
//
// System 573 security cartridges carry a Xicor X76F100 (112-byte secured serial
// flash) alongside the DS2401 serial number. The BIOS bit-bangs an I2C-like
// protocol through the Konami ASIC I/O control/status register (CS, RST, SCL and
// a bidirectional SDA) to authenticate with an 8-byte password and then read or
// write the 112 data bytes.
//
// This model reproduces the protocol exactly as documented by MAME's
// machine/x76f100.cpp (the authoritative reverse-engineered reference):
//
//   * RST 0->1 (while CS low) starts a 4-byte "response to reset" stream
//     (0x19,0x00,0xAA,0x55) clocked out LSB-first on each FALLING SCL edge,
//     looping until a start condition.
//   * A start condition (SDA 1->0 while SCL high) from STOP begins a command.
//   * Command / password / write-data bytes are clocked in MSB-first on RISING
//     SCL edges; the device drives an ACK (SDA low) on the 9th clock of each.
//   * Command byte:  bit7=1,bit0=1 => READ ; bit7=1,bit0=0 => WRITE.
//     bits[4:1] select an 8-byte block:  offset = ((cmd>>1)&0x0f)*8 + byte.
//   * After 8 password bytes the device compares against the read password
//     (for READ commands) or the write password (for WRITE), then waits for a
//     0x55 ACK-password byte: if the password matched it enters READ/WRITE and
//     ACKs (SDA low), otherwise it NAKs (SDA high).
//   * READ streams data MSB-first; the master ACKs (SDA low) each byte to
//     advance. WRITE buffers 8 bytes then flushes them to the selected block
//     (or replaces the read/write password for commands 0xFE / 0xFC).
//   * Eight consecutive failed password attempts zero the passwords and data.
//
// SDA is modeled with two unidirectional signals, exactly as the 573 ASIC wires
// it: sda_i is the level the host drives, sda_o is the level the device drives
// (1 = released/high, 0 = pulled low). Passwords and data are NVRAM and persist
// across the (volatile) system reset; only the bit-bang state machine is reset.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module x76f100 #(
    parameter [63:0] READ_PASSWORD  = 64'h0000_0000_0000_0000,
    parameter [63:0] WRITE_PASSWORD = 64'h0000_0000_0000_0000
)(
    input  wire clk,        // system clock (the model samples the pins on this)
    input  wire rst,        // system reset: clears the volatile bit-bang state
    input  wire cs,         // chip select, active low (0 = selected)
    input  wire sec_rst,    // chip RST pin, active high (0->1 = response to reset)
    input  wire scl,        // serial clock
    input  wire sda_i,      // SDA driven by the host (1 = released/high)
    output reg  sda_o,      // SDA driven by the device (1 = high, 0 = low)

    // ---- boot-time NVRAM image load (the 132-byte MAME x76f100 nvram image) ----
    // Streamed in byte-by-byte at boot from the security-EEPROM ioctl channel. The
    // image layout (machine/x76f100.cpp nvram_read/nvram_write order) is:
    //   [  0:  3] response-to-reset (4 bytes, 0x19,0x00,0xAA,0x55) -- IGNORED here
    //            (the RTR constant is hard-wired in rtr_val()); accepted + dropped.
    //   [  4: 11] write password    (8 bytes)  -> wpw[0..7]
    //   [ 12: 19] read  password    (8 bytes)  -> rpw[0..7]
    //   [ 20:131] 112 data bytes               -> data[0..111]
    // load_we writes load_data at byte address load_addr (0..131). When any byte is
    // loaded, `loaded` latches and the loaded NVRAM overrides the compile-time params
    // (params stay the default for sims that never drive the load port). Byte order is
    // chosen so rpw[0] == .u1[12] == the FIRST read-password byte the master sends, so
    // the ST_PW compare (wbuf[j] vs rpw[j], j ascending) matches MSB-first as on HW.
    input  wire        load_we,
    input  wire [9:0]  load_addr,   // 0..131
    input  wire [7:0]  load_data
);
    // ---- states (match MAME state_t order) ----
    localparam [2:0] ST_STOP     = 3'd0,
                     ST_RTR      = 3'd1, // response to reset
                     ST_CMD      = 3'd2, // load command
                     ST_PW       = 3'd3, // load password
                     ST_VERIFY   = 3'd4, // verify password (await 0x55 ack)
                     ST_READ     = 3'd5,
                     ST_WRITE    = 3'd6;

    // ---- command constants ----
    localparam [7:0] CMD_ACK     = 8'h55,
                     CMD_CHG_WPW = 8'hfc,
                     CMD_CHG_RPW = 8'hfe;

    // ---- NVRAM (persists across system reset) ----
    // data[] is the 112-byte EEPROM body. Like the X76F041 it is accessed through a
    // SINGLE synchronous write port and a SINGLE registered read port so Quartus
    // infers it as block RAM rather than 896 flip-flops + a computed-index address
    // mux. The 8-byte block write is serialised to one byte per clock by a small
    // burst engine; the protocol read drives the address one cycle ahead and
    // consumes the registered byte. The deterministic k->k default pattern is a
    // RAM-init (block-RAM friendly) so existing read-default tests still pass. The
    // small 8-byte register files (wpw/rpw/wbuf) stay as registers.
    reg [7:0] data [0:111];
    reg [7:0] wpw  [0:7];   // write password
    reg [7:0] rpw  [0:7];   // read password
    reg [7:0] wbuf [0:7];   // input byte buffer (password / write data)

    // ---- image-load byte-offset map (MAME x76f100 nvram layout) ----
    // 4-byte RTR header at [0:3] is consumed but not stored (RTR is constant).
    localparam integer LD_WPW  = 4;     // write password [4:11]
    localparam integer LD_RPW  = 12;    // read  password [12:19]
    localparam integer LD_DATA = 20;    // 112 data bytes [20:131]

    // High once any image byte has been loaded (the loaded NVRAM is authoritative;
    // before that the compile-time params remain in effect so existing sims pass).
    reg loaded = 1'b0;

    integer k;
    initial begin
        for (k = 0; k < 8;   k = k + 1) begin
            wpw[k] = WRITE_PASSWORD[8*(7-k) +: 8];
            rpw[k] = READ_PASSWORD [8*(7-k) +: 8];
            wbuf[k] = 8'h00;
        end
        for (k = 0; k < 112; k = k + 1)
            data[k] = k[7:0]; // deterministic default pattern for simulation
    end

    // ---- data[] single write port + registered read port (block-RAM friendly) ----
    // Read port: rd_addr is driven one cycle ahead (rd_addr_next, below) and the
    // byte lands in data_rdata; with two cycles of latency the address is stable for
    // the ~9 idle clocks per serial bit, so the byte is ready when shifted out.
    // Write port: one byte per clock, from the block-flush burst engine.
    localparam [1:0] BRST_IDLE = 2'd0, BRST_WRITE = 2'd1;
    reg [1:0] brst_state;
    reg [3:0] brst_idx;        // 0..8 burst byte index
    reg [7:0] brst_buf [0:7];  // the 8 bytes to write
    reg [6:0] brst_base;       // block base offset {command[4:1],3'b000}
    reg       brst_kick;       // 1-clock pulse: FSM requests a block flush

    reg [6:0] ram_waddr;
    reg [7:0] ram_wdata;
    reg       ram_we;
    reg [6:0] rd_addr;
    reg [7:0] data_rdata;

    // ---- volatile state ----
    reg [2:0] state;
    reg [3:0] bitc;     // 0..8 (8 = ACK clock)
    reg [7:0] bytec;    // byte index (read can run past one block)
    reg [7:0] shift;
    reg [7:0] command;
    reg [3:0] retry;    // failed-password counter
    reg       pw_ok;

    // ---- edge detection ----
    reg pscl, pcs, psda, prst;

    // response-to-reset byte by index (mod 4)
    function [7:0] rtr_val(input [7:0] b);
        case (b[1:0])
            2'd0: rtr_val = 8'h19;
            2'd1: rtr_val = 8'h00;
            2'd2: rtr_val = 8'haa;
            default: rtr_val = 8'h55;
        endcase
    endfunction

    // temporaries
    reg [7:0] s;
    reg       match;
    integer   j;

    // ----- data[] read address, one cycle ahead of the ST_READ consumer -----
    // The read offset {command[4:1],3'b000}+bytec can run past the 112-byte body
    // (the device streams 0x00 there). Track an in-range address and an OOB flag so
    // the registered read returns the right byte (or 0) when shifted out.
    wire [7:0] rd_off_next = {command[4:1], 3'b000} + bytec;
    wire       rd_oob_next = (rd_off_next >= 8'd112);
    reg        rd_oob;

    // ----- RAM port: the ONLY place data[] is read or written (block-RAM cell) -----
    always @(posedge clk) begin
        rd_addr    <= rd_oob_next ? 7'd0 : rd_off_next[6:0];
        rd_oob     <= rd_oob_next;
        data_rdata <= data[rd_addr];
        if (ram_we) data[ram_waddr] <= ram_wdata;
    end

    always @(posedge clk) begin
        // one-shot default
        ram_we <= 1'b0;

        // ===== boot-time NVRAM image load (runs even while rst is asserted) =====
        // Small register files are written directly; the 112-byte body goes through the
        // single write port. The 4-byte RTR header is dropped. (Boot load completes long
        // before any protocol edge, so it never overlaps the block-flush burst engine.)
        if (load_we) begin
            loaded <= 1'b1;
            if (load_addr >= LD_DATA[9:0]) begin
                ram_we    <= 1'b1;
                ram_waddr <= (load_addr - LD_DATA[9:0]); // 0..111 (low 7 bits)
                ram_wdata <= load_data;
            end else if (load_addr >= LD_RPW[9:0])
                rpw[load_addr - LD_RPW[9:0]] <= load_data;
            else if (load_addr >= LD_WPW[9:0])
                wpw[load_addr - LD_WPW[9:0]] <= load_data;
            // load_addr < LD_WPW (0..3): the 4-byte RTR header -- accepted and dropped
            // (RtR is hard-wired in rtr_val()).
        end

        // ===== write-burst engine: serialise the 8-byte block flush to one byte /
        // clock (a block flush only starts on a rising-SCL edge, ~9 idle clocks
        // apart, so the burst completes before the next edge and never overlaps a
        // protocol read -- ST_READ vs ST_WRITE are distinct states). =====
        case (brst_state)
            BRST_IDLE: if (brst_kick) begin
                brst_idx   <= 4'd0;
                brst_state <= BRST_WRITE;
            end
            BRST_WRITE: begin
                if (brst_idx < 4'd8) begin
                    if (({1'b0, brst_base} + {4'd0, brst_idx}) < 8'd112) begin
                        ram_we    <= 1'b1;
                        ram_waddr <= brst_base + {3'd0, brst_idx};
                        ram_wdata <= brst_buf[brst_idx];
                    end
                    brst_idx <= brst_idx + 4'd1;
                end else
                    brst_state <= BRST_IDLE;
            end
            default: brst_state <= BRST_IDLE;
        endcase

        if (rst) begin
            state   <= ST_STOP;
            bitc    <= 4'd0;
            bytec   <= 8'd0;
            shift   <= 8'd0;
            command <= 8'd0;
            retry   <= 4'd0;
            pw_ok   <= 1'b0;
            sda_o   <= 1'b0;
            brst_kick <= 1'b0;
            for (j = 0; j < 8; j = j + 1) wbuf[j] <= 8'h00;
        end else begin
            brst_kick <= 1'b0;   // FSM burst request is a one-shot pulse
            // ===== chip select transitions =====
            if (pcs != 1'b0 && cs == 1'b0)              // enable: 1->0
                state <= ST_STOP;
            if (pcs == 1'b0 && cs != 1'b0) begin        // disable: 0->1
                state <= ST_STOP;
                sda_o <= 1'b0;
            end

            if (cs == 1'b0) begin
                // ===== RST pin: response to reset =====
                if (prst == 1'b0 && sec_rst != 1'b0) begin
                    state <= ST_RTR;
                    bitc  <= 4'd0;
                    bytec <= 8'd0;
                end

                // ===== start / stop conditions (SDA edge while SCL high) =====
                if (scl != 1'b0) begin
                    if (psda == 1'b0 && sda_i != 1'b0) begin     // stop: SDA 0->1
                        state <= ST_STOP;
                        sda_o <= 1'b0;
                    end else if (psda != 1'b0 && sda_i == 1'b0) begin // start: 1->0
                        if (state == ST_STOP)
                            state <= ST_CMD;
                        bitc  <= 4'd0;
                        bytec <= 8'd0;
                        shift <= 8'd0;
                        sda_o <= 1'b0;
                    end
                end

                // ===== SCL clocking =====
                // Response-to-reset clocks out on the FALLING edge, LSB-first.
                if (state == ST_RTR && pscl != 1'b0 && scl == 1'b0) begin
                    s     = (bitc == 4'd0) ? rtr_val(bytec) : shift;
                    sda_o <= s[0];
                    shift <= s >> 1;
                    if (bitc == 4'd7) begin
                        bitc  <= 4'd0;
                        bytec <= (bytec == 8'd3) ? 8'd0 : bytec + 8'd1;
                    end else
                        bitc <= bitc + 4'd1;
                end

                // Everything else is processed on the RISING edge.
                if (pscl == 1'b0 && scl != 1'b0) begin
                    if (state == ST_CMD || state == ST_PW ||
                        state == ST_VERIFY || state == ST_WRITE) begin
                        if (bitc < 4'd8) begin
                            shift <= {shift[6:0], sda_i}; // MSB-first
                            bitc  <= bitc + 4'd1;
                        end else begin
                            // 9th clock: drive ACK low, then act on the byte
                            sda_o <= 1'b0;
                            bitc  <= 4'd0;
                            shift <= 8'd0;
                            case (state)
                                ST_CMD: begin
                                    command <= shift;
                                    state   <= ST_PW;
                                    bytec   <= 8'd0;
                                end
                                ST_PW: begin
                                    wbuf[bytec] <= shift;
                                    if (bytec == 8'd7) begin
                                        state <= ST_VERIFY;
                                        // compare against selected password
                                        // (read pw if (cmd & 0xe1)==0x81)
                                        match = 1'b1;
                                        for (j = 0; j < 7; j = j + 1) begin
                                            if (((command & 8'he1) == 8'h81)
                                                  ? (wbuf[j] != rpw[j])
                                                  : (wbuf[j] != wpw[j]))
                                                match = 1'b0;
                                        end
                                        if (((command & 8'he1) == 8'h81)
                                              ? (shift != rpw[7])
                                              : (shift != wpw[7]))
                                            match = 1'b0;
                                        pw_ok <= match;
                                        if (!match) begin
                                            if (retry == 4'd7) begin
                                                // lockout: zero the passwords.
                                                // synthesis translate_off
                                                // SIM-ONLY: 16-byte clocked password
                                                // clear. The 8-fail lockout never trips
                                                // at BIOS boot -- the cart is read, not
                                                // brute-forced. (data[] is the M10K body
                                                // and is not bulk-cleared from here; it
                                                // has a single write port.)
                                                for (j = 0; j < 8; j = j + 1) begin
                                                    rpw[j] <= 8'h00;
                                                    wpw[j] <= 8'h00;
                                                end
                                                // synthesis translate_on
                                                retry <= 4'd0;
                                            end else
                                                retry <= retry + 4'd1;
                                        end
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                                ST_VERIFY: begin
                                    if (shift == CMD_ACK) begin
                                        if (pw_ok) begin
                                            retry <= 4'd0;
                                            if ((command & 8'h81) == 8'h81)
                                                state <= ST_READ;
                                            else if ((command & 8'h81) == 8'h80)
                                                state <= ST_WRITE;
                                        end else
                                            sda_o <= 1'b1; // NAK
                                    end
                                end
                                ST_WRITE: begin
                                    wbuf[bytec] <= shift;
                                    if (bytec == 8'd7) begin
                                        if (command == CMD_CHG_WPW) begin
                                            for (j = 0; j < 7; j = j + 1)
                                                wpw[j] <= wbuf[j];
                                            wpw[7] <= shift;
                                        end else if (command == CMD_CHG_RPW) begin
                                            for (j = 0; j < 7; j = j + 1)
                                                rpw[j] <= wbuf[j];
                                            rpw[7] <= shift;
                                        end else begin
                                            // hand the 8-byte block to the burst engine,
                                            // which serialises it to the single data[]
                                            // write port (one byte per clock).
                                            for (j = 0; j < 7; j = j + 1) brst_buf[j] <= wbuf[j];
                                            brst_buf[7] <= shift;
                                            brst_base   <= {command[4:1], 3'b000};
                                            brst_kick   <= 1'b1;
                                        end
                                        bytec <= 8'd0;
                                    end else
                                        bytec <= bytec + 8'd1;
                                end
                            endcase
                        end
                    end else if (state == ST_READ) begin
                        if (bitc < 4'd8) begin
                            if (bitc == 4'd0)
                                // registered read: data_rdata == data[off] (rd_addr
                                // tracked the offset one cycle ahead); rd_oob streams
                                // 0x00 for offsets past the 112-byte body.
                                s = rd_oob ? 8'h00 : data_rdata;
                            else
                                s = shift;
                            sda_o <= s[7];
                            shift <= s << 1;
                            bitc  <= bitc + 4'd1;
                        end else begin
                            bitc  <= 4'd0;
                            sda_o <= 1'b0;
                            if (sda_i == 1'b0)        // master ACK -> next byte
                                bytec <= bytec + 8'd1;
                        end
                    end
                end
            end

            // ---- register the pins for edge detection ----
            pscl <= scl;
            pcs  <= cs;
            psda <= sda_i;
            prst <= sec_rst;
        end
    end
endmodule
