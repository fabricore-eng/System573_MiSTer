// -----------------------------------------------------------------------------
// zs01.v - Konami ZS01 (NS2K001) security-cartridge PIC, high-level model
//
// The ZS01 is a PIC microcontroller used on later System 573 security carts. It
// speaks the same CS/RST/SCL/SDA serial lines as the X76 EEPROMs but wraps every
// access in a fixed-size, obfuscated, CRC-checked packet rather than a bit-banged
// command/password handshake:
//
//   * RST 0->1 (CS low) streams a 4-byte response-to-reset (0x5A,0x53,0x00,0x01)
//     MSB-first on FALLING SCL edges, then stops on its own.
//   * A start condition moves STOP -> LOAD_COMMAND; the host clocks in a 12-byte
//     packet MSB-first (device ACKs each byte on the 9th clock).
//   * The 12 bytes are descrambled with the fixed 8-byte command key; if command
//     bit2 is set the 8 data bytes get a second descramble with the per-cart data
//     key. A CRC-16/CCITT (poly 0x1021, init 0xFFFF, inverted) over bytes 0..9 is
//     checked against bytes 10..11.
//   * Packet = [command][address][8 data][crc16].  command bit0: 0=write,1=read.
//     data_offset = address*8 into 112 data bytes; addresses 0xFC/0xFD read the
//     internal DS2401, 0xFE the config registers, 0xFF sets the data key, 0xFD
//     write erases the data + data key.
//   * The device builds a 12-byte response [status][..][8 data][crc16], scrambles
//     it with the *response key* (the 8 data bytes the host sent on a read), and
//     the host clocks it back out, ACKing each byte.
//
// The scramble is a custom byte cipher (NOT DES): key[0] is an additive term and
// key[1..7] are (rotate, add) pairs, CBC-chained on the ciphertext byte. This is
// a faithful transliteration of MAME's src/mame/konami/zs01.cpp. The heavy packet
// transform is performed in a single behavioral step (the reference is itself an
// HLE of the PIC); the surrounding serial framing is a clocked FSM.
//
// SDA is split into host-driven (sda_i) and device-driven (sda_o) levels, as the
// 573 ASIC wires IO0. Data, keys and config registers persist across the
// (volatile) system reset.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module zs01 #(
    parameter [63:0] COMMAND_KEY = 64'hED68_504B_C644_483E, // fixed PIC command key
    parameter [63:0] DATA_KEY    = 64'h0000_0000_0000_0000, // per-cart (set via 0xFF)
    parameter [63:0] CONFIG_INIT = 64'h0000_0000_FF00_0000, // 8 config regs (RR=idx4)
    parameter [63:0] DS2401_ID   = 64'h0102_0304_0506_0708  // internal serial number
)(
    input  wire clk,
    input  wire rst,        // system reset: clears volatile framing state
    input  wire cs,         // chip select, active low (0 = selected)
    input  wire sec_rst,    // chip RST pin, active high (0->1 = response to reset)
    input  wire scl,
    input  wire sda_i,      // SDA driven by the host (1 = released/high)
    output reg  sda_o       // SDA driven by the device
);
    localparam [1:0] ST_STOP = 2'd0, ST_RTR = 2'd1, ST_CMD = 2'd2, ST_READ = 2'd3;
    localparam [7:0] STATUS_OK = 8'h00, STATUS_ERROR = 8'h02;
    localparam integer CONFIG_RR = 4, CONFIG_RC = 5;

    // ---- NVRAM (persists across system reset) ----
    reg [7:0] wbuf [0:11];
    reg [7:0] rbuf [0:11];
    reg [7:0] dkey [0:7];   // data key (mutable)
    reg [7:0] rkey [0:7];   // response key (set per read)
    reg [7:0] creg [0:7];   // configuration registers
    reg [7:0] data [0:111];

    integer ii;
    initial begin
        for (ii = 0; ii < 8;  ii = ii + 1) begin
            dkey[ii] = DATA_KEY   [8*(7-ii) +: 8];
            creg[ii] = CONFIG_INIT[8*(7-ii) +: 8];
            rkey[ii] = 8'h00;
        end
        for (ii = 0; ii < 12;  ii = ii + 1) begin wbuf[ii] = 0; rbuf[ii] = 0; end
        for (ii = 0; ii < 112; ii = ii + 1) data[ii] = ii[7:0];
    end

    // ---- volatile framing state ----
    reg [1:0] state;
    reg [3:0] bitc;
    reg [7:0] bytec;
    reg [7:0] shift;
    reg [7:0] prevbyte;     // m_previous_byte (data-key chain seed)
    reg       pscl, psda, prst;

    function [7:0] rtr_val(input [7:0] b);
        case (b[1:0])
            2'd0: rtr_val = 8'h5a;
            2'd1: rtr_val = 8'h53;
            2'd2: rtr_val = 8'h00;
            default: rtr_val = 8'h01;
        endcase
    endfunction
    function [7:0] ds_byte(input integer k); ds_byte = DS2401_ID[8*k +: 8]; endfunction
    function [7:0] ror8(input [7:0] x, input [2:0] r); ror8 = (x >> r) | (x << ((4'd8-r) & 3'd7)); endfunction
    function [7:0] rol8(input [7:0] x, input [2:0] r); rol8 = (x << r) | (x >> ((4'd8-r) & 3'd7)); endfunction

    // CRC-16/CCITT over 10 bytes, init 0xFFFF, MSB-first, final inversion.
    function [15:0] calc_crc10(input [79:0] d);
        integer a3, a2; reg [15:0] v; reg [7:0] b;
        begin
            v = 16'hffff;
            for (a3 = 0; a3 < 10; a3 = a3 + 1) begin
                b = d[8*(9-a3) +: 8];
                v = v ^ {b, 8'h00};
                for (a2 = 0; a2 < 8; a2 = a2 + 1)
                    v = v[15] ? ((v << 1) ^ 16'h1021) : (v << 1);
            end
            calc_crc10 = ~v;
        end
    endfunction

    // ---- the packet cipher (faithful to MAME decrypt/decrypt2/encrypt) ----
    // descending descramble of wbuf[0..11] with the command key, prev seed 0xFF
    task decrypt_cmd;
        integer idx, kk; reg [7:0] prev, t1, t0, kb;
        begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                t1 = wbuf[idx]; t0 = t1;
                for (kk = 7; kk >= 1; kk = kk - 1) begin
                    kb = COMMAND_KEY[8*(7-kk) +: 8];
                    t0 = t0 - (kb & 8'h1f);
                    t0 = ror8(t0, kb[7:5]);
                end
                wbuf[idx] = (t0 - COMMAND_KEY[63:56]) ^ prev;
                prev = t1;
            end
        end
    endtask
    // ascending second descramble of the 8 data bytes wbuf[2..9] with the data key
    task decrypt_data(input [7:0] prev0);
        integer idx, kk; reg [7:0] prev, t1, t0, kb;
        begin
            prev = prev0;
            for (idx = 2; idx <= 9; idx = idx + 1) begin
                t1 = wbuf[idx]; t0 = t1;
                for (kk = 7; kk >= 1; kk = kk - 1) begin
                    kb = dkey[kk];
                    t0 = t0 - (kb & 8'h1f);
                    t0 = ror8(t0, kb[7:5]);
                end
                wbuf[idx] = (t0 - dkey[0]) ^ prev;
                prev = t1;
            end
        end
    endtask
    // descending scramble of rbuf[0..11] with the response key, prev seed 0xFF
    task encrypt_resp;
        integer idx, kk; reg [7:0] prev, acc, kb;
        begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                acc = rkey[0] + (rbuf[idx] ^ prev);
                for (kk = 1; kk <= 7; kk = kk + 1) begin
                    kb  = rkey[kk];
                    acc = rol8(acc, kb[7:5]);
                    acc = acc + (kb & 8'h1f);
                end
                rbuf[idx] = acc;
                prev = acc;
            end
        end
    endtask

    integer i;
    reg [15:0] crcv, msgcrc, crc2;
    reg [11:0] off;
    reg [7:0]  pbnext;
    reg [7:0]  sbyte;

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_STOP; bitc <= 0; bytec <= 0; shift <= 0;
            prevbyte <= 0; sda_o <= 1'b0;
        end else begin
            if (cs == 1'b0) begin
                // ----- RST pin: response to reset -----
                if (prst == 1'b0 && sec_rst != 1'b0) begin
                    state <= ST_RTR; bitc <= 0; bytec <= 0;
                end
                // ----- start condition (SDA 1->0 while SCL high) -----
                if (scl != 1'b0 && psda != 1'b0 && sda_i == 1'b0) begin
                    if (state == ST_STOP) state <= ST_CMD;
                    bitc <= 0; bytec <= 0; shift <= 0; sda_o <= 1'b0;
                end
                // ----- response-to-reset: FALLING edge, MSB-first -----
                if (state == ST_RTR && pscl != 1'b0 && scl == 1'b0) begin
                    sbyte = (bitc == 4'd0) ? rtr_val(bytec) : shift;
                    sda_o <= sbyte[7];
                    shift <= sbyte << 1;
                    if (bitc == 4'd7) begin
                        bitc <= 0;
                        if (bytec == 8'd3) begin sda_o <= 1'b1; state <= ST_STOP; bytec <= 0; end
                        else bytec <= bytec + 8'd1;
                    end else
                        bitc <= bitc + 4'd1;
                end
                // ----- SCL rising edge: command load / response read -----
                if (pscl == 1'b0 && scl != 1'b0) begin
                    if (state == ST_CMD) begin
                        if (bitc < 4'd8) begin
                            shift <= {shift[6:0], sda_i};
                            bitc  <= bitc + 4'd1;
                        end else begin
                            sda_o <= 1'b0;
                            bitc  <= 4'd0;
                            shift <= 8'd0;
                            wbuf[bytec] = shift;                 // store byte
                            if (bytec == 8'd11) begin
                                // synthesis translate_off
                                // SIM-ONLY: the ZS01 security-packet engine -- unrolled
                                // decrypt/encrypt ciphers + CRC + two 112-byte clocked
                                // full-array clears, all in one clock edge. Quartus-
                                // hostile, and the security cart is bypassed at BIOS boot
                                // (gchgchmp no-security path), so it never runs there.
                                // ===== full packet processing (behavioral) =====
                                decrypt_cmd;
                                if (wbuf[0] & 8'h04) decrypt_data(prevbyte);
                                crcv   = calc_crc10({wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4],
                                                     wbuf[5],wbuf[6],wbuf[7],wbuf[8],wbuf[9]});
                                msgcrc = {wbuf[10], wbuf[11]};
                                for (i = 0; i < 12; i = i + 1) rbuf[i] = 8'h00;
                                if (crcv == msgcrc) begin
                                    creg[CONFIG_RC] = 8'h00;
                                    rbuf[0] = STATUS_OK;
                                    off = {wbuf[1], 3'b000};     // address * 8
                                    if (wbuf[0][0] == 1'b0) begin
                                        // ---- WRITE ----
                                        if (wbuf[1] == 8'hfd) begin
                                            for (i = 0; i < 112; i = i + 1) data[i] = 8'h00;
                                            for (i = 0; i < 8;   i = i + 1) dkey[i] = 8'h00;
                                        end else if (wbuf[1] == 8'hfe) begin
                                            for (i = 0; i < 8; i = i + 1) creg[i] = wbuf[2+i];
                                        end else if (wbuf[1] == 8'hff) begin
                                            for (i = 0; i < 8; i = i + 1) dkey[i] = wbuf[2+i];
                                        end else if (off < 12'd112) begin
                                            for (i = 0; i < 8; i = i + 1) data[off+i] = wbuf[2+i];
                                        end
                                    end else begin
                                        // ---- READ ----
                                        if (wbuf[1] == 8'hfc || wbuf[1] == 8'hfd) begin
                                            for (i = 0; i < 8; i = i + 1) rbuf[2+i] = ds_byte(7-i);
                                        end else if (wbuf[1] == 8'hfe) begin
                                            for (i = 0; i < 8; i = i + 1) rbuf[2+i] = creg[i];
                                        end else if (off < 12'd112) begin
                                            for (i = 0; i < 8; i = i + 1) rbuf[2+i] = data[off+i];
                                        end
                                        for (i = 0; i < 8; i = i + 1) rkey[i] = wbuf[2+i];
                                    end
                                end else begin
                                    rbuf[0] = STATUS_ERROR;
                                    creg[CONFIG_RC] = creg[CONFIG_RC] + 8'h01;
                                    if (creg[CONFIG_RC] >= creg[CONFIG_RR]) begin
                                        for (i = 0; i < 112; i = i + 1) data[i] = 8'h00;
                                        for (i = 0; i < 8;   i = i + 1) dkey[i] = 8'h00;
                                    end
                                end
                                pbnext = rbuf[1];
                                crc2 = calc_crc10({rbuf[0],rbuf[1],rbuf[2],rbuf[3],rbuf[4],
                                                   rbuf[5],rbuf[6],rbuf[7],rbuf[8],rbuf[9]});
                                rbuf[10] = crc2[15:8];
                                rbuf[11] = crc2[7:0];
                                encrypt_resp;
                                prevbyte <= pbnext;
                                // synthesis translate_on
                                bytec <= 8'd0;
                                state <= ST_READ;
                            end else
                                bytec <= bytec + 8'd1;
                        end
                    end else if (state == ST_READ) begin
                        if (bitc < 4'd8) begin
                            sbyte = (bitc == 4'd0) ? rbuf[bytec] : shift;
                            sda_o <= sbyte[7];
                            shift <= sbyte << 1;
                            bitc  <= bitc + 4'd1;
                        end else begin
                            bitc  <= 4'd0;
                            sda_o <= 1'b0;
                            if (sda_i == 1'b0) begin                 // master ACK
                                if (bytec == 8'd11) begin
                                    bytec <= 8'd0; sda_o <= 1'b1; state <= ST_CMD;
                                end else
                                    bytec <= bytec + 8'd1;
                            end
                        end
                    end
                end
            end
            pscl <= scl;
            psda <= sda_i;
            prst <= sec_rst;
        end
    end
endmodule
