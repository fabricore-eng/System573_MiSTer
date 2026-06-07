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
// 573 ASIC wires IO0. NOTE the real ZS01 cassette wires SDA-out on a SEPARATE line
// from the X76 carts: per k573cass.cpp the ZI cassette leaves D0 unconnected and
// drives ZS01 SDA from the CONTROL register bit 6 (write_line_zs01_sda, active-low);
// SCL/CS/RST stay on the D1/D2/D3 data-latch bits and the read-back uses the same
// secflash_sda path. The glue (s573_seccart.v) routes sda_i for type 2 accordingly;
// this module just sees sda_i/sda_o. Data, keys and config registers persist across
// the (volatile) system reset.
//
// --- boot-time NVRAM image load (the gtrfrk5m gea26jaa.u1 ZS01 dump) ---
// The .u1 is the raw MAME zs01 nvram image (machine konami/zs01.cpp nvram_read order):
//   [  0:  3] response-to-reset (4 bytes, 0x5A,0x53,0x00,0x01) -- IGNORED here (the
//             RTR constant is hard-wired in rtr_val()); accepted + dropped.
//   [  4: 11] command key  (8 bytes) -> cmdkey[0..7]  (fixed PIC key, same on all carts)
//   [ 12: 19] data key     (8 bytes) -> dkey[0..7]    (the PER-CART key -- it is IN the
//             dump, NOT set at runtime, so loading the .u1 establishes authentication)
//   [ 20: 27] config regs  (8 bytes) -> creg[0..7]    (RR=idx4, RC=idx5)
//   [ 28:139] 112 data bytes        -> data[0..111]
// gtrfrk5m's gea26jaa.u1 is 4116 bytes = this 140-byte image + zero padding (the real
// 4 KB EEPROM body; MAME only models the first 112 bytes, so we load [28:139] and drop
// the rest). load_we writes load_data at byte address load_addr; the first loaded byte
// latches `loaded`, after which the loaded NVRAM overrides the compile-time params (the
// params stay the default for sims -- e.g. tb_zs01 -- that never drive the load port).
//
// --- Synthesis note (the 112-byte data array is an M10K block RAM) ---
// data[] is accessed through a SINGLE synchronous write port (the boot image load)
// and a single registered read port, exactly mirroring the M10K-friendly template in
// the fixed rtl/x76f041.v (commit d0d9f61): one clocked block, registered read
// `data_rdata <= data[rd_addr]`, single muxed write `if (ram_we) data[ram_waddr] <=
// ram_wdata`, NO combinational/computed-index reads and NO `initial` fill that blocks
// inference. The packet engine's data reads/writes (the off+i loop) live inside the
// `synthesis translate_off` SIM-ONLY block, so they never synthesize -- in hardware
// data[] is only ever written by the load port and read through data_rdata, the
// canonical block-RAM access pattern. The small register files (cmdkey/dkey/rkey/creg/
// wbuf/rbuf) stay as registers (8-12 bytes each).
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
    output reg  sda_o,      // SDA driven by the device

    // ---- boot-time NVRAM image load (the 140-byte MAME zs01 nvram image) ----
    // Streamed in byte-by-byte at boot from the security-EEPROM ioctl channel
    // (index 4). load_addr is the file byte index 0..4115 (the real .u1 may carry
    // trailing zero padding past the 140-byte image; addresses >= 140 are dropped).
    input  wire        load_we,
    input  wire [12:0] load_addr,  // 0..4115 (12-bit covers the padded .u1)
    input  wire [7:0]  load_data,

    // ---- internal DS2401 serial load (the .u6 image, file byte index 0..7) ----
    // The ZI cassette's single DS2401 is read both on D4 (the board path) AND
    // internally by the ZS01 (the 0xFC/0xFD addresses). MAME's internal read returns
    // direct_read(7-i) = file byte 7-i; our ds_byte(k) returns file byte k, so we load
    // dsid[k] = .u6 file byte k. Defaults to the DS2401_ID param when not loaded.
    input  wire        load_ds_we,
    input  wire [2:0]  load_ds_addr,  // file byte index 0..7
    input  wire [7:0]  load_ds_data
);
    localparam [1:0] ST_STOP = 2'd0, ST_RTR = 2'd1, ST_CMD = 2'd2, ST_READ = 2'd3;
    localparam [7:0] STATUS_OK = 8'h00, STATUS_ERROR = 8'h02;
    localparam integer CONFIG_RR = 4, CONFIG_RC = 5;

    // ---- image-load byte-offset map (MAME zs01.cpp nvram layout) ----
    // 4-byte RTR header at [0:3] is consumed but not stored (RTR is constant).
    localparam integer LD_CMDKEY = 4;    // command key      [4:11]
    localparam integer LD_DKEY   = 12;   // data key         [12:19]
    localparam integer LD_CREG   = 20;   // config registers [20:27]
    localparam integer LD_DATA   = 28;   // 112 data bytes   [28:139]
    localparam integer LD_DATA_END = LD_DATA + 112; // 140 (exclusive)

    // ---- NVRAM (persists across system reset) ----
    // data[] is the 112-byte EEPROM body -- single write port + registered read port
    // (see below) so it infers as one M10K block (the fixed x76f041.v pattern).
    reg [7:0] wbuf   [0:11];
    reg [7:0] rbuf   [0:11];
    reg [7:0] cmdkey [0:7];  // command key (fixed PIC key; loadable from the .u1)
    reg [7:0] dkey   [0:7];  // data key (per-cart; loaded from .u1, mutable via 0xFF)
    reg [7:0] rkey   [0:7];  // response key (set per read)
    reg [7:0] creg   [0:7];  // configuration registers
    reg [7:0] dsid   [0:7];  // internal DS2401 serial (file byte k -> dsid[k])
    reg [7:0] data   [0:111];

    // High once any image byte has been loaded (the loaded NVRAM is authoritative;
    // before that the compile-time params remain in effect so existing sims pass).
    reg loaded = 1'b0;

    integer ii;
    initial begin
        for (ii = 0; ii < 8;  ii = ii + 1) begin
            cmdkey[ii] = COMMAND_KEY[8*(7-ii) +: 8];
            dkey[ii]   = DATA_KEY   [8*(7-ii) +: 8];
            creg[ii]   = CONFIG_INIT[8*(7-ii) +: 8];
            dsid[ii]   = DS2401_ID  [8*ii     +: 8];  // ds_byte(k)=dsid[k]=file byte k
            rkey[ii]   = 8'h00;
        end
        for (ii = 0; ii < 12;  ii = ii + 1) begin wbuf[ii] = 0; rbuf[ii] = 0; end
    end

    // SIM-ONLY default ramp for data[] (data[i]=i). Kept under translate_off so it is
    // invisible to synthesis and therefore CANNOT block M10K inference; in hardware
    // data[] starts as the (uninitialized) block RAM and is filled by the load port.
    // synthesis translate_off
    integer jj;
    initial for (jj = 0; jj < 112; jj = jj + 1) data[jj] = jj[7:0];
    // synthesis translate_on

    // ---- data[] single synchronous write port + registered read (M10K template) ----
    // The ONLY synthesizable writer of data[] is the boot image load (driven into
    // ram_we/ram_waddr/ram_wdata by the load block in the main always below). The
    // packet engine's data reads/writes live in the SIM-ONLY translate_off block, so
    // in hardware data[] is a pure RAM: written by the load and read through
    // data_rdata -- the same one-clocked-block pattern as the fixed x76f041.v.
    reg [6:0] ram_waddr;
    reg [7:0] ram_wdata;
    reg       ram_we;
    reg [6:0] rd_addr;
    reg [7:0] data_rdata;
    always @(posedge clk) begin
        rd_addr    <= 7'd0;                     // (read port unused in HW; tied for inference)
        data_rdata <= data[rd_addr];            // registered read port
        if (ram_we) data[ram_waddr] <= ram_wdata;
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
    function [7:0] ds_byte(input integer k); ds_byte = dsid[k]; endfunction
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
                    kb = cmdkey[kk];           // loaded command key (== COMMAND_KEY param default)
                    t0 = t0 - (kb & 8'h1f);
                    t0 = ror8(t0, kb[7:5]);
                end
                wbuf[idx] = (t0 - cmdkey[0]) ^ prev;
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
        // ===== boot-time NVRAM image load (runs even while rst is asserted) =====
        // Small register files are written directly; the 112-byte body goes through
        // the single data[] write port (ram_we/ram_waddr/ram_wdata). The 4-byte RTR
        // header and any padding past byte 139 are accepted and dropped.
        ram_we <= 1'b0;                          // one-shot default
        if (load_we) begin
            loaded <= 1'b1;
            if (load_addr >= LD_DATA[12:0] && load_addr < LD_DATA_END[12:0]) begin
                ram_we    <= 1'b1;
                ram_waddr <= load_addr[6:0] - LD_DATA[6:0];   // 0..111
                ram_wdata <= load_data;
            end else if (load_addr >= LD_CREG[12:0] && load_addr < LD_DATA[12:0])
                creg[load_addr - LD_CREG[12:0]]     <= load_data;
            else if (load_addr >= LD_DKEY[12:0] && load_addr < LD_CREG[12:0])
                dkey[load_addr - LD_DKEY[12:0]]     <= load_data;
            else if (load_addr >= LD_CMDKEY[12:0] && load_addr < LD_DKEY[12:0])
                cmdkey[load_addr - LD_CMDKEY[12:0]] <= load_data;
            // load_addr < LD_CMDKEY: the 4-byte RTR header -- accepted and dropped.
            // load_addr >= LD_DATA_END: trailing .u1 padding -- accepted and dropped.
        end
        // internal DS2401 serial (.u6): file byte k -> dsid[k].
        if (load_ds_we) begin
            loaded <= 1'b1;
            dsid[load_ds_addr] <= load_ds_data;
        end

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
