`timescale 1ns/1ps
// Testbench for atapi.v - drives the ATAPI device like the 573 IDE host:
// checks the power-on ATAPI signature, runs a non-data PACKET command
// (TEST UNIT READY), runs a PIO data-in PACKET command (INQUIRY) and verifies
// the returned bytes, and checks INTRQ assertion / clear-on-status-read.
module tb_atapi;
    reg        clk = 0, rst = 1;
    reg        sel = 0, we = 0, re = 0;
    reg [3:0]  addr = 0;
    reg [15:0] din = 0;
    wire [15:0] dout;
    wire        intrq;
    integer errors = 0;

    // cd_attached=0 -> READ(10) streams the legacy SIM disc[] store (this test's
    // expected bytes). The external-CD-image path is covered by tb_atapi_cdread.v.
    atapi dut (.clk(clk), .rst(rst), .ide_rst(1'b0),
               .sel(sel), .addr(addr), .we(we), .re(re),
               .din(din), .dout(dout), .intrq(intrq),
               .cd_attached(1'b0), .sec_req(), .sec_lba(),
               .sbuf_addr(), .sbuf_q(16'h0000));

    always #5 clk = ~clk;

    task io_write(input [3:0] a, input [15:0] d);
        begin @(negedge clk); sel=1; we=1; addr=a; din=d; @(negedge clk); sel=0; we=0; end
    endtask
    task io_read(input [3:0] a, output [15:0] d);
        begin @(negedge clk); sel=1; re=1; addr=a; #1 d=dout; @(negedge clk); sel=0; re=0; end
    endtask
    task chk(input [15:0] got, input [15:0] exp, input [199:0] what);
        begin
            if (got !== exp) begin
                $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask
    task send_packet(input [7:0] opcode);
        integer w; begin
            io_write(4'd0, {8'h00, opcode});       // word 0 (opcode in low byte)
            for (w = 0; w < 5; w = w + 1) io_write(4'd0, 16'h0000);
        end
    endtask

    reg [15:0] v, word [0:17];
    reg [7:0]  byte_n;
    integer i;

    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ---- power-on ATAPI signature ----
        io_read(4'd2, v); chk(v, 16'h0001, "sig ireason");
        io_read(4'd3, v); chk(v, 16'h0001, "sig lbalo");
        io_read(4'd4, v); chk(v, 16'h0014, "sig bclo");
        io_read(4'd5, v); chk(v, 16'h00EB, "sig bchi");

        // ---- TEST UNIT READY (non-data PACKET command) ----
        io_write(4'd7, 16'h00A0);                 // PACKET
        io_read(4'd7, v); chk(v, 16'h0008, "TUR drq");      // DRQ set
        io_read(4'd2, v); chk(v, 16'h0001, "TUR ireason");  // C/D=1,I/O=0
        send_packet(8'h00);                        // TEST UNIT READY
        io_read(4'd7, v); chk(v, 16'h0050, "TUR status");   // DRDY|DSC
        io_read(4'd2, v); chk(v, 16'h0003, "TUR done ireason");

        // ---- INQUIRY (PIO data-in PACKET command) ----
        io_write(4'd7, 16'h00A0);
        send_packet(8'h12);                        // INQUIRY
        io_read(4'd7, v); chk(v, 16'h0048, "INQ status");   // DRDY|DRQ
        io_read(4'd2, v); chk(v, 16'h0002, "INQ ireason");  // I/O=1
        io_read(4'd4, v); chk(v, 16'h0024, "INQ byte count"); // 36 bytes

        for (i = 0; i < 18; i = i + 1) io_read(4'd0, word[i]);

        // first word = {resp[1],resp[0]} = {0x80,0x05}
        chk(word[0], 16'h8005, "INQ word0");
        // bytes 8..10 = "KON"
        chk(word[4], 16'h4F4B, "INQ vendor KO");   // {resp[9]=O, resp[8]=K}
        chk({8'h00, word[5][7:0]}, 16'h004E, "INQ vendor N");

        io_read(4'd7, v); chk(v, 16'h0050, "INQ done status"); // back to DRDY|DSC

        // ---- READ(10): stream one 2048-byte sector from the disc store ----
        io_write(4'd7, 16'h00A0);
        io_write(4'd0, 16'h0028);   // word0: opcode 0x28 (READ(10))
        io_write(4'd0, 16'h0000);   // LBA[31:16]
        io_write(4'd0, 16'h0100);   // LBA[15:0] -> pkt[5]=0x01 (sector 1)
        io_write(4'd0, 16'h0000);
        io_write(4'd0, 16'h0000);   // transfer length
        io_write(4'd0, 16'h0000);   // -> dispatch
        io_read(4'd7, v); chk(v, 16'h0048, "READ status");      // DRDY|DRQ
        io_read(4'd5, v); chk(v, 16'h0008, "READ byte count hi"); // 0x0800 = 2048
        // disc[i] = i & 0xff ; sector 1 starts at byte 2048
        for (i = 0; i < 8; i = i + 1) begin
            io_read(4'd0, v);
            chk(v, (((2048+2*i+1) & 8'hff) << 8) | ((2048+2*i) & 8'hff), "READ data");
        end

        // ---- IDENTIFY PACKET DEVICE (0xA1): the GX700 POST "DRIVE CHECK" ----
        // The 573 BIOS drive check issues 0xA1, requires DRQ set, byte count <= 0x800,
        // a 256-word data-in, and ERR clear at completion. Content is not validated.
        io_write(4'd7, 16'h00A1);                  // IDENTIFY PACKET DEVICE
        io_read(4'd7, v); chk(v, 16'h0048, "IDENT status");     // DRDY|DRQ
        io_read(4'd2, v); chk(v, 16'h0002, "IDENT ireason");    // I/O=1, C/D=0
        io_read(4'd4, v); chk(v, 16'h0000, "IDENT bc lo");      // byte count 0x0200
        io_read(4'd5, v); chk(v, 16'h0002, "IDENT bc hi");
        io_read(4'd0, word[0]); chk(word[0], 16'h85C0, "IDENT word0"); // ATAPI CD-ROM config
        io_read(4'd0, v);       chk(v, 16'h0000, "IDENT word1");        // zero-filled
        for (i = 2; i < 255; i = i + 1) io_read(4'd0, v);   // drain to the last word
        io_read(4'd0, v);                                   // 256th word -> completion
        io_read(4'd7, v); chk(v, 16'h0050, "IDENT done status"); // DRDY|DSC, ERR clear

        // ---- INTRQ assert + clear-on-status-read ----
        // INTRQ is a registered, edge-guaranteed output (atapi.v irq_out): it asserts a
        // couple of clocks after the event that raises it, so settle before sampling.
        io_write(4'd7, 16'h00A0); send_packet(8'h00); // TUR -> completion asserts INTRQ
        repeat (3) @(posedge clk);
        if (intrq !== 1'b1) begin $display("FAIL: intrq not asserted"); errors=errors+1; end
        io_read(4'd7, v);                              // status read clears it
        repeat (3) @(posedge clk);
        if (intrq !== 1'b0) begin $display("FAIL: intrq not cleared"); errors=errors+1; end

        if (errors == 0) $display("RESULT: PASS (atapi)");
        else             $display("RESULT: FAIL (atapi, %0d errors)", errors);
        $finish;
    end
endmodule
