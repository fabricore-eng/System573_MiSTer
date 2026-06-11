`timescale 1ns/1ps
// Testbench for s573_seccart.v - drives the security cartridge the way the BIOS
// does: bit-banging the D0-D7 latch and reading IO0 / I0 back.
//
//  Part 1 (CART_TYPE 0, X76F100):  full authenticated block read through D0..D3 /
//          IO0, and a DS2401 Read-ROM through D4 / I0 (param-configured serial),
//          proving the security devices work through the bus glue unchanged.
//
//  Part 0 (CART_TYPE 0, X76F100):  replays the disassembled BIOS cart-type-IDENTIFY
//          waveform VERBATIM from the MAME differential trace
//          (local/seccart_presence/sectapA_trace.txt, BIOS leaf 0x800377xx):
//          latch writes 0,4,0 then 3 rounds of [RST pulse 8,A,8,0 + 32x
//          (write 2 / sample the IN1-visible sec_io0 / write 0)] then 4, each
//          round accumulating the response-to-reset LSB-first == 32'h1900AA55
//          (X76F100 type-2, our hardcoded RtR). This predicts the post-DSR-fix
//          silicon screen (the -11N-class state). Uses REAL latch semantics: one
//          latch_we pulse per value, latch_we low between writes.
//
//  Part 0b (OQ3 d_latch hardening): a WATCHDOG KICK (CPU store to 0x1f5c0000 --
//          d_latch input wiggles while latch_we=0, exactly what system573_top's
//          live exp1_wdata wiring produces) lands inside the RTR read loop. The
//          cassette pins must HOLD the latched value (MAME ksys573 security_w
//          semantics): pre-fix the combinational follow yanks SCL low mid-bit ->
//          a spurious RTR shift -> byte0 reads 0x09 not 0x19 (RED); post-fix the
//          registered latch holds and byte0 == 0x19 (GREEN).
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

    // latch_we held HIGH: every dl2 change is an INTENDED latch write (the
    // registered d_latch then follows one clk later, inside the >=3-clk task pacing).
    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut2 (
        .clk(clk), .rst(rst),
        .cart_type(2'd1),                 // X76F041
        .latch_we(1'b1), .d_latch(dl2), .io0_dir(1'b0),
        .load_eep_we(e_load_we), .load_eep_addr(e_load_addr), .load_eep_data(e_load_data),
        .load_ser_we(s_load_we), .load_ser_addr(s_load_addr), .load_ser_data(s_load_data),
        .sec_io0(sec_io0_2), .sec_in(sec_in_2), .sec_drdy(sec_drdy_2), .sec_irdy(sec_irdy_2)
    );

    // ---- Part 3 DUT: ZS01 (cart_type 2), loaded with the real gtrfrk5m dump ----
    // SDA WIRING DIFFERS: the ZS01 cassette drives SDA-out from CONTROL bit 6 (io0_dir,
    // ACTIVE-LOW) -- NOT D0. SCL=D1, CS=D2, RST=D3, DS2401=D4; readback = sec_io0.
    reg [7:0]  dl3   = 8'b0000_0100;  // cs=1(desel via D2), scl=0, rst=0, ds=0
    reg        io0_3 = 1'b0;          // control bit 6 (active-low): 0 -> SDA released(1)
    reg        e3_we = 0;  reg [12:0] e3_addr = 0;  reg [7:0] e3_data = 0;
    reg        s3_we = 0;  reg [2:0]  s3_addr = 0;  reg [7:0] s3_data = 0;
    wire       sec_io0_3, sec_irdy_3, sec_drdy_3;
    wire [7:0] sec_in_3;

    s573_seccart #(.DS_CLK_HZ(1_000_000)) dut3 (
        .clk(clk), .rst(rst),
        .cart_type(2'd2),                 // ZS01
        .latch_we(1'b1), .d_latch(dl3), .io0_dir(io0_3),
        .load_eep_we(e3_we), .load_eep_addr(e3_addr), .load_eep_data(e3_data),
        .load_ser_we(s3_we), .load_ser_addr(s3_addr), .load_ser_data(s3_data),
        .sec_io0(sec_io0_3), .sec_in(sec_in_3), .sec_drdy(sec_drdy_3), .sec_irdy(sec_irdy_3)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask
    task setb(input integer b, input v); begin @(negedge clk); dl[b] = v; latch_we = 1; @(negedge clk); latch_we = 0; end endtask

    // ---- Part 0 primitives: REAL latch semantics ----
    // One CPU store to 0x1f6a0000 = one latch_we pulse with the full byte
    // (latch_we = sel_seclatch & exp1_we for one cycle, low between writes).
    task bios_w(input [7:0] v); begin
        @(negedge clk); dl = v; latch_we = 1;
        @(negedge clk); latch_we = 0;
        repeat (2) @(posedge clk);
    end endtask
    // A watchdog kick mid-transaction: the CPU stores to 0x1f5c0000, so the EXP1
    // write data bus (which system573_top wires STRAIGHT into d_latch) carries the
    // kick value while latch_we stays LOW. The cassette pins must not see it.
    task wdog_kick_bus(input [7:0] busdata);
        reg [7:0] save; begin
        save = dl;
        @(negedge clk); dl = busdata;   // latch_we NOT asserted (not our select)
        repeat (3) @(posedge clk);
        @(negedge clk); dl = save;      // the bus moves on
        repeat (3) @(posedge clk);
    end endtask

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

    // =====================================================================
    // Part 3 infrastructure (ZS01 over dut3): the master drives the packet protocol.
    // SDA-out = io0_3 (control bit 6, ACTIVE-LOW): io0_3=0 releases SDA (high), io0_3=1
    // pulls it low. SCL=dl3[1], CS=dl3[2], RST=dl3[3], DS2401=dl3[4]; readback=sec_io0_3.
    // =====================================================================
    reg [7:0] z_eep [0:4115];   // gtrfrk5m gea26jaa.u1 (4116 bytes, ZS01 NVRAM + padding)
    reg [7:0] z_ser [0:7];      // gtrfrk5m gea26jaa.u6 (8 bytes)
    reg [7:0] z_cmdkey [0:7];   // command key from the dump ([4:11])

    task z_load_eep(input [12:0] a, input [7:0] v); begin
        @(negedge clk); e3_addr=a; e3_data=v; e3_we=1;
        @(negedge clk); e3_we=0; end
    endtask
    task z_load_ser(input [2:0] a, input [7:0] v); begin
        @(negedge clk); s3_addr=a; s3_data=v; s3_we=1;
        @(negedge clk); s3_we=0; end
    endtask

    // drive ZS01 SDA via control bit 6 (active-low): sda_drv=1 -> pull low (io0_3=1).
    task z_sda(input v); begin io0_3 = ~v; tk; end endtask   // v=1 release(high), v=0 low
    task z_scl(input v); begin dl3[1] = v; tk; end endtask

    // I2C-like start: SDA 1->0 while SCL high
    task z_start; begin
        dl3[1]=0;tk; io0_3=~1'b1;tk; dl3[1]=1;tk; io0_3=~1'b0;tk; dl3[1]=0;tk;
    end endtask
    task z_stop; begin
        dl3[1]=0;tk; io0_3=~1'b0;tk; dl3[1]=1;tk; io0_3=~1'b1;tk;
    end endtask
    task z_send(input [7:0] dat, output ack);
        integer i; begin
            for (i=7;i>=0;i=i-1) begin dl3[1]=0;tk; io0_3=~dat[i];tk; dl3[1]=1;tk; end
            dl3[1]=0;tk; io0_3=~1'b1;tk; dl3[1]=1;tk; ack=sec_io0_3; dl3[1]=0;tk; // 9th = dev ack
        end
    endtask
    task z_read(output [7:0] dat);   // master ACKs every byte (drives SDA low on 9th)
        integer i; begin
            dat=8'h00;
            for (i=7;i>=0;i=i-1) begin dl3[1]=0;tk; io0_3=~1'b1;tk; dl3[1]=1;tk; dat[i]=sec_io0_3; end
            dl3[1]=0;tk; io0_3=~1'b0;tk; dl3[1]=1;tk; dl3[1]=0;tk; io0_3=~1'b1; // master ack (low)
        end
    endtask
    task z_read_rtr(output [7:0] dat);   // RTR: device shifts MSB-first on falling SCL
        integer i; begin
            dat=8'h00;
            for (i=0;i<8;i=i+1) begin dl3[1]=1;tk; dl3[1]=0;tk; dat={dat[6:0],sec_io0_3}; end
        end
    endtask

    // ---- master-side ZS01 cipher (independent transliteration of zs01.cpp) ----
    function [7:0] ror8(input [7:0] x, input [2:0] r); ror8 = (x >> r) | (x << ((4'd8-r)&3'd7)); endfunction
    function [7:0] rol8(input [7:0] x, input [2:0] r); rol8 = (x << r) | (x >> ((4'd8-r)&3'd7)); endfunction
    function [15:0] z_crc(input [79:0] dd);
        integer a3,a2; reg [15:0] v; reg [7:0] b; begin
            v=16'hffff;
            for (a3=0;a3<10;a3=a3+1) begin
                b=dd[8*(9-a3)+:8]; v=v^{b,8'h00};
                for (a2=0;a2<8;a2=a2+1) v = v[15] ? ((v<<1)^16'h1021) : (v<<1);
            end
            z_crc = ~v;
        end
    endfunction

    reg [7:0] zpkt [0:11];
    reg [7:0] zrsp [0:11];
    // descending scramble with key (host->device); key bytes z_cmdkey[0..7] or rkey
    task z_encrypt(input [7:0] k0,k1,k2,k3,k4,k5,k6,k7);
        integer idx,kk; reg [7:0] prev,acc,kb,key[0:7]; begin
            key[0]=k0;key[1]=k1;key[2]=k2;key[3]=k3;key[4]=k4;key[5]=k5;key[6]=k6;key[7]=k7;
            prev=8'hff;
            for (idx=11;idx>=0;idx=idx-1) begin
                acc = key[0] + (zpkt[idx]^prev);
                for (kk=1;kk<=7;kk=kk+1) begin kb=key[kk]; acc=rol8(acc,kb[7:5]); acc=acc+(kb&8'h1f); end
                zpkt[idx]=acc; prev=acc;
            end
        end
    endtask
    // descending descramble of the response with the response key (== device decrypt)
    task z_decrypt(input [7:0] k0,k1,k2,k3,k4,k5,k6,k7);
        integer idx,kk; reg [7:0] prev,t1,t0,kb,key[0:7]; begin
            key[0]=k0;key[1]=k1;key[2]=k2;key[3]=k3;key[4]=k4;key[5]=k5;key[6]=k6;key[7]=k7;
            prev=8'hff;
            for (idx=11;idx>=0;idx=idx-1) begin
                t1=zrsp[idx]; t0=t1;
                for (kk=7;kk>=1;kk=kk-1) begin kb=key[kk]; t0=t0-(kb&8'h1f); t0=ror8(t0,kb[7:5]); end
                zrsp[idx]=(t0-key[0])^prev; prev=t1;
            end
        end
    endtask

    // Run one ZS01 command: build [cmd][addr][8 payload][crc], scramble with the cmd
    // key, clock in, read+descramble the 12-byte response with the response key.
    // bad_key=1 scrambles with the WRONG command key (negative control).
    task z_command(input [7:0] cmd, input [7:0] addr, input [63:0] payload,
                   input bad_key, input [63:0] rkey,
                   output [7:0] status, output [63:0] rdata);
        integer i; reg [15:0] crc; reg [7:0] k0,k1,k2,k3,k4,k5,k6,k7; reg lack; begin
            zpkt[0]=cmd; zpkt[1]=addr;
            for (i=0;i<8;i=i+1) zpkt[2+i]=payload[8*(7-i)+:8];
            crc = z_crc({zpkt[0],zpkt[1],zpkt[2],zpkt[3],zpkt[4],zpkt[5],zpkt[6],zpkt[7],zpkt[8],zpkt[9]});
            zpkt[10]=crc[15:8]; zpkt[11]=crc[7:0];
            k0=z_cmdkey[0]; k1=z_cmdkey[1]; k2=z_cmdkey[2]; k3=z_cmdkey[3];
            k4=z_cmdkey[4]; k5=z_cmdkey[5]; k6=z_cmdkey[6]; k7=z_cmdkey[7];
            if (bad_key) begin                 // wrong key -> device CRC fails
                k0=k0^8'hff; k1=k1^8'hff; k2=k2^8'hff; k3=k3^8'hff;
                k4=k4^8'hff; k5=k5^8'hff; k6=k6^8'hff; k7=k7^8'hff;
            end
            z_encrypt(k0,k1,k2,k3,k4,k5,k6,k7);
            z_start;
            for (i=0;i<12;i=i+1) z_send(zpkt[i], lack);
            for (i=0;i<12;i=i+1) z_read(zrsp[i]);
            z_decrypt(rkey[63:56],rkey[55:48],rkey[47:40],rkey[39:32],
                      rkey[31:24],rkey[23:16],rkey[15:8],rkey[7:0]);
            status = zrsp[0];
            rdata  = {zrsp[2],zrsp[3],zrsp[4],zrsp[5],zrsp[6],zrsp[7],zrsp[8],zrsp[9]};
        end
    endtask

    integer i;
    reg [7:0] b0,b1,b2,b3,d;
    reg       ack;
    reg [63:0] rom, exprom;
    reg        bv;
    reg [7:0] zst;
    reg [63:0] zdat;
    reg [15:0] zc;
    reg z_present;

    integer fh, fh3;
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
        // Part 3 (ZS01) uses gtrfrk5m's real dump, gated independently.
        z_present = 1'b0;
        fh3 = $fopen("secdata/gtrfrk5m_u1.hex", "r");
        if (fh3 != 0) begin
            $fclose(fh3);
            $readmemh("secdata/gtrfrk5m_u1.hex", z_eep);
            $readmemh("secdata/gtrfrk5m_u6.hex", z_ser);
            z_present = 1'b1;
        end

        repeat (4) @(posedge clk); @(negedge clk); rst = 0; tk;

        // =====================================================================
        // Part 0: the BIOS cart-type-IDENTIFY waveform, replayed verbatim from
        // the MAME trace (local/seccart_presence/sectapA_trace.txt @5.06483s):
        //   0,4,0 then 3x [8,A,8,0 + 32x(2,sample,0)] then 4.
        // CS = d_latch[2] (LOW = selected); RST pulse enters response-to-reset;
        // the A->8 falling SCL edge inside the pulse shifts out RTR bit 0, each
        // loop's trailing write-0 shifts the next. The BIOS samples the
        // IN1-visible bit (s573_io r_status[2] = sec_io0) while SCL is high and
        // accumulates LSB-first -> the X76F100 type-2 signature 0x1900AA55.
        // =====================================================================
        begin : bios_identify
            integer round, k;
            reg [31:0] rtr;
            bios_w(8'h00); bios_w(8'h04); bios_w(8'h00);
            for (round = 0; round < 3; round = round + 1) begin
                bios_w(8'h08); bios_w(8'h0A); bios_w(8'h08); bios_w(8'h00);
                rtr = 32'h0;
                for (k = 0; k < 32; k = k + 1) begin
                    bios_w(8'h02);                 // SCL high
                    rtr[k] = sec_io0;              // the IN1 bit-2 sample
                    bios_w(8'h00);                 // SCL low -> next RTR bit
                end
                if ({rtr[7:0], rtr[15:8], rtr[23:16], rtr[31:24]} !== 32'h1900AA55) begin
                    $display("FAIL: identify round %0d RTR=%02h%02h%02h%02h (want 1900AA55, X76F100 type-2)",
                             round, rtr[7:0], rtr[15:8], rtr[23:16], rtr[31:24]);
                    errors = errors + 1;
                end
            end
            bios_w(8'h04);                          // deselect, as the BIOS does
        end

        // =====================================================================
        // Part 0b: d_latch hold-through-watchdog-kick (MAME security_w latch
        // semantics). A kick (store of 0x0000 to 0x1f5c0000) lands inside the
        // RTR read loop, between the SCL-high write and the sample. Pre-fix the
        // combinational d_latch follows the live bus: SCL is yanked low mid-bit,
        // the X76F100 shifts a SPURIOUS bit, and byte0 accumulates 0x09 (RED).
        // Post-fix the registered latch holds: byte0 == 0x19 (GREEN).
        // =====================================================================
        begin : wdog_glitch
            integer k;
            reg [7:0] b;
            bios_w(8'h00);
            bios_w(8'h08); bios_w(8'h0A); bios_w(8'h08); bios_w(8'h00);  // RST pulse
            b = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                bios_w(8'h02);                     // SCL high
                if (k == 3) wdog_kick_bus(8'h00);  // the watchdog kick, mid-bit
                b[k] = sec_io0;
                bios_w(8'h00);                     // SCL low
            end
            if (b !== 8'h19) begin
                $display("FAIL: watchdog kick GLITCHED the X76 read: RTR byte0=%02h (want 19) -- d_latch followed the live EXP1 bus",
                         b);
                errors = errors + 1;
            end
            bios_w(8'h04);                          // deselect
        end

        // From here on the legacy parts change dl bit-at-a-time: hold latch_we
        // HIGH so every dl change is an intended latch write (the registered
        // latch follows one clk later, inside every task's >=3-clk pacing).
        @(negedge clk); dl = 8'b0000_0101; latch_we = 1;
        tk; tk;

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

      // =====================================================================
      // Part 3: ZS01 cart loaded with the REAL gtrfrk5m dump (dut3)
      //   This is the Feature-A clean validation target: gtrfrk5m is flash + ZS01.
      //   We load the real gea26jaa.u1 (4116-byte ZS01 NVRAM image) + .u6 through the
      //   new load ports, then drive the authenticated packet protocol:
      //     (a) response-to-reset = 5A 53 00 01
      //     (b) authenticated READ of address 0x00 returns the REAL decrypted data
      //         00 00 4a 41 00 00 f7 46 -- NOT the sim-default ramp 00..07
      //     (c) READ of address 0x01 returns the REAL 02 00 00 00 00 00 00 fd
      //     (d) READ config regs (0xFE) returns the dump's 47 45 41 32 36 00 00 00
      //     (e) READ internal DS2401 (0xFC) returns the loaded .u6 serial bytes
      //     (f) NEGATIVE CONTROL: a packet scrambled with the WRONG command key fails
      //         the device CRC and returns STATUS_ERROR (0x02), not OK.
      // =====================================================================
      if (!z_present) begin
        $display("NOTE: gtrfrk5m dump absent -- skipping ZS01 real-data test (run sim/gen_secdata.sh with dumps/)");
      end else begin
        // ---- stream the real .u1 (4116 B) + .u6 (8 B) in through the load ports ----
        for (i=0;i<4116;i=i+1) z_load_eep(i[12:0], z_eep[i]);
        for (i=0;i<8;   i=i+1) z_load_ser(i[2:0],  z_ser[i]);
        // the master needs the command key from the dump ([4:11]) to scramble packets.
        for (i=0;i<8;i=i+1) z_cmdkey[i] = z_eep[4+i];
        tk;

        // ---- (a) response to reset ----
        dl3[2]=0; tk;                    // CS low (D2) = select
        dl3[3]=1; tk;                    // RST high (D3) -> RTR
        z_read_rtr(b0); z_read_rtr(b1); z_read_rtr(b2); z_read_rtr(b3);
        if ({b0,b1,b2,b3} !== 32'h5a53_0001) begin
            $display("FAIL: zs01 rtr %02h%02h%02h%02h (want 5a530001)", b0,b1,b2,b3); errors=errors+1; end
        dl3[3]=0; tk;                    // RST low (device self-stops after RTR)

        // ---- (b) authenticated READ of address 0x00 = the real data ----
        z_command(8'h01, 8'h00, 64'hA0A1_A2A3_A4A5_A6A7, 1'b0, 64'hA0A1_A2A3_A4A5_A6A7, zst, zdat);
        if (zst !== 8'h00) begin $display("FAIL: zs01 read0 status=%02h (want 00)", zst); errors=errors+1; end
        if (zdat !== 64'h0000_4a41_0000_f746) begin
            $display("FAIL: zs01 read addr0 = %016h (want real 00004a410000f746)", zdat); errors=errors+1; end
        if (zdat === 64'h0001_0203_0405_0607) begin
            $display("FAIL: zs01 read addr0 is the SIM-DEFAULT ramp -- load not applied"); errors=errors+1; end

        // ---- (c) READ of address 0x01 = the real data ----
        z_command(8'h01, 8'h01, 64'hB0B1_B2B3_B4B5_B6B7, 1'b0, 64'hB0B1_B2B3_B4B5_B6B7, zst, zdat);
        if (zst !== 8'h00) begin $display("FAIL: zs01 read1 status=%02h", zst); errors=errors+1; end
        if (zdat !== 64'h0200_0000_0000_00fd) begin
            $display("FAIL: zs01 read addr1 = %016h (want real 020000000000 00fd)", zdat); errors=errors+1; end

        // ---- (d) READ config registers (address 0xFE) = the dump's config ----
        z_command(8'h01, 8'hfe, 64'hC0C1_C2C3_C4C5_C6C7, 1'b0, 64'hC0C1_C2C3_C4C5_C6C7, zst, zdat);
        if (zst !== 8'h00) begin $display("FAIL: zs01 cfg status=%02h", zst); errors=errors+1; end
        if (zdat !== 64'h4745_4132_3600_0000) begin
            $display("FAIL: zs01 config = %016h (want real 4745413236000000)", zdat); errors=errors+1; end

        // ---- (e) READ internal DS2401 (address 0xFC) = the loaded .u6 serial ----
        // MAME returns direct_read(7-i) for i=0..7 = file bytes 7,6,...,0.
        z_command(8'h01, 8'hfc, 64'hD0D1_D2D3_D4D5_D6D7, 1'b0, 64'hD0D1_D2D3_D4D5_D6D7, zst, zdat);
        if (zst !== 8'h00) begin $display("FAIL: zs01 ds2401 status=%02h", zst); errors=errors+1; end
        if (zdat !== {z_ser[7],z_ser[6],z_ser[5],z_ser[4],z_ser[3],z_ser[2],z_ser[1],z_ser[0]}) begin
            $display("FAIL: zs01 internal ds2401 = %016h (want loaded %02h%02h%02h%02h%02h%02h%02h%02h)",
                     zdat, z_ser[7],z_ser[6],z_ser[5],z_ser[4],z_ser[3],z_ser[2],z_ser[1],z_ser[0]);
            errors=errors+1; end

        // ---- (f) NEGATIVE CONTROL: wrong command key -> device CRC fails -> ERROR ----
        // On a bad-CRC packet the device does NOT update its response key (MAME only
        // sets m_response_key on a successful READ), so the error response is scrambled
        // with the STALE key = the previous (0xFC) command's payload D0..D7. Descramble
        // with that; the freshly-set rbuf[0]=STATUS_ERROR then decodes to 0x02.
        z_command(8'h01, 8'h00, 64'hE0E1_E2E3_E4E5_E6E7, 1'b1, 64'hD0D1_D2D3_D4D5_D6D7, zst, zdat);
        if (zst !== 8'h02) begin
            $display("FAIL: zs01 wrong-key did NOT report STATUS_ERROR (got %02h, want 02)", zst);
            errors=errors+1; end
        if (zst === 8'h00) begin
            $display("FAIL: zs01 wrong-key was ACCEPTED (status OK) -- auth not enforced"); errors=errors+1; end

        dl3[2]=1; tk;                    // deselect
      end // if (z_present)

        if (errors == 0) begin
            $display("RESULT: PASS (s573_seccart)");
            if (data_present) begin
                $display("  X76F041 pnchmn2 data[0..4] = 4a 41 00 00 74 (\"JA..t\") -- LOADED, not sim-default,");
                $display("  real cpw a8360282dd6c1004 gated OK (+ wrong-pw NAK), real-config CR=0xac lockout enforced,");
                $display("  loaded DS2401 ROM = %016h (real pnchmn2 d202030405060701)", rom);
            end else
                $display("  (X76F041 real-data Part 2 skipped: pnchmn2 dump absent)");
            if (z_present)
                $display("  ZS01 gtrfrk5m: authenticated READ addr0 = 00004a410000f746 (REAL, not default ramp),");
            else
                $display("  (ZS01 real-data Part 3 skipped: gtrfrk5m dump absent)");
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
