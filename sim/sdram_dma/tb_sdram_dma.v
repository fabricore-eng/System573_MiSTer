// ============================================================================
// tb_sdram_dma -- Level-2 GP0-corruption experiment: directed iverilog test of
// the 573-PATCHED psx/rtl/sdram.sv (patch 0007 ch4-flash channel) DMA read path.
//
// WHY THIS RIG: on real HW the GPU draw-list words flow
//   SDRAM chip -> sdram.sv ch1 (ch1_dma bursts) -> dma_wr/dma_data strobes ->
//   dma.vhd (ch2 useDataDirect = registered passthrough) -> DMA_GPU_write
// Level 1 (NVC tb_gpu_dma_ingest) proved the GPU-side ingest is word-exact, and
// dma.vhd is a 1-register passthrough for ch2 -- so the remaining RTL stage is
// sdram.sv itself, which the 573 fork modified (ch4 flash line-fill channel:
// new arbiter slot, ch widened 2->3 bits, data_ready_delay4). The full-system
// NVC harness uses the behavioral sdram_model3x and contains NONE of this
// logic, so this iverilog rig is the only offline test that covers it.
//
// WHAT IT DOES:
//   * behavioral SDR SDRAM chip model (CL=2, BL=2 sequential -- exactly what
//     sdram.sv's MODE register programs), preloaded with:
//       - a linked-list OT of GP0 0x2C textured-quad nodes (CLUT word
//         0x7AC00000 = palette row 491) in low RAM, and
//       - a distinct address-tagged pattern in the flash window
//         (FLASH_START = 27'h0100_0000, per rtl/emu.sv).
//   * a ch1 driver that replays dma.vhd's EXACT linked-list request pacing
//     (header chunk -> reqprocessed-paced autoread chunks of (cntDMA+1) words,
//     3 chunks/node, inter-node gap = the PAUSING->OFF->retrigger window).
//   * a ch4 driver hammering flash line-fill requests (the 573 delta under
//     suspicion) -- continuous max-pressure interleave, switchable off.
//   * auto-refresh runs at its real cadence (cycles_per_refresh=780).
//   * scoreboard: EVERY dma_data word is compared against the preloaded
//     memory; every ch4_dout burst likewise. Any mismatch prints, and a
//     0x7AC0->0x78xx-family hit is flagged as the SILICON SIGNATURE.
//
// Plusargs: +ch4=0|1 (default 1), +gap=N inter-node clk1x gap (default 6),
//           +verbose=1 word-level trace.
// Run via sim/sdram_dma/run.sh (seds a sim-only copy of sdram.sv: the vendored
// file declares `inout reg SDRAM_DQ`, which Quartus accepts but iverilog
// rejects; the copy gets a net + internal reg. The vendored tree is untouched.)
// ============================================================================
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// altddio_out stub (Quartus primitive used for SDRAM_CLK only -- irrelevant
// to data integrity; the model clocks on the controller's `clk` directly).
// ---------------------------------------------------------------------------
module altddio_out #(
   parameter extend_oe_disable     = "OFF",
   parameter intended_device_family= "Cyclone V",
   parameter invert_output         = "OFF",
   parameter lpm_hint              = "UNUSED",
   parameter lpm_type              = "altddio_out",
   parameter oe_reg                = "UNREGISTERED",
   parameter power_up_high         = "OFF",
   parameter width                 = 1
) (
   input  [width-1:0] datain_h,
   input  [width-1:0] datain_l,
   input              outclock,
   output [width-1:0] dataout,
   input              aclr,
   input              aset,
   input              oe,
   input              outclocken,
   input              sclr,
   input              sset
);
   assign dataout = {width{1'b0}};
endmodule

// ---------------------------------------------------------------------------
// Behavioral SDR SDRAM chip (single rank = chip 0; the 573 maps both main RAM
// and the flash window below addr[26], so chip 1 is never addressed outside
// the startup refreshes). CL=2, BL=2 sequential, write latency 0, single-word
// writes (NO_WRITE_BURST) -- the exact MODE sdram.sv loads.
// Permissive on A10 auto-precharge: sdram.sv issues READA every 2 cycles to
// the same open row (works on the real chips); the model keeps the row open.
// ---------------------------------------------------------------------------
module sdr_chip_model (
   input         clk,
   inout  [15:0] dq,
   input  [12:0] a,
   input  [1:0]  ba,
   input         ncs,
   input         nras,
   input         ncas,
   input         nwe,
   input         dqml,
   input         dqmh
);
   // {ba(2), row(13), col(9)} = 24-bit halfword address = byte addr[24:1]
   reg [15:0] mem [0:(1<<24)-1];

   reg [12:0] open_row [0:3];

   // Read pipe honoring the PROGRAMMED CAS latency (latched from LOAD MODE
   // REGISTER, a[6:4]). Previously hardcoded CL=2, which made any controller
   // CL change read as corruption (controller waits CL3, chip drives CL2) --
   // caught when validating patch 0020 (CAS_LATENCY 2->3).
   reg [16:0] pipe0 = 0, pipe1 = 0, pipe2 = 0;   // {valid, data}
   reg [16:0] drv   = 0;
   reg [2:0]  cl    = 3'd2;   // until LMR programs it

   assign dq = drv[16] ? drv[15:0] : 16'hzzzz;

   wire [2:0] cmd = {nras, ncas, nwe};

   integer refreshes = 0;

   always @(posedge clk) begin
      // shift the drive pipe
      drv   <= pipe0;
      pipe0 <= pipe1;
      pipe1 <= pipe2;
      pipe2 <= 17'h0;

      if (!ncs) begin
         case (cmd)
            3'b000: cl <= a[6:4]; // LOAD MODE REGISTER: capture CAS latency
            3'b011: begin // ACTIVE
               open_row[ba] <= a;
            end
            3'b101: begin // READ (A10 auto-precharge ignored -- see header)
               if (cl == 3'd3) begin
                  pipe1 <= {1'b1, mem[{ba, open_row[ba], a[8:0]}]};
                  pipe2 <= {1'b1, mem[{ba, open_row[ba], a[8:1], ~a[0]} ]}; // BL=2 seq: col^1
               end else begin
                  pipe0 <= {1'b1, mem[{ba, open_row[ba], a[8:0]}]};
                  pipe1 <= {1'b1, mem[{ba, open_row[ba], a[8:1], ~a[0]} ]};
               end
            end
            3'b100: begin // WRITE (single word, DQM = byte mask)
               if (!dqml) mem[{ba, open_row[ba], a[8:0]}][ 7:0] <= dq[ 7:0];
               if (!dqmh) mem[{ba, open_row[ba], a[8:0]}][15:8] <= dq[15:8];
            end
            3'b001: refreshes <= refreshes + 1; // AUTO REFRESH
            default: ; // NOP / PRECHARGE: no data effect
         endcase
      end
   end
endmodule

// ---------------------------------------------------------------------------
// The testbench proper.
// ---------------------------------------------------------------------------
module tb_sdram_dma;

   // ---- clocks: clk3x 10ns, clk1x 30ns, rising edges aligned every 3rd ----
   reg clk3x = 1'b1;
   reg clk1x = 1'b1;
   always #5  clk3x = ~clk3x;
   always #15 clk1x = ~clk1x;

   // ---- config ----
   integer cfg_ch4  = 1;
   integer cfg_gap  = 6;
   integer cfg_verb = 0;
   integer cfg_inject = 0;  // +inject=1: scoreboard NEGATIVE SELF-TEST -- XOR
                            // one expected CLUT word so a MISMATCH MUST fire
                            // (proves the checker is not vacuous)

   // ---- DUT wires ----
   wire [15:0] SDRAM_DQ;
   wire [12:0] SDRAM_A;
   wire [1:0]  SDRAM_BA;
   wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

   reg         init = 1'b1;

   reg  [26:0] ch1_addr = 0;
   wire [127:0] ch1_dout;
   wire [31:0] ch1_dout32;
   reg         ch1_req  = 0;
   reg  [1:0]  ch1_cntDMA = 2'd3;
   wire        ch1_ready;
   wire [3:0]  cache_wr;
   wire [31:0] cache_data;
   wire [7:0]  cache_addr;
   wire        dma_wr;
   wire        dma_reqprocessed;
   wire [31:0] dma_data;

   reg  [26:0] ch4_addr = 0;
   wire [127:0] ch4_dout;
   reg         ch4_req  = 0;
   wire        ch4_ready;

   // ---- DUT: the PATCHED controller (sim copy, see run.sh) ----
   sdram dut (
      .init        (init),
      .clk         (clk3x),
      .clk_base    (clk1x),
      .SDRAM_EN    (1'b1),
      .SDRAM_DQ    (SDRAM_DQ),
      .SDRAM_A     (SDRAM_A),
      .SDRAM_DQML  (SDRAM_DQML),
      .SDRAM_DQMH  (SDRAM_DQMH),
      .SDRAM_BA    (SDRAM_BA),
      .SDRAM_nCS   (SDRAM_nCS),
      .SDRAM_nWE   (SDRAM_nWE),
      .SDRAM_nRAS  (SDRAM_nRAS),
      .SDRAM_nCAS  (SDRAM_nCAS),
      .SDRAM_CKE   (SDRAM_CKE),
      .SDRAM_CLK   (SDRAM_CLK),
      .refreshForce(1'b0),
      .ram_idle    (),
      .ch1_addr    (ch1_addr),
      .ch1_dout    (ch1_dout),
      .ch1_dout32  (ch1_dout32),
      .ch1_din     (16'h0),
      .ch1_req     (ch1_req),
      .ch1_rnw     (1'b1),
      .ch1_dma     (1'b1),
      .ch1_cntDMA  (ch1_cntDMA),
      .ch1_cache   (1'b0),
      .ch1_ready   (ch1_ready),
      .cache_wr    (cache_wr),
      .cache_data  (cache_data),
      .cache_addr  (cache_addr),
      .dma_wr      (dma_wr),
      .dma_reqprocessed(dma_reqprocessed),
      .dma_data    (dma_data),
      .ch2_addr    (27'h0),
      .ch2_dout    (),
      .ch2_din     (32'h0),
      .ch2_req     (1'b0),
      .ch2_rnw     (1'b1),
      .ch2_be      (4'h0),
      .ch2_ready   (),
      .ch3_addr    (27'h0),
      .ch3_dout    (),
      .ch3_din     (32'h0),
      .ch3_req     (1'b0),
      .ch3_rnw     (1'b1),
      .ch3_be      (4'h0),
      .ch3_ready   (),
      .ch4_addr    (ch4_addr),
      .ch4_dout    (ch4_dout),
      .ch4_req     (ch4_req),
      .ch4_ready   (ch4_ready),
      .dmafifo_adr (27'h0),
      .dmafifo_data(32'h0),
      .dmafifo_empty(1'b1),
      .dmafifo_read()
   );

   // ---- the chip ----
   sdr_chip_model chip (
      .clk  (clk3x),
      .dq   (SDRAM_DQ),
      .a    (SDRAM_A),
      .ba   (SDRAM_BA),
      .ncs  (SDRAM_nCS),
      .nras (SDRAM_nRAS),
      .ncas (SDRAM_nCAS),
      .nwe  (SDRAM_nWE),
      .dqml (SDRAM_DQML),
      .dqmh (SDRAM_DQMH)
   );

   // ------------------------------------------------------------------------
   // Memory image: linked-list OT of 0x2C quads + flash pattern.
   //   node k at byte LBASE + k*64; header {size=9, next}; payload word 2 =
   //   0x7AC00000 (CLUT row 491 -- the silicon-corrupted word).
   // ------------------------------------------------------------------------
   localparam LBASE       = 27'h0001000;
   localparam NODES       = 200;
   localparam FLASH_BYTE  = 27'h1000000;   // FLASH_START in emu.sv

   // expected 32-bit word at byte address a (reads the chip model's memory)
   function [31:0] mem_word(input [26:0] a);
      mem_word = {chip.mem[(a>>1)+1], chip.mem[a>>1]};
   endfunction

   task set_word(input [26:0] a, input [31:0] d);
      begin
         chip.mem[a>>1]     = d[15:0];
         chip.mem[(a>>1)+1] = d[31:16];
      end
   endtask

   integer k, i;
   reg [26:0] na;
   reg [23:0] nxt;
   initial begin
      if (!$value$plusargs("ch4=%d", cfg_ch4))  cfg_ch4  = 1;
      if (!$value$plusargs("gap=%d", cfg_gap))  cfg_gap  = 6;
      if (!$value$plusargs("verbose=%d", cfg_verb)) cfg_verb = 0;
      if (!$value$plusargs("inject=%d", cfg_inject)) cfg_inject = 0;

      // flash window: address-tagged halfwords (any cross-channel leak shows)
      for (i = 0; i < (1<<16); i = i + 1)
         chip.mem[(FLASH_BYTE>>1) + i] = (i[15:0] ^ 16'hA5A5);

      // the OT
      for (k = 0; k < NODES; k = k + 1) begin
         na  = LBASE + k*64;
         nxt = (k == NODES-1) ? 24'hFFFFFF : (LBASE + (k+1)*64);
         set_word(na + 0,  {8'd9, nxt});       // header: 9 payload words
         set_word(na + 4,  32'h2C808080);      // GP0 2C textured quad
         set_word(na + 8,  {16'h0020, 16'h0020 + k[15:0]});
         set_word(na + 12, 32'h7AC00000);      // CLUT 0x7AC0 = row 491
         set_word(na + 16, 32'h00200060);
         set_word(na + 20, 32'h000E003F);      // texpage word
         set_word(na + 24, 32'h00600020);
         set_word(na + 28, 32'h00003F00);
         set_word(na + 32, 32'h00600060);
         set_word(na + 36, 32'h00003F3F);
         set_word(na + 40, 32'hFEED0000 | (k*16));     // padding (over-read words)
         set_word(na + 44, 32'hFEED0001 | (k*16));
         for (i = 48; i < 64; i = i + 4)
            set_word(na + i, 32'hBEEF0000 | (k*16+i));
      end

      $display("tb: %0d nodes at %07x, ch4=%0d gap=%0d", NODES, LBASE, cfg_ch4, cfg_gap);

      // release init after a few cycles; the controller then runs its 121us
      // startup (12100 clk3x) before STATE_IDLE.
      repeat (10) @(posedge clk3x);
      init = 1'b0;
   end

   // ------------------------------------------------------------------------
   // ch1 driver: dma.vhd's linked-list pacing, verbatim at the request level.
   //   cnt presented = f(addr[9:2]) (dma.vhd lines 190-200);
   //   header chunk at node addr; on header word: required = size+1, issue
   //   chunk2 immediately (READHEADER behavior); further chunks issued on the
   //   dma_reqprocessed edge while requested < required (autoread);
   //   addr += (cnt+1)*4 on every reqprocessed.
   // ------------------------------------------------------------------------
   function [1:0] cnt_f(input [26:0] a);
      case (a[9:2])
         8'hFF:   cnt_f = 2'd0;
         8'hFE:   cnt_f = 2'd1;
         8'hFD:   cnt_f = 2'd2;
         default: cnt_f = 2'd3;
      endcase
   endfunction

   // expectation FIFO of byte addresses for pending dma_wr words
   reg [26:0] expq [0:63];
   integer    expq_w = 0, expq_r = 0;

   task push_chunk(input [26:0] a, input [1:0] cnt);
      integer j;
      begin
         for (j = 0; j <= cnt; j = j + 1) begin
            expq[expq_w % 64] = a + j*4;
            expq_w = expq_w + 1;
         end
      end
   endtask

   localparam S_BOOT = 0, S_HDRREQ = 1, S_RUN = 2, S_GAP = 3, S_DONE = 4;
   integer st = S_BOOT;

   reg [26:0] cur_addr  = 0;
   reg [1:0]  cur_cnt   = 0;
   integer    requested = 0, required = 0, streamed = 0;
   reg        header_seen = 0;
   reg [23:0] next_node  = 0;
   integer    gapcnt     = 0;
   integer    node_cnt   = 0;

   integer    errors = 0, sigs = 0, words_total = 0;
   integer    ch4_fills = 0, ch4_errors = 0;
   reg [31:0] expw;
   reg [26:0] expa;

   wire [1:0] cnt_now = cnt_f(cur_addr);

   always @(posedge clk1x) begin
      ch1_req <= 1'b0;

      case (st)
         S_BOOT: begin
            // wait out the controller startup
            if ($time > 125000 && init == 1'b0) begin
               cur_addr <= LBASE;
               st       <= S_HDRREQ;
            end
         end

         S_HDRREQ: begin
            ch1_req     <= 1'b1;
            ch1_addr    <= cur_addr;
            ch1_cntDMA  <= cnt_now;
            cur_cnt     <= cnt_now;
            push_chunk(cur_addr, cnt_now);
            requested   <= cnt_now + 1;
            required    <= 99;          // unknown until the header word lands
            streamed    <= 0;
            header_seen <= 0;
            st          <= S_RUN;
         end

         S_RUN: begin
            // dma.vhd line 906: on reqprocessed advance the address
            if (dma_reqprocessed) begin
               cur_addr <= cur_addr + ((cur_cnt + 1) * 4);
               // autoread re-issue (only after the header told us the size)
               if (header_seen && requested < required) begin
                  ch1_req    <= 1'b1;
                  ch1_addr   <= cur_addr + ((cur_cnt + 1) * 4);
                  ch1_cntDMA <= cnt_f(cur_addr + ((cur_cnt + 1) * 4));
                  cur_cnt    <= cnt_f(cur_addr + ((cur_cnt + 1) * 4));
                  push_chunk(cur_addr + ((cur_cnt + 1) * 4),
                             cnt_f(cur_addr + ((cur_cnt + 1) * 4)));
                  requested  <= requested + cnt_f(cur_addr + ((cur_cnt + 1) * 4)) + 1;
               end
            end

            // consume dma_wr words; compare each against the memory image
            if (dma_wr) begin
               expa = expq[expq_r % 64];
               expq_r = expq_r + 1;
               expw = mem_word(expa);
               // negative self-test: fault the expectation of node 5's CLUT
               // word (mimics 491->480: bits 22/23/25 of the word dropped)
               if (cfg_inject && expa == (LBASE + 5*64 + 12))
                  expw = expw ^ 32'h02C00000;
               words_total = words_total + 1;
               streamed = streamed + 1;

               if (cfg_verb)
                  $display("t=%0t node=%0d w=%0d addr=%07x got=%08x exp=%08x",
                           $time, node_cnt, streamed, expa, dma_data, expw);

               if (dma_data !== expw) begin
                  errors = errors + 1;
                  $display("MISMATCH t=%0t node=%0d addr=%07x got=%08x exp=%08x xor=%08x",
                           $time, node_cnt, expa, dma_data, expw, dma_data ^ expw);
                  // silicon signature: the CLUT halfword 7AC0 read back with
                  // low palette-row bits dropped (7800/7840/7880/78C0/7A00...)
                  if (expw[31:16] == 16'h7AC0 && dma_data[31:16] != 16'h7AC0 &&
                      (dma_data[31:16] & 16'h7AC0) == dma_data[31:16]) begin
                     sigs = sigs + 1;
                     $display("  ** SILICON SIGNATURE: 7AC0 -> %04x (low bits dropped)",
                              dma_data[31:16]);
                  end
               end

               if (!header_seen) begin
                  header_seen <= 1'b1;
                  required    <= dma_data[31:24] + 1;
                  next_node   <= dma_data[23:0];
                  // READHEADER: issue chunk 2 right away (addr already
                  // advanced by the header chunk's reqprocessed)
                  if (dma_reqprocessed) begin
                     // simultaneous: let the reqprocessed branch above handle
                     // the advance; chunk2 goes out next edge via required<
                  end else begin
                     ch1_req    <= 1'b1;
                     ch1_addr   <= cur_addr;
                     ch1_cntDMA <= cnt_now;
                     cur_cnt    <= cnt_now;
                     push_chunk(cur_addr, cnt_now);
                     requested  <= requested + cnt_now + 1;
                  end
               end

               // node complete: all requested words streamed and enough seen
               if (header_seen && streamed + 1 > requested && requested >= required) begin
                  // (can't happen -- guarded below on equality instead)
               end
            end

            if (header_seen && streamed == requested && requested >= required) begin
               node_cnt <= node_cnt + 1;
               if (next_node[23]) begin
                  st <= S_DONE;
               end else begin
                  gapcnt <= cfg_gap;
                  st     <= S_GAP;
               end
            end
         end

         S_GAP: begin
            // PAUSING -> OFF -> retrigger window (CPU runs here on real HW)
            if (gapcnt > 0) gapcnt <= gapcnt - 1;
            else begin
               cur_addr <= {3'b000, next_node};
               st       <= S_HDRREQ;
            end
         end

         S_DONE: begin
            $display("");
            $display("== RESULT ==");
            $display("nodes          : %0d", node_cnt);
            $display("dma words      : %0d", words_total);
            $display("dma mismatches : %0d", errors);
            $display("signature hits : %0d", sigs);
            $display("ch4 fills      : %0d", ch4_fills);
            $display("ch4 mismatches : %0d", ch4_errors);
            $display("chip refreshes : %0d", chip.refreshes);
            if (errors == 0 && ch4_errors == 0)
               $display("VERDICT: CLEAN -- every DMA word and ch4 burst is bit-exact.");
            else if (sigs > 0)
               $display("VERDICT: REPRO -- silicon-signature corruption reproduced.");
            else
               $display("VERDICT: MISMATCH -- corruption seen but not the 480/481 family.");
            $finish;
         end
      endcase
   end

   // ------------------------------------------------------------------------
   // ch4 driver: continuous flash line-fill pressure (the 573 delta).
   // s573_flash steps 16-byte ch4 bursts; re-request as soon as the previous
   // fill returns = maximum arbiter interleave with the ch1 DMA chunks.
   // ------------------------------------------------------------------------
   reg        ch4_busy = 0;
   reg [26:0] ch4_cur  = 0;
   integer    j4;
   reg [15:0] exp_hw;

   always @(posedge clk1x) begin
      ch4_req <= 1'b0;

      if (cfg_ch4 && st != S_BOOT && st != S_DONE) begin
         if (!ch4_busy) begin
            ch4_req  <= 1'b1;
            ch4_addr <= FLASH_BYTE + ch4_cur;
            ch4_busy <= 1'b1;
         end
      end

      if (ch4_ready) begin
         ch4_busy  <= 1'b0;
         ch4_fills <= ch4_fills + 1;
         for (j4 = 0; j4 < 8; j4 = j4 + 1) begin
            exp_hw = chip.mem[((FLASH_BYTE + ch4_cur) >> 1) + j4];
            if (ch4_dout[j4*16 +: 16] !== exp_hw) begin
               ch4_errors = ch4_errors + 1;
               if (ch4_errors <= 20)
                  $display("CH4 MISMATCH t=%0t addr=%07x hw%0d got=%04x exp=%04x",
                           $time, FLASH_BYTE + ch4_cur, j4,
                           ch4_dout[j4*16 +: 16], exp_hw);
            end
         end
         ch4_cur <= (ch4_cur + 16) & 27'h001FFFF;  // walk a 128KB flash window
      end
   end

   // safety timeout
   initial begin
      #20_000_000; // 20 ms
      $display("TIMEOUT: did not finish (st=%0d node=%0d streamed=%0d requested=%0d required=%0d)",
               st, node_cnt, streamed, requested, required);
      $finish;
   end

endmodule
