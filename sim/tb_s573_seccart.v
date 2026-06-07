`timescale 1ns/1ps
// Testbench for s573_seccart.v - drives the security cartridge the way the BIOS
// does: bit-banging the D0-D7 latch and reading IO0 / I0 back.
//
//  Part 1 (CART_TYPE 0, X76F100):  full authenticated block read through D0..D3 /
//          IO0, and a DS2401 Read-ROM through D4 / I0 (param-configured serial),
//          proving the security devices work through the bus glue unchanged.
//
//  Part 2 (CART_TYPE 1, X76F041):  loads the REAL Punch Mania 2 (pnchmn2) security
//          cart dumps -- gqa09ja.u1 (548-byte X76F041 image) and gqa09ja.u6 (8-byte
//          DS2401 serial) -- through the new boot-time load ports, then:
//            (a) proves the loaded CONFIG took effect: the dump's CR=0xac puts the
//                device in the MAME unauthorized-access lockout, so a plain READ is
//                NAKed (the sim-default config would NOT do this);
//            (b) overrides CR/BCR1 to a permissive value and reads the 512-byte data
//                array back, asserting the REAL pnchmn2 bytes ("JA..t" region marker)
//                come out -- NOT the sim-default 00,01,02,... ramp;
//            (c) authenticates a CONFIG-register read with the REAL config password
//                from the dump (positive), and a wrong password (negative control);
//            (d) reads the DS2401 ROM and asserts it is the loaded serial
//                d2 02 03 04 05 06 07 01 (CRC-first on the wire), not the param.
//
// DS_CLK_HZ = 1_000_000 -> 1 clk == 1 us in the DS2401 time base.
module tb_s573_seccart;
    localparam [63:0] READ_PASSWORD = 64'h0102_0304_0506_0708;
    localparam [47:0] DS_SERIAL     = 48'hABCD_EF12_3456;

    reg        clk = 0, rst = 1;

    // ---- Part 1 DUT: X76F100 (cart_type 0), param-configured ----
    reg        latch_we = 0;
    reg [7:0]  dl = 8'b0000_0101;   // sda=1(rel), scl=0, cs=1(desel), rst=0, ds=0
    wire       sec_io0, sec_irdy, sec_drdy;
    wire [7:0] sec_in;
    integer errors = 0;

    s573_seccart #(.READ_PASSWORD(READ_PASSWORD), .DS_SERIAL(DS_SERIAL), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst),
        .cart_type(2'd0),
        .latch_we(latch_we), .d_latch(dl), .io0_dir(1'b0),
        .load_eep_we(1'b0), .load_eep_addr(10'd0), .load_eep_data(8'd0),
        .load_ser_we(1'b0), .load_ser_addr(3'd0), .load_ser_data(8'd0),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy)
    );

    // ---- Part 2 DUT: X76F041 (cart_type 1), loaded with the real pnchmn2 dump ----
    reg [7:0]  dl2 = 8'b0000_0101;
    reg        e_load_we = 0;  reg [9:0] e_load_addr = 0;  reg [7:0] e_load_data = 0;
    reg        s_load_we = 0;  reg [2:0] s_load_addr = 0;  reg [7:0] s_load_data = 0;
    wire       sec_io0_2, sec_irdy_2, sec_drdy_2;
    wire [7:0] sec_in_2;

    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut2 (
        .clk(clk), .rst(rst),
        .cart_type(2'd1),                 // X76F041
        .latch_we(1'b0), .d_latch(dl2), .io0_dir(1'b0),
        .load_eep_we(e_load_we), .load_eep_addr(e_load_addr), .load_eep_data(e_load_data),
        .load_ser_we(s_load_we), .load_ser_addr(s_load_addr), .load_ser_data(s_load_data),
        .sec_io0(sec_io0_2), .sec_in(sec_in_2), .sec_drdy(sec_drdy_2), .sec_irdy(sec_irdy_2)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask
    task setb(input integer b, input v); begin @(negedge clk); dl[b] = v; latch_we = 1; @(negedge clk); latch_we = 0; end endtask

    // =====================================================================
    // Part 1 primitives (X76F100 over dut: D0=SDA, D1=SCL, D2=CS, D3=RST, IO0)
    // =====================================================================
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

    // ---- DS2401 1-Wire master over D4 of dut, read I0 ----
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

    // =====================================================================
    // Part 2 primitives (X76F041 over dut2: D0=SDA, D1=SCL, D2=CS, D3=RST, IO0)
    // =====================================================================
    task tk2; begin repeat (3) @(posedge clk); end endtask
    task i2c_start2; begin dl2[1]=0;tk2; dl2[0]=1;tk2; dl2[1]=1;tk2; dl2[0]=0;tk2; dl2[1]=0;tk2; end endtask
    task i2c_stop2;  begin dl2[1]=0;tk2; dl2[0]=0;tk2; dl2[1]=1;tk2; dl2[0]=1;tk2; end endtask
    task send_byte2(input [7:0] d, output ack);
        integer i; begin
            for (i=7;i>=0;i=i-1) begin dl2[1]=0;tk2; dl2[0]=d[i];tk2; dl2[1]=1;tk2; end
            dl2[1]=0;tk2; dl2[0]=1;tk2; dl2[1]=1;tk2; ack=sec_io0_2; dl2[1]=0;tk2;
        end
    endtask
    task read_byte2(input ack_bit, output [7:0] d);
        integer i; begin
            d=8'h00;
            for (i=7;i>=0;i=i-1) begin dl2[1]=0;tk2; dl2[0]=1;tk2; dl2[1]=1;tk2; d[i]=sec_io0_2; end
            dl2[1]=0;tk2; dl2[0]=ack_bit;tk2; dl2[1]=1;tk2; dl2[1]=0;tk2; dl2[0]=1;
        end
    endtask
    // DS2401 over D4 of dut2
    task ow2_reset; begin dl2[4]=1; wait_us(500); dl2[4]=0; wait_us(250); end endtask
    task ow2_write_bit(input b); integer low; begin
        low = b ? 6 : 50; dl2[4]=1; wait_us(low); dl2[4]=0; wait_us(75-low); end
    endtask
    task ow2_read_bit(output b); begin
        dl2[4]=1; wait_us(4); dl2[4]=0; wait_us(8); b=sec_in_2[0]; wait_us(63); end
    endtask

    // ---- real pnchmn2 dump images, loaded at boot ----
    reg [7:0] eep_img [0:547];   // gqa09ja.u1 (548 bytes)
    reg [7:0] ser_img [0:7];     // gqa09ja.u6 (8 bytes)

    task load_eep_byte(input [9:0] a, input [7:0] v); begin
        @(negedge clk); e_load_addr=a; e_load_data=v; e_load_we=1;
        @(negedge clk); e_load_we=0; end
    endtask
    task load_ser_byte(input [2:0] a, input [7:0] v); begin
        @(negedge clk); s_load_addr=a; s_load_data=v; s_load_we=1;
        @(negedge clk); s_load_we=0; end
    endtask

    integer i;
    reg [7:0] b0,b1,b2,b3,d;
    reg       ack;
    reg [63:0] rom, exprom;
    reg        bv;

    integer fh;
    reg data_present;

    initial begin
        // The pnchmn2 dump is copyrighted + gitignored; sim/gen_secdata.sh derives the
        // hex fixtures from it before the run. If they are absent (a machine without
        // the dump) we SKIP Part 2 so the suite still passes -- the real-data
        // assertions run wherever the dump exists.
        data_present = 1'b0;
        fh = $fopen("secdata/pnchmn2_u1.hex", "r");
        if (fh != 0) begin
            $fclose(fh);
            $readmemh("secdata/pnchmn2_u1.hex", eep_img);
            $readmemh("secdata/pnchmn2_u6.hex", ser_img);
            data_present = 1'b1;
        end

        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;

        // =====================================================================
        // Part 1: X76F100 + param DS2401 through dut (unchanged regression)
        // =====================================================================
        dl[2] = 0;                       // CS low = select EEPROM
        dl[3] = 1; tk;                   // RST high -> response to reset
        read_rtr_byte(b0); read_rtr_byte(b1); read_rtr_byte(b2); read_rtr_byte(b3);
        if ({b0,b1,b2,b3} !== 32'h1900_AA55) begin
            $display("FAIL: rtr %02h%02h%02h%02h", b0,b1,b2,b3); errors=errors+1; end

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

        ow_reset;
        for (i=0;i<8;i=i+1) ow_write_bit((8'h33 >> i) & 1'b1);
        rom = 64'd0;
        for (i=0;i<64;i=i+1) begin ow_read_bit(bv); rom[i]=bv; end
        exprom = {crc8({DS_SERIAL, 8'h01}), DS_SERIAL, 8'h01};
        if (rom !== exprom) begin
            $display("FAIL: ds2401 ROM %016h (expected %016h)", rom, exprom); errors=errors+1; end

        @(negedge clk); latch_we = 1; @(negedge clk); latch_we = 0;
        if (sec_drdy !== 1'b1) begin $display("FAIL: drdy not set"); errors=errors+1; end

      // =====================================================================
      // Part 2: X76F041 cart loaded with the REAL pnchmn2 dump (dut2)
      // =====================================================================
      if (!data_present) begin
        $display("NOTE: pnchmn2 dump absent -- skipping X76F041 real-data test (run sim/gen_secdata.sh with dumps/)");
      end else begin
        // ---- stream the real images in through the load ports ----
        for (i=0;i<548;i=i+1) load_eep_byte(i[9:0], eep_img[i]);
        for (i=0;i<8;  i=i+1) load_ser_byte(i[2:0], ser_img[i]);
        tk2;

        // ---- response to reset on the X76F041 ----
        dl2[2]=0; tk2;                   // CS low
        dl2[3]=1; tk2;                   // RST high -> RTR
        // X76F041 RTR = 0x19,0x55,0xAA,0x55, LSB-first on falling SCL (same framing
        // as x76f100 RTR read).
        read_rtr2(b0); read_rtr2(b1); read_rtr2(b2); read_rtr2(b3);
        if ({b0,b1,b2,b3} !== 32'h19_55_AA_55) begin
            $display("FAIL: f041 rtr %02h%02h%02h%02h", b0,b1,b2,b3); errors=errors+1; end
        dl2[1]=0;tk2; dl2[0]=0;tk2; dl2[1]=1;tk2; dl2[0]=1;tk2;   // stop

        // ---- (a) the loaded CONFIG (CR=0xac) must lock out a plain READ ----
        // This is the MAME unauthorized-access lockout: load_address() NAKs. Proves
        // the real config registers reached creg[] (the sim-default config does NOT
        // lock out -- Part-1-style reads succeed).
        i2c_start2;
        send_byte2(8'h20, ack);          // READ command
        send_byte2(8'h00, ack);          // address 0x00 -> load_address lockout
        if (ack !== 1'b1) begin
            $display("FAIL: f041 real-config lockout not asserted (addr ack=%b, want 1)", ack);
            errors=errors+1;
        end
        i2c_stop2;

        // ---- (b) override CR/BCR1 permissive, read back the REAL data bytes ----
        // creg image offsets: BCR1=28, BCR2=29, CR=30, RR=31, RC=32.
        load_eep_byte(10'd28, 8'h00);    // BCR1 = 0x00 (password-free data read)
        load_eep_byte(10'd30, 8'h00);    // CR   = 0x00 (no lockout / retry)
        tk2;
        i2c_start2;
        send_byte2(8'h20, ack);          // READ
        send_byte2(8'h00, ack);          // address 0x00 -> READ_DATA (now allowed)
        if (ack !== 1'b0) begin
            $display("FAIL: f041 permissive read addr ack=%b (want 0)", ack); errors=errors+1; end
        // Real pnchmn2 data[0..4] = 4a 41 00 00 74 ("JA" region marker + 't').
        // The sim-default would be 00 01 02 03 04 -- assert we get the LOADED bytes.
        check_f041(0, 8'h4a); check_f041(1, 8'h41); check_f041(2, 8'h00);
        check_f041(3, 8'h00);
        read_byte2(1'b1, d);
        if (d !== 8'h74) begin $display("FAIL: f041 data[4]=%02h (want 74 real)", d); errors=errors+1; end
        if (d === 8'h04) begin $display("FAIL: f041 data[4] is the SIM-DEFAULT 04, load not applied"); errors=errors+1; end
        i2c_stop2;

        // ---- (c) CONFIG-register read gated by the REAL config password ----
        // real cpw = a8 36 02 82 dd 6c 10 04 (image offset 20..27).
        i2c_start2;
        send_byte2(8'h80, ack);          // CONFIGURATION
        send_byte2(8'h60, ack);          // sub-cmd: READ CONFIG REGISTERS (needs cpw)
        send_byte2(8'ha8,ack); send_byte2(8'h36,ack); send_byte2(8'h02,ack); send_byte2(8'h82,ack);
        send_byte2(8'hdd,ack); send_byte2(8'h6c,ack); send_byte2(8'h10,ack); send_byte2(8'h04,ack);
        send_byte2(8'hc0, ack);          // verify
        if (ack !== 1'b0) begin
            $display("FAIL: f041 REAL config password rejected (verify ack=%b)", ack); errors=errors+1; end
        // BCR1 was overridden to 0x00, BCR2 still loaded 0x00, CR overridden 0x00.
        read_byte2(1'b0, d);   // creg[0]=BCR1
        if (d !== 8'h00) begin $display("FAIL: f041 cfg BCR1=%02h", d); errors=errors+1; end
        read_byte2(1'b1, d);   // creg[1]=BCR2
        if (d !== 8'h00) begin $display("FAIL: f041 cfg BCR2=%02h", d); errors=errors+1; end
        i2c_stop2;

        // ---- (c-neg) wrong config password must NAK ----
        i2c_start2;
        send_byte2(8'h80, ack);
        send_byte2(8'h60, ack);
        for (i=0;i<8;i=i+1) send_byte2(8'h00, ack);
        send_byte2(8'hc0, ack);
        if (ack !== 1'b1) begin
            $display("FAIL: f041 wrong config password accepted (ack=%b, want 1=NAK)", ack); errors=errors+1; end
        i2c_stop2;
        dl2[2]=1; tk2;                   // deselect
        dl2[3]=0; tk2;

        // ---- (d) DS2401 loaded serial: real d2 02 03 04 05 06 07 01 ----
        // over-the-wire ROM (LSB-first, m_data[7]=family first) == file bytes 7..0
        // reversed into rom[63:0] = {file[0],file[1],...,file[7]} as bytes... our rom
        // is streamed rom[0] first; expected wire stream byte k = file[7-k]. Assemble
        // the 64-bit value as read out: rom[i] for i=0..63.
        ow2_reset;
        for (i=0;i<8;i=i+1) ow2_write_bit((8'h33 >> i) & 1'b1);
        rom = 64'd0;
        for (i=0;i<64;i=i+1) begin ow2_read_bit(bv); rom[i]=bv; end
        // expected: rom[8*(7-k)+:8] = file byte k  =>  rom = {u6[0],u6[1],...,u6[7]}
        exprom = {ser_img[0],ser_img[1],ser_img[2],ser_img[3],
                  ser_img[4],ser_img[5],ser_img[6],ser_img[7]};
        if (rom !== exprom) begin
            $display("FAIL: f041-cart ds2401 ROM %016h (expected loaded %016h)", rom, exprom);
            errors=errors+1; end
      end // if (data_present)

        if (errors == 0) begin
            $display("RESULT: PASS (s573_seccart)");
            if (data_present) begin
                $display("  X76F041 pnchmn2 data[0..4] = 4a 41 00 00 74 (\"JA..t\") -- LOADED, not sim-default,");
                $display("  real cpw a8360282dd6c1004 gated OK (+ wrong-pw NAK), real-config CR=0xac lockout enforced,");
                $display("  loaded DS2401 ROM = %016h (real pnchmn2 d202030405060701)", rom);
            end else
                $display("  (X76F041 real-data Part 2 skipped: pnchmn2 dump absent)");
        end else
            $display("RESULT: FAIL (s573_seccart, %0d errors)", errors);
        $finish;
    end

    // ---- helpers that need to be tasks (called above) ----
    task read_rtr2(output [7:0] d);
        integer i; begin
            d=8'h00;
            for (i=0;i<8;i=i+1) begin dl2[1]=1;tk2; dl2[1]=0;tk2; d[i]=sec_io0_2; end
        end
    endtask
    task check_f041(input integer idx, input [7:0] exp);
        reg [7:0] g; begin
            read_byte2(1'b0, g);
            if (g !== exp) begin
                $display("FAIL: f041 data[%0d]=%02h (want %02h real)", idx, g, exp);
                errors=errors+1;
            end
        end
    endtask
endmodule
