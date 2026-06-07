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

entity tb_gpu_replay is
   generic
   (
      CMD_FILE     : string  := "cmd_stream.txt";
      PRELOAD_VRAM : std_logic := '0';
      VRAM_FILE    : string  := "vram_init.bin";
      SLOWTIMING   : integer := 0;
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
   -- The OUT/PIX rows fire for the rect path (gpu_rect); the poly path (gpu_poly,
   -- GP0 0x2C) does NOT render in this NVC rig -- its divider record-port `.done`
   -- elaborates as undriven 'U' (see the POLY_DIV(*).DONE init warnings), so the
   -- poly drawer stalls (proc_idle stays low) and emits no pixels. Use the rect
   -- path to exercise the SAME 4bpp/8bpp->CLUT pixel pipeline.
   constant DBG_TAP8 : boolean := false;

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
   signal DDRAM_RD            : std_logic;
   signal DDRAM_DIN           : std_logic_vector(63 downto 0);
   signal DDRAM_BE            : std_logic_vector(7 downto 0);
   signal DDRAM_WE            : std_logic;

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
      vram_BUSY            => DDRAM_BUSY,
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

   iddrram_model : entity tb.ddrram_model
   generic map
   (
      loadVram   => '0',          -- preload via COMMAND_FILE_START_2 instead
      SLOWTIMING => SLOWTIMING
   )
   port map
   (
      DDRAM_CLK        => clk2x,
      DDRAM_BUSY       => DDRAM_BUSY,
      DDRAM_BURSTCNT   => vram_BURSTCNT,
      DDRAM_ADDR       => DDRAM_ADDR,
      DDRAM_DOUT       => DDRAM_DOUT,
      DDRAM_DOUT_READY => DDRAM_DOUT_READY,
      DDRAM_RD         => DDRAM_RD,
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
      begin
         if rising_edge(clk2x) then
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
                        " clutDataB=" & h(t_clutdataB0));
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

end architecture;
