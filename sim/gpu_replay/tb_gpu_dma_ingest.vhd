-- =============================================================================
-- tb_gpu_dma_ingest -- GPU DMA-PORT ingest harness (level 1 of the GP0-word
-- corruption experiment ladder, 2026-06-10).
--
-- SILICON FACTS UNDER TEST (SignalTap, real 573 HW): the game's draw list holds
-- textured quads with CLUT halfword 0x7AC0 (palette row 491 = 0x1EB), but
-- gpu_poly's decoded rec_textPalY on HW only ever holds 480 (0x1E0) / 481
-- (0x1E1) -- low-bit manglings of 0x1EB. The same stream via the BUS port in
-- tb_gpu_replay decodes clean, so the corruption needs the DMA ingest path.
--
-- THIS TB isolates the GPU-SIDE half of that path: it is tb_gpu_replay with the
-- GP0 stream re-routed through the DMA write port (DMA_GPU_writeEna /
-- DMA_GPU_write, dmaOn='1'), mimicking dma.vhd's WORKING-state contract:
--   * DMA_GPU_writeEna / DMA_GPU_write are registered on clk1x (dma.vhd line
--     ~699 sets them inside its clk1x process), one word per clk1x cycle;
--   * back-to-back words keep writeEna high with data changing each clk1x
--     (dma.vhd defaults writeEna to '0' each cycle and re-asserts per word);
--   * the GPU ingests at clk2x when (clk2xIndex='1' and DMA_GPU_writeEna='1')
--     -> fifoIn_Wr/fifoIn_Din (gpu.vhd ~841). dmaOn is an unused input port of
--     gpu.vhd (decorative); tied '1' here for documentation value.
-- GP1 control writes (addr 04 lines) still go via the bus port -- as on real
-- HW (GP1 is never DMA-fed).
--
-- VERDICT METRIC (word-level, no pixels needed) -- taps logged to
-- dma_ingest_tap.log in the build dir:
--   WR <hex>   : every word written INTO the GPU command fifo (fifoIn_Wr)
--   RD <hex>   : every word the command decoder CONSUMES (fifoIn_Valid)
--   PALY <hex> : every CHANGE of gpu_poly.rec_textPalY (the silicon-corrupted
--                register; expect 1EB, corruption family = 1E0/1E1/...)
-- The run script diffs the RD sequence against the injected GP0 word list:
-- any mismatch = REPRO; bit-exact = this stage exonerated.
--
-- Command stream format: identical to tb_gpu_replay ("<addr> <time> <data>",
-- hex; addr 00 = GP0 -> DMA port here, addr 04 = GP1 -> bus port).
-- This file is ORIGINAL to this repo (it only INSTANTIATES vendored psx/ +
-- upstream-tb entities); the vendored submodule is untouched.
-- Build via run_dma_ingest.sh.
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

entity tb_gpu_dma_ingest is
   generic
   (
      CMD_FILE     : string  := "cmd_stream.txt";
      PRELOAD_VRAM : std_logic := '0';
      VRAM_FILE    : string  := "vram_init.bin";
      SLOWTIMING   : integer := 0;
      DRAIN_MS     : time    := 1 ms
   );
end entity;

architecture sim of tb_gpu_dma_ingest is

   -- RIG FIX gate (ships ON) -- carried over verbatim from tb_gpu_replay (see
   -- its header for the full root-cause note): NVC's init-time resolution of
   -- the gpu_poly/gpu_line `inout div_type` ports poisons div .done to 'U'
   -- forever, parking the poly drawer. Without this fix quad #1 never finishes
   -- and quads #2/#3 never DECODE -- the fix is required for the multi-quad
   -- ingest verdict, and it touches only the divider read-back fan-out
   -- (nothing on the fifo/ingest path under test).
   constant FIX_POLY_DIV : boolean := true;

   signal clk1x               : std_logic := '1';
   signal clk2x               : std_logic := '1';
   signal clkvid              : std_logic := '1';

   signal clk1xToggle         : std_logic := '0';
   signal clk1xToggle2X       : std_logic := '0';
   signal clk2xIndex          : std_logic := '0';

   signal reset               : std_logic := '1';

   -- gpu bus (GP1 control writes only in this tb)
   signal bus_gpu_addr        : unsigned(3 downto 0) := (others => '0');
   signal bus_gpu_dataWrite   : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_gpu_read        : std_logic := '0';
   signal bus_gpu_write       : std_logic := '0';
   signal bus_gpu_dataRead    : std_logic_vector(31 downto 0);

   -- DMA-port injection (the path under test)
   signal dma_writeEna        : std_logic := '0';
   signal dma_write           : std_logic_vector(31 downto 0) := (others => '0');

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

   -- clk2xIndex generation (verbatim from upstream gpu tb / tb_gpu_replay)
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
   -- DUT: vendored psx.gpu, standalone. Identical to tb_gpu_replay's port map
   -- EXCEPT the DMA write port is live (dmaOn='1', DMA_GPU_writeEna/write
   -- driven by the replay process below).
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

      dmaOn                => '1',
      gpu_dmaRequest       => o_gpu_dmaRequest,
      DMA_GPU_waiting      => '0',
      DMA_GPU_writeEna     => dma_writeEna,
      DMA_GPU_readEna      => '1', -- keep read fifo drained so vram2cpu can't stall
      DMA_GPU_write        => dma_write,
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

   -- VRAM at DDR base 0x30000000 (mapping copied verbatim from psx_mister.vhd)
   DDRAM_ADDR(28 downto 25) <= "0011";
   DDRAM_ADDR(24 downto  0) <= vram_ADDR(27 downto 3);

   -- NO contention shim in this rig: model wired straight (the shim experiment
   -- was a separate, cancelled investigation; this tb tests the fifo ingest).
   iddrram_model : entity tb.ddrram_model
   generic map
   (
      loadVram     => '0',
      SLOWTIMING   => SLOWTIMING,
      RANDOMTIMING => '0'
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

   -- -----------------------------------------------------------------------
   -- Reset + optional VRAM preload sequencer (verbatim from tb_gpu_replay).
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
         COMMAND_FILE_TARGET  <= 0;
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;
         COMMAND_FILE_ENDIAN  <= '0';
         COMMAND_FILE_START_2 <= '1';
         wait for 16 ns;
         COMMAND_FILE_START_2 <= '0';
         wait for 2 us;
         report "tb_gpu_dma_ingest: VRAM preloaded from " & VRAM_FILE;
      end if;

      wait for 1 us;
      reset <= '0';
      wait;
   end process;

   -- -----------------------------------------------------------------------
   -- Command-stream replay. "<addr> <time> <data>" hex lines as tb_gpu_replay,
   -- but routing addr 00 (GP0) through the DMA WRITE PORT:
   --   * dma_write/dma_writeEna assigned right after a clk1x rising edge --
   --     the same registered-on-clk1x timing dma.vhd produces;
   --   * one word per clk1x cycle; consecutive same-time words stream
   --     BACK-TO-BACK (writeEna stays high, data changes each clk1x), which is
   --     dma.vhd's WORKING-state burst behavior and the max-rate stress case.
   -- addr 04 (GP1) lines remain plain bus writes.
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
   begin
      wait until reset = '0';
      wait until rising_edge(clk1x);

      file_open(f_status, infile, CMD_FILE, read_mode);
      assert f_status = open_ok
         report "tb_gpu_dma_ingest: cannot open command file " & CMD_FILE
         severity failure;

      while (not endfile(infile)) loop
         readline(infile, inLine);

         -- find first non-whitespace char; classify the line
         okc := true;
         loop
            if inLine.all'length = 0 then okc := false; exit; end if;
            read(inLine, c, okc);
            exit when not okc;
            exit when c /= ' ' and c /= HT;
         end loop;
         next when not okc;          -- blank line
         next when c = '#';          -- comment line

         para_addr := hexval(c);
         loop
            exit when inLine.all'length = 0;
            read(inLine, c, okc);
            exit when not okc;
            exit when c = ' ' or c = HT;
            para_addr := para_addr * 16 + hexval(c);
         end loop;

         HREAD(inLine, para_time, okh); next when not okh;
         HREAD(inLine, para_data, okh); next when not okh;

         -- wait until the requested tick (deasserting both issue strobes while
         -- waiting, so a time gap ends any back-to-back DMA burst)
         while (clkCount < to_integer(unsigned(para_time))) loop
            bus_gpu_write <= '0';
            dma_writeEna  <= '0';
            clkCount <= clkCount + 1;
            wait until rising_edge(clk1x);
         end loop;

         -- default both strobes low; the assignment below (same delta, no
         -- intervening wait) wins for the active path -- so a GP0 word directly
         -- followed by another GP0 word keeps dma_writeEna='1' (back-to-back)
         bus_gpu_write <= '0';
         dma_writeEna  <= '0';

         if (para_addr mod 16) = 0 then
            -- GP0 -> DMA write port
            dma_write    <= para_data;
            dma_writeEna <= '1';
         else
            -- GP1 -> bus port
            bus_gpu_addr      <= to_unsigned(para_addr mod 16, 4);
            bus_gpu_dataWrite <= para_data;
            bus_gpu_write     <= '1';
         end if;

         clkCount <= clkCount + 1;
         cmdCount <= cmdCount + 1;
         wait until rising_edge(clk1x);
      end loop;

      bus_gpu_write <= '0';
      dma_writeEna  <= '0';

      file_close(infile);
      report "tb_gpu_dma_ingest: replayed " & integer'image(cmdCount) & " words; draining";

      wait for DRAIN_MS;
      report "tb_gpu_dma_ingest: DONE";
      std.env.stop;
   end process;

   -- -----------------------------------------------------------------------
   -- FIX_POLY_DIV (carried verbatim from tb_gpu_replay, paths updated): repair
   -- the NVC inout-record 'U' poison on the shared-divider read ports so the
   -- POLY path renders. See tb_gpu_replay.vhd for the full root-cause comment.
   -- -----------------------------------------------------------------------
   fix_div_gen : if FIX_POLY_DIV generate
      fix_div : process
         alias s0d is << signal .tb_gpu_dma_ingest.igpu.gdividers(0).idivider.done : std_logic >>;
         alias s0q is << signal .tb_gpu_dma_ingest.igpu.gdividers(0).idivider.quotient  : signed(44 downto 0) >>;
         alias s0r is << signal .tb_gpu_dma_ingest.igpu.gdividers(0).idivider.remainder : signed(24 downto 0) >>;
         alias s1d is << signal .tb_gpu_dma_ingest.igpu.gdividers(1).idivider.done : std_logic >>;
         alias s1q is << signal .tb_gpu_dma_ingest.igpu.gdividers(1).idivider.quotient  : signed(44 downto 0) >>;
         alias s1r is << signal .tb_gpu_dma_ingest.igpu.gdividers(1).idivider.remainder : signed(24 downto 0) >>;
         alias s2d is << signal .tb_gpu_dma_ingest.igpu.gdividers(2).idivider.done : std_logic >>;
         alias s2q is << signal .tb_gpu_dma_ingest.igpu.gdividers(2).idivider.quotient  : signed(44 downto 0) >>;
         alias s2r is << signal .tb_gpu_dma_ingest.igpu.gdividers(2).idivider.remainder : signed(24 downto 0) >>;
         alias s3d is << signal .tb_gpu_dma_ingest.igpu.gdividers(3).idivider.done : std_logic >>;
         alias s3q is << signal .tb_gpu_dma_ingest.igpu.gdividers(3).idivider.quotient  : signed(44 downto 0) >>;
         alias s3r is << signal .tb_gpu_dma_ingest.igpu.gdividers(3).idivider.remainder : signed(24 downto 0) >>;
         alias s4d is << signal .tb_gpu_dma_ingest.igpu.gdividers(4).idivider.done : std_logic >>;
         alias s4q is << signal .tb_gpu_dma_ingest.igpu.gdividers(4).idivider.quotient  : signed(44 downto 0) >>;
         alias s4r is << signal .tb_gpu_dma_ingest.igpu.gdividers(4).idivider.remainder : signed(24 downto 0) >>;
         alias s5d is << signal .tb_gpu_dma_ingest.igpu.gdividers(5).idivider.done : std_logic >>;
         alias s5q is << signal .tb_gpu_dma_ingest.igpu.gdividers(5).idivider.quotient  : signed(44 downto 0) >>;
         alias s5r is << signal .tb_gpu_dma_ingest.igpu.gdividers(5).idivider.remainder : signed(24 downto 0) >>;
         alias p1 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div1 : div_type >>;
         alias p2 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div2 : div_type >>;
         alias p3 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div3 : div_type >>;
         alias p4 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div4 : div_type >>;
         alias p5 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div5 : div_type >>;
         alias p6 is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.div6 : div_type >>;
         alias l1 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div1 : div_type >>;
         alias l2 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div2 : div_type >>;
         alias l3 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div3 : div_type >>;
         alias l4 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div4 : div_type >>;
         alias l5 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div5 : div_type >>;
         alias l6 is << signal .tb_gpu_dma_ingest.igpu.igpu_line.div6 : div_type >>;
      begin
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

   -- -----------------------------------------------------------------------
   -- VERDICT TAP (always on). Read-only external-name taps; logs to
   -- dma_ingest_tap.log in the run dir:
   --   WR <word>          every fifoIn write (post DMA-port sampling)
   --   RD <word>          every word the decoder consumes (fifoIn_Valid)
   --   PALY <y> PALX <x>  every change of gpu_poly's decoded CLUT row/x
   -- The run script diffs RD against the injected GP0 list and classifies the
   -- PALY values (1EB = clean; 1E0/1E1 family = the silicon corruption).
   -- -----------------------------------------------------------------------
   verdict_tap : process(clk2x)
      alias t_fifoWr    is << signal .tb_gpu_dma_ingest.igpu.fifoIn_Wr    : std_logic >>;
      alias t_fifoDin   is << signal .tb_gpu_dma_ingest.igpu.fifoIn_Din   : std_logic_vector(31 downto 0) >>;
      alias t_fifoValid is << signal .tb_gpu_dma_ingest.igpu.fifoIn_Valid : std_logic >>;
      alias t_fifoDout  is << signal .tb_gpu_dma_ingest.igpu.fifoIn_Dout  : std_logic_vector(31 downto 0) >>;
      alias t_recPalY   is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.rec_textPalY : unsigned(8 downto 0) >>;
      alias t_recPalX   is << signal .tb_gpu_dma_ingest.igpu.igpu_poly.rec_textPalX : unsigned(9 downto 0) >>;
      file ftap      : text open write_mode is "dma_ingest_tap.log";
      variable l     : line;
      variable lastY : unsigned(8 downto 0) := (others => '1');  -- 1FF = impossible init
   begin
      if rising_edge(clk2x) then
         if (t_fifoWr = '1') then
            write(l, string'("WR ") & to_hstring(t_fifoDin));
            writeline(ftap, l);
         end if;
         if (t_fifoValid = '1') then
            write(l, string'("RD ") & to_hstring(t_fifoDout));
            writeline(ftap, l);
         end if;
         if (t_recPalY /= lastY) then
            write(l, string'("PALY ") & to_hstring(std_logic_vector(t_recPalY)) &
                     " PALX " & to_hstring(std_logic_vector(t_recPalX)));
            writeline(ftap, l);
            report "tb_gpu_dma_ingest: rec_textPalY = 0x" &
                   to_hstring(std_logic_vector(t_recPalY)) &
                   " (" & integer'image(to_integer(t_recPalY)) & ")";
            lastY := t_recPalY;
         end if;
      end if;
   end process;

end architecture;
