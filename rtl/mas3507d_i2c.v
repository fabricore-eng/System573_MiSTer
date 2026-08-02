// -----------------------------------------------------------------------------
// mas3507d_i2c.v - minimal MAS3507D MP3-decoder I2C slave (control port only)
//
// The BEMANI Digital I/O board bit-bangs the MAS3507D's I2C control port
// through k573dio register 0xac (bit13 = SCL, bit12 = SDA, open-drain, idle
// high). This module is the SLAVE side: it watches the two host line latches
// and answers through a single SDA pull-down, the same wired-AND idiom as the
// board DS2401 one module over.
//
// Modeled on MAME 0.285 src/devices/sound/mas3507d.cpp (the boot oracle) plus
// MAS3507D datasheet framing; derivation + adversarial verification:
// docs/2026-07-01-ddrsbm-dio-i2c-transactions.md.
//   - START = SDA falling while SCL high (from ANY state), STOP = SDA rising
//     while SCL high. A repeated START preserves the armed read data and byte
//     count (the frame-count read flow depends on that).
//   - Bits sample on rising SCL, MSB first. If one register write moves both
//     lines, SCL applies first, then SDA (MAME mas_i2c_w order): the bit
//     sampled on a rise is the PRE-write SDA, and START/STOP detection uses
//     the POST-write SCL.
//   - Device address: ACKs 0x3a (write) / 0x3b (read) - 7-bit address 0x1d.
//     Anything else is NAKed (SDA released) and the bus is dead to us until
//     the next START/STOP.
//   - Write path: every byte to a validated address is ACKed. Subcommand 0x69
//     ("data read") arms the read-back value = the 32-bit decoded-frame count
//     in MAME's byte order [15:8],[7:0],[31:24],[23:16]. All other bytes
//     (0x68 pipes, 0x6a control, register/memory writes) are accepted and
//     DROPPED - there is no decoder behind this port yet; the drop is loud in
//     sim ($display, DBG-gated, ships OFF) so nothing fails silently.
//   - Read path (address 0x3b): streams the armed value MSB-first per byte,
//     data changing only while SCL is low; unarmed reads stream zeros (MAME
//     zeroes sdao_data on every write byte). Honors the master NACK; serves
//     at most 4 bytes then parks (MAME parks after 3; the game reads 2).
//   - The slave NEVER stretches SCL - SCL readback is the host latch, always
//     (MAME i2c_sclo is set at reset and never cleared). The k573dio read mux
//     owns that; this module never touches SCL.
//   - frame_count is the REAL decoded-frame count (0 until the MP3 decode
//     lane exists - a truthful zero, not a stub lie).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module mas3507d_i2c #(
    parameter [0:0] DBG = 1'b0        // sim-only: log accepted-and-dropped bytes
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        scl,           // host SCL latch (k573dio 0xac bit13)
    input  wire        sda,           // host SDA latch (k573dio 0xac bit12)
    output reg         sda_pd,        // 1 = slave pulls SDA low (wired-AND)

    input  wire [31:0] frame_count,   // decoded MP3 frames (0: nothing decoded)

    // ---- OUTPUT GAIN MATRIX (MAS3507D bank-1 memory 0x7f8..0x7fb) --------------
    // The game sets its own output level here and MUTES by writing zeros -- MAME's
    // mas3507d treats 0 as a mute (`if(val == 0) return 0`). We used to ACK and drop
    // these, so we played everything at unity: measured on silicon 2026-07-31 at
    // peak 0.000265 dBFS (pinned to digital full scale) while the game had asked for
    // 0xAF3CD. Decoding them is the fix for the clipping.
    //
    // Only L->L (word 0) and R->R (word 3) are surfaced; the cross terms are always
    // zero in ddrsbm and nothing downstream can use them yet.
    output reg [19:0] gain_ll,
    output reg [19:0] gain_rr,
    output reg        gain_stb        // 1-cycle pulse when a matrix write completes
);
    localparam [2:0] S_IDLE  = 3'd0,  // between STOP and START
                     S_BITS  = 3'd1,  // shifting address/write byte (host drives SDA)
                     S_ACK   = 3'd2,  // we drive ACK; waiting for the 9th rising edge
                     S_ACK2  = 3'd3,  // 9th high seen; ACK ends on the falling edge
                     S_RBIT  = 3'd4,  // read byte: we drive data bits
                     S_MACK  = 3'd5,  // master ACK/NACK clock (we release SDA)
                     S_MACK2 = 3'd6,  // master bit sampled; acts on the falling edge
                     S_DEAD  = 3'd7;  // NAKed/parked: only START or STOP revive us

    reg [2:0] state;
    reg       prev_scl, prev_sda;     // line history (reset high = idle bus)
    reg [2:0] bitcnt;                 // bit position, 7 down to 0
    reg [6:0] shreg;                  // partial byte (bits 7..1; bit 0 joins live)
    reg       addr_phase;             // next byte is the device address
    reg       read_sel;               // validated address was 0x3b
    reg       sub_first;              // next write byte is the subcommand
    reg       mack;                   // sampled master ACK/NACK bit
    reg [1:0] rd_bytes;               // read-byte counter (0..3)
    reg [31:0] rd_data;               // armed read-back value (MAME sdao_data)

    // ---- WRITE_MEM parse state (gain matrix) ----
    // Byte layout after the device address, confirmed against both a live MAME tap
    // and this lane's July transaction list (docs/2026-07-01-ddrsbm-dio-i2c-*.md):
    //   idx0 subcommand 0x68 | idx1 cmd (0xa0 bank0 / 0xb0 bank1) | idx2 pad
    //   idx3:4 word count BE | idx5:6 address BE | idx7.. payload, 4 bytes per word
    // Word value packing is MAME's i2c_device_got_byte:
    //   val = ((b3 & 0xf) << 16) | (b0 << 8) | b1     (b2 unused)
    localparam [5:0] PAYLOAD0 = 6'd7;
    reg [5:0]  wbyte;                 // write-byte index after the address (saturating)
    reg        bank1;                 // idx1 was 0xb0
    reg [15:0] mem_adr;               // idx5:6
    reg [15:0] wacc;                  // {b0,b1} of the word being assembled
    reg [19:0] g_ll_s;                // L->L staged until R->R (word 3) lands
    wire [5:0] pidx = wbyte - PAYLOAD0;   // payload byte index (valid when wbyte>=PAYLOAD0)

    wire scl_rise = scl & ~prev_scl;
    wire scl_fall = ~scl & prev_scl;
    wire start_c  = prev_sda & ~sda & scl;   // SDA falls with (post-write) SCL high
    wire stop_c   = ~prev_sda & sda & scl;   // SDA rises with SCL high
    wire bit_in   = prev_sda;                // pre-write SDA (MAME applies SCL first)
    wire [7:0] cur_byte = {shreg, bit_in};

    function rbit(input [1:0] byten, input [2:0] bitn);
        rbit = rd_data[{byten, bitn}];       // bit (byten*8 + bitn)
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            prev_scl <= 1'b1; prev_sda <= 1'b1;
            state <= S_IDLE; sda_pd <= 1'b0;
            bitcnt <= 3'd7; shreg <= 7'd0;
            addr_phase <= 1'b0; read_sel <= 1'b0; sub_first <= 1'b0;
            mack <= 1'b0; rd_bytes <= 2'd0; rd_data <= 32'd0;
            wbyte <= 6'd0; bank1 <= 1'b0; mem_adr <= 16'd0; wacc <= 20'd0;
            g_ll_s <= 20'd0;
            // Reset to UNITY-equivalent "not yet told": 0 would mean muted, and a core
            // that boots muted because the game has not spoken yet is worse than one
            // that boots loud. Downstream treats gain_stb as "a real value exists".
            gain_ll <= 20'd0; gain_rr <= 20'd0; gain_stb <= 1'b0;
        end else begin
            gain_stb <= 1'b0;
            // ---- clock-edge work (S_IDLE / S_DEAD ignore clocks) ----
            if (scl_rise) begin
                case (state)
                    S_BITS:
                        if (bitcnt == 3'd0) begin
                            // byte complete on this 8th rising edge
                            if (addr_phase) begin
                                if ((cur_byte & 8'hfe) == 8'h3a) begin
                                    addr_phase <= 1'b0;
                                    read_sel   <= cur_byte[0];
                                    sub_first  <= ~cur_byte[0];
                                    sda_pd     <= 1'b1;          // ACK
                                    state      <= S_ACK;
                                    wbyte      <= 6'd0;          // write bytes start here
                                    bank1      <= 1'b0;
                                    mem_adr    <= 16'd0;
                                end else begin
                                    sda_pd <= 1'b0;              // NAK: release, play dead
                                    state  <= S_DEAD;
                                    // synthesis translate_off
                                    if (DBG) $display("[mas3507d_i2c] NAK address %02x", cur_byte);
                                    // synthesis translate_on
                                end
                            end else begin
                                if (sub_first && cur_byte == 8'h69) begin
                                    // "data read": arm the default read = frame count,
                                    // MAME byte order [15:8],[7:0],[31:24],[23:16]
                                    rd_data  <= {frame_count[23:16], frame_count[31:24],
                                                 frame_count[7:0],   frame_count[15:8]};
                                    rd_bytes <= 2'd0;
                                end else begin
                                    rd_data <= 32'd0;            // any other write disarms
                                    // synthesis translate_off
                                    if (DBG) $display("[mas3507d_i2c] ACK+drop %02x%s",
                                        cur_byte, sub_first ? " (subcommand)" : "");
                                    // synthesis translate_on
                                end

                                // ---- WRITE_MEM parse: capture the output gain matrix ----
                                if (wbyte == 6'd1) bank1            <= (cur_byte == 8'hb0);
                                if (wbyte == 6'd5) mem_adr[15:8]    <= cur_byte;
                                if (wbyte == 6'd6) mem_adr[7:0]     <= cur_byte;
                                if (wbyte >= PAYLOAD0) begin
                                    case (pidx[1:0])
                                        2'd0: wacc[15:8] <= cur_byte;
                                        2'd1: wacc[7:0]  <= cur_byte;
                                        2'd2: ;                  // b2 is unused (MAME)
                                        2'd3:
                                          if (bank1 && mem_adr == 16'h07f8) begin
                                            // val = ((b3 & 0xf) << 16) | (b0 << 8) | b1
                                            if (pidx[5:2] == 4'd0)
                                                g_ll_s <= {cur_byte[3:0], wacc};
                                            if (pidx[5:2] == 4'd3) begin
                                                gain_ll  <= g_ll_s;
                                                gain_rr  <= {cur_byte[3:0], wacc};
                                                gain_stb <= 1'b1;
                                                // synthesis translate_off
                                                if (DBG) $display(
                                                  "[mas3507d_i2c] GAIN ll=%05x rr=%05x%s",
                                                  g_ll_s, {cur_byte[3:0], wacc},
                                                  (g_ll_s == 0 && wacc == 0 && cur_byte[3:0] == 0)
                                                    ? "  (MUTE)" : "");
                                                // synthesis translate_on
                                            end
                                          end
                                    endcase
                                end
                                if (wbyte != 6'd63) wbyte <= wbyte + 6'd1;

                                sub_first <= 1'b0;
                                sda_pd    <= 1'b1;               // ACK-and-drop
                                state     <= S_ACK;
                            end
                            shreg  <= 7'd0;
                            bitcnt <= 3'd7;
                        end else begin
                            shreg  <= {shreg[5:0], bit_in};
                            bitcnt <= bitcnt - 3'd1;
                        end
                    S_ACK:  state <= S_ACK2;                     // host samples ACK now
                    S_MACK: begin mack <= bit_in; state <= S_MACK2; end
                    default: ;                                   // S_RBIT: host sampling
                endcase
            end
            if (scl_fall) begin
                case (state)
                    S_ACK2: begin
                        // ACK window closes; next byte begins
                        if (read_sel) begin                      // just ACKed 0x3b
                            bitcnt <= 3'd7;
                            sda_pd <= ~rbit(rd_bytes, 3'd7);
                            state  <= S_RBIT;
                        end else begin
                            sda_pd <= 1'b0;
                            bitcnt <= 3'd7;
                            shreg  <= 7'd0;
                            state  <= S_BITS;
                        end
                    end
                    S_RBIT:
                        if (bitcnt == 3'd0) begin
                            sda_pd <= 1'b0;                      // release for master ACK
                            state  <= S_MACK;
                        end else begin
                            bitcnt <= bitcnt - 3'd1;
                            sda_pd <= ~rbit(rd_bytes, bitcnt - 3'd1);
                        end
                    S_MACK2:
                        if (!mack && rd_bytes != 2'd3) begin     // master ACK: next byte
                            rd_bytes <= rd_bytes + 2'd1;
                            bitcnt   <= 3'd7;
                            sda_pd   <= ~rbit(rd_bytes + 2'd1, 3'd7);
                            state    <= S_RBIT;
                        end else begin                           // NACK or exhausted: park
                            sda_pd <= 1'b0;
                            state  <= S_DEAD;
                        end
                    default: ;
                endcase
            end
            // ---- START/STOP win over same-cycle edge work (MAME order) ----
            if (start_c) begin
                state      <= S_BITS;
                addr_phase <= 1'b1;
                read_sel   <= 1'b0;
                sub_first  <= 1'b0;
                bitcnt     <= 3'd7;
                shreg      <= 7'd0;
                sda_pd     <= 1'b0;
                // rd_data / rd_bytes preserved: repeated-START read flow
            end else if (stop_c) begin
                state      <= S_IDLE;
                addr_phase <= 1'b0;
                read_sel   <= 1'b0;
                sub_first  <= 1'b0;
                sda_pd     <= 1'b0;
            end
            prev_scl <= scl;
            prev_sda <= sda;
        end
    end
endmodule
