`timescale 1ns/1ps
// Testbench for s573_seccart.v - drives the security cartridge the way the BIOS
// does: bit-banging the D0-D7 latch and reading IO0 / I0 back. Runs a full
// X76F100 authenticated block read through D0..D3 / IO0, and a DS2401 Read-ROM
// through D4 / I0, proving the security devices work through the bus glue.
// DS_CLK_HZ = 1_000_000 -> 1 clk == 1 us in the DS2401 time base.
module tb_s573_seccart;
    localparam [63:0] READ_PASSWORD = 64'h0102_0304_0506_0708;
    localparam [47:0] DS_SERIAL     = 48'hABCD_EF12_3456;

    reg        clk = 0, rst = 1;
    reg        latch_we = 0;
    reg [7:0]  dl = 8'b0000_0101;   // sda=1(rel), scl=0, cs=1(desel), rst=0, ds=0
    wire       sec_io0, sec_irdy, sec_drdy;
    wire [7:0] sec_in;
    integer errors = 0;

    s573_seccart #(.READ_PASSWORD(READ_PASSWORD), .DS_SERIAL(DS_SERIAL), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .latch_we(latch_we), .d_latch(dl), .io0_dir(1'b0),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask
    task setb(input integer b, input v); begin @(negedge clk); dl[b] = v; latch_we = 1; @(negedge clk); latch_we = 0; end endtask

    // ---- X76F100 master over D0=SDA, D1=SCL, D2=CS, D3=RST, read IO0 ----
    task scl(input v); begin dl[1] = v; tk; end endtask
    task sda(input v); begin dl[0] = v; tk; end endtask

    task i2c_start; begin dl[1]=0;tk; dl[0]=1;tk; dl[1]=1;tk; dl[0]=0;tk; dl[1]=0;tk; end endtask

    task send_byte(input [7:0] d, output ack);
        integer i; begin
            for (i=7;i>=0;i=i-1) begin dl[1]=0;tk; dl[0]=d[i];tk; dl[1]=1;tk; end
            dl[1]=0;tk; dl[0]=1;tk; dl[1]=1;tk; ack=sec_io0; dl[1]=0;tk;
        end
    endtask
    task read_byte(input ack_bit, output [7:0] d);
        integer i; begin
            d=8'h00;
            for (i=7;i>=0;i=i-1) begin dl[1]=0;tk; dl[0]=1;tk; dl[1]=1;tk; d[i]=sec_io0; end
            dl[1]=0;tk; dl[0]=ack_bit;tk; dl[1]=1;tk; dl[1]=0;tk; dl[0]=1;
        end
    endtask
    task read_rtr_byte(output [7:0] d);
        integer i; begin
            d=8'h00;
            for (i=0;i<8;i=i+1) begin dl[1]=1;tk; dl[1]=0;tk; d[i]=sec_io0; end
        end
    endtask
    function [7:0] pwbyte(input [63:0] pw, input integer i); pwbyte = pw[8*(7-i) +: 8]; endfunction

    // ---- DS2401 1-Wire master over D4, read I0 ----
    task ow_low;     begin dl[4]=1; tk; end endtask
    task ow_release; begin dl[4]=0; tk; end endtask
    task ow_reset; begin ow_low; wait_us(500); ow_release; wait_us(250); end endtask
    task ow_write_bit(input b); integer low; begin
        low = b ? 6 : 50; dl[4]=1; wait_us(low); dl[4]=0; wait_us(75-low); end
    endtask
    task ow_read_bit(output b); begin
        dl[4]=1; wait_us(4); dl[4]=0; wait_us(8); b=sec_in[0]; wait_us(63); end
    endtask
    function [7:0] crc8(input [55:0] data);
        integer i; reg [7:0] c; reg bt; begin
            c=8'h00;
            for (i=0;i<56;i=i+1) begin bt=data[i]^c[0]; c=c>>1; if (bt) c=c^8'h8C; end
            crc8=c; end
    endfunction

    integer i;
    reg [7:0] b0,b1,b2,b3,d;
    reg       ack;
    reg [63:0] rom, exprom;
    reg        bv;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;

        // ===== X76F100 through the latch =====
        dl[2] = 0;                       // CS low = select EEPROM
        dl[3] = 1; tk;                   // RST high -> response to reset
        read_rtr_byte(b0); read_rtr_byte(b1); read_rtr_byte(b2); read_rtr_byte(b3);
        if ({b0,b1,b2,b3} !== 32'h1900_AA55) begin
            $display("FAIL: rtr %02h%02h%02h%02h", b0,b1,b2,b3); errors=errors+1; end

        // STOP then authenticated READ of block 0
        dl[1]=0;tk; dl[0]=0;tk; dl[1]=1;tk; dl[0]=1;tk;       // stop
        i2c_start;
        send_byte(8'h81, ack);                                 // READ block 0
        for (i=0;i<8;i=i+1) send_byte(pwbyte(READ_PASSWORD,i), ack);
        send_byte(8'h55, ack);                                 // verify
        if (ack !== 1'b0) begin $display("FAIL: x76 auth ack=%b", ack); errors=errors+1; end
        i2c_start;                                             // repeated start
        for (i=0;i<8;i=i+1) begin
            read_byte((i==7)?1'b1:1'b0, d);
            if (d !== i[7:0]) begin $display("FAIL: x76 data[%0d]=%02h", i, d); errors=errors+1; end
        end
        dl[2] = 1; tk;                   // deselect EEPROM
        dl[3] = 0; tk;                   // RST low

        // ===== DS2401 through the latch =====
        ow_reset;
        for (i=0;i<8;i=i+1) ow_write_bit((8'h33 >> i) & 1'b1);
        rom = 64'd0;
        for (i=0;i<64;i=i+1) begin ow_read_bit(bv); rom[i]=bv; end
        exprom = {crc8({DS_SERIAL, 8'h01}), DS_SERIAL, 8'h01};
        if (rom !== exprom) begin
            $display("FAIL: ds2401 ROM %016h (expected %016h)", rom, exprom); errors=errors+1; end

        // a latch register write raises DRDY
        @(negedge clk); latch_we = 1; @(negedge clk); latch_we = 0;
        if (sec_drdy !== 1'b1) begin $display("FAIL: drdy not set"); errors=errors+1; end

        if (errors == 0) $display("RESULT: PASS (s573_seccart)  ds2401=%016h", rom);
        else             $display("RESULT: FAIL (s573_seccart, %0d errors)", errors);
        $finish;
    end
endmodule
