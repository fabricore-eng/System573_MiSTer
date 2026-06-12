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
use psx.pGPU.all;         -- div_type (the FIX_POLY_DIV whole-record force aliases)

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
      -- *** Option A (README) preload of the FASTSIM-skipped VRAM + RAM slices ***
      -- With is_simu='1' the in-core user-load SKIPS savetype 15 (VRAM) + 16 (RAM).
      -- To get a faithful per-draw render we additionally preload the .ss VRAM slice
      -- straight into the ddrram_model VRAM window (TARGET=0 -> data[0..0x3FFFF], the
      -- 1024x512 RGB555 region the GPU samples) and the .ss main-RAM slice into the
      -- main sdram_model3x (TARGET=0 -> PSX physical 0x0, the game code/data the CPU
      -- runs). Both are tb-only COMMAND_FILE preloads (no vendored edit). run.sh
      -- carves the slices with tools/ss_vram_extract.py and passes the basenames.
      PRELOAD_VRAM : std_logic := '0';
      PRELOAD_RAM  : std_logic := '0';
      VRAM_FILE    : string    := "ss_vram.bin";   -- 1 MiB, 1024x512 RGB555 LE
      RAM_FILE     : string    := "ss_ram.bin";    -- 2 MiB, PSX main RAM bytes
      -- DDR word index where the savestate region ALIASES into the ddrram_model
      -- data[] array. DERIVATION (see report): savestates Softmap_SaveState_ADDR =
      -- 0x3800000 (DWORD) -> top ddr3_ADDR = (addr<<2) = 0xE000000 byte ->
      -- psx_mister DDRAM_ADDR(24:0) = ddr3_ADDR(27:3) = 0x1C00000 ->
      -- ddrram_model.intern_addr = DDRAM_ADDR(22:0) & '0' = 0x400000<<1 = 0x800000.
      -- (the model decodes ONLY DDRAM_ADDR(22:0), so the high savestate address
      -- aliases deterministically to this low data[] word -- no VRAM collision.)
      SS_WORD_BASE : integer := 16#800000#;
      -- 573 has 4 MB RAM; the core natively decodes 2 MB ('0') or 8 MB ('1').
      RAM8MB      : std_logic := '1';
      -- 4 MB main-RAM mask on top of the 8 MB decode (psx_patches/0022) -- matches the
      -- .rbf (emu.sv S573_RAM4MB=1). '0' = the old (wrong) 8 MB linear decode.
      RAM4MB      : std_logic := '1';
      -- Sim accelerator (TURBO_MEM/COMP/CACHE).
      TURBO       : std_logic := '1';
      -- VRAM (DDR) model read latency in cycles for the GPU path. 0 = near-instant.
      SLOWVRAM    : integer := 0;
      -- Per-draw GPU tap (Stage-1 deliverable). Ships OFF; flip to '1' (or run.sh
      -- DRAWTAP=1) to emit a per-draw record via NVC external names (no DUT edit).
      -- When ON it taps the live CLUT pipeline (drawMode, textPalX/Y, the CLUT-load
      -- handshake reqVRAMXPos/YPos, CLUTaddrB index, CLUTDataB color, output
      -- pixelColor) over the garble band so the report can PIN the wrong-CLUT source.
      DRAWTAP     : std_logic := '0';
      -- Diagnostic CPU-PC + activity probe (pcprobe.log): samples PC + GPU/IRQ
      -- liveness so we can tell a resumed-and-progressing CPU from a wait-loop spin
      -- (the redraw never arriving = a bounded negative). Ships OFF.
      PCPROBE     : std_logic := '0';
      -- Diagnostic GPU/DMA-state probe (gpuprobe.log): taps the DMA state machine +
      -- GPU command-FIFO + draw proc_idle so we can pin WHY the GPU produces no
      -- pixels when the CPU spins on the GPU-DMA-busy bit (D2_CHCR bit24). Ships OFF.
      GPUPROBE    : std_logic := '0';
      -- FIX_POLY_DIV (ships ON): repair the NVC inout-record 'U' poison on the
      -- shared-divider read ports so the POLY (0x2C QUAD) + LINE paths RENDER under
      -- NVC. gpu.vhd wires the dividers through `inout div_type` ports on
      -- gpu_poly/gpu_line; those drawers never assign the read-only .done/.quotient/
      -- .remainder fields, but an inout port still creates a SOURCE for the whole
      -- record, and div_type.done is a default-less std_logic -> NVC init-time
      -- multi-source resolution makes POLY_DIV(i).done='U' forever -> gpu_poly's
      -- divider-gated states never advance -> 0 pixels (the band's 320 quads draw
      -- NOTHING). This is the SAME blocker the cold sim/gpu_replay rig hit; the fix
      -- (force the whole div_type record on each igpu_poly/igpu_line.divN port to the
      -- real divider instance outputs gdividers(i).idivider.*) is ported verbatim,
      -- re-rooted to this harness's GPU path. Pure NVC artifact; NO psx/ edit; on
      -- silicon there is no init 'U'. Without it the WHOLE garble experiment is a
      -- false negative (poly path silently emits no pixels). See gpu_replay README M5.
      FIX_POLY_DIV : boolean := true;
      -- Garble band window (display/VRAM pixel coords) the tap restricts to, so the
      -- log stays bounded to the 320-quad chain that paints the green band. Defaults
      -- = the hyperbbc GAME-OVER band (M5: display x123..378 y0..203).
      TAP_X0      : integer := 123;
      TAP_X1      : integer := 378;
      TAP_Y0      : integer := 0;
      TAP_Y1      : integer := 203;
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

      -- (1b) Option A: PRELOAD the .ss main-RAM slice into the SAME sdram_model3x at
      --      PSX physical byte 0 (TARGET=0 -> data[0..]). The FASTSIM user-load skips
      --      savetype 16 (RAM), so without this the CPU steps forward over BIOS-left
      --      garbage instead of the frozen game code/data. Independent COMMAND_FILE_
      --      START_1 handshake (the model serves one load per pulse). Byte-array
      --      model: file bytes land 1:1 at data[TARGET+i], and a main-RAM read indexes
      --      data[ram_Adr & ~1] with ram_Adr top bits "00" for phys 0 (memorymux.vhd
      --      :576/:630), so byte 0 == data[0]. The slice is the pre-carved 2 MiB
      --      ss_ram.bin (run.sh: tools/ss_vram_extract.py), loaded whole (OFFSET/SIZE=0).
      if PRELOAD_RAM = '1' then
         COMMAND_FILE_NAME    <= (others => ' ');
         COMMAND_FILE_NAME(1 to RAM_FILE'length) <= RAM_FILE;
         COMMAND_FILE_NAMELEN <= RAM_FILE'length;
         COMMAND_FILE_TARGET  <= 0;
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;        -- whole 2 MiB slice
         COMMAND_FILE_ENDIAN  <= '0';
         COMMAND_FILE_START_1 <= '1';
         wait for 200 ns;
         COMMAND_FILE_START_1 <= '0';
         wait for 5 us;                    -- 2 MiB byte-by-byte load
         report "tb_573_ssreplay: .ss main-RAM slice preloaded into SDRAM model @0";
      end if;

      -- (1c) Option A: PRELOAD the .ss VRAM slice into the ddrram_model VRAM window
      --      (TARGET=0 -> data[0..0x3FFFF] = 1024x512 RGB555 the GPU samples; see
      --      ddrram_model.vhd:359-374 dumpVRAMimage which reads data[y*512+x]). The
      --      FASTSIM user-load skips savetype 15 (VRAM), so without this the GPU draws
      --      over whatever VRAM the boot left, not the frozen scene/textures/CLUTs.
      --      The slice is the pre-carved 1 MiB ss_vram.bin (same byte layout as data[]:
      --      each 32-bit LE word = 2 RGB555 px). Loaded BEFORE the savestate-region
      --      load below (disjoint: VRAM=data[0..0x3FFFF], SS region=data[0x800000..]).
      if PRELOAD_VRAM = '1' then
         COMMAND_FILE_NAME    <= (others => ' ');
         COMMAND_FILE_NAME(1 to VRAM_FILE'length) <= VRAM_FILE;
         COMMAND_FILE_NAMELEN <= VRAM_FILE'length;
         COMMAND_FILE_TARGET  <= 0;
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;        -- whole 1 MiB slice
         COMMAND_FILE_ENDIAN  <= '0';      -- .bin is LE 32-bit words
         COMMAND_FILE_START_2 <= '1';
         wait for 16 ns;
         COMMAND_FILE_START_2 <= '0';
         wait for 3 us;
         report "tb_573_ssreplay: .ss VRAM slice preloaded into ddrram_model @0";
      end if;

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
      ram4mb                => RAM4MB,
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
   -- PER-DRAW GPU CLUT TAP (DRAWTAP='1'; Stage-1 deliverable). Via NVC external
   -- names (no DUT edit) it reads the FULL CLUT pipeline the garble hunt needs and
   -- emits, restricted to the garble band (TAP_X*/Y*), to drawtap.log:
   --
   --   OUT  rows : each pixel write -- stage6 x/y, drawMode(8:7) (color mode),
   --               CLUTaddrB(0) (the texel INDEX), CLUTDataB(0) (the CLUT-looked-up
   --               color), pixelColor (the output). For 4bpp (drawMode(8)='0')
   --               pixelColor derives from texdata_palette==CLUTDataB. The
   --               DISAMBIGUATOR: pixelColor==CLUT[index] (correct blue) vs
   --               ==index<<5 (green leak), and what CLUTDataB itself holds.
   --   CLUT rows : during the palette load (state=REQUESTPALETTE/WAITPALETTE), the
   --               LIVE cache coord textPalX/Y + textPalFetched, the request coord
   --               reqVRAMXPos/YPos (where the CLUT is read FROM), CLUTaddrA, and the
   --               vram_DOUT word being written into the CLUT RAM. This shows whether
   --               the live CLUT coord is (0,491)=0x7ac0 (blue, correct) and whether
   --               the bytes it loads are blue or a green ramp.
   --
   -- The alias paths are the SAME ones the cold gpu_replay rig (DBG_TAP8) proved,
   -- re-rooted at the full-system GPU instance
   -- .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.*. The per-i
   -- combinational CLUT arrays are tapped at the dpram INSTANCE PORTS
   -- (gfiltermemmult(0).iclutram.{address_b,q_b}) because NVC folds the arch-level
   -- array signals; run.sh passes --no-collapse to keep these names live.
   -- =======================================================================
   -- -----------------------------------------------------------------------
   -- FIX_POLY_DIV: repair the NVC inout-record 'U' poison on the shared dividers so
   -- the POLY + LINE paths render (see the FIX_POLY_DIV generic comment + the
   -- gpu_replay rig M5 root-cause). Ported verbatim from sim/gpu_replay, re-rooted to
   -- .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.*. Clean sources = the divider
   -- instance output ports gdividers(i).idivider.*; poisoned sinks = the whole
   -- div_type record on each igpu_poly/igpu_line.divN inout port. COMBINATIONAL force
   -- (the divider .done is a single clk2x pulse; a clk-gated mirror lands a cycle
   -- late and the drawer misses it). NO psx/ edit.
   -- -----------------------------------------------------------------------
   fix_div_gen : if FIX_POLY_DIV generate
      fix_div : process
         alias s0d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(0).idivider.done : std_logic >>;
         alias s0q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(0).idivider.quotient  : signed(44 downto 0) >>;
         alias s0r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(0).idivider.remainder : signed(24 downto 0) >>;
         alias s1d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(1).idivider.done : std_logic >>;
         alias s1q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(1).idivider.quotient  : signed(44 downto 0) >>;
         alias s1r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(1).idivider.remainder : signed(24 downto 0) >>;
         alias s2d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(2).idivider.done : std_logic >>;
         alias s2q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(2).idivider.quotient  : signed(44 downto 0) >>;
         alias s2r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(2).idivider.remainder : signed(24 downto 0) >>;
         alias s3d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(3).idivider.done : std_logic >>;
         alias s3q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(3).idivider.quotient  : signed(44 downto 0) >>;
         alias s3r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(3).idivider.remainder : signed(24 downto 0) >>;
         alias s4d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(4).idivider.done : std_logic >>;
         alias s4q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(4).idivider.quotient  : signed(44 downto 0) >>;
         alias s4r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(4).idivider.remainder : signed(24 downto 0) >>;
         alias s5d is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(5).idivider.done : std_logic >>;
         alias s5q is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(5).idivider.quotient  : signed(44 downto 0) >>;
         alias s5r is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.gdividers(5).idivider.remainder : signed(24 downto 0) >>;
         alias p1 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div1 : div_type >>;
         alias p2 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div2 : div_type >>;
         alias p3 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div3 : div_type >>;
         alias p4 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div4 : div_type >>;
         alias p5 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div5 : div_type >>;
         alias p6 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_poly.div6 : div_type >>;
         alias l1 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div1 : div_type >>;
         alias l2 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div2 : div_type >>;
         alias l3 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div3 : div_type >>;
         alias l4 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div4 : div_type >>;
         alias l5 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div5 : div_type >>;
         alias l6 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_line.div6 : div_type >>;
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
   -- DIAGNOSTIC CPU-PC + liveness probe (PCPROBE='1' -> pcprobe.log). Samples the
   -- CPU PC + irqRequest + GPU DMA-request every N clk1x. Used to tell a resumed,
   -- progressing CPU (PC wanders over code) from a wait-loop spin (PC parked in a
   -- few addresses = the redraw never arriving = bounded negative).
   -- -----------------------------------------------------------------------
   pcprobe_gen : if PCPROBE = '1' generate
      pcprobe : process(clk1x)
         alias a_pc    is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.icpu.PC : unsigned(31 downto 0) >>;
         alias a_irq   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.irqRequest : std_logic >>;
         alias a_gpudma is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.gpu_dmaRequest : std_logic >>;
         file     f      : text;
         variable status : FILE_OPEN_STATUS;
         variable opened : boolean := false;
         variable l      : line;
         variable cnt    : integer := 0;
         variable pv_pc  : unsigned(31 downto 0) := (others => '1');
      begin
         if rising_edge(clk1x) then
            if not opened then
               file_open(status, f, "pcprobe.log", write_mode); file_close(f);
               opened := true;
            end if;
            cnt := cnt + 1;
            if cnt >= 200 and not is_x(std_logic_vector(a_pc)) then  -- ~ every 200 clk1x
               cnt := 0;
               if a_pc /= pv_pc then
                  write(l, string'("t=")); write(l, now);
                  write(l, string'(" PC=0x")); write(l, to_hstring(a_pc));
                  write(l, string'(" irq=")); write(l, a_irq);
                  write(l, string'(" gpudma=")); write(l, a_gpudma);
                  file_open(status, f, "pcprobe.log", append_mode);
                  writeline(f, l); file_close(f);
                  pv_pc := a_pc;
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- -----------------------------------------------------------------------
   -- DIAGNOSTIC GPU/DMA-state probe (GPUPROBE='1' -> gpuprobe.log). Pins WHY the GPU
   -- renders no pixels while the CPU spins on D2_CHCR busy: taps the DMA active
   -- channel + dmaOn + DMA_GPU_waiting + gpu_dmaRequest and the GPU command-FIFO
   -- (fifoIn_Empty/Valid) + draw proc_idle. Logs on any change.
   -- -----------------------------------------------------------------------
   gpuprobe_gen : if GPUPROBE = '1' generate
      gpuprobe : process(clk1x)
         alias a_dmaOn   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.dmaOn : std_logic >>;
         alias a_gpuwait is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.DMA_GPU_waiting : std_logic >>;
         alias a_gpureq  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.gpu_dmaRequest : std_logic >>;
         alias a_actch   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.idma.activeChannel : integer range 0 to 6 >>;
         alias a_todev   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.idma.toDevice : std_logic >>;
         alias a_fEmpty  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.fifoIn_Empty : std_logic >>;
         alias a_fValid  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.fifoIn_Valid : std_logic >>;
         alias a_procidle is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.proc_idle : std_logic >>;
         alias a_procReqF is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.proc_requestFifo : std_logic >>;
         alias a_polyReqF is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.poly_requestFifo : std_logic >>;
         alias a_rectReqF is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.rect_requestFifo : std_logic >>;
         alias a_polyVR   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.poly_reqVRAMEnable : std_logic >>;
         file     f      : text;
         variable status : FILE_OPEN_STATUS;
         variable opened : boolean := false;
         variable l      : line;
         variable cnt    : integer := 0;
         variable pv     : std_logic_vector(7 downto 0) := (others => 'X');
         variable cur    : std_logic_vector(7 downto 0);
      begin
         if rising_edge(clk1x) then
            if not opened then
               file_open(status, f, "gpuprobe.log", write_mode); file_close(f);
               opened := true;
            end if;
            cur := a_dmaOn & a_gpuwait & a_gpureq & a_todev & a_fEmpty & a_fValid & a_procidle & a_procReqF;
            cnt := cnt + 1;
            if (cur /= pv or cnt >= 5000) and not is_x(cur) then
               cnt := 0; pv := cur;
               write(l, string'("t=")); write(l, now);
               write(l, string'(" dmaOn=")); write(l, a_dmaOn);
               write(l, string'(" gpuWait=")); write(l, a_gpuwait);
               write(l, string'(" gpuReq=")); write(l, a_gpureq);
               write(l, string'(" actCh=")); write(l, a_actch);
               write(l, string'(" toDev=")); write(l, a_todev);
               write(l, string'(" fifoEmpty=")); write(l, a_fEmpty);
               write(l, string'(" fifoValid=")); write(l, a_fValid);
               write(l, string'(" procIdle=")); write(l, a_procidle);
               write(l, string'(" procReqFifo=")); write(l, a_procReqF);
               write(l, string'(" polyReqFifo=")); write(l, a_polyReqF);
               write(l, string'(" rectReqFifo=")); write(l, a_rectReqF);
               write(l, string'(" polyReqVRAM=")); write(l, a_polyVR);
               file_open(status, f, "gpuprobe.log", append_mode);
               writeline(f, l); file_close(f);
            end if;
         end if;
      end process;
   end generate;

   drawtap_gen : if DRAWTAP = '1' generate
      drawtap : process(clk2x)
         -- output / per-pixel resolve side
         alias t_drawMode   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.drawMode      : unsigned(13 downto 0) >>;
         alias t_s6valid    is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.stage6_valid  : std_logic >>;
         alias t_s6x        is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.stage6_x      : unsigned(9 downto 0) >>;
         alias t_s6y        is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.stage6_y      : unsigned(8 downto 0) >>;
         alias t_pixColor   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.pixelColor    : std_logic_vector(15 downto 0) >>;
         alias t_clutAddrB0 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.address_b : std_logic_vector(7 downto 0) >>;
         alias t_clutDataB0 is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.gfiltermemmult(0).iclutram.q_b       : std_logic_vector(15 downto 0) >>;
         -- CLUT-load handshake side (the live cache coord + where it reads from).
         -- NB: the pipeline `state` enum is a local type (not aliasable across the
         -- external-name boundary); CLUTwrenA already gates the CLUT-load rows and
         -- textPalFetched reports the cache validity, so `state` is not needed.
         alias t_textPalX   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.textPalX       : unsigned(9 downto 0) >>;
         alias t_textPalY   is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.textPalY       : unsigned(8 downto 0) >>;
         alias t_textPalFet is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.textPalFetched : std_logic >>;
         alias t_reqx       is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.reqVRAMXPos    : unsigned(9 downto 0) >>;
         alias t_reqy       is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.reqVRAMYPos    : unsigned(8 downto 0) >>;
         alias t_reqsize    is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.reqVRAMSize    : unsigned(10 downto 0) >>;
         alias t_clutWrenA  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.CLUTwrenA      : std_logic >>;
         alias t_clutAddrA  is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.igpu_pixelpipeline.CLUTaddrA      : unsigned(5 downto 0) >>;
         alias t_vrdout     is << signal .tb_573_ssreplay.ipsx_mister.ipsx_top.igpu.vram_DOUT                         : std_logic_vector(63 downto 0) >>;
         file     f      : text;
         variable status : FILE_OPEN_STATUS;
         variable opened : boolean := false;
         variable l      : line;
         variable n      : integer := 0;
         variable c      : integer := 0;
         function inband(x : unsigned; y : unsigned) return boolean is
         begin
            return (to_integer(x) >= TAP_X0 and to_integer(x) <= TAP_X1 and
                    to_integer(y) >= TAP_Y0 and to_integer(y) <= TAP_Y1);
         end function;
      begin
         if rising_edge(clk2x) then
            if not opened then
               file_open(status, f, "drawtap.log", write_mode); file_close(f);
               opened := true;
            end if;

            -- CLUT-load rows: every word written into the CLUT RAM (the palette the
            -- GPU will sample). Capturing CLUTwrenA gives the EXACT CLUT contents +
            -- the coord it was read from -- the (a)-vs-(b) disambiguator data.
            if t_clutWrenA = '1' and c < 200000 and not is_x(t_vrdout) then
               write(l, string'("CLUT  t=")); write(l, now);
               write(l, string'(" reqX="));   write(l, to_integer(t_reqx));
               write(l, string'(" reqY="));   write(l, to_integer(t_reqy));
               write(l, string'(" size="));   write(l, to_integer(t_reqsize));
               write(l, string'(" addrA="));  write(l, to_integer(t_clutAddrA));
               write(l, string'(" palFetched=")); write(l, t_textPalFet);
               write(l, string'(" textPalX=")); write(l, to_integer(t_textPalX));
               write(l, string'(" textPalY=")); write(l, to_integer(t_textPalY));
               write(l, string'(" vramDOUT=0x")); write(l, to_hstring(t_vrdout));
               file_open(status, f, "drawtap.log", append_mode);
               writeline(f, l); file_close(f);
               c := c + 1;
            end if;

            -- OUT rows: each in-band pixel write -- the resolve the garble needs.
            if t_s6valid = '1' and inband(t_s6x, t_s6y) and n < 400000
               and not is_x(t_pixColor) then
               write(l, string'("OUT   t=")); write(l, now);
               write(l, string'(" x="));      write(l, to_integer(t_s6x));
               write(l, string'(" y="));      write(l, to_integer(t_s6y));
               write(l, string'(" mode="));   write(l, std_logic'image(t_drawMode(8)));
               write(l, std_logic'image(t_drawMode(7)));
               write(l, string'(" idxB=0x")); write(l, to_hstring(t_clutAddrB0));
               write(l, string'(" clutDataB=0x")); write(l, to_hstring(t_clutDataB0));
               write(l, string'(" palFetched=")); write(l, t_textPalFet);
               write(l, string'(" textPalX=")); write(l, to_integer(t_textPalX));
               write(l, string'(" textPalY=")); write(l, to_integer(t_textPalY));
               write(l, string'(" pixelColor=0x")); write(l, to_hstring(t_pixColor));
               file_open(status, f, "drawtap.log", append_mode);
               writeline(f, l); file_close(f);
               n := n + 1;
            end if;
         end if;
      end process;
   end generate;

end architecture;
