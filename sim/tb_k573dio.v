`timescale 1ns/1ps
// Testbench for k573dio.v - the BEMANI Digital I/O board register block.
// Checks the ID/status words, the MP3 address window and crypto-key latches,
// the lamp-output bit remap, the DRAM port auto-increment, and then bit-bangs
// the board DS2401 1-Wire ROM through register 0xee to verify integration.
// DS_CLK_HZ = 1_000_000 -> 1 clk == 1 microsecond in the DS2401 time base.
module tb_k573dio;
    localparam [47:0] DS_SERIAL = 48'hABCD_EF12_3456;

    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [7:0]  off = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire [31:0] lamp;
    wire [15:0] crypto_key1, crypto_key2, crypto_key3;
    wire [31:0] mp3_start, mp3_end;
    wire [15:0] fpga_ctrl, network_id;
    integer errors = 0;

    k573dio #(.RAM_WORDS(4096), .DS_SERIAL(DS_SERIAL), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(lamp),
        .crypto_key1(crypto_key1), .crypto_key2(crypto_key2), .crypto_key3(crypto_key3),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .fpga_ctrl(fpga_ctrl), .network_id(network_id)
    );

    always #5 clk = ~clk;
    task wait_us(input integer n); begin repeat (n) @(posedge clk); end endtask

    task bus_write(input [7:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; off=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task bus_read(input [7:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; off=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [127:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ----- DS2401 1-Wire master, driven through register 0xee bit 12 -----
    reg [15:0] rl;
    task ow_low;     begin bus_write(8'hee, 16'h1000); end endtask  // pull line low
    task ow_release; begin bus_write(8'hee, 16'h0000); end endtask  // release
    task ow_sample(output b); begin bus_read(8'hee, rl); b = rl[12]; end endtask

    task ow_reset; begin
        ow_low;     wait_us(500);
        ow_release; wait_us(250);
    end endtask
    task ow_write_bit(input b); integer low; begin
        low = b ? 6 : 50;
        ow_low;     wait_us(low);
        ow_release; wait_us(75 - low);
    end endtask
    task ow_read_bit(output b); begin
        ow_low;     wait_us(4);
        ow_release; wait_us(8);
        ow_sample(b);
        wait_us(63);
    end endtask

    function [7:0] crc8(input [55:0] data);
        integer i; reg [7:0] c; reg bt;
        begin
            c = 8'h00;
            for (i = 0; i < 56; i = i + 1) begin
                bt = data[i] ^ c[0]; c = c >> 1; if (bt) c = c ^ 8'h8C;
            end
            crc8 = c;
        end
    endfunction

    integer i;
    reg [15:0] v;
    reg [63:0] rom, exprom;
    reg        bit_v;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; wait_us(5);

        // ---- ID / status words ----
        bus_read(8'h00, v); chk(v, 16'h0000, "a00");
        bus_read(8'h02, v); chk(v, 16'h0001, "a02");
        bus_read(8'h80, v); chk(v, 16'h1234, "a80 id");
        bus_read(8'hf6, v); chk(v, 16'hB000, "fpga status");

        // ---- MP3 address window R/W ----
        bus_write(8'ha0, 16'h1234); bus_write(8'ha2, 16'h5678);
        bus_write(8'ha4, 16'h9abc); bus_write(8'ha6, 16'hdef0);
        bus_read(8'ha0, v); chk(v, 16'h1234, "mp3_start hi");
        bus_read(8'ha2, v); chk(v, 16'h5678, "mp3_start lo");
        bus_read(8'ha4, v); chk(v, 16'h9abc, "mp3_end hi");
        bus_read(8'ha6, v); chk(v, 16'hdef0, "mp3_end lo");
        if (mp3_start !== 32'h1234_5678) begin $display("FAIL: mp3_start port"); errors=errors+1; end
        if (mp3_end   !== 32'h9abc_def0) begin $display("FAIL: mp3_end port");   errors=errors+1; end

        // ---- crypto key + fpga_ctrl + network id latches ----
        bus_write(8'ha8, 16'hAAAA); bus_write(8'hea, 16'hBBBB); bus_write(8'hec, 16'hCCCC);
        if (crypto_key1 !== 16'hAAAA) begin $display("FAIL: key1"); errors=errors+1; end
        if (crypto_key2 !== 16'hBBBB) begin $display("FAIL: key2"); errors=errors+1; end
        if (crypto_key3 !== 16'hCCCC) begin $display("FAIL: key3"); errors=errors+1; end
        bus_write(8'hae, 16'h00F0);
        bus_read(8'hae, v); chk(v, 16'h00F0, "fpga_ctrl");
        bus_write(8'h90, 16'h4321);
        if (network_id !== 16'h4321) begin $display("FAIL: network_id"); errors=errors+1; end

        // ---- lamp outputs (remap {0,2,3,1} from bits [15:12]) ----
        bus_write(8'he2, 16'hA000);   // offset 0, nibble 1010 -> lamp[3:0]=1100
        if (lamp[3:0]   !== 4'b1100) begin $display("FAIL: lamp off0 = %b", lamp[3:0]); errors=errors+1; end
        bus_write(8'hfe, 16'h3000);   // offset 2, nibble 0011 -> lamp[11:8]=1001
        if (lamp[11:8]  !== 4'b1001) begin $display("FAIL: lamp off2 = %b", lamp[11:8]); errors=errors+1; end
        bus_write(8'he6, 16'hF000);   // offset 7, nibble 1111 -> lamp[31:28]=1111
        if (lamp[31:28] !== 4'b1111) begin $display("FAIL: lamp off7 = %b", lamp[31:28]); errors=errors+1; end

        // ---- DRAM port: write 3 words from addr 0, read them back ----
        bus_write(8'hb0, 16'h0000); bus_write(8'hb2, 16'h0000);   // write ptr = 0
        bus_write(8'hb4, 16'h1111); bus_write(8'hb4, 16'h2222); bus_write(8'hb4, 16'h3333);
        bus_write(8'hb6, 16'h0000); bus_write(8'hb8, 16'h0000);   // read ptr = 0
        bus_read(8'hb4, v); chk(v, 16'h1111, "dram[0]");
        bus_read(8'hb4, v); chk(v, 16'h2222, "dram[1]");
        bus_read(8'hb4, v); chk(v, 16'h3333, "dram[2]");

        // ---- board DS2401: Read-ROM (0x33) through register 0xee ----
        ow_reset;
        for (i = 0; i < 8; i = i + 1) ow_write_bit((8'h33 >> i) & 1'b1);
        rom = 64'd0;
        for (i = 0; i < 64; i = i + 1) begin ow_read_bit(bit_v); rom[i] = bit_v; end
        exprom = {crc8({DS_SERIAL, 8'h01}), DS_SERIAL, 8'h01};
        if (rom !== exprom) begin
            $display("FAIL: ds2401 ROM %016h (expected %016h)", rom, exprom);
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (k573dio)  ds2401=%016h", rom);
        else             $display("RESULT: FAIL (k573dio, %0d errors)", errors);
        $finish;
    end
endmodule
