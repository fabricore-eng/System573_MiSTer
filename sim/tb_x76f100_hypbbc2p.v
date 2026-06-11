`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_x76f100_hypbbc2p.v - RED/GREEN reproduction of the hypbbc2p in-game security
// check (game fn 0x80036ec4, disassembled in workflow w135q1s92), proving the new
// x76f100.v image-LOAD port turns the "-3N INCORRECT SECURITY CASSETTE" wall green.
//
// The game program (loaded from CD) authenticates the X76F100 by sending an 8-byte
// READ PASSWORD it carries in plaintext:  e9 34 df 40 7a d1 a7 ff
// On a mismatch the chip NAKs the 0x55 verify byte and the game returns -3. On a
// match it READs the cassette and checks ONLY:
//   data[0] == 0x4a && data[1] == 0x41          ("JA" region)
//   data[4] == (~(data[0] + data[1]) & 0xff)     (= 0x74 for "JA")
//
//   RED   : no image loaded (read pw defaults to 0) -> verify NAKs -> BIOS code -3.
//   GREEN : load the synth .u1 -> verify ACCEPTs -> read data -> all predicates pass.
//   CONTROLS: a zero-password image still NAKs (-3 calibration); a correct-pw image
//             whose data[4] is wrong fails the checksum predicate (-11N calibration).
//
// Pure-Verilog -- the X76F100 model is Verilog, so no VHDL/NVC is needed. The host
// bit-bang primitives mirror tb_x76f100.v exactly.
// -----------------------------------------------------------------------------
module tb_x76f100_hypbbc2p;
    // The game's plaintext read password (sent MSB-first as 8 bytes).
    localparam [63:0] HYPBBC2P_READ_PW = 64'he934_df40_7ad1_a7ff;

    reg  clk = 0, rst = 1;
    reg  cs = 1, sec_rst = 0, scl = 0, sda_m = 1;
    wire sda_o;
    // image-load port
    reg        load_we   = 0;
    reg [9:0]  load_addr = 0;
    reg [7:0]  load_data = 0;
    integer errors = 0;

    // NOTE: the params default to 0 (a blank chip), exactly the silicon wall. The
    // GREEN case overrides them via the new load port -- never via the params.
    x76f100 dut (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o),
        .load_we(load_we), .load_addr(load_addr), .load_data(load_data)
    );

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    function [7:0] pwbyte(input [63:0] pw, input integer i);
        pwbyte = pw[8*(7-i) +: 8];
    endfunction

    // ---- I2C-like master primitives (identical to tb_x76f100.v) ----
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
            scl = 0; tk; sda_m = 1; tk; scl = 1; tk; // 9th clock: read ack
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
            scl = 0; tk; sda_m = ack_bit; tk; scl = 1; tk; // 9th clock: master ack
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

    // Authenticate (command + 8 password bytes + 0x55 verify). ack = 0 accept, 1 NAK.
    task authenticate(input [7:0] cmd, input [63:0] pw, output ack);
        integer i; reg a;
        begin
            send_byte(cmd, a);
            for (i = 0; i < 8; i = i + 1) send_byte(pwbyte(pw, i), a);
            send_byte(8'h55, ack); // verify; ack reflects accept(0)/reject(1)
        end
    endtask

    // ---- the synthesized .u1 image (must match tools/gen_seccart_u1.py) ----
    reg [7:0] u1 [0:131];

    // Stream a 132-byte X76F100 .u1 image through the boot load port (byte at a time).
    task load_image(input [8:0] len);
        integer i;
        begin
            for (i = 0; i < len; i = i + 1) begin
                @(posedge clk);
                load_we   <= 1'b1;
                load_addr <= i[9:0];
                load_data <= u1[i];
                @(posedge clk);
                load_we   <= 1'b0;
            end
            @(posedge clk);
        end
    endtask

    integer m;
    task build_u1(input [7:0] d0, input [7:0] d1, input [7:0] d4);
        begin
            for (m = 0; m < 132; m = m + 1) u1[m] = 8'h00;
            u1[0]=8'h19; u1[1]=8'h00; u1[2]=8'haa; u1[3]=8'h55;        // RtR (dropped)
            // [4:12] write password = 0 (already cleared)
            u1[12]=8'he9; u1[13]=8'h34; u1[14]=8'hdf; u1[15]=8'h40;    // read pw
            u1[16]=8'h7a; u1[17]=8'hd1; u1[18]=8'ha7; u1[19]=8'hff;
            u1[20]=d0; u1[21]=d1; u1[24]=d4;                           // data[0],[1],[4]
        end
    endtask

    task expect_eq(input [7:0] got, input [7:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %02h (expected %02h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    integer i;
    reg [7:0] r0, r1, r2, r3, d;
    reg [7:0] dat [0:7];
    reg       ack, pred_region, pred_csum, bios_pass;
    reg       reset_dut;

    // Pulse a system reset (clears only the volatile bit-bang state, NOT NVRAM).
    task pulse_reset; begin
        rst = 1; cs = 1; sec_rst = 0; scl = 0; sda_m = 1; tk; tk;
        @(negedge clk); rst = 0; tk;
    end endtask

    // Run the full game-style check against the currently loaded NVRAM. Returns
    // ack (verify NAK -> -3) and, on accept, the read-data predicates.
    task run_check(output verify_ack, output [7:0] od0, output [7:0] od1, output [7:0] od4);
        begin
            cs = 0; tk;
            sec_rst = 1; tk;                       // RtR
            read_rtr_byte(r0); read_rtr_byte(r1);
            read_rtr_byte(r2); read_rtr_byte(r3);
            expect_eq(r0, 8'h19, "rtr0"); expect_eq(r1, 8'h00, "rtr1");
            expect_eq(r2, 8'haa, "rtr2"); expect_eq(r3, 8'h55, "rtr3");
            // step (3): authenticated READ with the game's plaintext read password.
            i2c_stop; i2c_start;
            authenticate(8'h81, HYPBBC2P_READ_PW, verify_ack);  // 0x81 = READ block 0
            od0 = 8'h00; od1 = 8'h00; od4 = 8'h00;
            if (verify_ack === 1'b0) begin
                i2c_start;                          // repeated start: byte = 0
                for (i = 0; i < 8; i = i + 1)
                    read_byte((i == 7) ? 1'b1 : 1'b0, dat[i]);
                od0 = dat[0]; od1 = dat[1]; od4 = dat[4];
            end
            i2c_stop;
            sec_rst = 0; cs = 1; tk;
        end
    endtask

    reg [7:0] g0, g1, g4;

    initial begin
        // =========================== RED ===========================
        // No image loaded: the read password defaults to 0. The game sends
        // e9 34 df 40 ... -> the chip NAKs the 0x55 verify -> game returns -3.
        pulse_reset;
        run_check(ack, g0, g1, g4);
        $display("RED  : ack=%b (NAK=1 expected)  -> BIOS code %0d", ack, ack ? -3 : 0);
        if (ack !== 1'b1) begin
            $display("FAIL: RED expected NAK (the -3 wall) but the blank chip ACCEPTED");
            errors = errors + 1;
        end

        // =========================== GREEN =========================
        // Load the synth .u1 (correct read pw + JA region + valid checksum), then the
        // identical game check now passes the password AND every data predicate.
        build_u1(8'h4a, 8'h41, 8'h74);             // "JA", data[4]=~(4a+41)&ff=0x74
        load_image(132);
        pulse_reset;
        run_check(ack, g0, g1, g4);
        pred_region = (g0 == 8'h4a) && (g1 == 8'h41);
        pred_csum   = ((~(g0 + g1)) & 8'hff) == g4;
        bios_pass   = (ack === 1'b0) && pred_region && pred_csum;
        $display("GREEN: ack=%b (ACCEPT=0)  data[0]=%02h data[1]=%02h data[4]=%02h",
                 ack, g0, g1, g4);
        $display("GREEN: region(\"JA\")=%b checksum=%b -> BIOS code %0d",
                 pred_region, pred_csum, bios_pass ? 0 : -1);
        if (ack !== 1'b0) begin
            $display("FAIL: GREEN read password not accepted (ack=%b)", ack); errors = errors + 1;
        end
        expect_eq(g0, 8'h4a, "GREEN data[0]");
        expect_eq(g1, 8'h41, "GREEN data[1]");
        expect_eq(g4, 8'h74, "GREEN data[4]");
        if (!pred_region) begin $display("FAIL: GREEN region predicate"); errors = errors + 1; end
        if (!pred_csum)   begin $display("FAIL: GREEN checksum predicate"); errors = errors + 1; end
        if (!bios_pass)   begin $display("FAIL: GREEN BIOS would not return 0"); errors = errors + 1; end

        // ===================== CONTROL A: zero-pw image still NAKs (-3) ============
        // An image whose READ PASSWORD is all-zero must NAK exactly like the blank
        // chip -- proves the GREEN accept comes from the loaded password, not the load
        // port short-circuiting authentication.
        build_u1(8'h4a, 8'h41, 8'h74);
        u1[12]=8'h00; u1[13]=8'h00; u1[14]=8'h00; u1[15]=8'h00;
        u1[16]=8'h00; u1[17]=8'h00; u1[18]=8'h00; u1[19]=8'h00;
        load_image(132);
        pulse_reset;
        run_check(ack, g0, g1, g4);
        $display("CTRL-A: zero-pw image ack=%b -> BIOS code %0d (NAK/-3 expected)",
                 ack, ack ? -3 : 0);
        if (ack !== 1'b1) begin
            $display("FAIL: CTRL-A zero-pw image should NAK (-3)"); errors = errors + 1;
        end

        // ===================== CONTROL B: correct pw but bad data[4] -> predicate fail
        // The password matches (verify ACCEPTs, the read succeeds) but data[4] is wrong,
        // so the game's checksum predicate fails -- this calibrates the -11N path
        // (auth OK, data invalid), distinct from the -3 (auth) wall.
        build_u1(8'h4a, 8'h41, 8'h00);             // checksum byte deliberately wrong
        load_image(132);
        pulse_reset;
        run_check(ack, g0, g1, g4);
        pred_csum = ((~(g0 + g1)) & 8'hff) == g4;
        $display("CTRL-B: correct-pw bad-csum ack=%b data[4]=%02h checksum=%b -> BIOS code %0d",
                 ack, g4, pred_csum, (ack === 1'b0 && pred_csum) ? 0 : -11);
        if (ack !== 1'b0) begin
            $display("FAIL: CTRL-B password should still be accepted"); errors = errors + 1;
        end
        if (pred_csum) begin
            $display("FAIL: CTRL-B checksum should FAIL with data[4]=00"); errors = errors + 1;
        end

        if (errors == 0)
            $display("RESULT: PASS (x76f100_hypbbc2p)  RED=-3  GREEN=0  ctrls calibrate -3/-11");
        else
            $display("RESULT: FAIL (x76f100_hypbbc2p, %0d errors)", errors);
        $finish;
    end
endmodule
