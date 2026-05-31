`timescale 1ns/1ps
// Testbench for zs01.v - acts as the 573 BIOS master. It builds 12-byte command
// packets (command, address, 8 data, CRC16), scrambles them with the command key
// exactly as the host must, clocks them in, then reads back the response packet
// and descrambles it with the response key. Exercises: response-to-reset, an
// authenticated data write + read-back, a config-register read, the internal
// DS2401 read, and a forced bad-CRC error.
//
// The master-side encrypt/decrypt/CRC here are an independent transliteration of
// the documented ZS01 algorithm; a green round-trip proves the RTL device FSM
// and datapath implement the same transform.
module tb_zs01;
    localparam [63:0] COMMAND_KEY = 64'hED68_504B_C644_483E;
    localparam [63:0] CONFIG_INIT = 64'h1122_3344_FF00_7788; // RR=idx4=FF, RC=idx5=00
    localparam [63:0] DS2401_ID   = 64'h0102_0304_0506_0708;

    reg  clk = 0, rst = 1;
    reg  cs = 1, sec_rst = 0, scl = 0, sda_m = 1;
    wire sda_o;
    integer errors = 0;

    zs01 #(.COMMAND_KEY(COMMAND_KEY), .CONFIG_INIT(CONFIG_INIT), .DS2401_ID(DS2401_ID)) dut (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    function [7:0] ror8(input [7:0] x, input [2:0] r); ror8 = (x >> r) | (x << ((4'd8-r)&3'd7)); endfunction
    function [7:0] rol8(input [7:0] x, input [2:0] r); rol8 = (x << r) | (x >> ((4'd8-r)&3'd7)); endfunction

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

    // master-side packet buffers
    reg [7:0] pkt  [0:11];
    reg [7:0] resp [0:11];

    // descending scramble (inverse of the device's command descramble)
    task tb_encrypt(input [63:0] key);
        integer idx, kk; reg [7:0] prev, acc, kb;
        begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                acc = key[63:56] + (pkt[idx] ^ prev);
                for (kk = 1; kk <= 7; kk = kk + 1) begin
                    kb  = key[8*(7-kk) +: 8];
                    acc = rol8(acc, kb[7:5]);
                    acc = acc + (kb & 8'h1f);
                end
                pkt[idx] = acc; prev = acc;
            end
        end
    endtask
    // descending descramble of the response (same transform the device decrypts with)
    task tb_decrypt(input [63:0] key);
        integer idx, kk; reg [7:0] prev, t1, t0, kb;
        begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                t1 = resp[idx]; t0 = t1;
                for (kk = 7; kk >= 1; kk = kk - 1) begin
                    kb = key[8*(7-kk) +: 8];
                    t0 = t0 - (kb & 8'h1f);
                    t0 = ror8(t0, kb[7:5]);
                end
                resp[idx] = (t0 - key[63:56]) ^ prev; prev = t1;
            end
        end
    endtask

    // ---- serial master primitives ----
    task i2c_start; begin
        scl = 0; tk; sda_m = 1; tk; scl = 1; tk; sda_m = 0; tk; scl = 0; tk;
    end endtask
    task send_byte(input [7:0] d);
        integer i; begin
            for (i = 7; i >= 0; i = i - 1) begin scl = 0; tk; sda_m = d[i]; tk; scl = 1; tk; end
            scl = 0; tk; sda_m = 1; tk; scl = 1; tk; scl = 0; tk;   // 9th clock = device ack
        end
    endtask
    task read_byte(output [7:0] d);
        integer i; begin
            d = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                scl = 0; tk; sda_m = 1; tk; scl = 1; tk; d[i] = sda_o;
            end
            scl = 0; tk; sda_m = 1'b0; tk; scl = 1; tk; scl = 0; tk; sda_m = 1; // master ack
        end
    endtask
    task read_rtr_byte(output [7:0] d);
        integer i; begin
            d = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin scl = 1; tk; scl = 0; tk; d = {d[6:0], sda_o}; end
        end
    endtask

    // run one command: build packet, scramble, send, read+descramble response
    task do_command(input [7:0] cmd, input [7:0] addr, input [63:0] payload,
                    input bad_crc, input [63:0] rkey,
                    output [7:0] status, output [63:0] rdata);
        integer i; reg [15:0] crc;
        begin
            pkt[0] = cmd; pkt[1] = addr;
            for (i = 0; i < 8; i = i + 1) pkt[2+i] = payload[8*(7-i) +: 8];
            crc = calc_crc10({pkt[0],pkt[1],pkt[2],pkt[3],pkt[4],pkt[5],pkt[6],pkt[7],pkt[8],pkt[9]});
            if (bad_crc) crc = crc ^ 16'hffff;       // deliberately wrong
            pkt[10] = crc[15:8]; pkt[11] = crc[7:0];
            tb_encrypt(COMMAND_KEY);

            i2c_start;
            for (i = 0; i < 12; i = i + 1) send_byte(pkt[i]);
            for (i = 0; i < 12; i = i + 1) read_byte(resp[i]);
            tb_decrypt(rkey);

            status = resp[0];
            rdata  = {resp[2],resp[3],resp[4],resp[5],resp[6],resp[7],resp[8],resp[9]};
        end
    endtask

    task expect64(input [63:0] got, input [63:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %016h (expected %016h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask
    task expect_status(input [7:0] got, input [7:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s status = %02h (expected %02h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    reg [7:0]  b0, b1, b2, b3, st;
    reg [63:0] rd;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;

        // ---- response to reset (0x5A,0x53,0x00,0x01) ----
        cs = 0; tk;
        sec_rst = 1; tk;
        read_rtr_byte(b0); read_rtr_byte(b1); read_rtr_byte(b2); read_rtr_byte(b3);
        if ({b0,b1,b2,b3} !== 32'h5a53_0001) begin
            $display("FAIL: rtr = %02h%02h%02h%02h (expected 5a530001)", b0, b1, b2, b3);
            errors = errors + 1;
        end

        // ---- WRITE 0xD0..0xD7 to address 0x05 (response key still 0) ----
        do_command(8'h00, 8'h05, 64'hD0D1_D2D3_D4D5_D6D7, 1'b0, 64'h0, st, rd);
        expect_status(st, 8'h00, "write");

        // ---- READ back address 0x05 (response key = A0..A7) ----
        do_command(8'h01, 8'h05, 64'hA0A1_A2A3_A4A5_A6A7, 1'b0, 64'hA0A1_A2A3_A4A5_A6A7, st, rd);
        expect_status(st, 8'h00, "readback");
        expect64(rd, 64'hD0D1_D2D3_D4D5_D6D7, "readback data");

        // ---- READ config registers (address 0xFE, response key = B0..B7) ----
        do_command(8'h01, 8'hfe, 64'hB0B1_B2B3_B4B5_B6B7, 1'b0, 64'hB0B1_B2B3_B4B5_B6B7, st, rd);
        expect_status(st, 8'h00, "config");
        expect64(rd, CONFIG_INIT, "config data");

        // ---- READ internal DS2401 (address 0xFC, response key = C0..C7) ----
        do_command(8'h01, 8'hfc, 64'hC0C1_C2C3_C4C5_C6C7, 1'b0, 64'hC0C1_C2C3_C4C5_C6C7, st, rd);
        expect_status(st, 8'h00, "ds2401");
        expect64(rd, 64'h0102_0304_0506_0708, "ds2401 data");

        // ---- bad CRC must report STATUS_ERROR (response key unchanged = C0..C7) ----
        do_command(8'h01, 8'h05, 64'hC0C1_C2C3_C4C5_C6C7, 1'b1, 64'hC0C1_C2C3_C4C5_C6C7, st, rd);
        expect_status(st, 8'h02, "bad-crc");

        if (errors == 0)
            $display("RESULT: PASS (zs01)  rtr=%02h%02h%02h%02h", b0, b1, b2, b3);
        else
            $display("RESULT: FAIL (zs01, %0d errors)", errors);
        $finish;
    end
endmodule
