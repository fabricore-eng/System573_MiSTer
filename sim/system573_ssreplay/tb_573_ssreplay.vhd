-- =============================================================================
-- tb_573_ssreplay -- savestate -> full-573 sim REPLAY harness (Stage 1 of the
-- garble-isolation plan, /Users/human/.claude/plans/calm-wiggling-honey.md).
--
-- GOAL: load a PlayStation/573 savestate (.ss) into the FULL 573 system in NVC
-- and run forward, so we can (later) tap per-draw GPU data deterministically.
-- This makes the core BOTH freezable (the .ss freezes complete state) AND fully
-- observable (in sim), the unlock for an alignment-free per-draw vs MAME compare.
--
-- It instantiates the SAME vendored DUT + memory models as sim/system573/
-- tb_system573.vhd (psx_mister + sdram_model3x x2 + ddrram_model + framebuffer),
-- but instead of tying the savestate path off, it drives the REAL in-core
-- savestate loader (psx/rtl/savestates.vhd, instanced as psx_top.isavestates):
--
--   * The .ss is PRELOADED into the ddrram_model (the sim's DDR3/VRAM backing) at
--     the DDR savestate region, exactly where the HPS DMAs it on real HW. Then
--   * load_state is PULSED on psx_mister; the in-core savestates FSM reads the
--     savestate back out of DDR and replays SS_wren/SS_DataWrite/SS_Adr +
--     loading_savestate into every sub-block (CPU/GPU/DMA/.../SPURAM[/VRAM/RAM]).
--
-- This is the architecturally-correct path: it is byte-for-byte what the .rbf
-- does (rtl/emu.sv ss_load -> psx_mister.load_state -> savestates.vhd reads DDR).
-- It needs NO edit to the vendored psx/ submodule and NO forcing of internal
-- signals: the SS_* wires are INTERNAL to psx_top (driven by isavestates and
-- consumed by every sub-block), so they cannot be driven from a tb -- the
-- standalone psx/sim/system/src/tb/tb_savestates.vhd (which the plan names) can
-- only be used in the UNIT benches where those sub-blocks are stood up bare; in
-- the full system the in-core loader owns them. See the harness README + the
-- final report for the full wiring trace (file:line).
--
-- *** KNOWN LIMITATION (is_simu/FASTSIM) ***
--   savestates.vhd gates the load by FASTSIM (= is_simu). With is_simu='1' (which
--   tb_system573 REQUIRES -- is_simu='0' stalls the boot at the reset vector) the
--   non-resetMode user-load loads savetypes 0..14 (CPU..SPURAM) but SKIPS VRAM(15)
--   and RAM(16) (savestates.vhd:588-590). So a user .ss load under is_simu='1'
--   restores CPU/GPU-regs/SPU/etc but NOT VRAM or main RAM. For the garble per-draw
--   tap that still gives the GPU register + draw-command state; the framebuffer
--   it renders will reflect whatever VRAM the boot left (NOT the .ss VRAM) unless
--   the FASTSIM gate is addressed. Options documented in the report. The harness
--   still fully de-risks the FSM: it runs the complete load handshake to LOAD_DONE.
--
-- This file is ORIGINAL to this repo (it only INSTANTIATES vendored psx/ +
-- upstream-tb entities); the vendored submodule is untouched. Build via run.sh.
-- =============================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

library tb;
use tb.globals.all;       -- COMMAND_FILE_* signals (the model-load handshake)

library psx;

entity tb_573_ssreplay is
   generic
   (
      -- Konami 512 KB BIOS (copied to the run dir as s573_bios.bin by run.sh).
      BIOS_FILE   : string  := "s573_bios.bin";
      BIOS_TARGET : integer := 16#800000#;   -- region-0 SDRAM byte base (= 0x1FC00000)
      -- The savestate file (.ss). 1048576 little-endian 32-bit DWORDs = 4 MiB, the
      -- raw DDR savestate region (psx/rtl/savestates.vhd layout; identical HW<->sim).
      -- run.sh stages whatever path it is given here into the run dir as this name.
      SS_FILE     : string  := "state.ss";
      -- LOAD_SS='1': preload SS_FILE into the ddrram_model + pulse load_state. '0'
      -- = plain boot (no savestate), to A/B the resume vs a stock boot.
      LOAD_SS     : std_logic := '1';
      -- DDR word index where the savestate region ALIASES into the ddrram_model
      -- data[] array. DERIVATION (see report): savestates Softmap_SaveState_ADDR =
      -- 0x3800000 (DWORD) -> top ddr3_ADDR = (addr<<2) = 0xE000000 byte ->
      -- psx_mister DDRAM_ADDR(24:0) = ddr3_ADDR(27:3) = 0x1C00000 ->
      -- ddrram_model.intern_addr = DDRAM_ADDR(22:0) & '0' = 0x400000<<1 = 0x800000.
      -- (the model decodes ONLY DDRAM_ADDR(22:0), so the high savestate address
      -- aliases deterministically to this low data[] word -- no VRAM collision.)
      SS_WORD_BASE : integer := 16#800000#;
      -- 573 has 4 MB RAM; core supports 2 MB ('0') or 8 MB ('1').
      RAM8MB      : std_logic := '1';
      -- Sim accelerator (TURBO_MEM/COMP/CACHE).
      TURBO       : std_logic := '1';
      -- VRAM (DDR) model read latency in cycles for the GPU path. 0 = near-instant.
      SLOWVRAM    : integer := 0;
      -- Per-draw GPU tap (Stage-1 deliverable). Ships OFF; flip to '1' (or run.sh
      -- DRAWTAP=1) to emit a per-draw record via NVC external names (no DUT edit).
      DRAWTAP     : std_logic := '0';
      -- sim time (after reset release) at which to pulse load_state, and the pulse
      -- width. Defaults give the resetMode init time to settle + validate the slot.
      LOAD_AT     : time := 60 us;
      LOAD_WIDTH  : time := 2 us
   );
end entity;

architecture sim of tb_573_ssreplay is

   -- clocks / reset / "on"
   signal clk1x, clk2x, clk3x, clkvid : std_logic := '1';
   signal reset       : std_logic;
   signal psx_on      : std_logic := '0';

   signal psx_LoadExe : std_logic := '0';

   -- 573 EXP1 master (widened ports) -- benign 0 responder (no flash here)
   signal exp1_addr      : std_logic_vector(23 downto 0);
   signal exp1_dataWrite : std_logic_vector(15 downto 0);
   signal exp1_we        : std_logic;
   signal exp1_re        : std_logic;
   signal exp1_dataRead  : std_logic_vector(15 downto 0) := (others => '0');
   signal exp_irq10      : std_logic := '0';

   -- savestate command path (driven into psx_mister)
   signal save_state     : std_logic := '0';
   signal load_state     : std_logic := '0';
   signal savestate_num  : integer range 0 to 3 := 0;
   signal state_loaded   : std_logic;
   signal validSStates   : std_logic_vector(3 downto 0);

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

   -- input tie-off constants (verbatim from upstream tb.vhd / tb_system573)
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
   -- -----------------------------------------------------------------------
   clk1x  <= not clk1x  after 15   ns;
   clk2x  <= not clk2x  after 7500 ps;
   clk3x  <= not clk3x  after 5    ns;
   clkvid <= not clkvid after 9462 ps;
   reset  <= not psx_on;

   -- -----------------------------------------------------------------------
   -- Stimulus: load the Konami BIOS into the SDRAM model at 0x800000, PRELOAD
   -- the savestate into the ddrram_model at the aliased savestate region (so the
   -- in-core loader can read it back), then release reset and run. The BIOS is
   -- still loaded so the boot ROM brings the system to a sane idle BEFORE the
   -- savestate replaces CPU/peripheral state (same as HW: the core is running
   -- when the user triggers a load).
   -- -----------------------------------------------------------------------
   stim : process
   begin
      psx_on               <= '0';
      COMMAND_FILE_START_1 <= '0';
      COMMAND_FILE_START_2 <= '0';
      COMMAND_FILE_NAME    <= (others => ' ');
      wait for 1 us;

      -- (1) BIOS -> main-RAM/BIOS SDRAM model (region-0 byte 0x800000), via the
      --     sdram_model3x SCRIPTLOADING COMMAND_FILE_START_1 handshake.
      COMMAND_FILE_NAME(1 to BIOS_FILE'length) <= BIOS_FILE;
      COMMAND_FILE_NAMELEN <= BIOS_FILE'length;
      COMMAND_FILE_TARGET  <= BIOS_TARGET;
      COMMAND_FILE_OFFSET  <= 0;
      COMMAND_FILE_SIZE    <= 0;        -- 0 = whole file
      COMMAND_FILE_ENDIAN  <= '0';
      COMMAND_FILE_START_1 <= '1';
      wait for 200 ns;
      COMMAND_FILE_START_1 <= '0';
      wait for 1 us;
      report "tb_573_ssreplay: BIOS loaded into SDRAM model";

      -- (2) savestate -> ddrram_model at the aliased savestate word base, via the
      --     ddrram_model COMMAND_FILE_START_2 handshake. The model loads the whole
      --     file as 32-bit LE words into data[SS_WORD_BASE ..]. The in-core
      --     savestates FSM later reads exactly these words back (the address alias
      --     is deterministic; see SS_WORD_BASE derivation above).
      if LOAD_SS = '1' then
         COMMAND_FILE_NAME    <= (others => ' ');
         COMMAND_FILE_NAME(1 to SS_FILE'length) <= SS_FILE;
         COMMAND_FILE_NAMELEN <= SS_FILE'length;
         COMMAND_FILE_TARGET  <= SS_WORD_BASE;
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;          -- whole file
         COMMAND_FILE_ENDIAN  <= '0';        -- .ss is LE 32-bit dwords
         COMMAND_FILE_START_2 <= '1';
         wait for 16 ns;                     -- ~one clk2x edge triggers the load
         COMMAND_FILE_START_2 <= '0';
         wait for 3 us;                      -- let the (4 MiB) load settle
         report "tb_573_ssreplay: savestate preloaded into ddrram_model";
      end if;

      report "tb_573_ssreplay: releasing reset";
      psx_on <= '1';

      wait;       -- bounded by --stop-time on the nvc -r command line
   end process;

   -- -----------------------------------------------------------------------
   -- LOAD_STATE sequencer. After reset release the in-core savestates FSM first
   -- runs its RESET-MODE init (auto, on reset edge -- restores scratchpad/SPURAM
   -- defaults AND scans the 4 DDR slots, setting validSStates per slot whose
   -- header DWORD[1] == STATESIZE(0xFFFFE)). Once that settles + the slot is
   -- valid, we PULSE load_state: statemanager.vhd latches it -> savestates.vhd
   -- LOAD path reads the .ss back out of DDR and replays it into the core.
   -- (load is GATED by validSStates(savestate_num)='1', so a wrong-magic .ss is
   -- a no-op -- the log will show validSStates=0 in that case.)
   -- -----------------------------------------------------------------------
   loadstate_seq : process
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable l      : line;
   begin
      save_state <= '0';
      load_state <= '0';
      savestate_num <= 0;
      if LOAD_SS /= '1' then
         wait;                    -- no savestate: never pulse
      end if;

      wait until psx_on = '1';    -- reset released
      file_open(status, f, "ssreplay.log", write_mode);
      write(l, string'("[ssreplay] reset released at ")); write(l, now);
      writeline(f, l); file_close(f);

      wait for LOAD_AT;           -- let the resetMode init + slot-scan settle

      file_open(status, f, "ssreplay.log", append_mode);
      write(l, string'("[ssreplay] validSStates=0x"));
      write(l, to_hstring(validSStates));
      write(l, string'(" -> pulsing load_state(slot ")); write(l, savestate_num);
      write(l, string'(") at ")); write(l, now);
      writeline(f, l); file_close(f);

      wait until rising_edge(clk1x);
      load_state <= '1';
      wait for LOAD_WIDTH;
      wait until rising_edge(clk1x);
      load_state <= '0';

      file_open(status, f, "ssreplay.log", append_mode);
      write(l, string'("[ssreplay] load_state pulse complete at ")); write(l, now);
      writeline(f, l); file_close(f);
      wait;
   end process;

   -- -----------------------------------------------------------------------
   -- Observe the load handshake: log every edge of state_loaded / validSStates /
   -- loading_savestate so the report can state "the load FSM ran + completed".
   -- loading_savestate is INTERNAL to psx_top (savestates output) -- read-only
   -- via an NVC external-name alias (the proven no-vendored-edit technique).
   -- -----------------------------------------------------------------------
   load_probe : process(clk1x)
      alias a_loading is
         << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.loading_savestate : std_logic >>;
      alias a_ssbusy is
         << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.savestate_busy : std_logic >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable pv_load : std_logic := '0';
      variable pv_sl   : std_logic := '0';
      variable pv_vs   : std_logic_vector(3 downto 0) := (others => '0');
      variable pv_busy : std_logic := '0';
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "ssload_probe.log", write_mode); file_close(f);
            opened := true;
         end if;
         if (a_loading /= pv_load) or (state_loaded /= pv_sl)
            or (validSStates /= pv_vs) or (a_ssbusy /= pv_busy) then
            write(l, string'("t=")); write(l, now);
            write(l, string'(" loading_ss=")); write(l, a_loading);
            write(l, string'(" ss_busy="));    write(l, a_ssbusy);
            write(l, string'(" state_loaded=")); write(l, state_loaded);
            write(l, string'(" validSStates=0x")); write(l, to_hstring(validSStates));
            file_open(status, f, "ssload_probe.log", append_mode);
            writeline(f, l); file_close(f);
            pv_load := a_loading; pv_sl := state_loaded;
            pv_vs := validSStates; pv_busy := a_ssbusy;
         end if;
      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- Minimal benign EXP1 responder: returns 0 (no flash/ATAPI here). The 573
   -- page reads/writes from resumed game code land here; benign-0 is fine for a
   -- short post-load run (the GPU draws from VRAM/GPU-regs, not EXP1).
   -- -----------------------------------------------------------------------
   exp1_responder : process(clk1x)
   begin
      if rising_edge(clk1x) then
         if exp1_re = '1' then
            exp1_dataRead <= (others => '0');
         end if;
      end if;
   end process;

   -- -----------------------------------------------------------------------
   -- DUT: vendored patched PSX core (psx_mister). Port map matches tb_system573
   -- VERBATIM except the savestate ports, which here are DRIVEN (load path) not
   -- tied to '0'. Keep is_simu='1' (is_simu='0' stalls the boot -- see the
   -- tb_system573 note; it ALSO sets FASTSIM, the VRAM/RAM-skip caveat above).
   -- -----------------------------------------------------------------------
   ipsx_mister : entity psx.psx_mister
   generic map
   (
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
      pause                 => '0',
      hps_busy              => '0',
      loadExe               => psx_LoadExe,
      exe_initial_pc        => exe_initial_pc,
      exe_initial_gp        => exe_initial_gp,
      exe_load_address      => exe_load_address,
      exe_file_size         => exe_file_size,
      exe_stackpointer      => exe_stackpointer,
      fastboot              => '0',
      ram8mb                => RAM8MB,
      TURBO_MEM             => TURBO,
      TURBO_COMP            => TURBO,
      TURBO_CACHE           => TURBO,
      TURBO_CACHE50         => '0',
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
      PATCHSERIAL           => '0',
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
      biosregion            => "00",
      exp1_addr             => exp1_addr,
      exp1_dataWrite        => exp1_dataWrite,
      exp1_we               => exp1_we,
      exp1_re               => exp1_re,
      exp1_dataRead         => exp1_dataRead,
      exp1_wait             => '0',
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
      DDRAM_BUSY            => DDRAM_BUSY,
      DDRAM_BURSTCNT        => DDRAM_BURSTCNT,
      DDRAM_ADDR            => DDRAM_ADDR,
      DDRAM_DOUT            => DDRAM_DOUT,
      DDRAM_DOUT_READY      => DDRAM_DOUT_READY,
      DDRAM_RD             => DDRAM_RD,
      DDRAM_DIN             => DDRAM_DIN,
      DDRAM_BE              => DDRAM_BE,
      DDRAM_WE             => DDRAM_WE,
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
      spuram_dataWrite      => spuram_dataWrite,
      spuram_Adr            => spuram_Adr,
      spuram_be             => spuram_be,
      spuram_rnw            => spuram_rnw,
      spuram_ena            => spuram_ena,
      spuram_dataRead       => spuram_dataRead,
      spuram_done           => spuram_done,
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
      sound_out_left        => sound_out_left,
      sound_out_right       => sound_out_right,
      -- savestates: DRIVEN here (the whole point of this harness)
      increaseSSHeaderCount => '1',
      save_state            => save_state,
      load_state            => load_state,
      savestate_number      => savestate_num,
      state_loaded          => state_loaded,
      validSStates          => validSStates,
      rewind_on             => '0',
      rewind_active         => '0',
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
   -- Main RAM + BIOS (SCRIPTLOADING => COMMAND_FILE_* path).
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
   -- VRAM model (also dumps gra_fb_out.gra from GPU VRAM writes). The savestate
   -- PRELOAD also lands in THIS model's data[] (the COMMAND_FILE_START_2 path) at
   -- the aliased savestate base; the in-core loader reads it back from here.
   -- -----------------------------------------------------------------------
   iddrram_model : entity tb.ddrram_model
   generic map
   (
      SLOWTIMING   => SLOWVRAM,
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
   -- Video-out capture -> gra_fb_out_vga.gra (640x480 displayed video).
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

   -- =======================================================================
   -- PER-DRAW GPU TAP (DRAWTAP='1'; Stage-1 deliverable scaffold). Reads, via
   -- NVC external-name aliases (no DUT edit), the GPU draw-input + output state
   -- the plan calls out, and emits one record per drawn primitive to drawtap.log.
   -- Ships OFF (DRAWTAP='0'). The exact alias paths are pinned to this fork's
   -- gpu.vhd / gpu_pixelpipeline.vhd (psx_top.igpu.*); if a name has drifted,
   -- NVC reports the unresolved external name at elaboration -- update here only.
   --
   -- This is intentionally MINIMAL + GATED: Stage 1's first job is the de-risk
   -- (does the load resume?), and the tap is the hook Stage 1/2 fills in once a
   -- real .ss reproduces the garble. Enabling it on a design where a name moved
   -- would fail elaboration, so it is OFF until the .ss arrives + the exact
   -- signals are confirmed against the live gpu.vhd.
   -- =======================================================================
   drawtap_gen : if DRAWTAP = '1' generate
      drawtap : process(clk2x)
         -- draw-input side (gpu_pixelpipeline.vhd): the texel + palette the
         -- pixel pipeline samples, plus the draw mode (gpu.vhd drawMode).
         alias t_pixWrite is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.pixelWrite : std_logic >>;
         alias t_pixColor is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.pixelColor      : std_logic_vector(15 downto 0) >>;
         alias t_pixAddr  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.pixelAddr       : unsigned(19 downto 0) >>;
         file     f      : text;
         variable status : FILE_OPEN_STATUS;
         variable opened : boolean := false;
         variable l      : line;
         variable n      : integer := 0;
      begin
         if rising_edge(clk2x) then
            if not opened then
               file_open(status, f, "drawtap.log", write_mode); file_close(f);
               opened := true;
            end if;
            if t_pixWrite = '1' and n < 2000000 and not is_x(t_pixColor) then
               write(l, string'("pixWrite addr=0x")); write(l, to_hstring(t_pixAddr));
               write(l, string'(" color=0x"));        write(l, to_hstring(t_pixColor));
               write(l, string'(" t="));               write(l, now);
               file_open(status, f, "drawtap.log", append_mode);
               writeline(f, l); file_close(f);
               n := n + 1;
            end if;
         end if;
      end process;
   end generate;

end architecture;
