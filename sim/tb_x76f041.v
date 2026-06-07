`timescale 1ns/1ps
// Testbench for x76f041.v - drives the security cartridge like the 573 BIOS:
// response-to-reset, a password-free data write/read (BCR1 = 0x00), an
// authenticated configuration-register read (full command/address/password/
// 0xC0 handshake), and a wrong-password rejection.
module tb_x76f041;
    localparam [63:0] CONFIG_PASSWORD = 64'hC0C1_C2C3_C4C5_C6C7;
    // creg: BCR1=00 (data password-free), BCR2=11, CR=00, RR=22, RC=33, 44,55,66
    localparam [63:0] CONFIG_REGS     = 64'h0011_0022_3344_5566;

    reg  clk = 0, rst = 1;
    reg  cs = 1, sec_rst = 0, scl = 0, sda_m = 1;
    wire sda_o;
    integer errors = 0;

    x76f041 #(.CONFIG_PASSWORD(CONFIG_PASSWORD), .CONFIG_REGS(CONFIG_REGS)) dut (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o),
        // this tb uses the compile-time params; the load port is exercised by the
        // pnchmn2 real-image test in tb_s573_seccart.v.
        .load_we(1'b0), .load_addr(10'd0), .load_data(8'd0)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    function [7:0] cfgbyte(input integer i);
        cfgbyte = CONFIG_REGS[8*(7-i) +: 8];
    endfunction
    function [7:0] cpwbyte(input integer i);
        cpwbyte = CONFIG_PASSWORD[8*(7-i) +: 8];
    endfunction

    // ---- I2C-like master primitives ----
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
            scl = 0; tk; sda_m = 1; tk; scl = 1; tk;
            ack = sda_o;
            scl = 0; tk;
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

        // ---- enable + response to reset (0x19,0x55,0xAA,0x55) ----
        cs = 0; tk;
        sec_rst = 1; tk;
        read_rtr_byte(b0); read_rtr_byte(b1);
        read_rtr_byte(b2); read_rtr_byte(b3);
        check8(b0, 8'h19, "rtr[0]"); check8(b1, 8'h55, "rtr[1]");
        check8(b2, 8'haa, "rtr[2]"); check8(b3, 8'h55, "rtr[3]");

        // ---- password-free WRITE of 8 bytes at address 0x10 ----
        i2c_stop; i2c_start;
        send_byte(8'h00, ack);          // command: WRITE (BCR1)
        send_byte(8'h10, ack);          // address -> password-free -> WRITE_DATA
        for (i = 0; i < 8; i = i + 1) send_byte(8'hD0 + i[7:0], ack);
        i2c_stop;

        // ---- password-free READ back ----
        i2c_start;
        send_byte(8'h20, ack);          // command: READ
        send_byte(8'h10, ack);          // address -> READ_DATA
        for (i = 0; i < 8; i = i + 1) begin
            read_byte((i == 7) ? 1'b1 : 1'b0, d);
            check8(d, 8'hD0 + i[7:0], "readback");
        end
        i2c_stop;

        // ---- authenticated configuration-register READ ----
        i2c_start;
        send_byte(8'h80, ack);          // command: CONFIGURATION
        send_byte(8'h60, ack);          // address: READ CONFIG REGISTERS -> need pw
        for (i = 0; i < 8; i = i + 1) send_byte(cpwbyte(i), ack);
        send_byte(8'hc0, ack);          // verify; ack 0 = accepted
        if (ack !== 1'b0) begin
            $display("FAIL: config password not accepted (ack=%b)", ack);
            errors = errors + 1;
        end
        for (i = 0; i < 8; i = i + 1) begin
            read_byte((i == 7) ? 1'b1 : 1'b0, d);
            check8(d, cfgbyte(i), "config reg");
        end
        i2c_stop;

        // ---- wrong configuration password must NAK ----
        i2c_start;
        send_byte(8'h80, ack);
        send_byte(8'h60, ack);
        for (i = 0; i < 8; i = i + 1) send_byte(8'h00, ack);
        send_byte(8'hc0, ack);
        if (ack !== 1'b1) begin
            $display("FAIL: wrong config password accepted (ack=%b)", ack);
            errors = errors + 1;
        end
        i2c_stop;

        if (errors == 0)
            $display("RESULT: PASS (x76f041)  rtr=%02h%02h%02h%02h", b0, b1, b2, b3);
        else
            $display("RESULT: FAIL (x76f041, %0d errors)", errors);
        $finish;
    end
endmodule
