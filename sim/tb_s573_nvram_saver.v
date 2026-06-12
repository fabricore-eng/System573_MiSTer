`timescale 1ns/1ps
// Testbench for s573_nvram_saver.v wired to m48t58.v -- the WIDE(1) ioctl NVRAM
// image SAVE-BACK (upload) end to end, the inverse of tb_s573_nvram_loader.v.
//
// HW-realistic protocol model (cited in docs/audits/2026-06-11-nvram-saveback-
// gate0.md): Main's arcade_nvm_save arms the upload (ioctl_upload=1, addr=0,
// index=3), then per 16-bit word hps_io latches fp_dout <= ioctl_din AT the
// FIO_FILE_TX_DAT strobe edge -- while ioctl_addr still points at the word --
// and THEN advances ioctl_addr by 2 (sys/hps_io.sv:686-699). There is NO
// ioctl_wait back-pressure on upload, so the tb samples on a strobe edge the
// core cannot see coming and uses a realistically TIGHT inter-strobe gap.
//
// RED-GREEN: this is the WIDE odd-byte trap in reverse. The test PROVES (red)
// that without the saver's commit path the upload reads zeros / torn words --
// run with -DBUG_NO_SAVER (ioctl_din forced 0, modelling "no save logic wired":
// every word check fails, including the hyperbbc signature bytes) or with
// -DBUG_LOWBYTE_ONLY (word = {8'h00, even byte}, the loader bug's mirror image:
// every ODD-byte check fails). The checked-in default (no defines) must PASS.
//
// Coverage:
//   1. full 8 KB load->upload round trip, byte-exact vs the reference image
//      (catches packing swaps, addressing slips, off-by-2)
//   2. explicit odd/even spot checks on real hyperbbc signature bytes
//   3. RTC top words (8184..8191) = live clock registers
//   4. a colliding game-bus WRITE during the fetch window (write-priority port:
//      saver must retry, the upload word must still be coherent)
//   5. game-side read port undisturbed mid-upload
module tb_s573_nvram_saver;
    reg clk = 0, rst = 1;

    // ---- loader side (preload known contents the proven way) ----
    reg         ioctl_wr   = 0;
    reg  [12:0] dl_addr    = 0;
    reg  [15:0] dl_dout    = 0;
    wire        nvram_we;
    wire [12:0] nvram_addr;
    wire [7:0]  nvram_din;
    wire        nv_hi;

    // ---- saver / upload side ----
    reg         save_en    = 0;     // = ioctl_upload && index==3 (emu demux)
    reg  [12:0] up_addr    = 0;     // hps_io ioctl_addr during upload
    wire [15:0] ioctl_din;
    wire [12:0] sav_addr;
    wire [7:0]  sav_dout;
    wire        sav_rd_ok;

    // ---- m48t58 game bus side ----
    reg  [12:0] addr = 0;
    reg  [7:0]  din  = 0;
    reg         we   = 0;
    wire [7:0]  dout;

    integer errors = 0;
    integer i;

    // Reference image (what the file on SD must contain after a save).
    reg [7:0] ref_img [0:8191];
    reg [15:0] up_img [0:4095];     // words captured by the modelled hps_io

    s573_nvram_loader loader (
        .clk(clk), .load_en(rst),
        .ioctl_wr(ioctl_wr), .ioctl_addr(dl_addr), .ioctl_dout(dl_dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .nv_hi(nv_hi)
    );

    wire [15:0] saver_din;
    s573_nvram_saver saver (
        .clk(clk), .save_en(save_en),
        .ioctl_addr(up_addr), .ioctl_din(saver_din),
        .sav_addr(sav_addr), .sav_dout(sav_dout), .sav_rd_ok(sav_rd_ok)
    );

`ifdef BUG_NO_SAVER
    // RED model: no save logic wired -> hps_io reads a constant (what Main would
    // get from an unconnected/zero ioctl_din): the .nvm becomes all zeros.
    assign ioctl_din = 16'h0000;
`elsif BUG_LOWBYTE_ONLY
    // RED model: the WIDE trap mirror image -- only the even (low) byte packed.
    assign ioctl_din = {8'h00, saver_din[7:0]};
`else
    assign ioctl_din = saver_din;
`endif

    m48t58 #(.CLK_FREQ_HZ(1)) nv (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(nvram_we), .nvram_addr(nvram_addr), .nvram_din(nvram_din),
        .sav_addr(sav_addr), .sav_dout(sav_dout), .sav_rd_ok(sav_rd_ok)
    );

    always #5 clk = ~clk;

    // One WIDE download word via the proven loader handshake (see
    // tb_s573_nvram_loader.v for why ioctl_wr is held across the wait).
    task dl_word(input [12:0] a, input [15:0] w);
        begin
            @(negedge clk); dl_addr = a; dl_dout = w; ioctl_wr = 1;
            @(posedge clk);
            @(posedge clk);
            @(negedge clk); ioctl_wr = 0;
            @(negedge clk);
        end
    endtask

    // One hps_io upload word strobe (sys/hps_io.sv:686-699 semantics): after a
    // gap of `gap` idle cycles, the FIO_FILE_TX_DAT strobe edge latches
    // fp_dout <= ioctl_din and advances ioctl_addr by 2 ON THE SAME posedge.
    // A posedge NBA latch captures the value ioctl_din held just BEFORE the
    // edge -- modelled here by sampling at the preceding negedge (all drivers
    // are posedge-clocked, so the negedge value IS the pre-edge value). The
    // addr advance lands after the edge (blocking-after-edge == NBA timing as
    // seen by the saver). The core gets no advance warning of the strobe.
    task up_word(input integer gap, output [15:0] w);
        begin
            repeat (gap) @(posedge clk);
            @(negedge clk);
            w = ioctl_din;                   // what fp_dout latches at the edge
            @(posedge clk);                  // THE strobe edge
            up_addr = up_addr + 13'd2;       // ioctl_addr <= ioctl_addr + 2
        end
    endtask

    task check_w(input [12:0] a, input [15:0] g, input [15:0] e, input [255:0] name);
        begin
            if (g !== e) begin
                if (errors < 12)
                    $display("FAIL: %0s @%0d got %04h expected %04h", name, a, g, e);
                errors = errors + 1;
            end
        end
    endtask

    reg [15:0] got;
    reg [7:0]  gotb;
    integer first_err;

    initial begin
        // ---------------------------------------------------------------
        // 1) Build a reference image with distinct even/odd bytes (addr-
        //    derived pattern, never symmetric: catches {even,even} dup,
        //    {odd,even}<->{even,odd} swaps and addressing slips), seeded
        //    with the real hyperbbc signature head bytes 51 47 00 00 37 38.
        // ---------------------------------------------------------------
        // (i&255 guarantees even/odd neighbours differ in bit0; the >>5 mix
        // makes every 32-byte block distinct -> addressing slips can't alias.)
        for (i = 0; i < 8192; i = i + 1)
            ref_img[i] = (i & 255) ^ ((i >> 5) + 59);
        ref_img[0] = 8'h51; ref_img[1] = 8'h47; ref_img[2] = 8'h00;
        ref_img[3] = 8'h00; ref_img[4] = 8'h37; ref_img[5] = 8'h38;
        // RTC region (8184..8191) of ref = the m48t58 LIVE regs right after
        // reset release: ctrl=00 sec=00 min=00 hour=00 dow=01 dom=01 mon=01 yr=00
        // (CLK_FREQ_HZ=1 -> the clock ticks once per cycle; freeze it via the
        // STOP bit below so the seconds byte stays deterministic.)
        ref_img[8184] = 8'h00; ref_img[8185] = 8'h80; ref_img[8186] = 8'h00;
        ref_img[8187] = 8'h00; ref_img[8188] = 8'h01; ref_img[8189] = 8'h01;
        ref_img[8190] = 8'h01; ref_img[8191] = 8'h00;

        // ---------------------------------------------------------------
        // 2) Preload the full 8 KB through the REAL loader path (under rst,
        //    as on HW). RTC bytes of the file are dropped by m48t58 (load
        //    keeps nvram_addr < RTC_BASE) -- matches the shipping behaviour.
        // ---------------------------------------------------------------
        for (i = 0; i < 8192; i = i + 2)
            dl_word(i[12:0], {ref_img[i+1], ref_img[i]});

        repeat (3) @(posedge clk); @(negedge clk); rst = 0;

        // Freeze the oscillator over the game bus so the live RTC regs are
        // deterministic for the RTC-word checks -- using the REAL M48T58 write
        // protocol (as 573 software must): set WRITE freeze (ctrl bit7) first
        // so ticking pauses, then write the clock regs, then clear the freeze.
        // (With CLK_FREQ_HZ=1 the clock ticks EVERY cycle; a bare seconds write
        // would race the tick increment -- the same reason real software uses
        // the freeze bit. Also exercises bus writes to the clock registers.)
        @(negedge clk); addr = 13'd8184; din = 8'h80; we = 1;  // WRITE freeze on
        @(negedge clk); we = 0;
        @(negedge clk); addr = 13'd8185; din = 8'h80; we = 1;  // sec: STOP bit
        @(negedge clk); we = 0;
        @(negedge clk); addr = 13'd8186; din = 8'h00; we = 1;  // min = 0
        @(negedge clk); we = 0;
        @(negedge clk); addr = 13'd8187; din = 8'h00; we = 1;  // hour = 0
        @(negedge clk); we = 0;
        @(negedge clk); addr = 13'd8184; din = 8'h00; we = 1;  // freeze off
        @(negedge clk); we = 0;                                 // (STOP keeps it parked)

        // ---------------------------------------------------------------
        // 3) UPLOAD the full image, hps_io-style. Arm (Main does set_index(3)
        //    + set_upload(1), then a >= microseconds command round-trip before
        //    the first data strobe -- modelled as a modest 30-cycle gap), then
        //    4096 word strobes with a TIGHT 12-cycle gap (gate-0 fact 2.5
        //    lower bound) -- and a few stress words at the absolute-floor gap.
        // ---------------------------------------------------------------
        @(negedge clk); up_addr = 0; save_en = 1;
        repeat (30) @(posedge clk);

        for (i = 0; i < 4096; i = i + 1) begin
            up_word((i % 64 == 63) ? 8 : 12, got);
            up_img[i] = got;
        end

        @(negedge clk); save_en = 0;

        // Byte-exact round-trip compare: upload == reference file.
        first_err = -1;
        for (i = 0; i < 4096; i = i + 1) begin
            check_w(i[11:0]*2, up_img[i], {ref_img[2*i+1], ref_img[2*i]}, "round-trip word");
            if (up_img[i] !== {ref_img[2*i+1], ref_img[2*i]} && first_err < 0) first_err = i;
        end
        if (first_err >= 0)
            $display("      (first mismatching word index %0d, %0d total)", first_err, errors);

        // Explicit odd/even spot checks (the WIDE trap in reverse): the same
        // hyperbbc signature bytes whose odd halves the loader bug dropped.
        check_w(13'd0, up_img[0], 16'h4751, "sig word0 {odd 47,even 51}");
        check_w(13'd4, up_img[2], 16'h3837, "sig word2 {odd 38,even 37}");
        if (up_img[0][15:8] !== 8'h47) begin
            $display("FAIL: ODD byte ram[1] missing from upload word0 -> half-zeroed .nvm");
            errors = errors + 1;
        end

        // RTC top words = live clock registers.
        check_w(13'd8184, up_img[4092], {ref_img[8185], ref_img[8184]}, "RTC {sec,ctrl}");
        check_w(13'd8186, up_img[4093], {ref_img[8187], ref_img[8186]}, "RTC {hour,min}");
        check_w(13'd8188, up_img[4094], {ref_img[8189], ref_img[8188]}, "RTC {dom,dow}");
        check_w(13'd8190, up_img[4095], {ref_img[8191], ref_img[8190]}, "RTC {year,month}");

        // ---------------------------------------------------------------
        // 4) Collision torture: re-upload word 16 while hammering game-bus
        //    writes to an UNRELATED address (0x123 <- A5) every other cycle.
        //    The write has port priority -> the saver must retry around the
        //    stolen cycles and still deliver a coherent, correct word.
        // ---------------------------------------------------------------
        @(negedge clk); up_addr = 13'd32; save_en = 1;
        fork : collide
            begin : writes
                forever begin
                    @(negedge clk); addr = 13'h123; din = 8'hA5; we = 1;
                    @(negedge clk); we = 0;
                end
            end
            begin
                repeat (40) @(posedge clk);   // generous: every-other-cycle steals
                disable writes;
            end
        join
        we = 0;
        // Post-barrage settle: with writes stealing alternate port cycles the
        // saver may not have landed a single clean pass yet; give it one clear
        // window (<= 8 cycles needed, 16 for margin), then sample pre-edge.
        repeat (16) @(posedge clk);
        @(negedge clk); got = ioctl_din;
        check_w(13'd32, got, {ref_img[33], ref_img[32]}, "word under write collisions");
        @(negedge clk); save_en = 0;

        // The collided writes themselves must have landed (write priority).
        @(negedge clk); addr = 13'h123; @(posedge clk); @(posedge clk); #1;
        if (dout !== 8'hA5) begin
            $display("FAIL: bus write displaced by save read (got %02h)", dout);
            errors = errors + 1;
        end

        // ---------------------------------------------------------------
        // 5) Game-side read port undisturbed DURING an active upload fetch.
        // ---------------------------------------------------------------
        @(negedge clk); up_addr = 13'd100; save_en = 1;
        repeat (6) @(posedge clk);          // saver mid-loop
        @(negedge clk); addr = 13'd5;       // game reads sig byte ram[5]
        @(posedge clk); @(posedge clk); #1 gotb = dout;
        if (gotb !== 8'h38) begin
            $display("FAIL: game-side read corrupted during upload (got %02h)", gotb);
            errors = errors + 1;
        end
        @(negedge clk); save_en = 0;

        if (errors == 0) $display("RESULT: PASS (s573_nvram_saver)");
        else             $display("RESULT: FAIL (s573_nvram_saver, %0d errors)", errors);
        $finish;
    end
endmodule
