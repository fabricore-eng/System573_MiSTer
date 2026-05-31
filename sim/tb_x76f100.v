`timescale 1ns/1ps
// Testbench for x76f100.v - acts as the System 573 BIOS bit-banging the
// security cartridge: drive RST for the response-to-reset, then run the
// I2C-like start / command / password / ack / read|write sequences.
//
// SDA is split into the host-driven level (sda_m -> dut.sda_i) and the
// device-driven level (dut.sda_o), exactly as the 573 ASIC wires IO0.
module tb_x76f100;
    localparam [63:0] READ_PASSWORD  = 64'h0102_0304_0506_0708;
    localparam [63:0] WRITE_PASSWORD = 64'h1112_1314_1516_1718;

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

    // ---- I2C-like master primitives ----
    task i2c_start; begin
        scl = 0; tk; sda_m = 1; tk; scl = 1; tk; sda_m = 0; tk; scl = 0; tk;
    end endtask

    task i2c_stop; begin
        scl = 0; tk; sda_m = 0; tk; scl = 1; tk; sda_m = 1; tk;
    end endtask

    // Send one byte MSB-first; return the device ACK bit (0 = ack).
    task send_byte(input [7:0] d, output ack);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                scl = 0; tk; sda_m = d[i]; tk; scl = 1; tk;
            end
            scl = 0; tk; sda_m = 1; tk; scl = 1; tk; // 9th clock: read ack
            ack = sda_o;
            scl = 0; tk;
        end
    endtask

    // Read one byte MSB-first; send ack_bit on the 9th clock (0 = ack/continue).
    task read_byte(input ack_bit, output [7:0] d);
        integer i;
        begin
            d = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                scl = 0; tk; sda_m = 1; tk; scl = 1; tk;
                d[i] = sda_o;
            end
            scl = 0; tk; sda_m = ack_bit; tk; scl = 1; tk; // 9th clock: master ack
            scl = 0; tk; sda_m = 1;
        end
    endtask

    // Read one response-to-reset byte: LSB-first, sampled on falling SCL.
    task read_rtr_byte(output [7:0] d);
        integer i;
        begin
            d = 8'h00;
            for (i = 0; i < 8; i = i + 1) begin
                scl = 1; tk; scl = 0; tk;
                d[i] = sda_o;
            end
        end
    endtask

    // Authenticate then run the appropriate transfer. cmd picks read/write+block.
    task authenticate(input [7:0] cmd, input [63:0] pw, output ack);
        integer i; reg a;
        begin
            send_byte(cmd, a);
            for (i = 0; i < 8; i = i + 1) send_byte(pwbyte(pw, i), a);
            send_byte(8'h55, ack); // verify; ack reflects accept(0)/reject(1)
        end
    endtask

    task check8(input [7:0] got, input [7:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %02h (expected %02h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    reg [7:0] b0, b1, b2, b3, d;
    reg       ack;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;

        // ---- enable chip + response to reset ----
        cs = 0; tk;
        sec_rst = 1; tk;                 // 0->1 -> response-to-reset
        read_rtr_byte(b0); read_rtr_byte(b1);
        read_rtr_byte(b2); read_rtr_byte(b3);
        check8(b0, 8'h19, "rtr[0]"); check8(b1, 8'h00, "rtr[1]");
        check8(b2, 8'haa, "rtr[2]"); check8(b3, 8'h55, "rtr[3]");

        // ---- authenticated READ of block 0 (data default = index) ----
        i2c_stop; i2c_start;
        authenticate(8'h81, READ_PASSWORD, ack);      // 0x81 = READ, block 0
        if (ack !== 1'b0) begin
            $display("FAIL: read password not accepted (ack=%b)", ack);
            errors = errors + 1;
        end
        i2c_start;                                     // repeated start: byte=0
        for (i = 0; i < 8; i = i + 1) begin
            read_byte((i == 7) ? 1'b1 : 1'b0, d);     // NAK the last byte
            check8(d, i[7:0], "read block0");
        end
        i2c_stop;

        // ---- authenticated WRITE of block 1, then read it back ----
        i2c_start;
        authenticate(8'h82, WRITE_PASSWORD, ack);     // 0x82 = WRITE, block 1
        if (ack !== 1'b0) begin
            $display("FAIL: write password not accepted (ack=%b)", ack);
            errors = errors + 1;
        end
        i2c_start;                                     // repeated start: byte=0
        for (i = 0; i < 8; i = i + 1) send_byte(8'hA0 + i[7:0], ack); // data
        i2c_stop;

        i2c_start;
        authenticate(8'h83, READ_PASSWORD, ack);      // 0x83 = READ, block 1
        i2c_start;                                     // repeated start: byte=0
        for (i = 0; i < 8; i = i + 1) begin
            read_byte((i == 7) ? 1'b1 : 1'b0, d);
            check8(d, 8'hA0 + i[7:0], "readback block1");
        end
        i2c_stop;

        // ---- wrong password must NAK ----
        i2c_start;
        authenticate(8'h81, 64'hDEAD_BEEF_DEAD_BEEF, ack);
        if (ack !== 1'b1) begin
            $display("FAIL: wrong password was accepted (ack=%b)", ack);
            errors = errors + 1;
        end
        i2c_stop;

        if (errors == 0)
            $display("RESULT: PASS (x76f100)  rtr=%02h%02h%02h%02h", b0, b1, b2, b3);
        else
            $display("RESULT: FAIL (x76f100, %0d errors)", errors);
        $finish;
    end
endmodule
