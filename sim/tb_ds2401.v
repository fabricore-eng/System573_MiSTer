`timescale 1ns/1ps
// Testbench for ds2401.v - acts as a 1-Wire master: reset/presence, Read ROM
// (0x33), shift out 64 bits, and verify family + serial + CRC8.
// CLK_FREQ_HZ = 1_000_000 => 1 clk == 1 microsecond in the DUT's time base.
module tb_ds2401;
    localparam [47:0] SERIAL = 48'h1234_5678_9ABC;

    reg  clk = 0, rst = 1;
    reg  master_low = 0;
    wire ds_pd;
    wire line = ~(master_low | ds_pd);   // wired-AND, pulled up to 1
    integer errors = 0;

    ds2401 #(.SERIAL(SERIAL), .CLK_FREQ_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .dq_in(line), .dq_pd(ds_pd),
        .load_we(1'b0), .load_addr(3'd0), .load_data(8'd0)
    );

    always #5 clk = ~clk;                 // 100 MHz; 1 clk == 1 us in the model
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask

    // CRC8 (Maxim, poly 0x8C reflected) over family+serial, matching the DUT.
    function [7:0] crc8(input [55:0] data);
        integer i; reg [7:0] c; reg b;
        begin
            c = 8'h00;
            for (i = 0; i < 56; i = i + 1) begin
                b = data[i] ^ c[0];
                c = c >> 1;
                if (b) c = c ^ 8'h8C;
            end
            crc8 = c;
        end
    endfunction

    task ow_reset; begin
        @(negedge clk); master_low = 1; wait_us(500);
        @(negedge clk); master_low = 0; wait_us(250);   // let presence finish
    end endtask

    // Write slot: pull low (short for 1, long for 0), then idle high. Total 75us
    // so the slave's 60us fixed slot completes with the line already released.
    task ow_write_bit(input b);
        integer low;
        begin
            low = b ? 6 : 50;
            @(negedge clk); master_low = 1; wait_us(low);
            @(negedge clk); master_low = 0; wait_us(75 - low);
        end
    endtask

    // Read slot: brief low to start, release, sample inside the window, idle.
    task ow_read_bit(output b);
        begin
            @(negedge clk); master_low = 1; wait_us(4);
            @(negedge clk); master_low = 0; wait_us(8);
            b = line;                     // sample at ~12us, before slave releases
            wait_us(63);                  // finish the 75us slot
        end
    endtask

    integer i;
    reg [7:0]  cmd;
    reg [63:0] rx;
    reg        bit_v;
    reg [63:0] expected;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0;
        wait_us(5);

        ow_reset;

        // Read ROM command 0x33, LSB first.
        cmd = 8'h33;
        for (i = 0; i < 8; i = i + 1) ow_write_bit(cmd[i]);

        // 64 ROM bits, LSB first.
        rx = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin
            ow_read_bit(bit_v);
            rx[i] = bit_v;
        end

        expected = {crc8({SERIAL, 8'h01}), SERIAL, 8'h01};

        if (rx[7:0] !== 8'h01) begin
            $display("FAIL: family code %02h (expected 01)", rx[7:0]);
            errors = errors + 1;
        end
        if (rx[55:8] !== SERIAL) begin
            $display("FAIL: serial %012h (expected %012h)", rx[55:8], SERIAL);
            errors = errors + 1;
        end
        if (rx[63:56] !== expected[63:56]) begin
            $display("FAIL: CRC %02h (expected %02h)", rx[63:56], expected[63:56]);
            errors = errors + 1;
        end
        if (rx !== expected) begin
            $display("FAIL: full ROM %016h (expected %016h)", rx, expected);
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (ds2401)  ROM=%016h", rx);
        else             $display("RESULT: FAIL (ds2401, %0d errors)", errors);
        $finish;
    end
endmodule
