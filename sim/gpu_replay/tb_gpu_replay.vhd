-- =============================================================================
-- tb_gpu_replay -- GPU-ISOLATED GP0/GP1 command-replay harness for NVC.
--
-- Stands the vendored psx.gpu up STANDALONE (no CPU, no BIOS, no full system),
-- drives it from a text command stream, and captures the rendered framebuffer
-- to the upstream .gra dump machinery:
--    ddrram_model -> gra_fb_out.gra      (raw VRAM-as-drawn, 1024x512)
--    framebuffer  -> gra_fb_out_vga.gra  (displayed video, 640x480)
-- gra2png.py renders either to PNG.
--
-- This is the NVC twin of the upstream ModelSim rig psx/sim/gpu/src/tb/tb.vhd,
-- but:
--   * pure reset bring-up (NO tb_savestates / .ss savestate load) -- with
--     loading_savestate='0' a plain reset fully soft-resets the GPU, so the
--     command stream programs everything (display mode, draw area, texpage,
--     CLUT) from scratch.
--   * VRAM preload via the ddrram_model COMMAND_FILE_START_2 path (TARGET=0
--     loads a raw 1024x512x2 = 1 MB VRAM image linearly into the model's data[]
--     word array). Lets us seed textures + CLUTs before replaying draws.
--   * generic-selectable command file + VRAM file + SLOWTIMING knob (the VRAM
--     read-latency lever: 0 = ideal, >0 = realistic HW latency) so the same rig
--     tests the RTL-logic-vs-HW-timing hypothesis for the 573 bg-panel garble.
--   * the FULL current gpu.vhd port map (this 573 fork has a 28-bit vram_ADDR
--     and many extra ports vs the old upstream gpu tb), copied from the
--     authoritative instantiation in psx_top.vhd; DDR address mapping copied
--     from psx_mister.vhd (DDRAM_ADDR(24:0) <= vram_ADDR(27:3), base 0x3<<25).
--
-- Command stream format (all hex, one event per line; blank/`#`-comment lines
-- skipped). EXTENDS the upstream 3-field "<type> <time> <data>" by making the
-- first field the GPU bus address so we can drive BOTH GP0 (addr 0) and GP1
-- (addr 4):
--     <addr> <time> <data>
--   addr : GPU bus_addr (00 = GP0 data/cmd FIFO, 04 = GP1 control)   [8 hex]
--   time : clk1x tick at/after which to issue the write               [8 hex]
--   data : the 32-bit word                                           [8 hex]
--
-- This file is ORIGINAL to this repo (it only INSTANTIATES vendored psx/ +
-- upstream-tb entities); the vendored submodule is untouched. Build via run.sh.
-- =============================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_textio.all;
library STD;
use STD.textio.all;

library tb;
use tb.globals.all;     -- COMMAND_FILE_* (the ddrram_model VRAM-load handshake)

library psx;
use psx.pGPU.all;        -- div_type (the FIX_POLY_DIV whole-record force aliases)

entity tb_gpu_replay is
   generic
   (
      CMD_FILE     : string  := "cmd_stream.txt";
      PRELOAD_VRAM : std_logic := '0';
      VRAM_FILE    : string  := "vram_init.bin";
      SLOWTIMING   : integer := 0;
      RANDTIMING   : std_logic := '0';  -- ddrram_model RANDOMTIMING (extra random read latency; needs SLOWTIMING>0)
      -- VRAM read-ISSUE contention (ddr_contention_shim between GPU and model;
      -- 0 = pure passthrough = bit-identical to the unshimmed rig):
      CONT_MODE    : integer := 0;
      CONT_PERIOD  : integer := 2000;
      CONT_LEN     : integer := 0;
      CONT_SEED    : integer := 1;
      DRAIN_MS     : time    := 4 ms
   );
end entity;

architecture sim of tb_gpu_replay is

   -- DEBUG probe gate (ships OFF). Set true to enable the internal GPU taps in
   -- the dbg_tex process (proc_idle / reqVRAMEnable / VRAMIdle / pipeline_stall).
   constant DBG_TEX : boolean := false;

   -- CLUT-resolve TAP gate (ships OFF). Set true to log the per-pixel CLUT
   -- resolve (PIX rows: cacheWord/clutAddrB/clutDataB), the FINAL output pixel
   -- (OUT rows: stage6 x/y/pixelColor) and the CLUT-load handshake (CLUT rows),
   -- to build/tap8.log. Used to pin the hyperbbc bg-panel garble. Read-only
   -- external-name taps into the vendored gpu_pixelpipeline (NO submodule edit).
   -- The OUT/PIX rows fire for BOTH the rect path (gpu_rect) AND -- since
   -- FIX_POLY_DIV (below) -- the POLY path (gpu_poly, GP0 0x2C), so the garble
   -- quad and its control rect can be tapped head-to-head. (M5 result: with the
   -- savestate VRAM both resolve CLUT 0x7ac0 correctly -> pixelColor = CLUT[idx],
   -- NO index<<5 leak; see the rig README "Milestone 5".)
   -- NB: ships OFF (matches the README). The aliases below are typed at the
   -- STOCK (1MB-VRAM, 9-bit-Y) widths; with psx_patches/0021 (2MB VRAM, 10-bit Y)
   -- applied, several would need width bumps (textPal*/stage*_y -> 9->10 bits).
   -- Re-type them for whichever tree you are probing before turning this on.
   constant DBG_TAP8 : boolean := false;

   -- RIG FIX gate (ships ON). Makes the POLY path (GP0 0x2C/0x28) render in NVC.
   -- WHY: gpu.vhd wires the shared dividers through `inout div_type` ports on
   -- gpu_poly/gpu_line (div1..div6). gpu_poly/gpu_line NEVER assign the read-only
   -- record fields (.done/.quotient/.remainder), but an `inout` port still creates
   -- a SOURCE for the whole record. div_type.done is a plain std_logic with no
   -- default, so under NVC's init-time multi-source resolution that port source is
   -- 'U' and `resolved('U', real) = 'U'` -> poly_div(i).done = 'U' FOREVER ->
   -- gpu_poly's state machine (CALCBOUNDARY2/CALCCOLOR3/CALCTEXTURE3 gate on
   -- div1.done='1') never advances -> the poly drawer stalls, emits 0 pixels.
   -- (Reproduced: the "POLY_DIV(*).DONE has 2 sources ... 'U' and no driver"
   -- init warnings; a 0x2C quad draws nothing.) On real silicon there is no init
   -- 'U' (regs reset to '0' and the divider drives the value), so this is a pure
   -- NVC-elaboration artifact of the inout-record idiom -- NOT a core bug.
   -- FIX (tb-side, NO psx/ edit): the *array* signals div_array(i) ARE clean (sole
   -- driver = the divider instance port), carrying the divider's REAL results. We
   -- VHDL-2008 `force` the poisoned poly_div(i)/line_div(i) .done/.quotient/
   -- .remainder to mirror div_array(i) every clk2x. `force` overrides resolution
   -- (verified: it pins past a 'U' source), so the poly path sees the genuine,
   -- timing-accurate divider outputs. This changes NOTHING the divider computes;
   -- it only repairs the NVC fan-out of those outputs to the drawer's read ports.
   constant FIX_POLY_DIV : boolean := true;

   -- POLY-progress diagnostic tap (ships OFF). Logs gpu_poly's internals
   -- (div1.done via the whole-record alias, baseStep, denom, xPos/yPos,
   -- firstPixel, vramLineEna, pipeline_new, done) to find WHERE the poly state
   -- machine parks. Used to confirm FIX_POLY_DIV unblocks the divider gates and
   -- to drive the per-pixel quad-vs-rect tap. Read-only external names.
   constant DBG_POLY : boolean := false;

   signal clk1x               : std_logic := '1';
   signal clk2x               : std_logic := '1';
   signal clkvid              : std_logic := '1';

   signal clk1xToggle         : std_logic := '0';
   signal clk1xToggle2X       : std_logic := '0';
   signal clk2xIndex          : std_logic := '0';

   signal reset               : std_logic := '1';

   -- gpu bus
   signal bus_gpu_addr        : unsigned(3 downto 0) := (others => '0');
   signal bus_gpu_dataWrite   : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_gpu_read        : std_logic := '0';
   signal bus_gpu_write       : std_logic := '0';
   signal bus_gpu_dataRead    : std_logic_vector(31 downto 0);

   -- vram (28-bit byte address in this fork)
   signal vram_ADDR           : std_logic_vector(27 downto 0);
   signal vram_BURSTCNT       : std_logic_vector(7 downto 0);

   -- video
   signal hblank              : std_logic;
   signal vblank              : std_logic;
   signal video_ce            : std_logic;
   signal video_interlace     : std_logic;
   signal video_r             : std_logic_vector(7 downto 0);
   signal video_g             : std_logic_vector(7 downto 0);
   signal video_b             : std_logic_vector(7 downto 0);

   -- ddrram (VRAM model)
   signal DDRAM_BUSY          : std_logic;
   signal DDRAM_ADDR          : std_logic_vector(28 downto 0);
   signal DDRAM_DOUT          : std_logic_vector(63 downto 0);
   signal DDRAM_DOUT_READY    : std_logic;
   signal DDRAM_RD            : std_logic;   -- GPU-side read request (pre-shim)
   signal DDRAM_DIN           : std_logic_vector(63 downto 0);
   signal DDRAM_BE            : std_logic_vector(7 downto 0);
   signal DDRAM_WE            : std_logic;

   -- VRAM-contention shim (READ-ISSUE path only; see ddr_contention_shim.vhd)
   signal DDRAM_RD_model      : std_logic;   -- post-shim read request, to the model
   signal shim_BUSY           : std_logic;   -- shim contention busy
   signal gpu_vram_BUSY       : std_logic;   -- model BUSY OR shim busy -> GPU vram_BUSY

   -- savestate ports tied off (NOT loading a savestate; reset alone soft-resets)
   signal loading_savestate   : std_logic := '0';
   signal SS_reset            : std_logic := '0';
   signal SS_DataWrite        : std_logic_vector(31 downto 0) := (others => '0');
   signal SS_Adr              : unsigned(2 downto 0) := (others => '0');

   -- open/ignored GPU outputs
   signal o_allowunpause      : std_logic;
   signal o_errorLINE, o_errorRECT, o_errorPOLY, o_errorGPU, o_errorMASK, o_errorFIFO : std_logic;
   signal o_bus_stall         : std_logic;
   signal o_gpu_dmaRequest    : std_logic;
   signal o_DMA_GPU_read      : std_logic_vector(31 downto 0);
   signal o_irq_VBLANK, o_irq_GPU : std_logic;
   signal o_vram_paused       : std_logic;
   signal o_vram_DIN          : std_logic_vector(63 downto 0);
   signal o_vram_BE           : std_logic_vector(7 downto 0);
   signal o_vram_WE, o_vram_RD : std_logic;
   signal o_hblank_tmr, o_vblank_tmr, o_dotclock : std_logic;
   signal o_hsync, o_vsync    : std_logic;
   signal o_DisplayWidth      : unsigned(10 downto 0);
   signal o_DisplayHeight     : unsigned( 9 downto 0);
   signal o_DisplayOffsetX    : unsigned( 9 downto 0);
   signal o_DisplayOffsetY    : unsigned( 8 downto 0);
   signal o_video_isPal, o_video_fbmode, o_video_fb24 : std_logic;
   signal o_video_hResMode    : std_logic_vector(2 downto 0);
   signal o_video_frameindex  : std_logic_vector(3 downto 0);
   signal o_Gun1IRQ10, o_Gun2IRQ10 : std_logic;
   signal o_SS_DataRead_GPU, o_SS_DataRead_Timing : std_logic_vector(31 downto 0);
   signal o_SS_Idle           : std_logic;

   signal clkCount            : integer := 0;
   signal cmdCount            : integer := 0;

   -- single hex digit -> 4-bit value
   function hexval(c : character) return integer is
   begin
      case c is
         when '0' to '9' => return character'pos(c) - character'pos('0');
         when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
         when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
         when others     => return 0;
      end case;
   end function;

begin

   clk1x  <= not clk1x  after 15 ns;
   clk2x  <= not clk2x  after 7500 ps;
   clkvid <= not clkvid after 9312 ps;     -- NTSC 53.693175 MHz

   -- clk2xIndex generation (verbatim from upstream gpu tb)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then
            clk2xIndex <= '1';
         end if;
      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- DUT: vendored psx.gpu, standalone. Port map copied from psx_top.vhd's
   -- igpu (the authoritative instantiation for this fork), with the savestate
   -- path tied to a plain non-loading reset and unused outputs left open.
   -- -----------------------------------------------------------------------
   igpu : entity psx.gpu
   port map
   (
      clk1x                => clk1x,
      clk2x                => clk2x,
      clk2xIndex           => clk2xIndex,
      clkvid               => clkvid,
      ce                   => '1',
      reset                => reset,

      allowunpause         => o_allowunpause,
      savestate_busy       => '0',
      system_paused        => '0',

      ditherOff            => '0',
      interlaced480pHack   => '0',
      REPRODUCIBLEGPUTIMING=> '0',
      videoout_on          => '1',
      isPal                => '0',
      pal60                => '1',
      fpscountOn           => '0',
      noTexture            => '0',
      textureFilter        => "00",
      textureFilterStrength=> "00",
      textureFilter2DOff   => '0',
      dither24             => '1',
      render24             => '0',
      drawSlow             => '0',
      debugmodeOn          => '0',
      syncVideoOut         => '0',
      syncInterlace        => '0',
      rotate180            => '0',
      fixedVBlank          => '1',
      vCrop                => "00",
      hCrop                => '0',

      oldGPU               => '0',

      Gun1CrosshairOn      => '0',
      Gun1X                => "00000001",
      Gun1Y_scanlines      => "000000001",
      Gun1offscreen        => '0',
      Gun1IRQ10            => o_Gun1IRQ10,

      Gun2CrosshairOn      => '0',
      Gun2X                => "00011111",
      Gun2Y_scanlines      => "000001111",
      Gun2offscreen        => '0',
      Gun2IRQ10            => o_Gun2IRQ10,

      cdSlow               => '0',

      errorOn              => '0',
      errorEna             => '0',
      errorCode            => x"8",

      LBAOn                => '0',
      LBAdisplay           => x"00000",

      errorLINE            => o_errorLINE,
      errorRECT            => o_errorRECT,
      errorPOLY            => o_errorPOLY,
      errorGPU             => o_errorGPU,
      errorMASK            => o_errorMASK,
      errorFIFO            => o_errorFIFO,

      bus_addr             => bus_gpu_addr,
      bus_dataWrite        => bus_gpu_dataWrite,
      bus_read             => bus_gpu_read,
      bus_write            => bus_gpu_write,
      bus_dataRead         => bus_gpu_dataRead,
      bus_stall            => o_bus_stall,

      dmaOn                => '0',
      gpu_dmaRequest       => o_gpu_dmaRequest,
      DMA_GPU_waiting      => '0',
      DMA_GPU_writeEna     => '0',
      DMA_GPU_readEna      => '1', -- keep read fifo drained so vram2cpu can't stall
      DMA_GPU_write        => x"00000000",
      DMA_GPU_read         => o_DMA_GPU_read,

      irq_VBLANK           => o_irq_VBLANK,
      irq_GPU              => o_irq_GPU,

      vram_pause           => '0',
      vram_paused          => o_vram_paused,
      vram_BUSY            => gpu_vram_BUSY,
      vram_DOUT            => DDRAM_DOUT,
      vram_DOUT_READY      => DDRAM_DOUT_READY,
      vram_BURSTCNT        => vram_BURSTCNT,
      vram_ADDR            => vram_ADDR,
      vram_DIN             => DDRAM_DIN,
      vram_BE              => DDRAM_BE,
      vram_WE              => DDRAM_WE,
      vram_RD              => DDRAM_RD,

      hblank_tmr           => o_hblank_tmr,
      vblank_tmr           => o_vblank_tmr,
      dotclock             => o_dotclock,

      video_hsync          => o_hsync,
      video_vsync          => o_vsync,
      video_hblank         => hblank,
      video_vblank         => vblank,
      video_DisplayWidth   => o_DisplayWidth,
      video_DisplayHeight  => o_DisplayHeight,
      video_DisplayOffsetX => o_DisplayOffsetX,
      video_DisplayOffsetY => o_DisplayOffsetY,
      video_ce             => video_ce,
      video_interlace      => video_interlace,
      video_r              => video_r,
      video_g              => video_g,
      video_b              => video_b,
      video_isPal          => o_video_isPal,
      video_fbmode         => o_video_fbmode,
      video_fb24           => o_video_fb24,
      video_hResMode       => o_video_hResMode,
      video_frameindex     => o_video_frameindex,

-- synthesis translate_off
      export_gtm           => open,
      export_line          => open,
      export_gpus          => open,
      export_gobj          => open,
-- synthesis translate_on

      loading_savestate    => loading_savestate,
      SS_reset             => SS_reset,
      SS_DataWrite         => SS_DataWrite,
      SS_Adr               => SS_Adr,
      SS_wren_GPU          => '0',
      SS_wren_Timing       => '0',
      SS_rden_GPU          => '0',
      SS_rden_Timing       => '0',
      SS_DataRead_GPU      => o_SS_DataRead_GPU,
      SS_DataRead_Timing   => o_SS_DataRead_Timing,
      SS_Idle              => o_SS_Idle
   );

   -- VRAM at DDR base 0x30000000 (mapping copied verbatim from psx_mister.vhd):
   --   DDRAM_ADDR(28:25) = "0011"; DDRAM_ADDR(24:0) = vram_ADDR(27:3).
   DDRAM_ADDR(28 downto 25) <= "0011";
   DDRAM_ADDR(24 downto  0) <= vram_ADDR(27 downto 3);

   -- -----------------------------------------------------------------------
   -- VRAM-CONTENTION shim, READ-ISSUE path only. Models the real-HW f2sdram
   -- arbitration (scaler/HPS can hold off the GPU's read issue arbitrarily),
   -- which the stock ddrram_model never does (it accepts a read the instant
   -- DDRAM_RD rises and never asserts BUSY for reads). CONT_MODE=0 (default)
   -- drives shim_BUSY='0' / DDRAM_RD_model<=DDRAM_RD = pure passthrough,
   -- bit-identical to the pre-shim rig. The GPU's vram_BUSY is the OR of the
   -- model's write-path BUSY and the shim's contention busy; ADDR/BURSTCNT/
   -- DIN/BE/WE/DOUT/DOUT_READY stay wired straight through (the WRITE path is
   -- deliberately NOT gated -- see the limitation note in the shim).
   -- -----------------------------------------------------------------------
   gpu_vram_BUSY <= DDRAM_BUSY or shim_BUSY;

   ishim : entity tb.ddr_contention_shim
   generic map
   (
      CONT_MODE   => CONT_MODE,
      CONT_PERIOD => CONT_PERIOD,
      CONT_LEN    => CONT_LEN,
      CONT_SEED   => CONT_SEED
   )
   port map
   (
      clk      => clk2x,
      gpu_RD   => DDRAM_RD,
      gpu_BUSY => shim_BUSY,
      mem_RD   => DDRAM_RD_model
   );

   iddrram_model : entity tb.ddrram_model
   generic map
   (
      loadVram     => '0',          -- preload via COMMAND_FILE_START_2 instead
      SLOWTIMING   => SLOWTIMING,
      RANDOMTIMING => RANDTIMING
   )
   port map
   (
      DDRAM_CLK        => clk2x,
      DDRAM_BUSY       => DDRAM_BUSY,
      DDRAM_BURSTCNT   => vram_BURSTCNT,
      DDRAM_ADDR       => DDRAM_ADDR,
      DDRAM_DOUT       => DDRAM_DOUT,
      DDRAM_DOUT_READY => DDRAM_DOUT_READY,
      DDRAM_RD         => DDRAM_RD_model,
      DDRAM_DIN        => DDRAM_DIN,
      DDRAM_BE         => DDRAM_BE,
      DDRAM_WE         => DDRAM_WE
   );

   -- VGA framebuffer dump (displayed video -> gra_fb_out_vga.gra, 640x480).
   gvga : block
      signal video_dither_r : std_logic_vector(5 downto 0);
      signal video_dither_g : std_logic_vector(5 downto 0);
      signal video_dither_b : std_logic_vector(5 downto 0);
   begin
      video_dither_r <= video_r(7 downto 2);
      video_dither_g <= video_g(7 downto 2);
      video_dither_b <= video_b(7 downto 2);

      iframebuffer : entity tb.framebuffer
      port map
      (
         clk                  => clkvid,
         hblank               => hblank,
         vblank               => vblank,
         video_ce             => video_ce,
         video_interlace      => video_interlace,
         video_r(7 downto 2)  => video_dither_r,
         video_r(1 downto 0)  => "00",
         video_g(7 downto 2)  => video_dither_g,
         video_g(1 downto 0)  => "00",
         video_b(7 downto 2)  => video_dither_b,
         video_b(1 downto 0)  => "00"
      );
   end block;

   -- -----------------------------------------------------------------------
   -- Reset + VRAM preload sequencer.
   --   1. Hold reset, optionally preload VRAM via COMMAND_FILE_START_2 (the
   --      ddrram_model handler runs on DDRAM_CLK=clk2x; one START_2 pulse loads
   --      the whole file into data[] at TARGET=0 = linear VRAM image).
   --   2. Release reset (GPU soft-resets clean with loading_savestate='0').
   -- -----------------------------------------------------------------------
   reset_seq : process
   begin
      reset                <= '1';
      COMMAND_FILE_START_2 <= '0';
      COMMAND_FILE_NAME    <= (others => ' ');
      wait for 1 us;

      if PRELOAD_VRAM = '1' then
         COMMAND_FILE_NAME(1 to VRAM_FILE'length) <= VRAM_FILE;
         COMMAND_FILE_NAMELEN <= VRAM_FILE'length;
         COMMAND_FILE_TARGET  <= 0;       -- VRAM word base
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;       -- whole file
         COMMAND_FILE_ENDIAN  <= '0';
         -- One clk2x edge with START_2 high triggers a complete file load inside
         -- the ddrram_model handler (it loads the whole file in a single pass).
         -- Hold for ~one clk2x period only -- holding longer just re-loads the
         -- whole file every clk2x edge (idempotent but wastes time + balloons the
         -- VRAM-dump .gra, since each load re-arms dumpVRAMimage).
         COMMAND_FILE_START_2 <= '1';
         wait for 16 ns;                  -- ~one clk2x (7.5 ns half-period)
         COMMAND_FILE_START_2 <= '0';
         wait for 2 us;                   -- let the load + VRAM-dump settle
         report "tb_gpu_replay: VRAM preloaded from " & VRAM_FILE;
      end if;

      wait for 1 us;
      reset <= '0';
      wait;
   end process;

   -- -----------------------------------------------------------------------
   -- Command-stream replay. Reads CMD_FILE lines "<addr> <time> <data>" (hex)
   -- and issues each as a one-clk1x bus write at the requested clkCount tick.
   -- Comment ('#') and blank lines are skipped.
   -- -----------------------------------------------------------------------
   replay : process
      file infile          : text;
      variable f_status    : FILE_OPEN_STATUS;
      variable inLine      : line;
      variable para_addr   : integer;
      variable para_time   : std_logic_vector(31 downto 0);
      variable para_data   : std_logic_vector(31 downto 0);
      variable c           : character;
      variable okc         : boolean;
      variable okh         : boolean;
      variable digits      : integer;
   begin
      wait until reset = '0';
      wait until rising_edge(clk1x);

      file_open(f_status, infile, CMD_FILE, read_mode);
      assert f_status = open_ok
         report "tb_gpu_replay: cannot open command file " & CMD_FILE
         severity failure;

      while (not endfile(infile)) loop
         readline(infile, inLine);

         -- Find first non-whitespace char; classify the line.
         okc := true;
         loop
            if inLine.all'length = 0 then okc := false; exit; end if;
            read(inLine, c, okc);
            exit when not okc;
            exit when c /= ' ' and c /= HT;
         end loop;
         next when not okc;          -- blank line
         next when c = '#';          -- comment line

         -- 'c' is the first hex digit of <addr>; read the field's remaining
         -- digits up to the next whitespace, accumulating the value. (addr is
         -- only ever 0 or 4, so we only really need the low nibble, but parse
         -- the whole token to consume it.)
         para_addr := hexval(c);
         digits    := 1;
         loop
            exit when inLine.all'length = 0;
            read(inLine, c, okc);
            exit when not okc;
            exit when c = ' ' or c = HT;   -- field separator
            para_addr := para_addr * 16 + hexval(c);
            digits    := digits + 1;
         end loop;

         -- HREAD skips leading whitespace, so it parses <time> then <data>.
         HREAD(inLine, para_time, okh); next when not okh;
         HREAD(inLine, para_data, okh); next when not okh;

         -- wait until the requested tick
         while (clkCount < to_integer(unsigned(para_time))) loop
            clkCount <= clkCount + 1;
            wait until rising_edge(clk1x);
         end loop;

         bus_gpu_addr      <= to_unsigned(para_addr mod 16, 4);
         bus_gpu_dataWrite <= para_data;
         bus_gpu_write     <= '1';

         clkCount <= clkCount + 1;
         cmdCount <= cmdCount + 1;
         wait until rising_edge(clk1x);
         bus_gpu_write     <= '0';
      end loop;

      file_close(infile);
      report "tb_gpu_replay: replayed " & integer'image(cmdCount) & " commands; draining";

      wait for DRAIN_MS;
      report "tb_gpu_replay: DONE";
      std.env.stop;
   end process;

   -- -----------------------------------------------------------------------
   -- DEBUG probe (DBG_TEX=true): tap GPU drawer-idle + VRAM-request internals via
   -- VHDL-2008 external names. Used to diagnose the textured-primitive hang (see
   -- the rig README: textured polys/rects leave proc_idle='0' and never issue a
   -- VRAM read under NVC, while fills/flat-rects render fine). Read-only (report);
   -- ships OFF -- flip DBG_TEX to re-enable the probe.
   -- -----------------------------------------------------------------------
   -- FIX_POLY_DIV: repair the NVC inout-record 'U' poison on the shared-divider
   -- read ports so the POLY (and LINE) path renders. See the FIX_POLY_DIV
   -- constant comment for the root cause.
   --
   -- We `force` the WHOLE div_type record on each gpu_poly/gpu_line inout port
   -- (igpu_poly.divN / igpu_line.divN) to the divider's genuine outputs. Two NVC
   -- external-name facts forced this exact shape (both verified with minimal
   -- testcases):
   --   * Record-FIELD sub-selection in an external name is NOT supported
   --     (`name X not found` -- ".done" is treated as a sub-region). So we cannot
   --     name `poly_div(i).done`; we alias the WHOLE record `igpu_poly.divN`
   --     (type psx.pGPU.div_type, a PACKAGE type -> usable) and write its fields
   --     in normal VHDL.
   --   * Array-of-record ELEMENT external names (`poly_div(i)`) also fail to
   --     resolve, but the gpu_poly/gpu_line PORTS divN are plain scalar-named
   --     records that DO resolve (and forcing a field of the aliased port IS seen
   --     by the child process that reads it -- verified).
   -- Clean source = the divider instance output ports gdividers(i).idivider.*
   -- (real, uncollapsed; carry the genuine computed quotient/remainder/done).
   -- gpu.vhd maps div1..div6 -> poly_div(0..5)/line_div(0..5) -> gdividers(0..5).
   -- We force on clk2x so the drawer sees the true divider result every cycle.
   -- -----------------------------------------------------------------------
   fix_div_gen : if FIX_POLY_DIV generate
      fix_div : process
         -- clean sources (divider instance output ports)
         alias s0d is << signal .tb_gpu_replay.igpu.gdividers(0).idivider.done : std_logic >>;
         alias s0q is << signal .tb_gpu_replay.igpu.gdividers(0).idivider.quotient  : signed(44 downto 0) >>;
         alias s0r is << signal .tb_gpu_replay.igpu.gdividers(0).idivider.remainder : signed(24 downto 0) >>;
         alias s1d is << signal .tb_gpu_replay.igpu.gdividers(1).idivider.done : std_logic >>;
         alias s1q is << signal .tb_gpu_replay.igpu.gdividers(1).idivider.quotient  : signed(44 downto 0) >>;
         alias s1r is << signal .tb_gpu_replay.igpu.gdividers(1).idivider.remainder : signed(24 downto 0) >>;
         alias s2d is << signal .tb_gpu_replay.igpu.gdividers(2).idivider.done : std_logic >>;
         alias s2q is << signal .tb_gpu_replay.igpu.gdividers(2).idivider.quotient  : signed(44 downto 0) >>;
         alias s2r is << signal .tb_gpu_replay.igpu.gdividers(2).idivider.remainder : signed(24 downto 0) >>;
         alias s3d is << signal .tb_gpu_replay.igpu.gdividers(3).idivider.done : std_logic >>;
         alias s3q is << signal .tb_gpu_replay.igpu.gdividers(3).idivider.quotient  : signed(44 downto 0) >>;
         alias s3r is << signal .tb_gpu_replay.igpu.gdividers(3).idivider.remainder : signed(24 downto 0) >>;
         alias s4d is << signal .tb_gpu_replay.igpu.gdividers(4).idivider.done : std_logic >>;
         alias s4q is << signal .tb_gpu_replay.igpu.gdividers(4).idivider.quotient  : signed(44 downto 0) >>;
         alias s4r is << signal .tb_gpu_replay.igpu.gdividers(4).idivider.remainder : signed(24 downto 0) >>;
         alias s5d is << signal .tb_gpu_replay.igpu.gdividers(5).idivider.done : std_logic >>;
         alias s5q is << signal .tb_gpu_replay.igpu.gdividers(5).idivider.quotient  : signed(44 downto 0) >>;
         alias s5r is << signal .tb_gpu_replay.igpu.gdividers(5).idivider.remainder : signed(24 downto 0) >>;
         -- poisoned sinks (whole div_type record on each gpu_poly inout port)
         alias p1 is << signal .tb_gpu_replay.igpu.igpu_poly.div1 : div_type >>;
         alias p2 is << signal .tb_gpu_replay.igpu.igpu_poly.div2 : div_type >>;
         alias p3 is << signal .tb_gpu_replay.igpu.igpu_poly.div3 : div_type >>;
         alias p4 is << signal .tb_gpu_replay.igpu.igpu_poly.div4 : div_type >>;
         alias p5 is << signal .tb_gpu_replay.igpu.igpu_poly.div5 : div_type >>;
         alias p6 is << signal .tb_gpu_replay.igpu.igpu_poly.div6 : div_type >>;
         alias l1 is << signal .tb_gpu_replay.igpu.igpu_line.div1 : div_type >>;
         alias l2 is << signal .tb_gpu_replay.igpu.igpu_line.div2 : div_type >>;
         alias l3 is << signal .tb_gpu_replay.igpu.igpu_line.div3 : div_type >>;
         alias l4 is << signal .tb_gpu_replay.igpu.igpu_line.div4 : div_type >>;
         alias l5 is << signal .tb_gpu_replay.igpu.igpu_line.div5 : div_type >>;
         alias l6 is << signal .tb_gpu_replay.igpu.igpu_line.div6 : div_type >>;
      begin
         -- COMBINATIONAL force (sensitive to the divider outputs, NOT clk-gated):
         -- gpu.vhd wires div_array(i).done <= divider.done as a zero-delay wire, and
         -- gpu_poly registers `if (div1.done='1')` on clk2x. The divider's `done` is
         -- a SINGLE clk2x pulse; a clk-gated force would register the mirror one
         -- clk2x late and gpu_poly would miss the one-cycle pulse (observed: it
         -- parked at CALCBOUNDARY2 with div1.done never seen '1'). Mirroring
         -- combinationally reproduces the real direct-wire timing so the pulse lands.
         wait on s0d, s0q, s0r, s1d, s1q, s1r, s2d, s2q, s2r,
                 s3d, s3q, s3r, s4d, s4q, s4r, s5d, s5q, s5r;
         p1.done <= force s0d; p1.quotient <= force s0q; p1.remainder <= force s0r;
         p2.done <= force s1d; p2.quotient <= force s1q; p2.remainder <= force s1r;
         p3.done <= force s2d; p3.quotient <= force s2q; p3.remainder <= force s2r;
         p4.done <= force s3d; p4.quotient <= force s3q; p4.remainder <= force s3r;
         p5.done <= force s4d; p5.quotient <= force s4q; p5.remainder <= force s4r;
         p6.done <= force s5d; p6.quotient <= force s5q; p6.remainder <= force s5r;
         l1.done <= force s0d; l1.quotient <= force s0q; l1.remainder <= force s0r;
         l2.done <= force s1d; l2.quotient <= force s1q; l2.remainder <= force s1r;
         l3.done <= force s2d; l3.quotient <= force s2q; l3.remainder <= force s2r;
         l4.done <= force s3d; l4.quotient <= force s3q; l4.remainder <= force s3r;
         l5.done <= force s4d; l5.quotient <= force s4q; l5.remainder <= force s4r;
         l6.done <= force s5d; l6.quotient <= force s5q; l6.remainder <= force s5r;
      end process;
   end generate;

   dbg_gen : if DBG_TEX generate
      dbg_tex : process(clk2x)
         alias pidle  is << signal .tb_gpu_replay.igpu.proc_idle      : std_logic >>;
         alias rqen   is << signal .tb_gpu_replay.igpu.reqVRAMEnable  : std_logic >>;
         alias vidle  is << signal .tb_gpu_replay.igpu.VRAMIdle       : std_logic >>;
         alias pstall is << signal .tb_gpu_replay.igpu.pipeline_stall : std_logic >>;
         variable n : integer := 0;
      begin
         if rising_edge(clk2x) then
            if cmdCount >= 1 then
               n := n + 1;
               if (n mod 4000) = 1 then
                  report "dbg_tex: proc_idle=" & std_logic'image(pidle) &
                         " reqVRAMEnable=" & std_logic'image(rqen) &
                         " VRAMIdle=" & std_logic'image(vidle) &
                         " pipeline_stall=" & std_logic'image(pstall) &
                         " DDRAM_RD=" & std_logic'image(DDRAM_RD);
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- -----------------------------------------------------------------------
   -- DBG_POLY: gpu_poly progress tap. Logs (to build/poly.log) the divider gate
   -- (div1.done from the whole-record alias), baseStep/denom (divider results
   -- captured at CALCBOUNDARY2), the rasteriser position (xPos/yPos/firstPixel),
   -- vramLineEna (='1' only in PROCPIXELS) and pipeline_new/done. Pinpoints where
   -- the poly state machine parks with FIX_POLY_DIV on vs off.
   -- -----------------------------------------------------------------------
   dbg_poly_gen : if DBG_POLY generate
      alias pd1       is << signal .tb_gpu_replay.igpu.igpu_poly.div1       : div_type >>;
      alias p_baseStep is << signal .tb_gpu_replay.igpu.igpu_poly.baseStep  : signed(44 downto 0) >>;
      alias p_denom    is << signal .tb_gpu_replay.igpu.igpu_poly.denom     : integer >>;
      alias p_xPos     is << signal .tb_gpu_replay.igpu.igpu_poly.xPos      : signed(11 downto 0) >>;
      alias p_yPos     is << signal .tb_gpu_replay.igpu.igpu_poly.yPos      : signed(10 downto 0) >>;
      alias p_firstPix is << signal .tb_gpu_replay.igpu.igpu_poly.firstPixel: std_logic >>;
      alias p_vramLine is << signal .tb_gpu_replay.igpu.poly_vramLineEna    : std_logic >>;
      alias p_pipenew  is << signal .tb_gpu_replay.igpu.poly_pipeline_new   : std_logic >>;
      alias p_done     is << signal .tb_gpu_replay.igpu.poly_done           : std_logic >>;
      function h(v : signed) return string is begin return to_hstring(std_logic_vector(v)); end function;
   begin
      dbg_poly : process(clk2x)
         file fp        : text open write_mode is "poly.log";
         variable l     : line;
         variable n     : integer := 0;
         variable lastd : std_logic := 'Z';
      begin
         if rising_edge(clk2x) then
            n := n + 1;
            -- log on every div1.done pulse, every pipeline_new (pixel), and periodically
            if (pd1.done = '1') or (p_pipenew = '1') or (p_done = '1') or (n mod 2000 = 1) then
               write(l, string'("t=") & integer'image(n) &
                        " div1.done=" & std_logic'image(pd1.done) &
                        " baseStep=" & h(p_baseStep) &
                        " denom=" & integer'image(p_denom) &
                        " xPos=" & h(p_xPos) & " yPos=" & h(p_yPos) &
                        " firstPix=" & std_logic'image(p_firstPix) &
                        " vramLineEna=" & std_logic'image(p_vramLine) &
                        " pipeNew=" & std_logic'image(p_pipenew) &
                        " polyDone=" & std_logic'image(p_done));
               writeline(fp, l);
            end if;
         end if;
      end process;
   end generate;

   -- -----------------------------------------------------------------------
   -- DBG_TAP8: 8bpp CLUT-resolve TAP. External-name read taps into the vendored
   -- gpu_pixelpipeline (no submodule edit). Logs two things to build/tap8.log:
   --   PIX rows  : per stage1-valid TEXTURED pixel, the resolve signals
   --               (x,y,colormode, U, texdata_raw, CLUTaddrB, CLUTDataB,
   --                texdata_palette, texcolor) -- index 0 (the rect's used lane).
   --   CLUT rows : during the palette load (state=REQUESTPALETTE/WAITPALETTE),
   --               reqVRAMXPos/YPos/Size + CLUTaddrA + the vram_DOUT being loaded.
   -- All values hex. A python post-pass parses this.
   -- -----------------------------------------------------------------------
   dbg_tap8_gen : if DBG_TAP8 generate
      -- External-name aliases of vendored pixelpipeline internals. The per-i
      -- combinational arrays (texdata_raw/CLUTaddrB/CLUTDataB/texdata_palette)
      -- are NOT preserved as named signals by NVC (folded into consumers), so we
      -- tap them at the dpram INSTANCE PORTS inside the gfiltermemmult(0) generate
      -- (those ARE real named signals), which carry exactly those values:
      --   icache.q_b   (64b)  = the cache word texdata_raw(0) is byte-muxed from
      --   iclutram.address_b  = CLUTaddrB(0)  (the 8bpp index used to index CLUT)
      --   iclutram.q_b        = CLUTDataB(0)  (the color the CLUT returned)
      -- For 8bpp (drawMode(8)='0') texdata_palette(0) == CLUTDataB(0) by line 439.
      alias t_drawMode    is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.drawMode        : unsigned(13 downto 0) >>;
      -- pixelpipeline INPUT taps: count emits-in vs writes-out, and the per-pixel CLUT-row tag.
      alias t_pnew_in     is << signal .tb_gpu_replay.igpu.pipeline_new          : std_logic >>;
      alias t_ptag_in     is << signal .tb_gpu_replay.igpu.pipeline_textPalYTag  : unsigned(8 downto 0) >>;
      alias t_ptex_in     is << signal .tb_gpu_replay.igpu.pipeline_texture      : std_logic >>;
      alias t_s1valid     is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage1_valid    : std_logic >>;
      alias t_s1texture   is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage1_texture  : std_logic >>;
      alias t_s1x         is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage1_x        : unsigned(9 downto 0) >>;
      alias t_s1y         is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage1_y        : unsigned(8 downto 0) >>;
      alias t_cacheq0     is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.gfiltermemmult(0).icache.q_b      : std_logic_vector(63 downto 0) >>;
      alias t_clutaddrB0  is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.address_b : std_logic_vector(7 downto 0) >>;
      alias t_clutdataB0  is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.q_b    : std_logic_vector(15 downto 0) >>;
      -- CLUT-load handshake taps
      alias t_clutwren    is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.CLUTwrenA       : std_logic >>;
      alias t_clutaddrA   is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.CLUTaddrA       : unsigned(5 downto 0) >>;
      alias t_reqx        is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.reqVRAMXPos     : unsigned(9 downto 0) >>;
      alias t_reqy        is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.reqVRAMYPos     : unsigned(8 downto 0) >>;
      alias t_reqsize     is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.reqVRAMSize     : unsigned(10 downto 0) >>;
      alias t_texPalReqX  is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.textPalReqX     : unsigned(9 downto 0) >>;
      alias t_texPalReqY  is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.textPalReqY     : unsigned(8 downto 0) >>;
      -- 573 RACE TAP: resident CLUT row (textPalY) + the pending request flag.
      -- A PIX read while textPalY = the STALE neighbor row but textPalReqY = 491
      -- (request pending, not yet fetched) is the read-timing race.
      alias t_texPalY     is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.textPalY        : unsigned(8 downto 0) >>;
      alias t_texPalReq   is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.textPalReq      : std_logic >>;
      alias t_pstall      is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.pipeline_stall  : std_logic >>;
      alias t_s1palReqY   is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage1_palReqY  : unsigned(8 downto 0) >>;
      -- CLUT-load source word: tap the clut RAM write port A data (vram_DOUT) the
      -- model is streaming in during WAITPALETTE.
      alias t_clutwrdata  is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.q_a    : std_logic_vector(63 downto 0) >>;
      alias t_clutwraddrA is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.address_a : std_logic_vector(5 downto 0) >>;
      alias t_vrdout      is << signal .tb_gpu_replay.igpu.vram_DOUT                          : std_logic_vector(63 downto 0) >>;
      -- FINAL output pixel (color the GPU writes to VRAM) + its coords/valid.
      alias t_pixcolor    is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.pixelColor       : std_logic_vector(15 downto 0) >>;
      alias t_s6valid     is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage6_valid     : std_logic >>;
      alias t_s6x         is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage6_x         : unsigned(9 downto 0) >>;
      alias t_s6y         is << signal .tb_gpu_replay.igpu.igpu_pixelpipeline.stage6_y         : unsigned(8 downto 0) >>;

      function h(v : std_logic_vector) return string is begin
         return to_hstring(v);
      end function;
      function h(v : unsigned) return string is begin
         return to_hstring(std_logic_vector(v));
      end function;
   begin
      dbg_tap8 : process(clk2x)
         file ftap         : text open write_mode is "tap8.log";
         variable l        : line;
         variable npix     : integer := 0;
         variable nin480   : integer := 0;
         variable nin491   : integer := 0;
         variable nintex   : integer := 0;
      begin
         if rising_edge(clk2x) then
            -- count textured pixels EMITTED into the pixelpipeline (input), by CLUT-row tag.
            if (t_pnew_in = '1' and t_ptex_in = '1') then
               nintex := nintex + 1;
               if    (t_ptag_in = 480) then nin480 := nin480 + 1;
               elsif (t_ptag_in = 491) then nin491 := nin491 + 1; end if;
               write(l, string'("IN tag=") & h(t_ptag_in) & " in480=" & integer'image(nin480) &
                        " in491=" & integer'image(nin491) & " intex=" & integer'image(nintex));
               writeline(ftap, l);
            end if;
            -- CLUT load: log every 64-bit word the CLUT RAM ingests (WAITPALETTE).
            if (t_clutwren = '1') then
               write(l, string'("CLUT wr wraddrA=") & h(t_clutwraddrA) &
                        " ctrAddrA=" & h(t_clutaddrA) &
                        " reqX=" & h(t_reqx) & " reqY=" & h(t_reqy) &
                        " reqSize=" & h(t_reqsize) &
                        " palReqX=" & h(t_texPalReqX) & " palReqY=" & h(t_texPalReqY) &
                        " vram_DOUT=" & h(t_vrdout));
               writeline(ftap, l);
            end if;
            -- per stage1-valid pixel resolve (textured OR not): one line. Logs the
            -- raw texel slice, the CLUT index it forms, and the CLUT color out.
            if (t_s1valid = '1') then
               npix := npix + 1;
               write(l, string'("PIX x=") & h(t_s1x) & " y=" & h(t_s1y) &
                        " tex=" & std_logic'image(t_s1texture) &
                        " dm=" & h(t_drawMode) &
                        " mode=" & std_logic'image(t_drawMode(8)) & std_logic'image(t_drawMode(7)) &
                        " cacheWord=" & h(t_cacheq0) &
                        " clutAddrB=" & h(t_clutaddrB0) &
                        " clutDataB=" & h(t_clutdataB0) &
                        " palY=" & h(t_texPalY) &
                        " s1tag=" & h(t_s1palReqY) &
                        " palReqY=" & h(t_texPalReqY) &
                        " palReq=" & std_logic'image(t_texPalReq) &
                        " pstall=" & std_logic'image(t_pstall));
               writeline(ftap, l);
            end if;
            -- FINAL output pixel: the actual color written to VRAM at (x,y).
            if (t_s6valid = '1') then
               write(l, string'("OUT x=") & h(t_s6x) & " y=" & h(t_s6y) &
                        " pixelColor=" & h(t_pixcolor));
               writeline(ftap, l);
            end if;
         end if;
      end process;
   end generate;

   -- -----------------------------------------------------------------------
   -- vram2cpu (GP0 C0) READBACK tap -- always on, zero-config. The tb holds
   -- DMA_GPU_readEna='1', so the GPU's vram2cpu fifo drains continuously; this
   -- logs every 32-bit word the fifo hands out (one 8-hex word per line) to
   -- build/vram2cpu_out.log. A command stream that ends in GP0 C0 reads thus
   -- dumps any VRAM region through the GPU's OWN read path -- the checker for
   -- the 2MB-VRAM red/green proof (psx_patches/0021) parses this file. When the
   -- stream has no C0, the file is simply empty. Width-independent (the fifo is
   -- 32-bit in both the stock and the 0021 tree). Same sample pattern as the
   -- upstream goutput block in gpu_vram2cpu.vhd (Dout valid while Rd='1' on a
   -- fall-through fifo).
   -- -----------------------------------------------------------------------
   rb_tap : process(clk2x)
      alias t_rbrd  is << signal .tb_gpu_replay.igpu.vram2cpu_Fifo_Rd   : std_logic >>;
      alias t_rbdat is << signal .tb_gpu_replay.igpu.vram2cpu_Fifo_Dout : std_logic_vector(31 downto 0) >>;
      file frb       : text open write_mode is "vram2cpu_out.log";
      variable l     : line;
   begin
      if rising_edge(clk2x) then
         if (t_rbrd = '1') then
            write(l, to_hstring(t_rbdat));
            writeline(frb, l);
         end if;
      end if;
   end process;

end architecture;
