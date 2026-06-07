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
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o),
        .load_we(1'b0), .load_addr(13'd0), .load_data(8'd0),
        .load_ds_we(1'b0), .load_ds_addr(3'd0), .load_ds_data(8'd0)
    );

    // ---- Part 2 DUT: loaded with the REAL gtrfrk5m gea26jaa.u1 via the load port ----
    reg  cs2 = 1, sec_rst2 = 0, scl2 = 0, sda_m2 = 1;
    wire sda_o2;
    reg        L_we = 0;  reg [12:0] L_addr = 0;  reg [7:0] L_data = 0;
    reg        Lds_we = 0; reg [2:0] Lds_addr = 0; reg [7:0] Lds_data = 0;
    zs01 dut2 (   // params at default -- the LOADED image must override them
        .clk(clk), .rst(rst), .cs(cs2), .sec_rst(sec_rst2),
        .scl(scl2), .sda_i(sda_m2), .sda_o(sda_o2),
        .load_we(L_we), .load_addr(L_addr), .load_data(L_data),
        .load_ds_we(Lds_we), .load_ds_addr(Lds_addr), .load_ds_data(Lds_data)
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

    // ---- Part 2 serial primitives + loader (drive dut2 with the loaded image) ----
    reg [7:0] pkt2 [0:11];
    reg [7:0] resp2 [0:11];
    reg [63:0] cmdkey2;   // command key from the dump (.u1[4:11])
    task i2c_start2; begin
        scl2 = 0; tk; sda_m2 = 1; tk; scl2 = 1; tk; sda_m2 = 0; tk; scl2 = 0; tk;
    end endtask
    task send_byte2(input [7:0] d);
        integer i; begin
            for (i = 7; i >= 0; i = i - 1) begin scl2 = 0; tk; sda_m2 = d[i]; tk; scl2 = 1; tk; end
            scl2 = 0; tk; sda_m2 = 1; tk; scl2 = 1; tk; scl2 = 0; tk;
        end
    endtask
    task read_byte2(output [7:0] d);
        integer i; begin
            d = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin scl2 = 0; tk; sda_m2 = 1; tk; scl2 = 1; tk; d[i] = sda_o2; end
            scl2 = 0; tk; sda_m2 = 1'b0; tk; scl2 = 1; tk; scl2 = 0; tk; sda_m2 = 1;
        end
    endtask
    task read_rtr_byte2(output [7:0] d);
        integer i; begin
            d = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin scl2 = 1; tk; scl2 = 0; tk; d = {d[6:0], sda_o2}; end
        end
    endtask
    task load_u1(input [12:0] a, input [7:0] v); begin
        @(posedge clk); L_addr=a; L_data=v; L_we=1; @(posedge clk); L_we=0; end
    endtask
    task load_u6(input [2:0] a, input [7:0] v); begin
        @(posedge clk); Lds_addr=a; Lds_data=v; Lds_we=1; @(posedge clk); Lds_we=0; end
    endtask
    // descending scramble on pkt2 / descending descramble on resp2, with an arbitrary key
    task tb_encrypt2(input [63:0] key);
        integer idx, kk; reg [7:0] prev, acc, kb; begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                acc = key[63:56] + (pkt2[idx] ^ prev);
                for (kk = 1; kk <= 7; kk = kk + 1) begin
                    kb = key[8*(7-kk) +: 8]; acc = rol8(acc, kb[7:5]); acc = acc + (kb & 8'h1f);
                end
                pkt2[idx] = acc; prev = acc;
            end
        end
    endtask
    task tb_decrypt2(input [63:0] key);
        integer idx, kk; reg [7:0] prev, t1, t0, kb; begin
            prev = 8'hff;
            for (idx = 11; idx >= 0; idx = idx - 1) begin
                t1 = resp2[idx]; t0 = t1;
                for (kk = 7; kk >= 1; kk = kk - 1) begin
                    kb = key[8*(7-kk) +: 8]; t0 = t0 - (kb & 8'h1f); t0 = ror8(t0, kb[7:5]);
                end
                resp2[idx] = (t0 - key[63:56]) ^ prev; prev = t1;
            end
        end
    endtask
    // run one command on dut2 using the LOADED command key. bad_key scrambles with the
    // wrong key (negative control); rkey is the key to descramble the response with.
    task do_command2(input [7:0] cmd, input [7:0] addr, input [63:0] payload,
                     input bad_key, input [63:0] rkey,
                     output [7:0] status, output [63:0] rdata);
        integer i; reg [15:0] crc;
        begin
            pkt2[0] = cmd; pkt2[1] = addr;
            for (i = 0; i < 8; i = i + 1) pkt2[2+i] = payload[8*(7-i) +: 8];
            crc = calc_crc10({pkt2[0],pkt2[1],pkt2[2],pkt2[3],pkt2[4],pkt2[5],pkt2[6],pkt2[7],pkt2[8],pkt2[9]});
            pkt2[10] = crc[15:8]; pkt2[11] = crc[7:0];
            tb_encrypt2(bad_key ? (cmdkey2 ^ 64'hFFFF_FFFF_FFFF_FFFF) : cmdkey2);
            i2c_start2;
            for (i = 0; i < 12; i = i + 1) send_byte2(pkt2[i]);
            for (i = 0; i < 12; i = i + 1) read_byte2(resp2[i]);
            tb_decrypt2(rkey);
            status = resp2[0];
            rdata  = {resp2[2],resp2[3],resp2[4],resp2[5],resp2[6],resp2[7],resp2[8],resp2[9]};
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

    // ---- Part 2 real-data fixtures (gtrfrk5m gea26jaa.u1/.u6) ----
    reg [7:0] z_u1 [0:4115];
    reg [7:0] z_u6 [0:7];
    integer   fh2, k;
    reg       z_present;

    initial begin
        z_present = 1'b0;
        fh2 = $fopen("secdata/gtrfrk5m_u1.hex", "r");
        if (fh2 != 0) begin
            $fclose(fh2);
            $readmemh("secdata/gtrfrk5m_u1.hex", z_u1);
            $readmemh("secdata/gtrfrk5m_u6.hex", z_u6);
            z_present = 1'b1;
        end

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

        cs = 1; tk;   // deselect dut

        // =====================================================================
        // Part 2: dut2 LOADED with the REAL gtrfrk5m gea26jaa.u1 (params at default).
        // Proves the chip-level load port establishes the per-cart data key + config +
        // data array + command key, and that an authenticated READ returns the REAL
        // decrypted bytes -- NOT the param/default ramp.
        // =====================================================================
        if (!z_present) begin
            $display("NOTE: gtrfrk5m dump absent -- skipping zs01 Part 2 (run sim/gen_secdata.sh with dumps/)");
        end else begin
            // stream the real image in through the chip's own load ports
            for (k = 0; k < 4116; k = k + 1) load_u1(k[12:0], z_u1[k]);
            for (k = 0; k < 8;    k = k + 1) load_u6(k[2:0],  z_u6[k]);
            cmdkey2 = {z_u1[4],z_u1[5],z_u1[6],z_u1[7],z_u1[8],z_u1[9],z_u1[10],z_u1[11]};
            tk;

            // ---- response to reset on dut2 ----
            cs2 = 0; tk; sec_rst2 = 1; tk;
            read_rtr_byte2(b0); read_rtr_byte2(b1); read_rtr_byte2(b2); read_rtr_byte2(b3);
            if ({b0,b1,b2,b3} !== 32'h5a53_0001) begin
                $display("FAIL: dut2 rtr = %02h%02h%02h%02h (want 5a530001)", b0,b1,b2,b3); errors=errors+1; end
            sec_rst2 = 0; tk;

            // ---- authenticated READ addr 0x00 = the REAL data 00004a410000f746 ----
            do_command2(8'h01, 8'h00, 64'hA0A1_A2A3_A4A5_A6A7, 1'b0, 64'hA0A1_A2A3_A4A5_A6A7, st, rd);
            expect_status(st, 8'h00, "real-read0");
            expect64(rd, 64'h0000_4a41_0000_f746, "real-read0 data");
            if (rd === 64'h0001_0203_0405_0607) begin
                $display("FAIL: dut2 read addr0 is the SIM-DEFAULT ramp -- load not applied"); errors=errors+1; end

            // ---- READ addr 0x01 = the REAL data 020000000000 00fd ----
            do_command2(8'h01, 8'h01, 64'hB0B1_B2B3_B4B5_B6B7, 1'b0, 64'hB0B1_B2B3_B4B5_B6B7, st, rd);
            expect_status(st, 8'h00, "real-read1");
            expect64(rd, 64'h0200_0000_0000_00fd, "real-read1 data");

            // ---- READ config regs (0xFE) = the dump's 4745413236000000 ----
            do_command2(8'h01, 8'hfe, 64'hC0C1_C2C3_C4C5_C6C7, 1'b0, 64'hC0C1_C2C3_C4C5_C6C7, st, rd);
            expect_status(st, 8'h00, "real-config");
            expect64(rd, 64'h4745_4132_3600_0000, "real-config data");

            // ---- READ internal DS2401 (0xFC) = the loaded .u6 (file bytes 7..0) ----
            do_command2(8'h01, 8'hfc, 64'hD0D1_D2D3_D4D5_D6D7, 1'b0, 64'hD0D1_D2D3_D4D5_D6D7, st, rd);
            expect_status(st, 8'h00, "real-ds2401");
            expect64(rd, {z_u6[7],z_u6[6],z_u6[5],z_u6[4],z_u6[3],z_u6[2],z_u6[1],z_u6[0]}, "real-ds2401 data");

            // ---- NEGATIVE CONTROL: wrong command key -> STATUS_ERROR (stale rkey D0..D7) ----
            do_command2(8'h01, 8'h00, 64'hE0E1_E2E3_E4E5_E6E7, 1'b1, 64'hD0D1_D2D3_D4D5_D6D7, st, rd);
            expect_status(st, 8'h02, "real-neg");
        end

        if (errors == 0) begin
            $display("RESULT: PASS (zs01)  rtr=%02h%02h%02h%02h", b0, b1, b2, b3);
            if (z_present)
                $display("  gtrfrk5m loaded: authenticated READ addr0 = 00004a410000f746 (REAL, not default), neg-control OK");
            else
                $display("  (zs01 real-data Part 2 skipped: gtrfrk5m dump absent)");
        end else
            $display("RESULT: FAIL (zs01, %0d errors)", errors);
        $finish;
    end
endmodule
