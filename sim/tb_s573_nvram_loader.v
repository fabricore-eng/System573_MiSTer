`timescale 1ns/1ps
// Testbench for s573_nvram_loader.v wired to m48t58.v -- the WIDE(1) ioctl NVRAM
// image load end to end.
//
// REGRESSION for hyperbbc's red "N": emu.sv instantiates hps_io with .WIDE(1), so
// each ioctl_wr delivers a 16-bit word (ioctl_dout[7:0]=file[2k], [15:8]=file[2k+1])
// and ioctl_addr steps by 2. The original wiring wrote only the LOW byte at the even
// address and dropped ioctl_dout[15:8] -> every ODD ram[] byte stayed 0. The boot
// self-test reads the M48T58 signature at ram indices {0,1,4,5,8,9,...} (7 even +
// 7 ODD); the zeroed odd bytes failed the "GQ876..1998EAA" compare -> status|=0x40.
//
// tb_m48t58.v could not catch this: it modelled a byte-contiguous load (one nv_load
// per byte, addr stepping by 1) and never exercised the WIDE step-2/low-byte-only
// front-end. This test drives the REAL WIDE word stream through the REAL loader and
// asserts the odd bytes are reconstructed -- it FAILS against the old single-byte
// wiring and PASSES with s573_nvram_loader.
module tb_s573_nvram_loader;
    reg clk = 0, rst = 1;
    // hps_io WIDE(1) ioctl stream (driven by the tb, modelling the HPS download).
    reg         ioctl_wr   = 0;
    reg  [12:0] ioctl_addr = 0;
    reg  [15:0] ioctl_dout = 0;
    // loader -> m48t58 byte-write port.
    wire        nvram_we;
    wire [12:0] nvram_addr;
    wire [7:0]  nvram_din;
    wire        nv_hi;
    // m48t58 bus side (used only for read-back here).
    reg  [12:0] addr = 0;
    reg  [7:0]  din  = 0;
    reg         we   = 0;
    wire [7:0]  dout;

    integer errors = 0;
    reg [7:0] got;

    s573_nvram_loader loader (
        .clk(clk), .load_en(rst /* load runs while core reset is held */),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .nv_hi(nv_hi)
    );

    m48t58 #(.CLK_FREQ_HZ(1)) nv (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din)
    );

    always #5 clk = ~clk;

    // One WIDE ioctl word, driven the way the REAL hps_io + emu ioctl_wait do it:
    // hps presents the word with ioctl_wr=1 and HOLDS it high while emu asserts
    // ioctl_wait for the loader's 2nd (odd) write, only advancing once the loader
    // has consumed both bytes. Holding ioctl_wr high across the wait is the case
    // that would expose a double-even-write if the loader's nv_hi priority were
    // wrong -- so the test must drive it this way, not with idle gaps.
    task nv_word(input [12:0] a, input [15:0] w);
        begin
            @(negedge clk); ioctl_addr = a; ioctl_dout = w; ioctl_wr = 1;
            @(posedge clk);   // even byte write commits; loader raises nv_hi
            @(posedge clk);   // odd byte write commits (ioctl_wr STILL high, held by wait)
            @(negedge clk); ioctl_wr = 0;   // emu drops ioctl_wait -> hps advances
            @(negedge clk);                 // settle before next word
        end
    endtask

    // Synchronous (registered M10K) read-back through the m48t58 read port.
    task rd_nv(input [12:0] a, output [7:0] d);
        begin
            addr = a; @(posedge clk); #1 d = dout;
        end
    endtask

    task check(input [7:0] g, input [7:0] e, input [127:0] name);
        begin
            if (g !== e) begin
                $display("FAIL: %0s got %02h expected %02h", name, g, e);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // Stream the first 16 bytes of the real hyperbbc image (dumps/hyperbbc/
        // nvram8k.bin) as WIDE words: file = 51 47 00 00 37 38 00 00 00 36 00 00 ...
        // so ioctl_dout = {file[2k+1], file[2k]}.
        nv_word(13'd0,  16'h4751);   // file[0]=51 'Q', file[1]=47 'G'
        nv_word(13'd2,  16'h0000);   // file[2]=00,     file[3]=00
        nv_word(13'd4,  16'h3837);   // file[4]=37 '7', file[5]=38 '8'
        nv_word(13'd6,  16'h0000);   // file[6]=00,     file[7]=00
        nv_word(13'd8,  16'h3600);   // file[8]=00,     file[9]=36 '6'
        // A word far from 0 to prove addressing scales across the array.
        nv_word(13'd32, 16'h23C9);   // file[32]=c9,    file[33]=23

        repeat (3) @(posedge clk); @(negedge clk); rst = 0;   // download done, release reset

        // EVEN bytes (the old wiring got these right).
        rd_nv(13'd0,  got); check(got, 8'h51, "even ram[0]");
        rd_nv(13'd4,  got); check(got, 8'h37, "even ram[4]");
        rd_nv(13'd8,  got); check(got, 8'h00, "even ram[8]");
        rd_nv(13'd32, got); check(got, 8'hC9, "even ram[32]");

        // ODD bytes -- THE REGRESSION. These were dropped (read 0x00) by the old
        // single-low-byte wiring; the game's signature compare reads exactly these.
        rd_nv(13'd1,  got); check(got, 8'h47, "ODD ram[1] (was dropped -> red N)");
        rd_nv(13'd5,  got); check(got, 8'h38, "ODD ram[5] (was dropped)");
        rd_nv(13'd9,  got); check(got, 8'h36, "ODD ram[9] (was dropped)");
        rd_nv(13'd33, got); check(got, 8'h23, "ODD ram[33] (was dropped)");

        // The game reads halfword idx0 = (ram[0]<<8)|ram[1]. With both bytes present
        // this is 0x5147; a half-zeroed load gives 0x5100 -> signature mismatch.
        rd_nv(13'd0, got);
        if (got !== 8'h51) begin $display("FAIL: sig hi byte"); errors = errors + 1; end
        rd_nv(13'd1, got);
        if (got !== 8'h47) begin
            $display("FAIL: sig lo (odd) byte zeroed -> this is the red-N bug");
            errors = errors + 1;
        end

        if (errors == 0) $display("RESULT: PASS (s573_nvram_loader)");
        else             $display("RESULT: FAIL (s573_nvram_loader, %0d errors)", errors);
        $finish;
    end
endmodule
