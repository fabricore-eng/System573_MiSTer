`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_x76f100_hypbbc2p.v - replay the hypbbc2p CD-installer's X76F100 READ
// sequence against x76f100.v and assert the gate-relevant bytes.
//
// WHY THIS TB EXISTS:
//   The standalone in-game security check does ONE authenticated block-0 read
//   (covered by tb_x76f100 / tb_s573_seccart Part 1, both passing).  The
//   hypbbc2p CD-INSTALLER instead does the disassembled (workflow wyjubeu7w)
//   multi-read sequence:
//     * a password-auth READ + block-0 8-byte read  (Gate A, fn 0x80036ec4)
//         checksum:  data[4] == (~(data[0]+data[1]) & 0xff)   (0x74 == 0x74)
//     * a password-auth READ + TWO 8-byte reads (offset 0 then offset 8)
//         (Gate B, fn 0x80025adc)   sum: (data[0..7]) & 0xff == 0xff
//   On silicon the installer hits the -11N ("incorrect security cassette")
//   wall, which is the Gate-A checksum failing -- i.e. a LATER read returns
//   wrong-offset bytes than the FIRST read does.  This TB replays exactly that
//   pattern (the prior TBs only ever did a SINGLE read after auth, so they were
//   blind to a byte-pointer / read-after-password / re-auth state bug).
//
//   The X76F100 has NO host load port, so we seed the three gate-relevant data
//   bytes the protocol-legal way -- an authenticated WRITE of block 0 with the
//   synth-.u1 contents (data[0]=0x4a 'J', data[1]=0x41 'A', data[4]=0x74) -- then
//   replay the installer reads against that NVRAM.
//
// SDA is split into host-driven (sda_m -> dut.sda_i) and device-driven
// (dut.sda_o), exactly as tb_x76f100.v does.
// -----------------------------------------------------------------------------
module tb_x76f100_hypbbc2p;
    // The synth .u1 carries the read password in plaintext (gen_seccart_u1.py).
    localparam [63:0] READ_PASSWORD  = 64'he934_df40_7ad1_a7ff;
    localparam [63:0] WRITE_PASSWORD = 64'h0000_0000_0000_0000;

    reg  clk = 0, rst = 1;
    reg  cs = 1, sec_rst = 0, scl = 0, sda_m = 1;
    wire sda_o;
    integer errors = 0;

    x76f100 #(.READ_PASSWORD(READ_PASSWORD), .WRITE_PASSWORD(WRITE_PASSWORD)) dut (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    function [7:0] pwbyte(input [63:0] pw, input integer i);
        pwbyte = pw[8*(7-i) +: 8];
    endfunction

    // ---- I2C-like master primitives (mirror tb_x76f100.v) ----
    task i2c_start; begin
        scl = 0; tk; sda_m = 1; tk; scl = 1; tk; sda_m = 0; tk; scl = 0; tk;
    end endtask
    task i2c_stop; begin
        scl = 0; tk; sda_m = 0; tk; scl = 1; tk; sda_m = 1; tk;
    end endtask

    task send_byte(input [7:0] d, output ack);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                scl = 0; tk; sda_m = d[i]; tk; scl = 1; tk;
            end
            scl = 0; tk; sda_m = 1; tk; scl = 1; tk; ack = sda_o; scl = 0; tk;
        end
    endtask

    task read_byte(input ack_bit, output [7:0] d);
        integer i;
        begin
            d = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                scl = 0; tk; sda_m = 1; tk; scl = 1; tk;
                d[i] = sda_o;
            end
            scl = 0; tk; sda_m = ack_bit; tk; scl = 1; tk;
            scl = 0; tk; sda_m = 1;
        end
    endtask

    // Authenticate: command, 8 password bytes, 0x55 verify. ack = accept(0)/reject(1).
    task authenticate(input [7:0] cmd, input [63:0] pw, output ack);
        integer i; reg a;
        begin
            send_byte(cmd, a);
            for (i = 0; i < 8; i = i + 1) send_byte(pwbyte(pw, i), a);
            send_byte(8'h55, ack);
        end
    endtask

    // EXACT hypbbc2p installer framing (disassembled read primitive 0x8003854c):
    //   START, command, 8 password bytes, REPEATED START, 0x55 verify, READ.
    // The repeated START sits BEFORE the 0x55 verify byte -- this is what resets the
    // device byte pointer to 0 so the data read starts at the block base (offset 0).
    // (The in-game check uses the SAME primitive, hence the same framing.)
    task authenticate_installer(input [7:0] cmd, input [63:0] pw, output ack);
        integer i; reg a;
        begin
            send_byte(cmd, a);
            for (i = 0; i < 8; i = i + 1) send_byte(pwbyte(pw, i), a);
            i2c_start;                       // repeated START before the verify byte
            send_byte(8'h55, ack);
        end
    endtask

    // ---- seed three data bytes via an authenticated block-0 WRITE ----
    // After this, data[0]=4a, data[1]=41, data[4]=74 (rest 0) -- the synth .u1.
    reg [7:0] seed [0:7];
    task seed_block0;
        integer i; reg a;
        begin
            for (i = 0; i < 8; i = i + 1) seed[i] = 8'h00;
            seed[0] = 8'h4a; seed[1] = 8'h41; seed[4] = 8'h74;
            i2c_start;
            authenticate_installer(8'h80, WRITE_PASSWORD, a);  // 0x80 = WRITE block 0
            if (a !== 1'b0) begin
                $display("FAIL: seed write password not accepted (ack=%b)", a);
                errors = errors + 1;
            end
            for (i = 0; i < 8; i = i + 1) send_byte(seed[i], a);
            i2c_stop;
        end
    endtask

    // A full installer-style "auth + read N bytes from block <cmd>" cycle, using the
    // EXACT installer framing (repeated START before the 0x55 verify, then read with
    // NO further repeated start -- the pointer is already reset).  Captures rd[].
    reg [7:0] rd [0:15];
    task auth_read_installer(input [7:0] cmd, input integer nbytes, input [127:0] tag);
        integer i; reg a;
        begin
            i2c_start;
            authenticate_installer(cmd, READ_PASSWORD, a);
            if (a !== 1'b0) begin
                $display("FAIL [%0s]: read password not accepted (ack=%b)", tag, a);
                errors = errors + 1;
            end
            for (i = 0; i < nbytes; i = i + 1)
                read_byte((i == nbytes-1) ? 1'b1 : 1'b0, rd[i]);
            i2c_stop;
        end
    endtask

    // The exact block-0 read cycle the installer/in-game checks use.
    task auth_read_block0(input integer nbytes, input dummy, input [127:0] tag);
        begin auth_read_installer(8'h81, nbytes, tag); end
    endtask

    // assert the Gate-A checksum on the captured block-0 bytes.
    task check_gateA(input [127:0] tag);
        reg [7:0] cksum;
        begin
            cksum = (~(rd[0] + rd[1])) & 8'hff;
            $display("  [%0s] read block0 = %02h %02h %02h %02h %02h %02h %02h %02h",
                     tag, rd[0],rd[1],rd[2],rd[3],rd[4],rd[5],rd[6],rd[7]);
            if (rd[0] !== 8'h4a) begin
                $display("FAIL [%0s]: data[0]=%02h (want 4a 'J') -> wrong-offset read",
                         tag, rd[0]); errors = errors + 1; end
            if (rd[1] !== 8'h41) begin
                $display("FAIL [%0s]: data[1]=%02h (want 41 'A') -> wrong-offset read",
                         tag, rd[1]); errors = errors + 1; end
            if (rd[4] !== cksum) begin
                $display("FAIL [%0s]: data[4]=%02h != checksum ~(d0+d1)=%02h -> the -11N",
                         tag, rd[4], cksum); errors = errors + 1; end
            else
                $display("  [%0s] checksum data[4]=%02h == ~(d0+d1)=%02h  OK",
                         tag, rd[4], cksum);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;
        cs = 0; tk;

        // ---- seed the synth-.u1 bytes ----
        seed_block0;

        // =====================================================================
        // The installer sequence: SEVERAL consecutive auth+read cycles.  The first
        // read is the in-game-style single read (must pass).  The SUBSEQUENT reads
        // are what the installer adds -- the suspected wrong-offset regression.
        // =====================================================================

        // (1) FIRST authenticated block-0 read -- the in-game path; must be correct.
        auth_read_block0(8, 1'b1, "read#1");
        check_gateA("read#1");

        // (2) SECOND authenticated block-0 read immediately after #1 (re-auth).
        //     This is Gate B's first read -- the installer re-runs the whole
        //     auth+read with the SAME block 0.  A read-after-password / pointer
        //     state bug shows up here as wrong bytes.
        auth_read_block0(8, 1'b1, "read#2");
        check_gateA("read#2");

        // (3) THIRD authenticated block-0 read (Gate A is later called AGAIN).
        auth_read_block0(8, 1'b1, "read#3");
        check_gateA("read#3");

        // (4) Gate-B: ONE installer-framed auth, then read block 0 (8 bytes); then a
        //     SECOND installer-framed auth+read of block 0 (Gate B re-reads).  Each
        //     read is its own auth+repeated-START+verify+read cycle (matching the
        //     disassembled 0x80038be8 -> 0x8003854c twice).  The sum check uses the
        //     block-0 bytes: 4a+41+00+00+74+00+00+00 = 0xff.
        auth_read_installer(8'h81, 8, "read#4-gateB-r1");
        if (((rd[0]+rd[1]+rd[2]+rd[3]+rd[4]+rd[5]+rd[6]+rd[7]) & 8'hff) !== 8'hff) begin
            $display("FAIL [read#4-gateB-r1]: sum(data[0..7])&ff=%02h (want ff) -> Gate B -2",
                (rd[0]+rd[1]+rd[2]+rd[3]+rd[4]+rd[5]+rd[6]+rd[7]) & 8'hff);
            errors = errors + 1; end
        else
            $display("  [read#4-gateB-r1] block0 = %02h %02h %02h %02h %02h .. sum&ff = ff  OK",
                rd[0],rd[1],rd[2],rd[3],rd[4]);
        if (rd[0] !== 8'h4a || rd[1] !== 8'h41 || rd[4] !== 8'h74) begin
            $display("FAIL [read#4-gateB-r1]: block0 = %02h %02h .. %02h (want 4a 41 .. 74)",
                rd[0], rd[1], rd[4]); errors = errors + 1; end

        // (5) Gate-B's second 8-byte read (re-auth + block 1, offset 8).
        auth_read_installer(8'h83, 8, "read#5-gateB-r2");
        $display("  [read#5-gateB-r2] block1 = %02h %02h %02h %02h %02h %02h %02h %02h",
            rd[0],rd[1],rd[2],rd[3],rd[4],rd[5],rd[6],rd[7]);

        // (6) THE INSTALL-CART TWO-ATTEMPT AUTH (per MAME x76f100.cpp comment): the 573
        //     boot first tries the GAME password (NAK for an install cart), THEN the
        //     INSTALL password (ACK).  This is the read-after-FAILED-password path that
        //     a single-read TB never exercised.  After the wrong-pw NAK, the RIGHT-pw
        //     read must still return the correct offset-0 bytes (4a 41 .. 74).
        begin : two_attempt
            integer i; reg a;
            // attempt 1: WRONG (game) password -> must NAK, increments retry counter
            i2c_start;
            authenticate_installer(8'h81, 64'hDEAD_BEEF_CAFE_F00D, a);
            if (a !== 1'b1) begin
                $display("FAIL [read#6-attempt1]: wrong pw was ACCEPTED (ack=%b, want 1=NAK)", a);
                errors = errors + 1; end
            else
                $display("  [read#6-attempt1] wrong (game) pw NAKed  OK");
            i2c_stop;
            // attempt 2: RIGHT (install) password -> must ACK and read correct bytes
            auth_read_installer(8'h81, 8, "read#6-attempt2");
            check_gateA("read#6-attempt2");
        end

        // (7) MAME-PARITY of the read byte-pointer after the 8-byte password load,
        //     exercised via the NO-repeated-start framing (read straight after the
        //     0x55 verify ack).  MAME's m_byte is left at 8 after the password load
        //     (m_write_buffer[m_byte++]), so a block-0 read with no repeated start
        //     returns data[8],data[9],... (offset 8).  This is NOT the installer
        //     path (the installer issues a repeated START before the verify, which
        //     resets the pointer to 0) -- it is a pure protocol-accuracy check that
        //     the RTL's post-password byte counter matches the authoritative model.
        //     Ground truth from the standalone MAME x76f100.cpp port:
        //         GateA-norstart -> 08 09 0a 0b 0c 0d 0e 0f   (offset 8)
        begin : mame_parity
            integer i; reg a;
            i2c_start;
            authenticate(8'h81, READ_PASSWORD, a);   // NO repeated start before verify
            if (a !== 1'b0) begin
                $display("FAIL [read#7-mame-parity]: pw not accepted (ack=%b)", a);
                errors = errors + 1; end
            for (i = 0; i < 8; i = i + 1) rd[i] = 8'hxx;
            for (i = 0; i < 8; i = i + 1) read_byte((i==7)?1'b1:1'b0, rd[i]);
            i2c_stop;
            $display("  [read#7-mame-parity] no-rstart block0 read = %02h %02h %02h %02h %02h %02h %02h %02h (MAME=08 09 0a 0b 0c 0d 0e 0f)",
                rd[0],rd[1],rd[2],rd[3],rd[4],rd[5],rd[6],rd[7]);
            // MAME leaves m_byte=8 after the password load -> first read byte = data[8]=0x08.
            if (rd[0] !== 8'h08) begin
                $display("FAIL [read#7-mame-parity]: post-password read offset != MAME (got data[?]=%02h, MAME data[8]=08) -- RTL byte pointer off-by-one",
                    rd[0]);
                errors = errors + 1; end
            else
                $display("  [read#7-mame-parity] post-password byte pointer == MAME (offset 8)  OK");
        end

        if (errors == 0)
            $display("RESULT: PASS (x76f100_hypbbc2p)");
        else
            $display("RESULT: FAIL (x76f100_hypbbc2p, %0d errors)", errors);
        $finish;
    end
endmodule
