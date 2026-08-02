`timescale 1ns/1ps
// Testbench for k573_mp3stream.v - the demand-paced MP3 streaming controller.
//
// Loads scrambled words into a DRAM model, starts streaming into a PACED sink, and
// checks the emitted byte stream against an independent descramble reference. The
// sink models the MAS3507D DEMAND back-pressure: out_ready is high only 1-of-4
// cycles, and a byte is captured ONLY on a cycle where out_valid && out_ready. A
// correct streamer holds each byte until it is accepted, so all bytes arrive in
// order; the pre-fix flood (MP3_UNPACED) advances regardless of out_ready, so the
// paced sink loses bytes -> RED.
//
// Phase 2 exercises the re-arm: after the stream parks at end, mp3_end is extended
// and a `reload` pulse is issued (MAME update_mp3_decode_state). The fixed streamer
// re-inits (cur<-start) and re-streams; the pre-fix one-shot stays parked -> RED.
module tb_k573_mp3stream;
    reg        clk = 0, rst = 1;
    reg [15:0] fpga_ctrl = 0;
    reg [24:0] mp3_start = 0, mp3_end = 8;   // phase 1: 4 words
    reg [15:0] key1 = 16'h1357, key2 = 16'h2468, key3 = 16'h9BDF;
    reg        reload = 0;
    wire [24:0] rd_addr;
    wire [7:0]  out_byte;
    wire        out_valid;
    wire [31:0] byte_counter;
    wire [15:0] fpga_ctrl_rb;
    reg         out_ready = 0;
    integer errors = 0;

    // DRAM model (scrambled MP3 words) behind the req/ready handshake: serve
    // with a rotating 0..3-cycle latency, data registered and held until the
    // next request (the k573dio backing contract, both sim and DDR3 modes).
    reg [15:0] mem [0:7];
    wire        rd_req;
    reg  [15:0] rd_data_r = 16'd0;
    reg         rd_ready_r = 1'b0;
    reg  [1:0]  srv_lat = 2'd0, srv_cnt = 2'd0;
    always @(posedge clk) begin
        rd_ready_r <= 1'b0;
        if (rst) begin
            srv_cnt <= 2'd0;
        end else if (rd_req && !rd_ready_r) begin
            if (srv_cnt == srv_lat) begin
                rd_data_r  <= mem[rd_addr >> 1];
                rd_ready_r <= 1'b1;
                srv_cnt    <= 2'd0;
                srv_lat    <= srv_lat + 2'd1;   // vary the latency per word
            end else
                srv_cnt <= srv_cnt + 2'd1;
        end
    end

    // paced sink: out_ready high 1-of-4 cycles (models MAS3507D DEMAND bursts)
    reg [1:0] rdy_cnt = 2'd0;
    always @(posedge clk) begin
        if (rst) begin rdy_cnt <= 2'd0; out_ready <= 1'b0; end
        else begin
            rdy_cnt   <= rdy_cnt + 2'd1;
            out_ready <= (rdy_cnt == 2'd0);
        end
    end

    k573_mp3stream dut (
        .clk(clk), .rst(rst), .fpga_ctrl(fpga_ctrl), .ddrsbm(1'b0),
        .mp3_start(mp3_start), .mp3_end(mp3_end),
        .key1(key1), .key2(key2), .key3(key3), .reload(reload),
        .rd_addr(rd_addr), .rd_req(rd_req),
        .rd_data(rd_data_r), .rd_ready(rd_ready_r),
        .out_ready(out_ready), .out_byte(out_byte), .out_valid(out_valid),
        .byte_counter(byte_counter), .fpga_ctrl_rb(fpga_ctrl_rb)
    );

    always #5 clk = ~clk;

    // ---- descramble reference (mirrors k573_mp3dec) ----
    function [15:0] r_common(input [15:0] data, input [15:0] key);
        integer i; reg [15:0] d; begin
            d = 16'd0;
            for (i=0;i<8;i=i+1)
                if (key[2*i+1]) begin d[2*i]=data[2*i+1]; d[2*i+1]=data[2*i]; end
                else            begin d[2*i]=data[2*i];   d[2*i+1]=data[2*i+1]; end
            r_common = d ^ (key & 16'h5555); end
    endfunction
    function [15:0] r_derive(input [15:0] s); reg [15:0] r; begin
        r=s; r[14]=s[13]; r[13]=s[14]; r[8]=s[7]; r[7]=s[8]; r[2]=s[1]; r[1]=s[2];
        r_derive=r; end
    endfunction
    function [15:0] r_spread(input [15:0] k); reg [15:0] r; begin
        r[15]=k[7];r[14]=k[0];r[13]=k[6];r[12]=k[1];r[11]=k[5];r[10]=k[2];r[9]=k[4];r[8]=k[3];
        r[7]=k[3];r[6]=k[4];r[5]=k[2];r[4]=k[5];r[3]=k[1];r[2]=k[6];r[1]=k[0];r[0]=k[7];
        r_spread=r; end
    endfunction

    reg [15:0] sk1, sk2, sk3, dk, dval;
    reg [7:0]  expb [0:15];   // reference for 8 words (16 bytes), seeded from originals
    reg [7:0]  gotb [0:63];
    integer    gi = 0, i, guard;

    // collect emitted bytes -- ONLY on an accepted transfer (out_valid && out_ready)
    always @(posedge clk) if (!rst && out_valid && out_ready) begin
        gotb[gi] = out_byte; gi = gi + 1;
    end

    // wait until `n` total bytes collected, or `lim` cycles elapse
    task wait_bytes(input integer n, input integer lim);
        begin
            guard = 0;
            while (gi < n && guard < lim) begin @(posedge clk); guard = guard + 1; end
        end
    endtask

    initial begin
        mem[0]=16'h1234; mem[1]=16'h5678; mem[2]=16'h9ABC; mem[3]=16'hDEF0;
        mem[4]=16'h0F1E; mem[5]=16'h2D3C; mem[6]=16'h4B5A; mem[7]=16'h6978;

        // expected descrambled byte stream for words 0..7 (schedule from originals)
        sk1=key1; sk2=key2; sk3=key3;
        for (i=0;i<8;i=i+1) begin
            dk   = r_derive(sk1 ^ sk2);
            dval = r_common(mem[i], dk) ^ r_spread(sk3);
            expb[2*i]   = dval[15:8];
            expb[2*i+1] = dval[7:0];
            if (sk1[14]^sk1[15]) sk2 = {sk2[14:0], sk2[15]};
            sk1 = {sk1[15], sk1[13:0], sk1[14]};
            sk3 = sk3 + 16'd1;
        end

        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- phase 1: seed keys via reload (game's setup writes), then stream ----
        // MAME seeds the schedule in update_mp3_decode_state (a setup-register write),
        // NOT on the enable edge; the enable bits only gate streaming.
        // negedge-aligned pulse so the DUT samples reload=1 at the enclosed posedge
        // (a posedge-aligned clear races the DUT's own posedge sample -> missed pulse)
        @(negedge clk); reload = 1'b1; @(negedge clk); reload = 1'b0;
        repeat (2) @(posedge clk);
        // 4-word window: MAME feeds 2N-1 = 7 bytes (the last word's low byte, expb[7],
        // is dropped by the window-check-before-emit ordering).
        fpga_ctrl = 16'h6000;            // MP3_ENABLE | STREAMING_ENABLE
        wait_bytes(7, 4000);
        repeat (8) @(posedge clk);       // let it settle / park

        if (gi !== 7) begin $display("FAIL: phase1 emitted %0d bytes (expected 7 = 2N-1)", gi); errors=errors+1; end
        for (i=0;i<7 && i<gi;i=i+1)
            if (gotb[i] !== expb[i]) begin
                $display("FAIL: phase1 byte[%0d]=%02h expected %02h", i, gotb[i], expb[i]);
                errors = errors + 1;
            end
        if (byte_counter !== 32'd7) begin $display("FAIL: phase1 byte_counter=%0d (expected 7)", byte_counter); errors=errors+1; end
        if (fpga_ctrl_rb !== 16'h0000) begin $display("FAIL: still streaming after end %04h", fpga_ctrl_rb); errors=errors+1; end

        // ---- phase 1b: a bit13/14 toggle after completion must NOT rewind ----
        // MAME set_fpga_ctrl never resets cur; cur==end so re-enable stays parked. The
        // pre-fix enable-edge re-init would rewind cur<-start and re-stream the song.
        fpga_ctrl = 16'h0000; repeat (2) @(posedge clk);
        fpga_ctrl = 16'h6000; repeat (24) @(posedge clk);
        if (gi !== 7) begin $display("FAIL: re-enable rewound the stream (gi=%0d, expected still 7)", gi); errors=errors+1; end

        // ---- phase 2: extend mp3_end + reload -> re-init (cur<-start) + re-stream ----
        // pre-fix one-shot ignores the reload and stays parked. 8-word window = 15 bytes.
        mp3_end = 16;                    // now 8 words
        @(negedge clk); reload = 1'b1; @(negedge clk); reload = 1'b0;

        wait_bytes(22, 8000);            // 7 (phase1) + re-streamed 15 (2*8-1)
        repeat (8) @(posedge clk);

        if (gi !== 22) begin $display("FAIL: phase2 total %0d bytes (expected 22 = 7 + re-streamed 15)", gi); errors=errors+1; end
        for (i=0;i<15 && (7+i)<gi;i=i+1)
            if (gotb[7+i] !== expb[i]) begin
                $display("FAIL: phase2 byte[%0d]=%02h expected %02h", i, gotb[7+i], expb[i]);
                errors = errors + 1;
            end
        if (byte_counter !== 32'd15) begin $display("FAIL: phase2 byte_counter=%0d (expected 15)", byte_counter); errors=errors+1; end

        if (errors == 0) $display("RESULT: PASS (k573_mp3stream)");
        else             $display("RESULT: FAIL (k573_mp3stream, %0d errors)", errors);
        $finish;
    end
endmodule
