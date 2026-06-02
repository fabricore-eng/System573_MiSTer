-- =============================================================================
-- tb_system573 -- Phase-2 full-system NVC bring-up harness for the Konami
-- System 573 MiSTer core.
--
-- Instantiates the vendored PSX core (psx_mister, VHDL-2008, patched for the
-- 573 EXP1 widening) plus the upstream pure-VHDL memory models (sdram_model3x
-- main RAM/BIOS + a second sdram_model3x for SPU RAM, ddrram_model for VRAM,
-- framebuffer for video-out -> .gra) and a minimal behavioral 573 EXP1
-- responder. Loads the game-in-BIOS Konami image (gchgchmp, boots with no CD
-- and no security cart) into SDRAM byte 0x800000 via the sdram_model3x
-- SCRIPTLOADING / COMMAND_FILE_* path, releases reset, and runs.
--
-- See docs/EXECUTION_PLAN.md (Phase 2), local/wf_out/map_simharness.md (the
-- authoritative construction), docs/PHASE1_PSX.md (EXP1 contract).
--
-- This file is original to this repo (NOT a derivative of the GPL psx/ core);
-- it only INSTANTIATES the vendored entities. Build/run via run.sh.
-- =============================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

library tb;
use tb.globals.all;       -- COMMAND_FILE_* signals (the BIOS-load handshake)

library psx;

entity tb_system573 is
   generic
   (
      -- Konami 512 KB BIOS, copied to the run dir as s573_bios.bin by run.sh.
      BIOS_FILE   : string  := "s573_bios.bin";
      BIOS_TARGET : integer := 16#800000#;   -- region-0 SDRAM byte base (= 0x1FC00000)
      -- 573 has 4 MB RAM; core supports 2 MB ('0') or 8 MB ('1'). Overridable from run.sh.
      RAM8MB      : std_logic := '1';
      -- Sim accelerator (TURBO_MEM/COMP/CACHE). '1' speeds bring-up; set '0' (TURBO=0 in
      -- run.sh) to confirm the integration under realistic memory/cache/DMA timing.
      TURBO       : std_logic := '1';
      -- VRAM (DDR) model read latency, in cycles, for the GPU's VRAM path. The boot
      -- spins on GPUSTAT bit 28 (GPU "ready to receive DMA" = command-FIFO empty), which
      -- drains only as fast as the GPU executes commands against VRAM -- so a slow VRAM
      -- model lengthens those waits and the whole drawing path. run.sh defaults this to 0
      -- (near-instant VRAM) for bring-up speed; set SLOWVRAM=15 for the realistic-timing
      -- confirmation. Sim-model only (ddrram_model is a tb model, never in the .rbf).
      SLOWVRAM    : integer := 15
   );
end entity;

architecture sim of tb_system573 is

   -- clocks / reset / "on" register (plain signal -- no procbus)
   signal clk1x, clk2x, clk3x, clkvid : std_logic := '1';
   signal reset       : std_logic;
   signal psx_on      : std_logic := '0';

   -- EXE bootstrap (unused: loadExe='0', but ports must connect)
   signal psx_LoadExe : std_logic := '0';

   -- 573 EXP1 master (widened ports)
   signal exp1_addr      : std_logic_vector(23 downto 0);
   signal exp1_dataWrite : std_logic_vector(15 downto 0);
   signal exp1_we        : std_logic;
   signal exp1_re        : std_logic;
   signal exp1_dataRead  : std_logic_vector(15 downto 0) := (others => '0');
   signal exp_irq10      : std_logic := '0';

   -- sdram / bios / cache / dma bus
   signal ram_dataWrite    : std_logic_vector(31 downto 0);
   signal ram_dataRead32   : std_logic_vector(31 downto 0);
   signal ram_Adr          : std_logic_vector(24 downto 0);
   signal ram_cntDMA       : std_logic_vector(1 downto 0);
   signal ram_be           : std_logic_vector(3 downto 0);
   signal ram_rnw          : std_logic;
   signal ram_ena          : std_logic;
   signal ram_dma          : std_logic;
   signal ram_iscache      : std_logic;
   signal ram_done         : std_logic;
   signal ram_refresh      : std_logic;
   signal cache_wr         : std_logic_vector(3 downto 0);
   signal cache_data       : std_logic_vector(31 downto 0);
   signal cache_addr       : std_logic_vector(7 downto 0);
   signal dma_wr           : std_logic;
   signal dma_reqprocessed : std_logic;
   signal dma_data         : std_logic_vector(31 downto 0);
   signal ram_dmafifo_adr  : std_logic_vector(22 downto 0);
   signal ram_dmafifo_data : std_logic_vector(31 downto 0);
   signal ram_dmafifo_empty: std_logic;
   signal ram_dmafifo_read : std_logic;
   signal exe_initial_pc   : unsigned(31 downto 0);
   signal exe_initial_gp   : unsigned(31 downto 0);
   signal exe_load_address : unsigned(31 downto 0);
   signal exe_file_size    : unsigned(31 downto 0);
   signal exe_stackpointer : unsigned(31 downto 0);

   -- ddr / vram bus
   signal DDRAM_BUSY       : std_logic;
   signal DDRAM_BURSTCNT   : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR       : std_logic_vector(28 downto 0);
   signal DDRAM_DOUT       : std_logic_vector(63 downto 0);
   signal DDRAM_DOUT_READY : std_logic;
   signal DDRAM_RD         : std_logic;
   signal DDRAM_DIN        : std_logic_vector(63 downto 0);
   signal DDRAM_BE         : std_logic_vector(7 downto 0);
   signal DDRAM_WE         : std_logic;

   -- spu ram bus (scratch model)
   signal spuram_dataWrite : std_logic_vector(31 downto 0);
   signal spuram_Adr       : std_logic_vector(18 downto 0);
   signal spuram_be        : std_logic_vector(3 downto 0);
   signal spuram_rnw       : std_logic;
   signal spuram_ena       : std_logic;
   signal spuram_dataRead  : std_logic_vector(31 downto 0);
   signal spuram_done      : std_logic;

   -- video
   signal hblank, vblank, video_ce, video_interlace : std_logic;
   signal video_r, video_g, video_b : std_logic_vector(7 downto 0);

   -- input tie-off constants (copied verbatim from upstream tb.vhd)
   signal KeyTriangle : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyCircle   : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyCross    : std_logic_vector(3 downto 0) := (others => '0');
   signal KeySquare   : std_logic_vector(3 downto 0) := (others => '0');
   signal KeySelect   : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyStart    : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyRight    : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyLeft     : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyUp       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyDown     : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyR1       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyR2       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyR3       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyL1       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyL2       : std_logic_vector(3 downto 0) := (others => '0');
   signal KeyL3       : std_logic_vector(3 downto 0) := (others => '0');
   -- NB: Analog1X/Y feed psx_top's gun-coordinate map
   --   Gun?X <= to_unsigned(to_integer(Analog1X + 128), 8)
   -- where the `+128` stays 8-bit signed and OVERFLOWS for any input in 0..127
   -- (e.g. 0 + 128 -> -128), which NVC flags as a fatal NATURAL-range error
   -- (ModelSim tolerates it). The gun is unused here (PadPortGunCon*='0'), so
   -- we just pick negative analog rest values: -128 + 128 = 0, staying in range.
   signal Analog1XP1  : signed(7 downto 0) := to_signed(-128, 8);
   signal Analog1YP1  : signed(7 downto 0) := to_signed(-128, 8);
   signal Analog2XP1  : signed(7 downto 0) := (others => '0');
   signal Analog2YP1  : signed(7 downto 0) := (others => '0');
   signal Analog1XP2  : signed(7 downto 0) := to_signed(-128, 8);
   signal Analog1YP2  : signed(7 downto 0) := to_signed(-128, 8);
   signal Analog2XP2  : signed(7 downto 0) := (others => '0');
   signal Analog2YP2  : signed(7 downto 0) := (others => '0');
   signal MouseEvent  : std_logic := '0';
   signal MouseX      : signed(8 downto 0) := to_signed(2, 9);
   signal MouseY      : signed(8 downto 0) := to_signed(-1, 9);

   signal sound_out_left  : std_logic_vector(15 downto 0);
   signal sound_out_right : std_logic_vector(15 downto 0);

begin

   -- -----------------------------------------------------------------------
   -- Clocks: free-running inverting drivers, identical to upstream tb.vhd.
   -- clk1x ~33.33 MHz, clk2x ~66.67 MHz, clk3x 100 MHz, clkvid ~52.85 MHz NTSC.
   -- -----------------------------------------------------------------------
   clk1x  <= not clk1x  after 15   ns;
   clk2x  <= not clk2x  after 7500 ps;
   clk3x  <= not clk3x  after 5    ns;
   clkvid <= not clkvid after 9462 ps;
   reset  <= not psx_on;

   -- -----------------------------------------------------------------------
   -- Stimulus: load the Konami BIOS into the SDRAM model at 0x800000 via the
   -- SCRIPTLOADING / COMMAND_FILE_* handshake, then release reset and run.
   -- -----------------------------------------------------------------------
   stim : process
   begin
      psx_on               <= '0';
      COMMAND_FILE_START_1 <= '0';
      COMMAND_FILE_NAME    <= (others => ' ');
      wait for 1 us;

      -- Trigger the sdram_model3x file read (handshake on clk1x in the model).
      COMMAND_FILE_NAME(1 to BIOS_FILE'length) <= BIOS_FILE;
      COMMAND_FILE_NAMELEN <= BIOS_FILE'length;
      COMMAND_FILE_TARGET  <= BIOS_TARGET;
      COMMAND_FILE_OFFSET  <= 0;
      COMMAND_FILE_SIZE    <= 0;        -- 0 = whole file
      COMMAND_FILE_ENDIAN  <= '0';
      COMMAND_FILE_START_1 <= '1';
      -- One clk3x edge with START high triggers a complete file read inside the
      -- sdram_model3x SCRIPTLOADING process (it loads the whole file in a single
      -- process pass). Hold START for a few clk1x periods to guarantee at least
      -- one such pass, then drop it. (We deliberately do NOT poll
      -- COMMAND_FILE_ACK_1: it pulses for a single clk3x delta and the model
      -- re-reads the entire 512 KB on every cycle START stays high, so holding
      -- until ACK would reload the BIOS thousands of times and never release.)
      wait for 200 ns;                  -- >= a few clk1x/clk3x periods
      COMMAND_FILE_START_1 <= '0';
      wait for 1 us;                    -- let the load settle

      report "tb_system573: BIOS loaded, releasing reset";
      psx_on <= '1';

      -- Run is bounded by --stop-time on the nvc -r command line; this wait
      -- just keeps the process alive.
      wait;
   end process;

   -- -----------------------------------------------------------------------
   -- Minimal behavioral 573 EXP1 responder.
   --   * Logs every EXP1 access (addr/we/re/wdata/returned rdata) to a textio
   --     trace file (exp1_trace.log).
   --   * Honors the REGISTERED-slave contract: the PSX FSM asserts exp1_re for
   --     one clk1x cycle (state EXT_READ_NEXT) and samples exp1_dataRead the
   --     NEXT cycle (state EXT_READ). We latch the response on the rising edge
   --     that sees exp1_re='1' and HOLD it, exactly like the real fabric's
   --     registered exp1_rdata (docs/PHASE1_PSX.md). Returns benign 0 for now;
   --     iterate here once we see where the BIOS stalls.
   --   * Fails (assert) on any access while we can detect width=0 -- but the
   --     ex1_memctrl programming is internal to memorymux and not observable on
   --     these ports, so we just note that and cannot enforce it here.
   -- -----------------------------------------------------------------------
   exp1_responder : process(clk1x)
      file     tracef    : text;
      variable opened    : boolean := false;
      variable l         : line;
      variable status    : FILE_OPEN_STATUS;
      variable rdata     : std_logic_vector(15 downto 0);
      variable wrote     : boolean := false;     -- flush bookkeeping

      procedure put_hex(variable ln : inout line; v : std_logic_vector) is
         variable nib : integer;
         constant hexchars : string(1 to 16) := "0123456789ABCDEF";
         variable n : integer := v'length / 4;
         variable vv : std_logic_vector(v'length-1 downto 0) := v;
      begin
         for i in n-1 downto 0 loop
            nib := to_integer(unsigned(vv(i*4+3 downto i*4)));
            write(ln, hexchars(nib+1));
         end loop;
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, tracef, "exp1_trace.log", write_mode);
            file_close(tracef);                 -- truncate
            opened := true;
         end if;

         wrote := false;

         -- READ: model returns benign 0, EXCEPT the Konami ASIC status word at
         -- 0x1f400004, whose bits[7:4] must return the H8 (18E) response nibble 0xC so
         -- the BIOS GX700 self-test passes the 18E check. Mirrors rtl/s573_io.v; keep
         -- the two in sync (the boot sim uses this behavioral stub, not the RTL).
         if exp1_re = '1' then
            if exp1_addr(23 downto 16) = x"40" and exp1_addr(3 downto 0) = x"4" then
               rdata := x"00C0";
            else
               rdata := (others => '0');
            end if;
            exp1_dataRead <= rdata;        -- registered, held until next read
            write(l, string'("EXP1 RE  addr=0x")); put_hex(l, exp1_addr);
            write(l, string'(" rdata=0x"));        put_hex(l, rdata);
            wrote := true;
         end if;

         -- WRITE: just log it. (exp1_re / exp1_we are mutually exclusive in the
         -- PSX ext-bus FSM, so at most one branch fires per cycle.)
         if exp1_we = '1' then
            write(l, string'("EXP1 WE  addr=0x")); put_hex(l, exp1_addr);
            write(l, string'(" wdata=0x"));        put_hex(l, exp1_dataWrite);
            wrote := true;
         end if;

         -- Append+flush each event (close-on-write) so the trace survives the
         -- forced --stop-time termination (NVC does not flush open files then).
         if wrote then
            file_open(status, tracef, "exp1_trace.log", append_mode);
            writeline(tracef, l);
            file_close(tracef);
         end if;
      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- SDRAM read tap (CPU-execution evidence; no easy PC export):
   --   * BIOS region  : ram_Adr(24:23) = "01"  (SDRAM byte >= 0x800000 = the
   --     0x1FC00000 BIOS window). The reset vector lives here.
   --   * Main RAM      : ram_Adr(24:23) = "00"  (SDRAM byte < 0x800000). The
   --     BIOS copies its runtime into low RAM and executes there, so tracking
   --     RAM reads shows where execution moved after the BIOS prologue.
   -- Logs the first 64 BIOS-region reads verbatim, then every 2000th read in
   -- EITHER region it appends a (region,total,addr) snapshot so the last fetch
   -- position survives a forced --stop-time stop. All writes are flushed.
   -- -----------------------------------------------------------------------
   bios_tap : process(clk1x)
      file     tf      : text;
      variable opened  : boolean := false;
      variable l       : line;
      variable status  : FILE_OPEN_STATUS;
      variable logged  : integer := 0;
      variable totbios : integer := 0;
      variable totram  : integer := 0;
      variable snap    : integer := 0;

      procedure put_hex(variable ln : inout line; v : std_logic_vector) is
         constant hexchars : string(1 to 16) := "0123456789ABCDEF";
         variable n  : integer := v'length / 4;
         variable vv : std_logic_vector(v'length-1 downto 0) := v;
         variable nib: integer;
      begin
         for i in n-1 downto 0 loop
            nib := to_integer(unsigned(vv(i*4+3 downto i*4)));
            write(ln, hexchars(nib+1));
         end loop;
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, tf, "bios_fetch.log", write_mode);
            file_close(tf);                     -- truncate
            opened := true;
         end if;

         if ram_ena = '1' and ram_rnw = '1' then
            if ram_Adr(24 downto 23) = "01" then
               totbios := totbios + 1;
            elsif ram_Adr(24 downto 23) = "00" then
               totram := totram + 1;
            end if;
         end if;

         -- first 64 BIOS-region reads, verbatim
         if ram_ena = '1' and ram_rnw = '1' and ram_Adr(24 downto 23) = "01"
            and logged < 64 then
            write(l, string'("BIOS fetch #")); write(l, totbios);
            write(l, string'(" ram_Adr=0x")); put_hex(l, "0000000" & ram_Adr);
            file_open(status, tf, "bios_fetch.log", append_mode);
            writeline(tf, l);
            file_close(tf);
            logged := logged + 1;
         end if;

         -- periodic position snapshot (every 2000 reads in either region)
         if ram_ena = '1' and ram_rnw = '1'
            and (ram_Adr(24 downto 23) = "01" or ram_Adr(24 downto 23) = "00") then
            snap := snap + 1;
            if (snap mod 2000) = 0 then
               write(l, string'("[snap] bios_reads=")); write(l, totbios);
               write(l, string'(" ram_reads="));        write(l, totram);
               write(l, string'(" last_ram_Adr=0x"));   put_hex(l, "0000000" & ram_Adr);
               file_open(status, tf, "bios_fetch.log", append_mode);
               writeline(tf, l);
               file_close(tf);
            end if;
         end if;

      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- DUT: vendored patched PSX core. Tie-offs copied verbatim from the
   -- upstream tb.vhd ipsx_mister, plus the widened EXP1 ports and the full
   -- generic list this psx_mister revision exposes.
   -- -----------------------------------------------------------------------
   ipsx_mister : entity psx.psx_mister
   generic map
   (
      -- KEEP is_simu='1'. It gates BOTH the per-instruction `export` debug writer and
      -- FASTSIM on the savestates block. Setting it '0' STALLS the boot at the reset
      -- vector -- the CPU issues a single BIOS fetch and never advances (verified
      -- 2026-06-01, bisected from a Phase-3 sim-speed attempt). The exact mechanism
      -- (export-removal dead-code elimination vs a savestates FASTSIM/pause interaction)
      -- is unpinned, but is_simu='0' is NOT a safe sim-speed lever despite looking like
      -- one in static analysis. (Disabling it would only remove R:\debug_*_sim.txt
      -- writers, which are negligible wall-clock anyway: they write per retired
      -- instruction and the uncached boot retires slowly. The real sim-speed lever
      -- is reducing the SDRAM model's per-access latency -- see sim/system573/
      -- README.md, Phase-3 "Next" item 1.)
      is_simu               => '1'
   )
   port map
   (
      clk1x                 => clk1x,
      clk2x                 => clk2x,
      clk3x                 => clk3x,
      clkvid                => clkvid,
      reset                 => reset,
      isPaused              => open,
      -- commands
      pause                 => '0',
      hps_busy              => '0',
      loadExe               => psx_LoadExe,
      exe_initial_pc        => exe_initial_pc,
      exe_initial_gp        => exe_initial_gp,
      exe_load_address      => exe_load_address,
      exe_file_size         => exe_file_size,
      exe_stackpointer      => exe_stackpointer,
      fastboot              => '0',     -- SCPH-specific patch; OFF for Konami BIOS
      ram8mb                => RAM8MB,
      TURBO_MEM             => TURBO, -- sim accelerators (bring-up); TURBO generic, the
      TURBO_COMP            => TURBO, -- .rbf never uses these. Note: these mainly help
      TURBO_CACHE           => TURBO, -- CACHED accesses; the BIOS boot is largely uncached
      TURBO_CACHE50         => '0',   -- (KSEG1), so the SDRAM-model latency still dominates.
      REPRODUCIBLEGPUTIMING => '0',
      INSTANTSEEK           => '0',
      FORCECDSPEED          => "000",
      LIMITREADSPEED        => '0',
      IGNORECDDMATIMING     => '0',
      ditherOff             => '0',
      interlaced480pHack    => '0',
      showGunCrosshairs     => '0',
      enableNeGconRumble    => '0',
      fpscountOn            => '0',
      cdslowOn              => '0',
      testSeek              => '0',
      pauseOnCDSlow         => '0',
      errorOn               => '0',
      LBAOn                 => '0',
      PATCHSERIAL           => '0',     -- SCPH-specific; OFF for Konami BIOS
      noTexture             => '0',
      textureFilter         => "00",
      textureFilterStrength => "00",
      textureFilter2DOff    => '0',
      dither24              => '0',
      render24              => '0',
      drawSlow              => '0',
      syncVideoOut          => '0',
      syncInterlace         => '0',
      rotate180             => '0',
      fixedVBlank           => '0',
      vCrop                 => "00",
      hCrop                 => '0',
      SPUon                 => '1',
      SPUIRQTrigger         => '0',
      SPUSDRAM              => '1',
      REVERBOFF             => '0',
      REPRODUCIBLESPUDMA    => '0',
      WIDESCREEN            => "00",
      oldGPU                => '0',
      -- RAM/BIOS interface
      biosregion            => "00",
      -- 573 EXP1 master
      exp1_addr             => exp1_addr,
      exp1_dataWrite        => exp1_dataWrite,
      exp1_we               => exp1_we,
      exp1_re               => exp1_re,
      exp1_dataRead         => exp1_dataRead,
      exp_irq10             => exp_irq10,
      ram_refresh           => ram_refresh,
      ram_dataWrite         => ram_dataWrite,
      ram_dataRead32        => ram_dataRead32,
      ram_Adr               => ram_Adr,
      ram_cntDMA            => ram_cntDMA,
      ram_be                => ram_be,
      ram_rnw               => ram_rnw,
      ram_ena               => ram_ena,
      ram_dma               => ram_dma,
      ram_cache             => ram_iscache,
      ram_done              => ram_done,
      ram_dmafifo_adr       => ram_dmafifo_adr,
      ram_dmafifo_data      => ram_dmafifo_data,
      ram_dmafifo_empty     => ram_dmafifo_empty,
      ram_dmafifo_read      => ram_dmafifo_read,
      cache_wr              => cache_wr,
      cache_data            => cache_data,
      cache_addr            => cache_addr,
      dma_wr                => dma_wr,
      dma_reqprocessed      => dma_reqprocessed,
      dma_data              => dma_data,
      -- vram/ddr3 interface
      DDRAM_BUSY            => DDRAM_BUSY,
      DDRAM_BURSTCNT        => DDRAM_BURSTCNT,
      DDRAM_ADDR            => DDRAM_ADDR,
      DDRAM_DOUT            => DDRAM_DOUT,
      DDRAM_DOUT_READY      => DDRAM_DOUT_READY,
      DDRAM_RD             => DDRAM_RD,
      DDRAM_DIN             => DDRAM_DIN,
      DDRAM_BE              => DDRAM_BE,
      DDRAM_WE              => DDRAM_WE,
      -- cd  (no disc: hasCD='0', LIDopen='1')
      region                => "00",
      region_out            => open,
      hasCD                 => '0',
      LIDopen               => '1',
      fastCD                => '0',
      trackinfo_data        => (others => '0'),
      trackinfo_addr        => (others => '0'),
      trackinfo_write       => '0',
      resetFromCD           => open,
      cd_hps_req            => open,
      cd_hps_lba            => open,
      cd_hps_lba_sim        => open,
      cd_hps_ack            => '0',
      cd_hps_write          => '0',
      cd_hps_data           => (others => '0'),
      -- spuram
      spuram_dataWrite      => spuram_dataWrite,
      spuram_Adr            => spuram_Adr,
      spuram_be             => spuram_be,
      spuram_rnw            => spuram_rnw,
      spuram_ena            => spuram_ena,
      spuram_dataRead       => spuram_dataRead,
      spuram_done           => spuram_done,
      -- memcard (all off)
      memcard_changed       => open,
      saving_memcard        => open,
      memcard1_load         => '0',
      memcard2_load         => '0',
      memcard_save          => '0',
      memcard1_mounted      => '0',
      memcard1_available    => '0',
      memcard1_rd           => open,
      memcard1_wr           => open,
      memcard1_lba          => open,
      memcard1_ack          => '0',
      memcard1_write        => '0',
      memcard1_addr         => (others => '0'),
      memcard1_dataIn       => (others => '0'),
      memcard1_dataOut      => open,
      memcard2_mounted      => '0',
      memcard2_available    => '0',
      memcard2_rd           => open,
      memcard2_wr           => open,
      memcard2_lba          => open,
      memcard2_ack          => '0',
      memcard2_write        => '0',
      memcard2_addr         => (others => '0'),
      memcard2_dataIn       => (others => '0'),
      memcard2_dataOut      => open,
      -- video
      videoout_on           => '1',
      isPal                 => '0',
      pal60                 => '0',
      hsync                 => open,
      vsync                 => open,
      hblank                => hblank,
      vblank                => vblank,
      DisplayWidth          => open,
      DisplayHeight         => open,
      DisplayOffsetX        => open,
      DisplayOffsetY        => open,
      video_ce              => video_ce,
      video_interlace       => video_interlace,
      video_r               => video_r,
      video_g               => video_g,
      video_b               => video_b,
      video_isPal           => open,
      video_fbmode          => open,
      video_fb24            => open,
      video_hResMode        => open,
      video_frameindex      => open,
      -- Keys - all active high
      DSAltSwitchMode       => '0',
      PadPortEnable1        => '1',
      PadPortDigital1       => '1',
      PadPortAnalog1        => '0',
      PadPortMouse1         => '0',
      PadPortGunCon1        => '0',
      PadPortneGcon1        => '0',
      PadPortWheel1         => '0',
      PadPortDS1            => '0',
      PadPortJustif1        => '0',
      PadPortStick1         => '0',
      PadPortPopn1          => '0',
      PadPortEnable2        => '0',
      PadPortDigital2       => '1',
      PadPortAnalog2        => '0',
      PadPortMouse2         => '0',
      PadPortGunCon2        => '0',
      PadPortneGcon2        => '0',
      PadPortWheel2         => '0',
      PadPortDS2            => '0',
      PadPortJustif2        => '0',
      PadPortStick2         => '0',
      PadPortPopn2          => '0',
      KeyTriangle           => KeyTriangle,
      KeyCircle             => KeyCircle,
      KeyCross              => KeyCross,
      KeySquare             => KeySquare,
      KeySelect             => KeySelect,
      KeyStart              => KeyStart,
      KeyRight              => KeyRight,
      KeyLeft               => KeyLeft,
      KeyUp                 => KeyUp,
      KeyDown               => KeyDown,
      KeyR1                 => KeyR1,
      KeyR2                 => KeyR2,
      KeyR3                 => KeyR3,
      KeyL1                 => KeyL1,
      KeyL2                 => KeyL2,
      KeyL3                 => KeyL3,
      ToggleDS              => "0000",
      Analog1XP1            => Analog1XP1,
      Analog1YP1            => Analog1YP1,
      Analog2XP1            => Analog2XP1,
      Analog2YP1            => Analog2YP1,
      Analog1XP2            => Analog1XP2,
      Analog1YP2            => Analog1YP2,
      Analog2XP2            => Analog2XP2,
      Analog2YP2            => Analog2YP2,
      Analog1XP3            => Analog1XP2,
      Analog1YP3            => Analog1YP2,
      Analog2XP3            => Analog2XP2,
      Analog2YP3            => Analog2YP2,
      Analog1XP4            => Analog1XP2,
      Analog1YP4            => Analog1YP2,
      Analog2XP4            => Analog2XP2,
      Analog2YP4            => Analog2YP2,
      multitap              => '0',
      multitapDigital       => '0',
      multitapAnalog        => '0',
      -- mouse
      MouseEvent            => MouseEvent,
      MouseLeft             => '0',
      MouseRight            => '0',
      MouseX                => MouseX,
      MouseY                => MouseY,
      RumbleDataP1          => open,
      RumbleDataP2          => open,
      RumbleDataP3          => open,
      RumbleDataP4          => open,
      padMode               => open,
      -- snac
      snacPort1             => '0',
      snacPort2             => '0',
      irq10Snac             => '0',
      actionNextSnac        => '0',
      receiveValidSnac      => '0',
      ackSnac               => '0',
      snacMC                => '0',
      receiveBufferSnac     => x"00",
      transmitValueSnac     => open,
      selectedPort1Snac     => open,
      selectedPort2Snac     => open,
      clk9Snac              => open,
      beginTransferSnac     => open,
      -- sound
      sound_out_left        => sound_out_left,
      sound_out_right       => sound_out_right,
      -- savestates
      increaseSSHeaderCount => '1',
      save_state            => '0',
      load_state            => '0',
      savestate_number      => 0,
      state_loaded          => open,
      validSStates          => open,
      rewind_on             => '0',
      rewind_active         => '0',
      -- cheats
      cheat_clear           => '0',
      cheats_enabled        => '0',
      cheat_on              => '0',
      cheat_in              => (127 downto 0 => '0'),
      cheats_active         => open,
      Cheats_BusAddr        => open,
      Cheats_BusRnW         => open,
      Cheats_BusByteEnable  => open,
      Cheats_BusWriteData   => open,
      Cheats_Bus_ena        => open,
      Cheats_BusReadData    => (31 downto 0 => '0'),
      Cheats_BusDone        => '0'
   );

   -- -----------------------------------------------------------------------
   -- Main RAM + BIOS (SCRIPTLOADING enabled => COMMAND_FILE_* load path).
   -- -----------------------------------------------------------------------
   isdram_model : entity tb.sdram_model3x
   generic map
   (
      DOREFRESH     => '1',
      SCRIPTLOADING => '1'
   )
   port map
   (
      clk                  => clk1x,
      clk3x                => clk3x,
      refresh              => ram_refresh,
      addr(26 downto 25)   => "00",
      addr(24 downto  0)   => ram_Adr,
      req                  => ram_ena,
      ram_dma              => ram_dma,
      ram_dmacnt           => ram_cntDMA,
      ram_iscache          => ram_iscache,
      rnw                  => ram_rnw,
      be                   => ram_be,
      di                   => ram_dataWrite,
      do                   => open,
      do32                 => ram_dataRead32,
      done                 => ram_done,
      cache_wr             => cache_wr,
      cache_data           => cache_data,
      cache_addr           => cache_addr,
      dma_wr               => dma_wr,
      dma_data             => dma_data,
      reqprocessed         => dma_reqprocessed,
      ram_idle             => open,
      ram_dmafifo_adr      => ram_dmafifo_adr,
      ram_dmafifo_data     => ram_dmafifo_data,
      ram_dmafifo_empty    => ram_dmafifo_empty,
      ram_dmafifo_read     => ram_dmafifo_read,
      exe_initial_pc       => exe_initial_pc,
      exe_initial_gp       => exe_initial_gp,
      exe_load_address     => exe_load_address,
      exe_file_size        => exe_file_size,
      exe_stackpointer     => exe_stackpointer
   );

   -- -----------------------------------------------------------------------
   -- SPU RAM (scratch; no preload).
   -- -----------------------------------------------------------------------
   ispu_ram : entity tb.sdram_model3x
   generic map
   (
      DOREFRESH     => '0',
      SCRIPTLOADING => '0'
   )
   port map
   (
      clk                  => clk1x,
      clk3x                => clk3x,
      refresh              => '0',
      addr(26 downto 19)   => "00000000",
      addr(18 downto  0)   => spuram_Adr,
      req                  => spuram_ena,
      ram_dma              => '0',
      ram_dmacnt           => "00",
      ram_iscache          => '0',
      rnw                  => spuram_rnw,
      be                   => spuram_be,
      di                   => spuram_dataWrite,
      do                   => open,
      do32                 => spuram_dataRead,
      done                 => spuram_done,
      reqprocessed         => open,
      ram_idle             => open,
      ram_dmafifo_adr      => (22 downto 0 => '0'),
      ram_dmafifo_data     => (31 downto 0 => '0'),
      ram_dmafifo_empty    => '1'
   );

   -- -----------------------------------------------------------------------
   -- VRAM model (also dumps gra_fb_out.gra from GPU VRAM writes).
   -- -----------------------------------------------------------------------
   iddrram_model : entity tb.ddrram_model
   generic map
   (
      SLOWTIMING   => SLOWVRAM,   -- run.sh-controlled; 0 (bring-up) speeds the GPU VRAM path
      RANDOMTIMING => '0'
   )
   port map
   (
      DDRAM_CLK        => clk2x,
      DDRAM_BUSY       => DDRAM_BUSY,
      DDRAM_BURSTCNT   => DDRAM_BURSTCNT,
      DDRAM_ADDR       => DDRAM_ADDR,
      DDRAM_DOUT       => DDRAM_DOUT,
      DDRAM_DOUT_READY => DDRAM_DOUT_READY,
      DDRAM_RD         => DDRAM_RD,
      DDRAM_DIN        => DDRAM_DIN,
      DDRAM_BE         => DDRAM_BE,
      DDRAM_WE         => DDRAM_WE
   );

   -- -----------------------------------------------------------------------
   -- Video-out capture -> gra_fb_out_vga.gra
   -- -----------------------------------------------------------------------
   iframebuffer : entity tb.framebuffer
   port map
   (
      clk             => clkvid,
      hblank          => hblank,
      vblank          => vblank,
      video_ce        => video_ce,
      video_interlace => video_interlace,
      video_r         => video_r,
      video_g         => video_g,
      video_b         => video_b
   );

   -- -----------------------------------------------------------------------
   -- CPU program-counter tap (NVC external name into the core; observability
   -- only, no DUT change). Logs each PC change to pc_trace.log (capped) plus a
   -- periodic [pcsnap] with the live PC, so the execution position survives a
   -- forced --stop-time stop. Turns "these look like instruction fetches" into
   -- "the PC is here" -- the primary bring-up scope for Phase 3.
   -- -----------------------------------------------------------------------
   pc_tap : process(clk1x)
      alias cpu_pc is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc : unsigned(31 downto 0) >>;
      file     pf     : text;
      variable opened : boolean := false;
      variable l      : line;
      variable status : FILE_OPEN_STATUS;
      variable prev   : unsigned(31 downto 0) := (others => '1');
      variable logged : integer := 0;
      variable cnt    : integer := 0;
      procedure put_hex8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop
            s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1);
         end loop;
         write(ln, s);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, pf, "pc_trace.log", write_mode); file_close(pf);
            file_open(status, pf, "pc_trace.log", append_mode); opened := true;
         end if;
         cnt := cnt + 1;
         -- Log only NON-sequential PC changes (branches/jumps/calls/returns), not
         -- every +4 fetch -- this captures control-flow structure (incl. main init
         -- past 0x5504) without the early RAM-test loop saturating the cap.
         if cpu_pc /= prev then
            if (cpu_pc /= prev + 4) and (logged < 60000) then
               write(l, string'("PC=0x")); put_hex8(l, cpu_pc); writeline(pf, l);
               logged := logged + 1;
               file_close(pf); file_open(status, pf, "pc_trace.log", append_mode);
            end if;
            prev := cpu_pc;
         end if;
         if (cnt mod 100000) = 0 then
            write(l, string'("[pcsnap] cnt=")); write(l, cnt);
            write(l, string'(" pc=0x")); put_hex8(l, cpu_pc); writeline(pf, l);
            file_close(pf); file_open(status, pf, "pc_trace.log", append_mode);
         end if;
      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- Internal-I/O address tap (NVC external name into memorymux; observability).
   -- Logs each distinct CPU access address that falls in the PSX internal I/O
   -- window 0x1F801000..0x1F801FFF (GPU/SPU/timer/DMA/IRQ), with the data the
   -- internal busses return. This identifies exactly which register the BIOS
   -- polls in its wait-with-timeout loops (e.g. the 0x44F0 poll) -- the EXP1
   -- responder only covers the 573 page, so internal-register waits show here.
   -- -----------------------------------------------------------------------
   io_tap : process(clk1x)
      alias io_addr is << signal .tb_system573.ipsx_mister.ipsx_top.imemorymux.addressData_buf : unsigned(31 downto 0) >>;
      alias io_data is << signal .tb_system573.ipsx_mister.ipsx_top.imemorymux.dataFromBusses : std_logic_vector(31 downto 0) >>;
      file     f      : text;
      variable opened : boolean := false;
      variable l      : line;
      variable status : FILE_OPEN_STATUS;
      variable last   : unsigned(28 downto 0) := (others => '1');
      variable logged : integer := 0;
      procedure hex(variable ln : inout line; v : std_logic_vector) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable vv : std_logic_vector(v'length-1 downto 0) := v;
         variable n  : integer := v'length/4;
      begin
         for i in n-1 downto 0 loop
            write(ln, hx(to_integer(unsigned(vv(i*4+3 downto i*4))) + 1));
         end loop;
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "io_trace.log", write_mode); file_close(f);
            file_open(status, f, "io_trace.log", append_mode); opened := true;
         end if;
         if (not is_x(std_logic_vector(io_addr))) and (to_integer(io_addr(28 downto 12)) = 16#1F801#)
            and (io_addr(28 downto 0) /= last) and (logged < 20000) then
            last := io_addr(28 downto 0);
            write(l, string'("IO addr=0x")); hex(l, std_logic_vector(io_addr));
            write(l, string'(" data=0x"));   hex(l, io_data);
            writeline(f, l); logged := logged + 1;
            file_close(f); file_open(status, f, "io_trace.log", append_mode);
         end if;
      end if;
   end process;

end architecture;
