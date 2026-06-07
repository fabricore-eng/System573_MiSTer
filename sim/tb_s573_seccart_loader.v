`timescale 1ns/1ps
// Testbench for s573_seccart_loader.v - the WIDE(1) ioctl -> security-cart byte
// stream unpacker. Verifies that each 16-bit WIDE word becomes TWO byte writes
// (even then odd), that ioctl_wait back-pressure (nv_hi) fires on the odd byte,
// that NO byte is dropped (the bug the M48T58 path hit), and that max_addr tracks
// the highest byte index so emu.sv can infer the cart type from the image size.
module tb_s573_seccart_loader;
    localparam integer AW = 10;
    localparam integer NBYTES = 548;   // an X76F041 image

    reg          clk = 0, load_en = 0, ioctl_wr = 0;
    reg  [AW-1:0] ioctl_addr = 0;
    reg  [15:0]  ioctl_dout = 0;
    wire         byte_we, nv_hi;
    wire [AW-1:0] byte_addr, max_addr;
    wire [7:0]   byte_data;
    integer errors = 0;

    s573_seccart_loader #(.AW(AW)) dut (
        .clk(clk), .load_en(load_en), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .byte_we(byte_we), .byte_addr(byte_addr), .byte_data(byte_data),
        .nv_hi(nv_hi), .max_addr(max_addr)
    );

    always #5 clk = ~clk;

    // golden model: the bytes we expect to land at each address
    reg [7:0] expect_mem [0:NBYTES-1];
    reg [7:0] got_mem    [0:NBYTES-1];
    reg       got_set    [0:NBYTES-1];

    // capture every committed byte write
    always @(posedge clk) begin
        if (byte_we) begin
            got_mem[byte_addr] <= byte_data;
            got_set[byte_addr] <= 1'b1;
        end
    end

    integer i;
    initial begin
        for (i = 0; i < NBYTES; i = i + 1) begin
            expect_mem[i] = (i*7 + 3) & 8'hff;   // arbitrary distinct pattern
            got_set[i]    = 1'b0;
        end

        @(negedge clk); load_en = 1;
        // Stream 274 WIDE words (548 bytes). Honour the nv_hi back-pressure: on the
        // even-write cycle the loader raises nv_hi the NEXT cycle; hold ioctl_wr low
        // until nv_hi clears, exactly as emu.sv's ioctl_wait gates hps_io.
        for (i = 0; i < NBYTES; i = i + 2) begin
            @(negedge clk);
            ioctl_addr = i[AW-1:0];
            ioctl_dout = {expect_mem[i+1], expect_mem[i]};  // [15:8]=odd, [7:0]=even
            ioctl_wr   = 1'b1;
            @(negedge clk);
            ioctl_wr   = 1'b0;
            // wait out the 2-cycle unpack (nv_hi pulses for the odd byte)
            @(posedge clk);                 // even byte commits
            while (!nv_hi) @(posedge clk);  // wait for odd-byte cycle
            @(posedge clk);                 // odd byte commits
        end
        @(negedge clk); load_en = 0;
        repeat (4) @(posedge clk);

        // ---- check every byte landed with the right value ----
        for (i = 0; i < NBYTES; i = i + 1) begin
            if (!got_set[i]) begin
                $display("FAIL: byte %0d never written (dropped!)", i); errors = errors + 1;
            end else if (got_mem[i] !== expect_mem[i]) begin
                $display("FAIL: byte %0d = %02h (expected %02h)", i, got_mem[i], expect_mem[i]);
                errors = errors + 1;
            end
        end

        // ---- max_addr must equal the highest index (547) for X76F041 type-infer ----
        if (max_addr !== (NBYTES-1)) begin
            $display("FAIL: max_addr = %0d (expected %0d)", max_addr, NBYTES-1);
            errors = errors + 1;
        end
        // and the inference threshold: 547 >= 112 -> X76F041
        if (!(max_addr >= 10'd112)) begin
            $display("FAIL: 548-byte image did not infer X76F041 (max_addr=%0d)", max_addr);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("RESULT: PASS (s573_seccart_loader)  %0d bytes, no drops, max_addr=%0d -> X76F041", NBYTES, max_addr);
        else
            $display("RESULT: FAIL (s573_seccart_loader, %0d errors)", errors);
        $finish;
    end
endmodule
