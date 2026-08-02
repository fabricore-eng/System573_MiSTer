`timescale 1ns/1ps
// Testbench for the MAS3507D I2C slave behind k573dio register 0xac -- the
// ddrsbm BOOT CHECK gate. Drives the EXACT bit-bang idioms the game uses
// (disasm + MAME-tap verified: docs/2026-07-01-ddrsbm-dio-i2c-transactions.md):
// the START/STOP sequences with their redundant rewrites, per-bit writes with
// SDA-release trailers, the SCL-echo spins (bounded here; unbounded in the
// game -- a timeout IS the reproduced BOOT CHECK hang), ACK samples, the two
// boot transactions T1 (WRITE_MEM bank0 0x32f = 0x00030) + T2 (RUN 0x0fcb),
// the runtime frame-count read flow, and a wrong-address NAK/recovery check.
//
// RED/GREEN: `make DIO_I2C_STUB=1 dio_i2c` compiles k573dio.v with the 0xac
// register removed (the pre-fix stub) -- this tb must FAIL at the very first
// SCL echo. The default build must PASS.
module tb_dio_i2c;
    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [7:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire [31:0] lamp;
    wire [15:0] crypto_key1, crypto_key2, crypto_key3;
    wire [31:0] mp3_start, mp3_end;
    wire [15:0] fpga_ctrl, network_id;
    wire [7:0]  mp3_out_byte;
    wire        mp3_out_valid;
    integer errors = 0;

    k573dio #(.RAM_WORDS(4096), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(lamp),
        .dio_wait(), .cfg_ddrsbm(1'b1),          // was parameter DDRSBM
        .mem_rd_req(), .mem_rd_addr(), .mem_rd_q(64'd0), .mem_rd_ack(1'b0),
        .mem_wr_req(), .mem_wr_addr(), .mem_wr_data(), .mem_wr_ack(1'b0),
        .dbg_wfifo_ovf(),
        .crypto_key1(crypto_key1), .crypto_key2(crypto_key2), .crypto_key3(crypto_key3),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .fpga_ctrl(fpga_ctrl), .network_id(network_id),
        .mp3_out_ready(1'b1),   // i2c test doesn't stream; keep sink ready (inert)
        .mp3_out_byte(mp3_out_byte), .mp3_out_valid(mp3_out_valid),
        .dec_frame_sync(1'b0), .dec_frame_idle(1'b0), .pcm_sample_tick(1'b0)  // frame_count stays 0
    );

    always #5 clk = ~clk;

    task bus_write(input [7:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; off=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task bus_read(input [7:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; off=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- game-idiom I2C primitives (0xac: bit13 = SCL, bit12 = SDA) --------
    reg [15:0] rv;
    integer    tmo;

    task ac_w(input [15:0] v); begin bus_write(8'hac, v); end endtask

    // the game's SCL-echo spin (unbounded on silicon; bounded here). A timeout
    // is the reproduced BOOT CHECK hang: fail fast, everything after would hang.
    task scl_echo; begin
        tmo = 0;
        bus_read(8'hac, rv);
        while (!rv[13] && tmo < 32) begin bus_read(8'hac, rv); tmo = tmo + 1; end
        if (!rv[13]) begin
            $display("FAIL: SCL echo never came back (the BOOT CHECK hang)");
            errors = errors + 1;
            $display("RESULT: FAIL (dio_i2c, %0d errors)", errors);
            $finish;
        end
    end endtask

    // START: release both -> echo -> SDA falls with SCL high -> SCL low
    task i2c_start; begin
        ac_w(16'h3000); scl_echo;
        ac_w(16'h3000); ac_w(16'h3000); ac_w(16'h3000);  // game's redundant rewrites
        ac_w(16'h2000);                                   // START
        ac_w(16'h0000); ac_w(16'h0000); ac_w(16'h0000); ac_w(16'h0000);
    end endtask

    // STOP: both low -> SCL high -> echo -> SDA rises with SCL high
    task i2c_stop; begin
        ac_w(16'h0000); ac_w(16'h0000); ac_w(16'h0000); ac_w(16'h0000);
        ac_w(16'h2000); ac_w(16'h2000); scl_echo;
        ac_w(16'h2000);
        ac_w(16'h3000); ac_w(16'h3000); ac_w(16'h3000); ac_w(16'h3000);
    end endtask

    // one host-driven bit, exactly as the game sends it (SDA-release trailer incl.)
    task send_bit(input b); begin
        ac_w({2'b00, 1'b0, b, 12'b0});                    // SCL low, SDA = bit
        ac_w({2'b00, 1'b1, b, 12'b0}); scl_echo;          // SCL high (slave samples)
        ac_w({2'b00, 1'b1, b, 12'b0}); ac_w({2'b00, 1'b1, b, 12'b0});
        ac_w({2'b00, 1'b0, b, 12'b0});                    // SCL low
        ac_w(16'h1000); ac_w(16'h1000);                   // trailer: release SDA
    end endtask

    // sample one bit with SDA released (the game's read_bit / ACK sample)
    task read_bit(output b); begin
        ac_w(16'h1000);                                   // SDA released, SCL low
        ac_w(16'h3000); scl_echo;                         // SCL high
        bus_read(8'hac, rv); b = rv[12];
        ac_w(16'h1000);                                   // SCL low
    end endtask

    reg ab;
    task send_byte(input [7:0] v, input exp_ack, input [127:0] what);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) send_bit(v[i]);
            read_bit(ab);                                 // 9th clock: slave ACK slot
            if (ab !== (exp_ack ? 1'b0 : 1'b1)) begin
                $display("FAIL: %0s: ACK bit = %b (expected %b)", what, ab, exp_ack ? 1'b0 : 1'b1);
                errors = errors + 1;
            end
        end
    endtask

    task read_byte(output [7:0] v, input last);
        integer i;
        reg b;
        begin
            for (i = 7; i >= 0; i = i - 1) begin read_bit(b); v[i] = b; end
            send_bit(last);                               // master ACK (0) / final NACK (1)
        end
    endtask

    reg [15:0] v16;
    reg [7:0]  rb0, rb1;
    integer    i2;
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        // 1. reset line state: both lines released high (MAME resets latches high)
        bus_read(8'hac, v16); chk(v16, 16'h3000, "0xac reset read");
        bus_read(8'h80, v16); chk(v16, 16'h1234, "board id (mux intact)");

        // 2. T1 -- WRITE_MEM bank0 addr 0x32f = 0x00030 (boot transaction 1)
        i2c_start;
        send_byte(8'h3a, 1'b1, "T1 addr 0x3a");
        send_byte(8'h68, 1'b1, "T1 subcmd 0x68");
        send_byte(8'ha0, 1'b1, "T1 cmd 0xa0");
        send_byte(8'h00, 1'b1, "T1 pad");
        send_byte(8'h00, 1'b1, "T1 count hi");
        send_byte(8'h01, 1'b1, "T1 count lo");
        send_byte(8'h03, 1'b1, "T1 mem addr hi");
        send_byte(8'h2f, 1'b1, "T1 mem addr lo");
        send_byte(8'h00, 1'b1, "T1 word b0");
        send_byte(8'h30, 1'b1, "T1 word b1");
        send_byte(8'h00, 1'b1, "T1 word b2");
        send_byte(8'h00, 1'b1, "T1 word b3");
        i2c_stop;

        // 3. T2 -- RUN 0x0fcb (boot transaction 2; boot gate = all bytes ACKed)
        i2c_start;
        send_byte(8'h3a, 1'b1, "T2 addr 0x3a");
        send_byte(8'h68, 1'b1, "T2 subcmd 0x68");
        send_byte(8'h0f, 1'b1, "T2 run hi");
        send_byte(8'hcb, 1'b1, "T2 run lo");
        i2c_stop;

        // 4. runtime frame-count read: 0x3a 0x69, repeated START, 0x3b, 2 bytes
        i2c_start;
        send_byte(8'h3a, 1'b1, "rd addr 0x3a");
        send_byte(8'h69, 1'b1, "rd subcmd 0x69");
        i2c_start;                                        // repeated START
        send_byte(8'h3b, 1'b1, "rd addr 0x3b");
        read_byte(rb0, 1'b0);                             // master ACK
        read_byte(rb1, 1'b1);                             // final byte: master NACK
        i2c_stop;
        chk({8'd0, rb0}, 16'h0000, "frame count hi (nothing decoded)");
        chk({8'd0, rb1}, 16'h0000, "frame count lo (nothing decoded)");

        // 5. wrong address NAKs (SDA released reads 1); next START recovers
        i2c_start;
        send_byte(8'h55, 1'b0, "wrong addr 0x55");
        i2c_stop;
        i2c_start;
        send_byte(8'h3a, 1'b1, "recovery addr 0x3a");
        send_byte(8'h68, 1'b1, "recovery subcmd");
        i2c_stop;

        // 6. SCL echo tracks low too (readback = host latch, both levels)
        ac_w(16'h1000);
        bus_read(8'hac, v16);
        if (v16[13] !== 1'b0) begin
            $display("FAIL: SCL low not echoed (read %04h)", v16); errors = errors + 1;
        end
        ac_w(16'h3000);

        // 7. OUTPUT GAIN MATRIX -- bank1 (cmd 0xb0) addr 0x7f8, four 20-bit words.
        //    Bytes are the EXACT sequence captured off ddrsbm in the MAME oracle
        //    (2026-07-31): 3a 68 b0 00 00 04 07 f8 f3 cd 00 0a 00*8 f3 cd 00 0a.
        //    Packing is MAME's: val = ((b3 & 0xf) << 16) | (b0 << 8) | b1
        //    -> 0x0a<<16 | 0xf3<<8 | 0xcd = 0xAF3CD on L->L and R->R.
        //    This is the level the game asks for and that we used to DROP, which is
        //    why silicon measured peak 0.000265 dBFS (pinned to full scale).
        i2c_start;
        send_byte(8'h3a, 1'b1, "gain addr");
        send_byte(8'h68, 1'b1, "gain subcmd");
        send_byte(8'hb0, 1'b1, "gain cmd (bank1)");
        send_byte(8'h00, 1'b1, "gain pad");
        send_byte(8'h00, 1'b1, "gain count hi");
        send_byte(8'h04, 1'b1, "gain count lo");
        send_byte(8'h07, 1'b1, "gain adr hi");
        send_byte(8'hf8, 1'b1, "gain adr lo");
        send_byte(8'hf3, 1'b1, "LL b0"); send_byte(8'hcd, 1'b1, "LL b1");
        send_byte(8'h00, 1'b1, "LL b2"); send_byte(8'h0a, 1'b1, "LL b3");
        send_byte(8'h00, 1'b1, "LR b0"); send_byte(8'h00, 1'b1, "LR b1");
        send_byte(8'h00, 1'b1, "LR b2"); send_byte(8'h00, 1'b1, "LR b3");
        send_byte(8'h00, 1'b1, "RL b0"); send_byte(8'h00, 1'b1, "RL b1");
        send_byte(8'h00, 1'b1, "RL b2"); send_byte(8'h00, 1'b1, "RL b3");
        send_byte(8'hf3, 1'b1, "RR b0"); send_byte(8'hcd, 1'b1, "RR b1");
        send_byte(8'h00, 1'b1, "RR b2"); send_byte(8'h0a, 1'b1, "RR b3");
        i2c_stop;
        if (dut.mas_i2c.gain_ll !== 20'h0af3cd) begin
            $display("FAIL: gain_ll = %05x (expected 0af3cd)", dut.mas_i2c.gain_ll);
            errors = errors + 1;
        end
        if (dut.mas_i2c.gain_rr !== 20'h0af3cd) begin
            $display("FAIL: gain_rr = %05x (expected 0af3cd)", dut.mas_i2c.gain_rr);
            errors = errors + 1;
        end

        // 8. MUTE -- the same write with all-zero words. MAME's mas3507d treats a
        //    gain of 0 as a mute (`if(val == 0) return 0`); the game issues this at
        //    song end and on a failed stage. Must land as 0, not be ignored.
        i2c_start;
        send_byte(8'h3a, 1'b1, "mute addr");
        send_byte(8'h68, 1'b1, "mute subcmd");
        send_byte(8'hb0, 1'b1, "mute cmd");
        send_byte(8'h00, 1'b1, "mute pad");
        send_byte(8'h00, 1'b1, "mute count hi");
        send_byte(8'h04, 1'b1, "mute count lo");
        send_byte(8'h07, 1'b1, "mute adr hi");
        send_byte(8'hf8, 1'b1, "mute adr lo");
        for (i2 = 0; i2 < 16; i2 = i2 + 1) send_byte(8'h00, 1'b1, "mute payload");
        i2c_stop;
        if (dut.mas_i2c.gain_ll !== 20'h00000 || dut.mas_i2c.gain_rr !== 20'h00000) begin
            $display("FAIL: mute not captured (ll=%05x rr=%05x)",
                     dut.mas_i2c.gain_ll, dut.mas_i2c.gain_rr);
            errors = errors + 1;
        end

        // 9. NEGATIVE CONTROL: a bank0 write to a different address must NOT touch
        //    the gains. Without this the test would pass on a decoder that latched
        //    every WRITE_MEM regardless of bank/address.
        i2c_start;
        send_byte(8'h3a, 1'b1, "neg addr");
        send_byte(8'h68, 1'b1, "neg subcmd");
        send_byte(8'ha0, 1'b1, "neg cmd (bank0)");
        send_byte(8'h00, 1'b1, "neg pad");
        send_byte(8'h00, 1'b1, "neg count hi");
        send_byte(8'h01, 1'b1, "neg count lo");
        send_byte(8'h03, 1'b1, "neg adr hi");
        send_byte(8'h2f, 1'b1, "neg adr lo");
        send_byte(8'hff, 1'b1, "neg b0"); send_byte(8'hff, 1'b1, "neg b1");
        send_byte(8'h00, 1'b1, "neg b2"); send_byte(8'h0f, 1'b1, "neg b3");
        i2c_stop;
        if (dut.mas_i2c.gain_ll !== 20'h00000 || dut.mas_i2c.gain_rr !== 20'h00000) begin
            $display("FAIL: bank0/0x32f write leaked into the gain regs (ll=%05x rr=%05x)",
                     dut.mas_i2c.gain_ll, dut.mas_i2c.gain_rr);
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (dio_i2c)");
        else             $display("RESULT: FAIL (dio_i2c, %0d errors)", errors);
        $finish;
    end
endmodule
