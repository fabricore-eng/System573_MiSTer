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
    reg        dec_frame_sync = 0, dec_frame_idle = 0, pcm_sample_tick = 0;
    wire [15:0] dout;
    wire [31:0] lamp;
    wire [15:0] crypto_key1, crypto_key2, crypto_key3;
    wire [31:0] mp3_start, mp3_end;
    wire [15:0] fpga_ctrl, network_id;
    wire [7:0]  mp3_out_byte;
    wire        mp3_out_valid;
    integer errors = 0;

    k573dio #(.RAM_WORDS(4096), .DS_SERIAL(DS_SERIAL), .DS_CLK_HZ(1_000_000)) dut (
        .clk(clk), .rst(rst), .sel(sel), .off(off), .we(we), .re(re),
        .din(din), .dout(dout), .lamp(lamp),
        .dio_wait(), .cfg_ddrsbm(1'b0),          // was parameter DDRSBM
        .mem_rd_req(), .mem_rd_addr(), .mem_rd_q(64'd0), .mem_rd_ack(1'b0),
        .mem_wr_req(), .mem_wr_addr(), .mem_wr_data(), .mem_wr_ack(1'b0),
        .dbg_wfifo_ovf(),
        .crypto_key1(crypto_key1), .crypto_key2(crypto_key2), .crypto_key3(crypto_key3),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .fpga_ctrl(fpga_ctrl), .network_id(network_id),
        .mp3_out_ready(1'b1),   // datapath test: always-ready sink (pacing is tb_k573_mp3stream)
        .mp3_out_byte(mp3_out_byte), .mp3_out_valid(mp3_out_valid),
        .dec_frame_sync(dec_frame_sync), .dec_frame_idle(dec_frame_idle),
        .pcm_sample_tick(pcm_sample_tick)
    );

    // descramble reference (mirrors k573_mp3dec) for the streaming check
    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d; begin
            d = 16'd0;
            for (i=0;i<8;i=i+1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555); end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r=s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2]; r_derive=r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7]; r_spread=r; end
    endfunction
    reg [7:0]  sgot [0:7];
    integer    sgi = 0;
    always @(posedge clk) if (!rst && mp3_out_valid) begin sgot[sgi]=mp3_out_byte; sgi=sgi+1; end

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

    // ---- MP3 decode-counter stimulus (P4b HPS decode / PCM-drain inputs) ----
    task frame_pulse;      // one decoded MPEG frame (MAME mpeg_frame_sync(1))
        begin @(negedge clk); dec_frame_sync = 1; @(negedge clk); dec_frame_sync = 0; end
    endtask
    task frame_idle_pulse; // a decode that produced no frame (MAME mpeg_frame_sync(0))
        begin @(negedge clk); dec_frame_idle = 1; @(negedge clk); dec_frame_idle = 0; end
    endtask
    task drain(input integer n); begin   // n PCM samples drained @44100Hz -> counter += n
        @(negedge clk); pcm_sample_tick = 1;
        repeat (n) @(posedge clk);
        @(negedge clk); pcm_sample_tick = 0;
    end endtask

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
    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [15:0] smem [0:3];
    reg [7:0]  sexp [0:7];

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

        // ---- MP3 streaming through the board: DRAM -> descramble -> byte stream ----
        bus_write(8'ha8, 16'h1357); bus_write(8'hea, 16'h2468); bus_write(8'hec, 16'h9BDF); // keys
        bus_write(8'ha0, 16'h0000); bus_write(8'ha2, 16'h0000);   // mp3_start = 0
        bus_write(8'ha4, 16'h0000); bus_write(8'ha6, 16'h0008);   // mp3_end   = 8 (4 words)
        bus_write(8'hb0, 16'h0000); bus_write(8'hb2, 16'h0000);   // DRAM write ptr = 0
        bus_write(8'hb4, 16'h1234); bus_write(8'hb4, 16'h5678);
        bus_write(8'hb4, 16'h9ABC); bus_write(8'hb4, 16'hDEF0);   // scrambled words
        // reference descramble (default scheme, running key schedule)
        sk1 = 16'h1357; sk2 = 16'h2468; sk3 = 16'h9BDF;
        smem[0]=16'h1234; smem[1]=16'h5678; smem[2]=16'h9ABC; smem[3]=16'hDEF0;
        for (i = 0; i < 4; i = i + 1) begin
            dk   = r_derive(sk1 ^ sk2);
            dval = r_common(smem[i], dk) ^ r_spread(sk3);
            sexp[2*i]   = dval[15:8];
            sexp[2*i+1] = dval[7:0];
            if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
            sk1 = {sk1[15], sk1[13:0], sk1[14]};
            sk3 = sk3 + 16'd1;
        end
        sgi = 0;
        bus_write(8'hae, 16'h6000);          // MP3_ENABLE | STREAMING_ENABLE
        repeat (50) @(posedge clk);
        // MAME feeds 2N-1 bytes for an N-word window (final word's low byte dropped)
        if (sgi !== 7) begin $display("FAIL: streamed %0d bytes (expected 7 = 2N-1)", sgi); errors=errors+1; end
        for (i = 0; i < 7 && i < sgi; i = i + 1)
            if (sgot[i] !== sexp[i]) begin
                $display("FAIL: mp3 byte[%0d]=%02h expected %02h", i, sgot[i], sexp[i]); errors=errors+1;
            end
        bus_read(8'hae, v); chk(v, 16'h0000, "fpga_ctrl after stream"); // not streaming

        // ================================================================
        // MP3 decode counters (0xa8 frame / 0xaa mpeg_status / 0xca-cc sample
        // position / 0xce diff) -- MAME k573fpga.cpp / k573dio.cpp. Driven off the
        // HPS decode/PCM-drain inputs. RED under -DMP3_COUNTER_STUB (counters read 0).
        // Note: this tb ties mp3_out_ready=1, so mpeg_status DEMAND (bit12) is always
        // set -> idle=0x1000, PLAYING=0x5000, IDLE=0x3000.
        // ================================================================
        // A setup-register write pulses mp3_reload -> counters zeroed + disarmed
        // (MAME update_mp3_decode_state).
        bus_write(8'hae, 16'h0000);          // fpga_ctrl clear (frame counter disabled)
        bus_write(8'ha8, 16'h0000);          // key1 write -> mp3_reload -> reset counters
        bus_read(8'ha8, v); chk(v, 16'h0000, "frame count @reset");
        bus_read(8'hcc, v); chk(v, 16'h0000, "sample lo @reset");
        bus_read(8'hca, v); chk(v, 16'h0000, "sample hi @reset");
        bus_read(8'haa, v); chk(v, 16'h1000, "mpeg_status @reset (demand only)");

        // Frame counter is GATED by FPGA_FRAME_COUNTER_ENABLE (fpga_ctrl bit15):
        // with bit15 clear, a frame sync must NOT increment it...
        frame_pulse;
        bus_read(8'ha8, v); chk(v, 16'h0000, "frame sync ignored while bit15=0");
        // ...but that first sync DID arm the sample counter + set PLAYING.
        bus_read(8'haa, v); chk(v, 16'h5000, "mpeg_status PLAYING after first sync");

        bus_write(8'hae, 16'h8000);          // FPGA_FRAME_COUNTER_ENABLE
        frame_pulse; frame_pulse; frame_pulse;
        bus_read(8'ha8, v); chk(v, 16'h0003, "frame count = 3 after 3 syncs");
        bus_write(8'hae, 16'h0000);          // clearing bit15 resets the frame counter
        bus_read(8'ha8, v); chk(v, 16'h0000, "frame count reset when bit15 cleared");
        bus_write(8'hae, 16'h8000);          // re-enable

        // Sample counter advances off PCM DRAIN only (pcm_sample_tick), while armed.
        drain(100);
        bus_read(8'hcc, v); chk(v, 16'd100, "sample lo = 100 after 100 drained");
        bus_read(8'hca, v); chk(v, 16'h0000, "sample hi still 0 (<65536)");

        // Cross the 16-bit boundary: prove the hi/lo latch + coherency. Drive to
        // 0xFFFE, latch via a 0xcc read, advance PAST 0x10000, then read 0xca -- it
        // must return the hi LATCHED at the 0xcc read, not a recomputed live hi.
        drain(32'hFFFE - 32'd100);           // counter -> 0xFFFE
        bus_read(8'hcc, v); chk(v, 16'hFFFE, "sample lo @0xFFFE");   // latches 0x0000_FFFE
        drain(4);                            // counter -> 0x10002 (live hi now 1)
        bus_read(8'hca, v); chk(v, 16'h0000, "sample hi = latched 0x0000 (coherent, not live 1)");
        bus_read(8'hcc, v); chk(v, 16'h0002, "sample lo @0x10002 (re-latches 0x0001_0002)");
        bus_read(8'hca, v); chk(v, 16'h0001, "sample hi = 0x0001 after re-latch");

        // 0xcc WRITE = reset_counter: zero + disarm; ticks must not count until the
        // next frame sync re-arms.
        bus_write(8'hcc, 16'h0000);
        bus_read(8'hcc, v); chk(v, 16'h0000, "sample counter reset by 0xcc write");
        drain(20);
        bus_read(8'hcc, v); chk(v, 16'h0000, "no count while disarmed (0xcc write)");
        frame_pulse;                         // re-arm
        drain(7);
        bus_read(8'hcc, v); chk(v, 16'd7, "counts again after re-arming frame sync");

        // IDLE bit: a decode that produced no frame sets IDLE, clears PLAYING.
        frame_idle_pulse;
        bus_read(8'haa, v); chk(v, 16'h3000, "mpeg_status IDLE after frame_idle");

        // get_counter_diff (0xce): samples since the last counter read.
        bus_read(8'hcc, v);                  // sets the diff reference = current count (7)
        drain(9);
        bus_read(8'hce, v); chk(v, 16'd9, "counter diff = 9 samples since last read");

        // mp3_reload (a setup write) also zeroes the sample counter + frame counter,
        // and re-references 0xce -- read 0xce FIRST (before any 0xcc read) -> ~0.
        bus_write(8'ha6, 16'h1234);          // mp3_end low write -> mp3_reload
        bus_read(8'hce, v); chk(v, 16'h0000, "counter diff = 0 right after reset (diff ref cleared)");
        bus_read(8'hcc, v); chk(v, 16'h0000, "sample counter reset by mp3_reload");
        bus_read(8'ha8, v); chk(v, 16'h0000, "frame counter reset by mp3_reload");

        if (errors == 0) $display("RESULT: PASS (k573dio)  ds2401=%016h", rom);
        else             $display("RESULT: FAIL (k573dio, %0d errors)", errors);
        $finish;
    end
endmodule
