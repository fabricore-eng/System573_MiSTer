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
      -- PRELOAD_COPY ('1', FAST_BOOT path): pre-stage the BIOS->RAM relocation that the
      -- boot ROM performs uncached at 0xBFC004D4 (copies BIOS file 0x10000..0x19000 ->
      -- main-RAM byte 0x500..0x9500, then `jr` to 0xA0000500). That 0x9000-byte uncached
      -- copy (~9216 word reads+writes) is the dominant sim bottleneck once the RAM-test/
      -- BSS shortcuts are in. With PRELOAD_COPY='1' the tb loads that exact slice into
      -- main RAM (region-0 byte 0x500) via a 2nd COMMAND_FILE pass, and run.sh's FAST_BOOT
      -- NOPs the copy LOOP branch (0x4E4) so the boot ROM skips the slow copy and `jr`s
      -- straight into the (now-already-present) relocated code. The two MUST be enabled
      -- together (run.sh ties both to FAST_BOOT). Sim-only; the .rbf runs the real copy.
      PRELOAD_COPY     : std_logic := '0';
      PRELOAD_OFFSET   : integer   := 16#10000#;   -- file bytes skipped (copy source)
      PRELOAD_SIZE     : integer   := 16#9000#;     -- bytes copied
      PRELOAD_TARGET   : integer   := 16#500#;      -- main-RAM (region 0) dest byte
      -- PRELOAD_EXE (tied to PRELOAD_COPY/FAST_BOOT): also pre-stage the PS-X EXE body the
      -- boot ROM copies BYTE-BY-BYTE at 0xBFC20230 (file 0x40800, 0x11000 bytes -> RAM
      -- 0x803c0000, i.e. region-0 byte 0x3c0000) -- ~69632 uncached iterations, the single
      -- largest barrier to reaching the EXE's GX700 self-test / ATAPI drive check. run.sh
      -- NOPs that copy loop (0x20244) so the boot jalr's straight into the EXE entry
      -- (0x803c296c) with the code already present. Sim-only; the .rbf runs the real copy.
      EXE_OFFSET       : integer   := 16#40800#;    -- EXE body file offset (after 0x800 header)
      EXE_SIZE         : integer   := 16#11000#;    -- EXE body bytes
      EXE_TARGET       : integer   := 16#3C0000#;   -- main-RAM (region 0) dest byte (=0x803c0000)
      -- 573 has 4 MB RAM; the core natively decodes 2 MB ('0') or 8 MB ('1'). Overridable
      -- from run.sh. The shipping config is RAM8MB='1' + RAM4MB='1' (below).
      RAM8MB      : std_logic := '1';
      -- 4 MB main-RAM mask on top of the 8 MB decode (psx_patches/0022) -- matches the
      -- .rbf (emu.sv S573_RAM4MB=1). '0' = the old (wrong) 8 MB linear decode.
      RAM4MB      : std_logic := '1';
      -- Sim accelerator (TURBO_MEM/COMP/CACHE). '1' speeds bring-up; set '0' (TURBO=0 in
      -- run.sh) to confirm the integration under realistic memory/cache/DMA timing.
      TURBO       : std_logic := '1';
      -- VRAM (DDR) model read latency, in cycles, for the GPU's VRAM path. The boot
      -- spins on GPUSTAT bit 28 (GPU "ready to receive DMA" = command-FIFO empty), which
      -- drains only as fast as the GPU executes commands against VRAM -- so a slow VRAM
      -- model lengthens those waits and the whole drawing path. run.sh defaults this to 0
      -- (near-instant VRAM) for bring-up speed; set SLOWVRAM=15 for the realistic-timing
      -- confirmation. Sim-model only (ddrram_model is a tb model, never in the .rbf).
      SLOWVRAM    : integer := 15;
      -- IRQ10 INJECTION (ATAPI-INTRQ emulation for the interrupt-delivery probe).
      -- The full-system harness has no Verilog ATAPI device (NVC can't co-sim Verilog),
      -- so to test whether an ATAPI interrupt actually reaches+vectors the integrated CPU
      -- we self-arm a clean exp_irq10 pulse: the injector watches I_MASK bit10 inside the
      -- core's irq.vhd and, INJECT_DELAY after it first sees bit10 UNMASKED (= the BIOS has
      -- enabled IRQ10, exactly as it does right before the drive-check IDENTIFY wait),
      -- raises exp_irq10 for INJECT_WIDTH then drops it -- the same clean 0->1->0 edge the
      -- edge-guaranteed atapi.intrq produces (commit dd76ade). The irq_probe process then
      -- captures the full delivery chain. INJECT=1 enables; '0' keeps the legacy behaviour
      -- (exp_irq10 held low, no injection). Sim-only; never in the .rbf.
      INJECT       : std_logic := '0';
      INJECT_DELAY : time      := 5 us;    -- after I_MASK(10) first seen unmasked
      INJECT_WIDTH : time      := 3 us;    -- INTRQ-high window (many clk1x wide, like HW)
      -- INJECT_AT > 0 ns: TIME-based injection mode. Fire the exp_irq10 pulse at this
      -- absolute sim time regardless of I_MASK (used when the BIOS never reaches its own
      -- IRQ-unmask in the simulable boot window -- it lets us still observe the integrated
      -- delivery HARDWARE: exp_irq10 -> LIGHTPEN -> irqIn -> I_STATUS bit10 latch ->
      -- irqRequest, which is independent of I_MASK). Two pulses INJECT_WIDTH apart test
      -- the edge re-arm. INJECT_AT=0 ns keeps the I_MASK self-arming mode above.
      INJECT_AT    : time      := 0 ns;
      -- ATAPI_EMU ('1'): make the behavioral EXP1 responder MIRROR rtl/atapi.v's register
      -- interface for the ATAPI page (0x48xxxx) + IDE-reset (0x56) so the full-system sim
      -- runs the REAL BIOS GX700 drive check against atapi.v-equivalent responses (NVC can
      -- co-sim only VHDL, not the Verilog atapi.v). It reproduces: the 0xEB14 signature
      -- task-file, STATUS/ERROR/byte-count regs, the A0 PACKET + A1 IDENTIFY + the data-in
      -- commands (TUR/INQUIRY/READCAP/REQSENSE/READTOC/MODESENSE), and -- crucially --
      -- drives exp_irq10 (ATAPI INTRQ, edge-guaranteed like atapi.v's irq_out) so we can
      -- observe whether the integrated IRQ10/ISR path services the drive check. Default '0'
      -- (legacy: ATAPI reads return 0). With INJECT=1 this is ignored (INJECT owns
      -- exp_irq10). Sim-only; the .rbf uses the real atapi.v.
      ATAPI_EMU    : std_logic := '0';
      -- MIRRORTEST ('1'): 4 MB main-RAM mirror red/green checker (psx_patches/0022).
      -- The 573 has 4 MB main RAM (MAME ksys573.cpp "4M"); MAME masks every DMA RAM
      -- access with n_adrmask = ramsize-1 = 0x3fffff (cpu/psx/dma.cpp) and the BIOS
      -- RAM_SIZE config 0xC gives the CPU a 4 MB window (psx.cpp update_ram_config).
      -- Run with a tiny probe ROM (sim/system573/run_ram_mirror.sh generates it; NOT
      -- the Konami BIOS) that (a) CPU-writes through the +4 MB alias 0xA0400000 and
      -- reads back at base, (b) CPU-reads through the alias what was written at base,
      -- (c) runs an OTC DMA (ch6) clear with MADR pointed at the alias -- then stores
      -- the three observed values to RAM 0x100/0x104/0x108 and a done flag to 0x10C.
      -- The checker spies those stores on the ram bus and FAILS the sim unless all
      -- three round-tripped through the 4 MB mask. Sim-only; never in the .rbf.
      MIRRORTEST   : std_logic := '0'
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
   -- exp_irq10 (ATAPI INTRQ into the core) is driven from two mutually-exclusive sim
   -- sources: the INJECT probe (inject_irq10) and the ATAPI_EMU responder (atapi_irq10).
   -- Concurrent OR so each process drives only its own signal (no multiple-driver clash).
   signal exp_irq10      : std_logic := '0';
   signal inject_irq10   : std_logic := '0';
   signal atapi_irq10    : std_logic := '0';

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

   -- ATAPI INTRQ into the core = INJECT pulse OR ATAPI_EMU drive (mutually exclusive).
   exp_irq10 <= inject_irq10 or atapi_irq10;

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

      -- FAST_BOOT preload: stage the BIOS->RAM relocation slice into main RAM so the
      -- boot ROM can skip its slow uncached copy loop (run.sh NOPs the 0x4E4 branch).
      -- Same handshake as the BIOS load, but into region-0 RAM at PRELOAD_TARGET with
      -- OFFSET/SIZE selecting the copied source slice.
      if PRELOAD_COPY = '1' then
         COMMAND_FILE_NAME    <= (others => ' ');
         COMMAND_FILE_NAME(1 to BIOS_FILE'length) <= BIOS_FILE;
         COMMAND_FILE_NAMELEN <= BIOS_FILE'length;
         COMMAND_FILE_TARGET  <= PRELOAD_TARGET;
         COMMAND_FILE_OFFSET  <= PRELOAD_OFFSET;
         COMMAND_FILE_SIZE    <= PRELOAD_SIZE;
         COMMAND_FILE_ENDIAN  <= '0';
         COMMAND_FILE_START_1 <= '1';
         wait for 200 ns;
         COMMAND_FILE_START_1 <= '0';
         COMMAND_FILE_OFFSET  <= 0;       -- restore defaults
         COMMAND_FILE_SIZE    <= 0;
         wait for 1 us;
         report "tb_system573: FAST_BOOT preload of BIOS->RAM copy slice done";

         -- and the PS-X EXE body (file 0x40800 -> RAM 0x3c0000), so the boot ROM can skip
         -- its 0x11000-byte byte-wise copy (run.sh NOPs the 0x20244 loop branch) and jalr
         -- straight into the EXE entry 0x803c296c with the drive-check code present.
         COMMAND_FILE_NAME    <= (others => ' ');
         COMMAND_FILE_NAME(1 to BIOS_FILE'length) <= BIOS_FILE;
         COMMAND_FILE_NAMELEN <= BIOS_FILE'length;
         COMMAND_FILE_TARGET  <= EXE_TARGET;
         COMMAND_FILE_OFFSET  <= EXE_OFFSET;
         COMMAND_FILE_SIZE    <= EXE_SIZE;
         COMMAND_FILE_ENDIAN  <= '0';
         COMMAND_FILE_START_1 <= '1';
         wait for 200 ns;
         COMMAND_FILE_START_1 <= '0';
         COMMAND_FILE_OFFSET  <= 0;
         COMMAND_FILE_SIZE    <= 0;
         wait for 1 us;
         report "tb_system573: FAST_BOOT preload of PS-X EXE body done";
      end if;

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

      -- ==== ATAPI_EMU state (mirrors rtl/atapi.v; see that file for the contract) ====
      -- task-file registers (8-bit each). reg index = exp1_addr(3 downto 1) for IDE0.
      variable r_error   : std_logic_vector(7 downto 0) := x"01";
      variable r_ireason : std_logic_vector(7 downto 0) := x"01";
      variable r_lbalo   : std_logic_vector(7 downto 0) := x"01";
      variable r_bclo    : std_logic_vector(7 downto 0) := x"14";   -- 0xEB14 signature
      variable r_bchi    : std_logic_vector(7 downto 0) := x"EB";
      variable r_device  : std_logic_vector(7 downto 0) := x"00";
      variable r_status  : std_logic_vector(7 downto 0) := x"00";
      variable r_feat    : std_logic_vector(7 downto 0) := x"00";
      variable r_devctl  : std_logic_vector(7 downto 0) := x"00";
      -- ATAPI state machine: 0=IDLE 1=PKT 2=DATAIN 3=DATAOUT
      variable atstate   : integer := 0;
      variable pkt0      : std_logic_vector(7 downto 0) := x"00";  -- first packet byte (opcode)
      variable pkt_idx   : integer := 0;
      variable resp_len  : integer := 0;
      variable ridx      : integer := 0;
      variable resp_cmd  : std_logic_vector(7 downto 0) := x"00";
      variable irq_pending : std_logic := '0';
      variable irq_event   : std_logic := '0';
      variable irq_out_v   : std_logic := '0';
      variable areg      : integer;        -- decoded register index
      variable is_ide0   : boolean;
      variable is_ide1   : boolean;
      variable is_iderst : boolean;
      variable is_atapi  : boolean;
      -- status bits
      constant ST_BSY : std_logic_vector(7 downto 0) := x"80";
      constant ST_DRDY: std_logic_vector(7 downto 0) := x"40";
      constant ST_DSC : std_logic_vector(7 downto 0) := x"10";
      constant ST_DRQ : std_logic_vector(7 downto 0) := x"08";
      constant ST_ERR : std_logic_vector(7 downto 0) := x"01";
      constant IR_CD  : std_logic_vector(7 downto 0) := x"01";
      constant IR_IO  : std_logic_vector(7 downto 0) := x"02";

      procedure set_signature is
      begin
         r_ireason := x"01"; r_lbalo := x"01";
         r_bclo := x"14"; r_bchi := x"EB";
         r_device := x"00"; r_status := x"00"; r_error := x"01";
      end procedure;

      -- ident_word(word index) per atapi.v: word0 = 0x85C0, else 0.
      impure function ident_word(widx : integer) return std_logic_vector is
      begin
         if widx = 0 then return x"85C0"; else return x"0000"; end if;
      end function;

      -- resp_byte ROM for the fixed data-in commands (mirrors atapi.v resp_byte).
      impure function resp_byte(cmd : std_logic_vector(7 downto 0); k : integer) return std_logic_vector is
      begin
         case cmd is
            when x"12" =>  -- INQUIRY (36): 0x05,0x80,_,0x21,0x1f,..,"KONAMI".."573".."1.00"
               case k is
                  when 0 => return x"05"; when 1 => return x"80"; when 3 => return x"21"; when 4 => return x"1F";
                  when 8 => return x"4B"; when 9 => return x"4F"; when 10 => return x"4E";
                  when 11 => return x"41"; when 12 => return x"4D"; when 13 => return x"49";
                  when 16 => return x"35"; when 17 => return x"37"; when 18 => return x"33";
                  when 32 => return x"31"; when 33 => return x"2E"; when 34 => return x"30"; when 35 => return x"30";
                  when others =>
                     if (k >= 14 and k <= 15) or (k >= 19 and k <= 31) then return x"20"; else return x"00"; end if;
               end case;
            when x"25" =>  -- READ CAPACITY (8)
               case k is when 1 => return x"01"; when 2 => return x"23"; when 3 => return x"44"; when 6 => return x"08"; when others => return x"00"; end case;
            when x"03" =>  -- REQUEST SENSE (16): code 0x70, key 0
               case k is when 0 => return x"70"; when 7 => return x"0A"; when others => return x"00"; end case;
            when x"43" =>  -- READ TOC (12)
               case k is when 1 => return x"0A"; when 2 => return x"01"; when 3 => return x"01"; when 5 => return x"14"; when 6 => return x"01"; when others => return x"00"; end case;
            when x"5A" =>  -- MODE SENSE(10) page 0x0E (24)
               case k is when 1 => return x"16"; when 8 => return x"0E"; when 9 => return x"0E"; when 10 => return x"04"; when 15 => return x"4B";
                              when 16 => return x"01"; when 17 => return x"FF"; when 18 => return x"02"; when 19 => return x"FF"; when others => return x"00"; end case;
            when others => return x"00";
         end case;
      end function;

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

         -- ATAPI page decode (mirrors rtl/s573_bus.v + system573_top.v atapi_addr).
         is_ide0   := (exp1_addr(23 downto 16) = x"48");
         is_ide1   := (exp1_addr(23 downto 16) = x"4C");
         is_iderst := (exp1_addr(23 downto 16) = x"56");
         is_atapi  := (ATAPI_EMU = '1') and (is_ide0 or is_ide1 or is_iderst);
         -- register index: IDE0 = exp1_addr(3:1); IDE1 (control block) = 8.
         if is_ide1 then areg := 8;
         elsif is_ide0 then areg := to_integer(unsigned(exp1_addr(3 downto 1)));
         else areg := 0; end if;

         -- ===== ATAPI_EMU clocked logic (mirrors atapi.v always @(posedge clk)) =====
         if ATAPI_EMU = '1' then
            irq_event := '0';                              -- default each clk
            -- edge-guaranteed INTRQ (atapi.v irq_out)
            if irq_pending = '0' then
               irq_out_v := '0';
            elsif (irq_event = '1') and (irq_out_v = '1') then
               irq_out_v := '0';
            else
               irq_out_v := '1';
            end if;

            -- IDE reset (write to 0x56 page) -> set_signature, like atapi.v ide_rst.
            if is_iderst and exp1_we = '1' then
               atstate := 0; pkt_idx := 0; ridx := 0; resp_len := 0;
               irq_pending := '0'; irq_event := '0'; irq_out_v := '0';
               set_signature;
            end if;

            -- register WRITE
            if (is_ide0 or is_ide1) and exp1_we = '1' then
               case areg is
                  when 0 =>
                     if atstate = 1 then                    -- packet bytes (S_PKT)
                        if pkt_idx = 0 then pkt0 := exp1_dataWrite(7 downto 0); end if;
                        pkt_idx := pkt_idx + 2;
                        if pkt_idx = 12 then                 -- full 12-byte packet
                           pkt_idx := 0;
                           case pkt0 is
                              when x"00" =>                  -- TEST UNIT READY
                                 r_status := ST_DRDY or ST_DSC; r_ireason := IR_CD or IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 0;
                              when x"12" => resp_cmd := x"12"; resp_len := 36; r_bclo := x"24"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 2;
                              when x"25" => resp_cmd := x"25"; resp_len := 8; r_bclo := x"08"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 2;
                              when x"03" => resp_cmd := x"03"; resp_len := 16; r_bclo := x"10"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 2;
                              when x"43" => resp_cmd := x"43"; resp_len := 12; r_bclo := x"0C"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 2;
                              when x"5A" => resp_cmd := x"5A"; resp_len := 24; r_bclo := x"18"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 2;
                              when x"55" => resp_cmd := x"55"; resp_len := 24; r_bclo := x"18"; r_bchi := x"00";
                                 ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := x"00"; r_error := x"00";
                                 irq_pending := '1'; irq_event := '1'; atstate := 3;
                              when others =>                 -- unsupported -> CHECK CONDITION
                                 r_status := ST_DRDY or ST_ERR; r_error := x"50"; r_ireason := IR_CD or IR_IO;
                                 irq_pending := '1'; irq_event := '1'; atstate := 0;
                           end case;
                        end if;
                     elsif atstate = 3 then                  -- MODE SELECT data-OUT
                        if (ridx + 2) >= resp_len then
                           r_status := ST_DRDY or ST_DSC; r_ireason := IR_CD or IR_IO; r_error := x"00";
                           irq_pending := '1'; irq_event := '1'; atstate := 0;
                        else ridx := ridx + 2; end if;
                     end if;
                  when 1 => r_feat    := exp1_dataWrite(7 downto 0);
                  when 2 => r_ireason := exp1_dataWrite(7 downto 0);
                  when 3 => r_lbalo   := exp1_dataWrite(7 downto 0);
                  when 4 => r_bclo    := exp1_dataWrite(7 downto 0);
                  when 5 => r_bchi    := exp1_dataWrite(7 downto 0);
                  when 6 => r_device  := exp1_dataWrite(7 downto 0);
                  when 7 =>                                  -- command register
                     irq_pending := '0';
                     case exp1_dataWrite(7 downto 0) is
                        when x"A0" => r_status := ST_DRQ; r_ireason := IR_CD; pkt_idx := 0; atstate := 1;
                        when x"A1" => resp_len := 512; r_bclo := x"00"; r_bchi := x"02";
                           ridx := 0; r_status := ST_DRDY or ST_DRQ; r_ireason := IR_IO; r_error := x"00";
                           resp_cmd := x"A1";
                           irq_pending := '1'; irq_event := '1'; atstate := 2;
                        when x"08" => set_signature; atstate := 0;     -- DEVICE RESET
                        when others => r_status := ST_DRDY or ST_ERR; r_error := x"04";
                           irq_pending := '1'; irq_event := '1'; atstate := 0;
                     end case;
                  when 8 =>                                  -- device control
                     if (r_devctl(2) = '1') and (exp1_dataWrite(2) = '0') then set_signature; end if;
                     r_devctl := exp1_dataWrite(7 downto 0);
                  when others => null;
               end case;
            end if;
         end if;

         -- READ: ATAPI page returns the atapi.v read mux (when ATAPI_EMU); the Konami ASIC
         -- 18E status nibble at 0x1f400004[7:4]=0xC; benign 0 elsewhere.
         if exp1_re = '1' then
            if is_atapi then
               -- read mux (mirrors atapi.v): reg index areg
               case areg is
                  when 0 =>
                     if atstate /= 2 then rdata := x"0000";
                     elsif resp_cmd = x"A1" then rdata := ident_word(ridx / 2);
                     else rdata := resp_byte(resp_cmd, ridx + 1) & resp_byte(resp_cmd, ridx); end if;
                  when 1 => rdata := x"00" & r_error;
                  when 2 => rdata := x"00" & r_ireason;
                  when 3 => rdata := x"00" & r_lbalo;
                  when 4 => rdata := x"00" & r_bclo;
                  when 5 => rdata := x"00" & r_bchi;
                  when 6 => rdata := x"00" & r_device;
                  when 7 => rdata := x"00" & r_status;
                  when 8 => rdata := x"00" & r_status;       -- alternate status
                  when others => rdata := x"0000";
               end case;
               -- read side effects (mirrors atapi.v): reg7 clears INTRQ; data-in advances.
               if areg = 7 then irq_pending := '0'; end if;
               if (areg = 0) and (atstate = 2) then
                  if (ridx + 2) >= resp_len then
                     r_status := ST_DRDY or ST_DSC; r_ireason := IR_CD or IR_IO;
                     irq_pending := '1'; irq_event := '1'; atstate := 0;
                  else ridx := ridx + 2; end if;
               end if;
            elsif exp1_addr(23 downto 16) = x"40" and exp1_addr(3 downto 0) = x"4" then
               rdata := x"00C0";              -- 18E H8 response nibble
            else
               rdata := (others => '0');
            end if;
            exp1_dataRead <= rdata;        -- registered, held until next read
            write(l, string'("EXP1 RE  addr=0x")); put_hex(l, exp1_addr);
            write(l, string'(" rdata=0x"));        put_hex(l, rdata);
            wrote := true;
         end if;

         -- drive the ATAPI INTRQ wire (atapi.v: intrq = irq_out & ~nIEN(devctl[1])).
         if ATAPI_EMU = '1' then
            if (irq_out_v = '1') and (r_devctl(1) = '0') then atapi_irq10 <= '1';
            else atapi_irq10 <= '0'; end if;
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
   -- MIRRORTEST checker (generic-gated; see the MIRRORTEST generic comment).
   -- Spies CPU stores on the ram bus (region "00" = main RAM) for the probe
   -- ROM's three result cells + done flag, then renders a PASS/FAIL verdict:
   --   0x100 expect 0x3C3C7E7E  (CPU write via +4MB alias, read back at base)
   --   0x104 expect 0x12348765  (CPU write at base, read back via the alias)
   --   0x108 expect 0x00FFFFFF  (OTC DMA end marker, MADR pointed at the alias)
   -- On the unfixed 8 MB-linear decode (ram8mb=1, no 4 MB mask) the alias
   -- accesses land at SDRAM 0x4xxxxx instead, so 0x100 reads back the base
   -- sentinel 0xAAAA5555 and 0x104/0x108 read zero-init RAM -> FAIL (RED).
   -- -----------------------------------------------------------------------
   gmirror : if MIRRORTEST = '1' generate
      signal mirror_done : std_logic := '0';
   begin
      mirror_check : process(clk1x)
         variable r1, r2, r3 : std_logic_vector(31 downto 0) := (others => '0');
         variable adr        : integer;
      begin
         if rising_edge(clk1x) then
            if ram_ena = '1' and ram_rnw = '0' and ram_Adr(24 downto 23) = "00" then
               adr := to_integer(unsigned(ram_Adr(22 downto 0)));
               case adr is
                  when 16#100# => r1 := ram_dataWrite;
                  when 16#104# => r2 := ram_dataWrite;
                  when 16#108# => r3 := ram_dataWrite;
                  when 16#10C# =>
                     mirror_done <= '1';
                     report "MIRRORTEST results: cpu_wr_via_alias=0x" & to_hstring(r1) &
                            " cpu_rd_via_alias=0x" & to_hstring(r2) &
                            " otc_dma_via_alias=0x" & to_hstring(r3);
                     if r1 = x"3C3C7E7E" and r2 = x"12348765" and r3 = x"00FFFFFF" then
                        report "MIRRORTEST PASS: 4 MB main-RAM mirror active (CPU + DMA mask 0x3fffff)";
                        std.env.finish;
                     else
                        assert false
                           report "MIRRORTEST FAIL: 4 MB mirror NOT active " &
                                  "(expected 0x3C3C7E7E/0x12348765/0x00FFFFFF; " &
                                  "got 0x" & to_hstring(r1) & "/0x" & to_hstring(r2) &
                                  "/0x" & to_hstring(r3) & ")"
                           severity failure;
                     end if;
                  when others => null;
               end case;
            end if;
         end if;
      end process;

      mirror_watchdog : process
      begin
         wait for 400 us;
         assert mirror_done = '1'
            report "MIRRORTEST TIMEOUT: probe ROM never wrote the done flag (0x10C)"
            severity failure;
         wait;
      end process;
   end generate;

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
      ram4mb                => RAM4MB,
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
      exp1_wait             => '0',   -- NVC harness has no flash backing: never stall
      exp_irq10             => exp_irq10,
      -- 573 ATAPI CD-ROM on DMA channel 5 (psx_patches/0023). This boot harness does not
      -- exercise the CD-DMA datapath, so tie the inputs off and leave the read-enable open;
      -- the real .rbf wires these to atapi.v (DMAREQ / DMA ch5 read strobe + data).
      atapi_dmaRequest      => '0',
      DMA_ATA_readEna       => open,
      DMA_ATA_read          => (others => '0'),
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
      variable halt_logged : integer := 0;
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
            if (cpu_pc /= prev + 4) and (logged < 400000) then
               write(l, string'("PC=0x")); put_hex8(l, cpu_pc); writeline(pf, l);
               logged := logged + 1;
               file_close(pf); file_open(status, pf, "pc_trace.log", append_mode);
            end if;
            -- HALT-CAPTURE: the boot parks in the j-self loop at 0x9FC20190 (a panic/
            -- error halt landing). Capture the EXACT predecessor PC (the jump source)
            -- the first few times we enter it, so we can see who jumped there even after
            -- the normal cap fills. (prev still holds the PC we came FROM.)
            if (cpu_pc = x"9FC20190") and (halt_logged < 8) then
               write(l, string'(">>> HALT-ENTER 0x9FC20190 from prevPC=0x")); put_hex8(l, prev);
               write(l, string'(" at cnt=")); write(l, cnt); writeline(pf, l);
               file_close(pf); file_open(status, pf, "pc_trace.log", append_mode);
               halt_logged := halt_logged + 1;
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

   -- =======================================================================
   -- ATAPI-INTRQ injector (INJECT=1). Self-arms on the core's I_MASK bit10:
   -- it taps irq.vhd I_MASK via an NVC external name, and INJECT_DELAY after
   -- the FIRST cycle it sees bit10 unmasked (= the BIOS enabled IRQ10), it
   -- drives a clean exp_irq10 pulse (0->1, hold INJECT_WIDTH, ->0) -- the
   -- registered, edge-guaranteed shape atapi.intrq produces on HW. This is
   -- the only driver of exp_irq10; with INJECT=0 it leaves it at its '0'
   -- initial value (legacy behaviour). The whole point: drive the SAME wire
   -- the real EXP1/atapi path drives (psx_top:1207 maps exp_irq10->LIGHTPEN)
   -- and watch whether the integrated CPU vectors+services it.
   -- =======================================================================
   irq_inject : process
      alias imask is
         << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_MASK : unsigned(31 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable l      : line;
   begin
      if INJECT /= '1' then
         inject_irq10 <= '0';
         wait;                            -- park; never inject
      end if;
      inject_irq10 <= '0';

      if INJECT_AT > 0 ns then
         -- TIME-based mode: fire at INJECT_AT regardless of I_MASK, then a 2nd pulse to
         -- exercise the rising-edge RE-ARM (the dd76ade concern). Observes the integrated
         -- delivery HARDWARE even when the BIOS hasn't unmasked IRQ10 in the sim window.
         wait for INJECT_AT;
         for k in 1 to 2 loop
            wait until rising_edge(clk1x);
            inject_irq10 <= '1';
            file_open(status, f, "irq_probe.log", append_mode);
            write(l, string'("[inject#")); write(l, k);
            write(l, string'("] exp_irq10 <= '1' (INTRQ) at ")); write(l, now);
            writeline(f, l); file_close(f);
            wait for INJECT_WIDTH;
            wait until rising_edge(clk1x);
            inject_irq10 <= '0';
            file_open(status, f, "irq_probe.log", append_mode);
            write(l, string'("[inject#")); write(l, k);
            write(l, string'("] exp_irq10 <= '0' (INTRQ off) at ")); write(l, now);
            writeline(f, l); file_close(f);
            wait for INJECT_WIDTH;             -- low gap before the re-arm pulse
         end loop;
         wait;
      end if;

      -- I_MASK self-arming mode (used if the BIOS reaches its own IRQ10 unmask).
      loop
         wait until rising_edge(clk1x);
         exit when imask(10) = '1';
      end loop;
      file_open(status, f, "irq_probe.log", append_mode);
      write(l, string'("[inject] I_MASK bit10 UNMASKED at ")); write(l, now);
      write(l, string'("; scheduling exp_irq10 pulse in ")); write(l, INJECT_DELAY);
      writeline(f, l); file_close(f);

      wait for INJECT_DELAY;
      wait until rising_edge(clk1x);
      inject_irq10 <= '1';                   -- ATAPI INTRQ asserted
      file_open(status, f, "irq_probe.log", append_mode);
      write(l, string'("[inject] exp_irq10 <= '1' (INTRQ asserted) at ")); write(l, now);
      writeline(f, l); file_close(f);

      wait for INJECT_WIDTH;
      wait until rising_edge(clk1x);
      inject_irq10 <= '0';                   -- ISR reg7 read would drop it
      file_open(status, f, "irq_probe.log", append_mode);
      write(l, string'("[inject] exp_irq10 <= '0' (INTRQ deasserted) at ")); write(l, now);
      writeline(f, l); file_close(f);
      wait;
   end process;

   -- =======================================================================
   -- INTERRUPT-DELIVERY PROBE. Around the injection window, captures the full
   -- chain the task asks for, on every clk1x edge where SOMETHING relevant
   -- changes (edge-triggered logging keeps the file small but complete):
   --   (1) exp_irq10 / irq_LIGHTPEN          -- does the rise reach the core?
   --   (2) irq.vhd irqIn(10)/irqIn_1(10), I_STATUS bit10, I_MASK bit10,
   --       irqRequest                        -- does bit10 LATCH and request?
   --   (3) CPU cop0_SR / cop0_CAUSE / cop0_EPC / exception / pc / FetchAddr
   --       -- does the CPU VECTOR (pc -> 0x80000080) and is IP10 set in CAUSE?
   -- All via NVC external names (observability only; no DUT change). Logged to
   -- irq_probe.log; flushed per line so it survives a forced --stop-time stop.
   -- =======================================================================
   irq_probe : process(clk1x)
      alias p_lightpen is << signal .tb_system573.ipsx_mister.ipsx_top.irq_LIGHTPEN : std_logic >>;
      alias p_istatus  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_STATUS : unsigned(10 downto 0) >>;
      alias p_imask    is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_MASK   : unsigned(31 downto 0) >>;
      alias p_irqin    is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.irqIn    : unsigned(10 downto 0) >>;
      alias p_irqin1   is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.irqIn_1  : unsigned(10 downto 0) >>;
      alias p_irqreq   is << signal .tb_system573.ipsx_mister.ipsx_top.irqRequest    : std_logic >>;
      alias p_sr       is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_SR    : unsigned(31 downto 0) >>;
      alias p_cause    is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_CAUSE : unsigned(31 downto 0) >>;
      alias p_epc      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_EPC   : unsigned(31 downto 0) >>;
      alias p_exc      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exception  : unsigned(4 downto 0) >>;
      alias p_pc       is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc         : unsigned(31 downto 0) >>;
      alias p_fetch    is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.FetchAddr  : unsigned(31 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable armed  : boolean := false;  -- start verbose logging when INTRQ rises
      variable done_n : integer := 0;      -- bound the verbose window
      -- previous values for edge detection
      variable pv_lp, pv_req : std_logic := '0';
      variable pv_st10, pv_msk10 : std_logic := '0';
      variable pv_exc  : unsigned(4 downto 0) := (others => '0');
      variable pv_pc   : unsigned(31 downto 0) := (others => '1');
      variable pv_sr   : unsigned(31 downto 0) := (others => '0');
      variable pv_cause: unsigned(31 downto 0) := (others => '0');
      variable sentinel_seen : boolean := false;
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
      procedure emit(variable ln : inout line) is
      begin
         file_open(status, f, "irq_probe.log", append_mode);
         writeline(f, ln); file_close(f);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "irq_probe.log", write_mode); file_close(f);
            opened := true;
         end if;

         -- arm verbose logging once INTRQ first rises into the core
         if (p_lightpen = '1') and not armed then
            armed := true;
         end if;

         if armed and done_n < 4000 and not is_x(std_logic_vector(p_pc)) then
            -- log any change in the watched chain
            if (p_lightpen /= pv_lp) or (p_irqreq /= pv_req)
               or (p_istatus(10) /= pv_st10) or (p_imask(10) /= pv_msk10)
               or (p_exc /= pv_exc) or (p_pc /= pv_pc)
               or (p_sr /= pv_sr) or (p_cause /= pv_cause) then
               write(l, string'("t=")); write(l, now);
               write(l, string'(" LP="));  write(l, p_lightpen);
               write(l, string'(" St10=")); write(l, p_istatus(10));
               write(l, string'(" Mk10=")); write(l, p_imask(10));
               write(l, string'(" in10=")); write(l, p_irqin(10));
               write(l, string'(" in1_10=")); write(l, p_irqin1(10));
               write(l, string'(" req=")); write(l, p_irqreq);
               write(l, string'(" exc=")); write(l, to_integer(p_exc));
               write(l, string'(" SR=0x"));    hx8(l, p_sr);
               write(l, string'(" CAUSE=0x")); hx8(l, p_cause);
               write(l, string'(" EPC=0x"));   hx8(l, p_epc);
               write(l, string'(" PC=0x"));    hx8(l, p_pc);
               write(l, string'(" Fetch=0x")); hx8(l, p_fetch);
               emit(l);
               done_n := done_n + 1;
            end if;
            -- explicit vector hit
            if (p_pc = x"80000080") and (pv_pc /= x"80000080") then
               write(l, string'(">>> CPU VECTORED to 0x80000080 (exception entry) at ")); write(l, now);
               emit(l);
            end if;
            pv_lp := p_lightpen; pv_req := p_irqreq;
            pv_st10 := p_istatus(10); pv_msk10 := p_imask(10);
            pv_exc := p_exc; pv_pc := p_pc; pv_sr := p_sr; pv_cause := p_cause;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- IRQTAKE PROBE (spurious-IRQ classifier). Independent of lightpen/INJECT
   -- so it works on the bare POST timer path. Catches the exact cycle the CPU
   -- DECIDES to take an interrupt (icpu.exceptionNew5 = the IRQ-take strobe at
   -- cpu.vhd:713) and, separately, every RISING and FALLING edge of the core's
   -- combinational irqRequest. At each it dumps the FULL irq.vhd state
   -- (I_STATUS all 11 bits, I_MASK low 11, irqIn, irqIn_1, irqRequest) plus the
   -- COP0 take inputs (cop0_CAUSE/SR/EPC, blockirq) and PC. This is exactly the
   -- evidence the task asks for: does irqRequest assert while I_STATUS=0 (=> a
   -- stale latch / COP0-ordering bug) or is I_STATUS genuinely set at the take
   -- (=> a real pending source the kernel ISR can't find). Observability only
   -- (NVC external names); written to irqtake.log, flushed per line.
   -- =======================================================================
   irqtake_probe : process(clk1x)
      alias q_istatus is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_STATUS : unsigned(10 downto 0) >>;
      alias q_imask   is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_MASK   : unsigned(31 downto 0) >>;
      alias q_irqin   is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.irqIn    : unsigned(10 downto 0) >>;
      alias q_irqin1  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.irqIn_1  : unsigned(10 downto 0) >>;
      alias q_irqreq  is << signal .tb_system573.ipsx_mister.ipsx_top.irqRequest    : std_logic >>;
      alias q_take5   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionNew5 : std_logic >>;
      alias q_block   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.blockirq  : std_logic >>;
      alias q_sr      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_SR    : unsigned(31 downto 0) >>;
      alias q_cause   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_CAUSE : unsigned(31 downto 0) >>;
      alias q_epc     is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_EPC   : unsigned(31 downto 0) >>;
      alias q_pc      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc         : unsigned(31 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable n_take : integer := 0;
      variable n_edge : integer := 0;
      variable pv_req : std_logic := '0';
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
      procedure dump(variable ln : inout line; tag : string) is
      begin
         write(ln, tag);
         write(ln, string'(" t=")); write(ln, now);
         write(ln, string'(" irqReq=")); write(ln, q_irqreq);
         write(ln, string'(" take5=")); write(ln, q_take5);
         write(ln, string'(" block=")); write(ln, q_block);
         write(ln, string'(" I_STAT=0x"));
         hx8(ln, resize(q_istatus, 32));
         write(ln, string'(" I_MASK=0x")); hx8(ln, q_imask);
         write(ln, string'(" irqIn=0x"));   hx8(ln, resize(q_irqin, 32));
         write(ln, string'(" irqIn1=0x"));  hx8(ln, resize(q_irqin1, 32));
         write(ln, string'(" SR=0x"));    hx8(ln, q_sr);
         write(ln, string'(" CAUSE=0x")); hx8(ln, q_cause);
         write(ln, string'(" EPC=0x"));   hx8(ln, q_epc);
         write(ln, string'(" PC=0x"));    hx8(ln, q_pc);
         file_open(status, f, "irqtake.log", append_mode);
         writeline(f, ln); file_close(f);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "irqtake.log", write_mode); file_close(f);
            opened := true;
         end if;
         if not is_x(std_logic_vector(q_pc)) and not is_x(std_logic_vector(resize(q_istatus,32))) then
            -- the IRQ-take decision strobe (the decisive evidence)
            if q_take5 = '1' and n_take < 200 then
               dump(l, string'("[TAKE]"));
               n_take := n_take + 1;
            end if;
            -- rising/falling edges of the combinational irqRequest
            if q_irqreq /= pv_req and n_edge < 800 then
               if q_irqreq = '1' then dump(l, string'("[REQ^]"));
               else                   dump(l, string'("[REQv]"));
               end if;
               n_edge := n_edge + 1;
            end if;
            pv_req := q_irqreq;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- ISR-SENTINEL probe (decision-tree branch 4). The BIOS ATAPI ISR bumps a
   -- counter at RAM 0x803d2280 and a flag at 0x803d228f. RAM byte address =
   -- (KUSEG) 0x3d2280; SDRAM byte addr = same (region 0). The core's ram_Adr
   -- is a 32-bit-word address into region 0 for main RAM, so word index =
   -- 0x3d2280 >> 2 = 0xF4A20. We can't read the SDRAM model's array via an
   -- external name portably, so instead we watch CPU WRITES to that address
   -- on the ram bus (ram_ena='1', ram_rnw='0', matching word). A write there
   -- after the vector PROVES the ISR ran (branch 4 reached).
   -- =======================================================================
   sentinel_probe : process(clk1x)
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable hits   : integer := 0;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "sentinel.log", write_mode); file_close(f);
            opened := true;
         end if;
         -- region-0 main-RAM word writes to the ISR-sentinel region 0x803d2xxx.
         -- The 573 GX700 drive check's IRQ-driven IDENTIFY wait (0x803cba44) spins
         -- comparing [0x803d2358] vs [0x803d2354]; the ATAPI ISR writes 0x803d2358 on
         -- completion. (The old probe only covered 0x803d228x; widened to the whole
         -- 0x803d2000..0x803d2fff page so we catch 0x803d2354/2358/235c.) ram_Adr is a
         -- WORD address into region 0; byte 0x3d2000..0x3d2fff = word 0xF4800..0xF4BFF =
         -- ram_Adr(24:10) = 0xF4800>>10 = 0x3D2.
         if ram_ena = '1' and ram_rnw = '0' and ram_Adr(24 downto 23) = "00"
            and unsigned(ram_Adr(24 downto 10)) = to_unsigned(16#3D2#, 15)
            and hits < 400 then
            write(l, string'("[sentinel] RAM WRITE word_adr=0x"));
            write(l, to_hstring("0000000" & ram_Adr));
            write(l, string'(" data=0x")); write(l, to_hstring(ram_dataWrite));
            write(l, string'(" be=")); write(l, to_hstring(ram_be));
            write(l, string'(" at ")); write(l, now);
            file_open(status, f, "sentinel.log", append_mode);
            writeline(f, l); file_close(f);
            hits := hits + 1;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- EXCEPTION probe. The boot parks at the BIOS panic-halt (j-self 0x9FC20190,
   -- reached via the kernel default-exception tail at 0x00001afc when an
   -- exception's ExcCode is NEITHER Interrupt(0) NOR Syscall(8)). To see WHICH
   -- exception, log every committed CPU exception with its ExcCode (CAUSE bits
   -- 6:2), CAUSE, EPC and the faulting PC. cop0_EPC = the instruction that
   -- faulted -> tells us the exact POST routine that triggers the panic.
   -- Observability only (NVC external names). Capped + flushed per line.
   -- =======================================================================
   exc_probe : process(clk1x)
      alias e_exc   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exception   : unsigned(4 downto 0) >>;
      alias e_cause is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_CAUSE  : unsigned(31 downto 0) >>;
      alias e_epc   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_EPC    : unsigned(31 downto 0) >>;
      alias e_pc    is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc          : unsigned(31 downto 0) >>;
      -- which path raised the exception (new5=interrupt, new3=execute, new1=PCbound)
      -- + the execute-stage code, to disambiguate the fatal exccode=0 take.
      alias e_new5  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionNew5 : std_logic >>;
      alias e_new3  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionNew3 : std_logic >>;
      alias e_new1  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionNew1 : std_logic >>;
      alias e_code3 is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionCode_3 : unsigned(3 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable prev_e : unsigned(4 downto 0) := (others => '0');
      variable logged : integer := 0;
      -- latch the *_new* strobes one cycle ahead of `exception` (they assert the
      -- cycle BEFORE `exception` registers them), so we report the cause path.
      variable hold_new5, hold_new3, hold_new1 : std_logic := '0';
      variable hold_code3 : unsigned(3 downto 0) := (others => '0');
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "exc_trace.log", write_mode); file_close(f);
            opened := true;
         end if;
         -- log on the rising edge of a non-zero exception (one line per take)
         if (e_exc /= 0) and (prev_e = 0) and (logged < 4000)
            and (not is_x(std_logic_vector(e_cause))) then
            write(l, string'("EXC exccode=")); write(l, to_integer(e_cause(6 downto 2)));
            write(l, string'(" exc=")); write(l, to_integer(e_exc));
            write(l, string'(" new5=")); write(l, hold_new5);
            write(l, string'(" new3=")); write(l, hold_new3);
            write(l, string'(" new1=")); write(l, hold_new1);
            write(l, string'(" code3=")); write(l, to_integer(hold_code3));
            write(l, string'(" CAUSE=0x")); hx8(l, e_cause);
            write(l, string'(" EPC=0x"));   hx8(l, e_epc);
            write(l, string'(" PC=0x"));     hx8(l, e_pc);
            write(l, string'(" at ")); write(l, now);
            file_open(status, f, "exc_trace.log", append_mode);
            writeline(f, l); file_close(f);
            logged := logged + 1;
         end if;
         prev_e := e_exc;
         -- capture the strobes for the NEXT cycle's `exception` registration
         if not is_x(std_logic_vector(e_exc)) then
            hold_new5 := e_new5; hold_new3 := e_new3; hold_new1 := e_new1;
            hold_code3 := e_code3;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- IRQ-CONTROLLER BUS-READ PROBE. The decisive spurious-IRQ evidence: when
   -- the kernel exception dispatcher (low-RAM 0x000019F4 region) reads I_STATUS
   -- (bus_addr=0, bus_read=1) to find which source fired, what VALUE does
   -- irq.vhd return? If it returns 0 while the CPU vectored => a phantom IRQ
   -- (the CPU took an interrupt the controller no longer reports). If it
   -- returns a real bit the kernel has no callback for => a source-routing /
   -- masking mismatch. Logs every IRQ-controller bus access with the live
   -- I_STATUS / I_MASK / irqRequest + the returned bus_dataRead, capped, around
   -- the death window. Observability only (NVC external names).
   -- =======================================================================
   irqbus_probe : process(clk1x)
      alias b_read  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.bus_read     : std_logic >>;
      alias b_write is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.bus_write    : std_logic >>;
      alias b_addr  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.bus_addr     : unsigned(3 downto 0) >>;
      alias b_wdata is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.bus_dataWrite: std_logic_vector(31 downto 0) >>;
      alias b_rdata is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.bus_dataRead : std_logic_vector(31 downto 0) >>;
      alias b_stat  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_STATUS     : unsigned(10 downto 0) >>;
      alias b_mask  is << signal .tb_system573.ipsx_mister.ipsx_top.iirq.I_MASK       : unsigned(31 downto 0) >>;
      alias b_req   is << signal .tb_system573.ipsx_mister.ipsx_top.irqRequest        : std_logic >>;
      alias b_pc    is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc           : unsigned(31 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable n      : integer := 0;
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "irqbus.log", write_mode); file_close(f);
            opened := true;
         end if;
         if (b_read = '1' or b_write = '1') and n < 4000
            and not is_x(std_logic_vector(resize(b_stat,32)))
            and now > 80 ms then  -- death window only (keeps the log small)
            if b_read = '1' then write(l, string'("[RD] addr="));
            else                 write(l, string'("[WR] addr=")); end if;
            write(l, to_integer(b_addr));
            if b_write = '1' then
               write(l, string'(" wdata=0x")); hx8(l, unsigned(b_wdata));
            else
               write(l, string'(" rdata=0x")); hx8(l, unsigned(b_rdata));
            end if;
            write(l, string'(" I_STAT=0x")); hx8(l, resize(b_stat,32));
            write(l, string'(" I_MASK=0x")); hx8(l, b_mask);
            write(l, string'(" irqReq=")); write(l, b_req);
            write(l, string'(" PC=0x")); hx8(l, b_pc);
            write(l, string'(" t=")); write(l, now);
            file_open(status, f, "irqbus.log", append_mode);
            writeline(f, l); file_close(f);
            n := n + 1;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- ADEL/STACK PROBE. The enriched exc_probe showed the FATAL event is an
   -- execute-stage Address-Error-Load (code3=4, AdEL) at EPC=0x803C8AD4 -- a
   -- STACK-relative access (sw/lw 0x10(sp)) right after the VBLANK ISR returns
   -- (RFE). That means $sp (or the value being accessed through it) is corrupt
   -- on return. To prove it, capture, in the death window (>80 ms): the faulting
   -- effective address (EXEMemAddr / cop0_BADVADDR) at every execute-stage
   -- AdEL/AdES, plus the live $sp(29), $ra(31), $k0(26), $k1(27), $a1(5). Also
   -- snapshot $sp on every CHANGE in the window so we see when/where it goes bad
   -- (e.g. the ISR context save/restore). Observability only (sim regs[] mirror,
   -- translate_off, external names).
   -- =======================================================================
   adel_probe : process(clk1x)
      alias a_new3  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionNew3 : std_logic >>;
      alias a_code3 is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exceptionCode_3 : unsigned(3 downto 0) >>;
      alias a_memad is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.EXEMemAddr   : unsigned(31 downto 0) >>;
      alias a_bad   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_BADVADDR: unsigned(31 downto 0) >>;
      alias a_pc    is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc           : unsigned(31 downto 0) >>;
      -- value1 = the EXECUTE-stage base-register operand (for sw/lw 0x10(sp) it is
      -- $sp). EXEMemAddr = value1 + imm = the faulting effective address. Together
      -- they show whether $sp is corrupt and by how much (the regs[] file isn't
      -- reachable by external name -- only assigned under translate_off comments).
      alias a_val1  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.value1       : unsigned(31 downto 0) >>;
      alias a_epc   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.cop0_EPC     : unsigned(31 downto 0) >>;
      -- the decoded instruction at the fault: if opcode0 matches the pristine BIOS
      -- word for the faulting PC, the FETCH is correct and the bug is a register
      -- (value1) corruption; if opcode0 is wrong, it's an instruction-fetch defect.
      alias a_op0   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.opcode0      : unsigned(31 downto 0) >>;
      alias a_dop   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.decodeOP     : unsigned(5 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable n      : integer := 0;
      variable pv_n3  : std_logic := '0';
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "adel.log", write_mode); file_close(f);
            opened := true;
         end if;
         if now > 80 ms and n < 2000 and not is_x(std_logic_vector(a_memad))
            and not is_x(std_logic_vector(a_pc)) then
            -- the execute-stage address-error (AdEL=4 / AdES=5) -- the fault.
            -- value1 = base register ($sp); EXEMemAddr/BADVADDR = faulting address.
            if a_new3 = '1' and pv_n3 = '0' and (a_code3 = 4 or a_code3 = 5) then
               write(l, string'("[ADERR] code3=")); write(l, to_integer(a_code3));
               write(l, string'(" base(value1)=0x")); hx8(l, a_val1);
               write(l, string'(" EXEMemAddr=0x")); hx8(l, a_memad);
               write(l, string'(" BADVADDR=0x"));   hx8(l, a_bad);
               write(l, string'(" EPC=0x"));   hx8(l, a_epc);
               write(l, string'(" opcode0=0x")); hx8(l, a_op0);
               write(l, string'(" decOP=")); write(l, to_integer(a_dop));
               write(l, string'(" PC=0x"));    hx8(l, a_pc);
               write(l, string'(" t=")); write(l, now);
               file_open(status, f, "adel.log", append_mode);
               writeline(f, l); file_close(f); n := n + 1;
            end if;
            pv_n3 := a_new3;
         end if;
      end if;
   end process;

   -- =======================================================================
   -- LATEREAD probe (diagnostic, observability only). The AdEL at 0x803c8ae8
   -- faults with a1(value1)=0x1 -- the I_STAT word the VBLANK ISR loaded. The
   -- hypothesis is the load-delay (lateRead) operand forward bleeding the ISR's
   -- loaded value across the interrupt return into the resumed debounce loop.
   -- Trace the lateRead* state + the decode/execute source regs + value1 while
   -- PC is in the debounce-loop window in the death window, to pin the exact
   -- cycle a1 becomes 0x1 and which forward path delivers it.
   -- =======================================================================
   lateread_probe : process(clk1x)
      alias lr_byp  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.lateReadBypass : std_logic >>;
      alias lr_tgt  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.lateReadTarget : unsigned(4 downto 0) >>;
      alias lr_dat  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.lateReadData   : unsigned(31 downto 0) >>;
      alias lr_blk  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.blockLoadforward : std_logic >>;
      alias ds1     is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.decodeSource1  : unsigned(4 downto 0) >>;
      alias ds2     is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.decodeSource2  : unsigned(4 downto 0) >>;
      alias v1      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.value1         : unsigned(31 downto 0) >>;
      alias v2      is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.value2         : unsigned(31 downto 0) >>;
      alias lr_exc  is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.exception      : unsigned(4 downto 0) >>;
      alias lr_pc   is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pc             : unsigned(31 downto 0) >>;
      alias lr_pco1 is << signal .tb_system573.ipsx_mister.ipsx_top.icpu.pcOld1         : unsigned(31 downto 0) >>;
      file     f      : text;
      variable status : FILE_OPEN_STATUS;
      variable opened : boolean := false;
      variable l      : line;
      variable n      : integer := 0;
      procedure hx8(variable ln : inout line; v : unsigned(31 downto 0)) is
         constant hx : string(1 to 16) := "0123456789ABCDEF";
         variable s  : string(1 to 8);
      begin
         for i in 0 to 7 loop s(8-i) := hx(to_integer(v(i*4+3 downto i*4)) + 1); end loop;
         write(ln, s);
      end procedure;
   begin
      if rising_edge(clk1x) then
         if not opened then
            file_open(status, f, "lateread.log", write_mode); file_close(f);
            opened := true;
         end if;
         -- Narrowed to ONLY the faulting re-execution: PC 0x803C8AD0..0x803C8AEC in
         -- the window AFTER the VBLANK ISR has run (it returns ~85.09 ms; AdEL is
         -- 85.158 ms). The earlier wide window (>82.7 ms, whole 0x803C8Axx page)
         -- filled its 1200-cap on ISR/loop iterations BEFORE reaching the fault, so
         -- the destructive cycle was never logged. This captures exactly the
         -- bne/lui-a1/lw-a1/nop/lw-v0 re-exec that clobbers a1 to 0x1.
         if now > 85000 us and n < 1200 and not is_x(std_logic_vector(lr_pco1))
            and lr_pco1 >= x"803C8AD0" and lr_pco1 <= x"803C8AEC" then
            write(l, string'("[lr] t=")); write(l, now);
            write(l, string'(" pcOld1=0x")); hx8(l, lr_pco1);
            write(l, string'(" exc=")); write(l, to_integer(lr_exc));
            write(l, string'(" byp=")); write(l, std_logic'image(lr_byp));
            write(l, string'(" blk=")); write(l, std_logic'image(lr_blk));
            write(l, string'(" tgt=")); write(l, to_integer(lr_tgt));
            write(l, string'(" dat=0x")); hx8(l, lr_dat);
            write(l, string'(" ds1=")); write(l, to_integer(ds1));
            write(l, string'(" v1=0x")); hx8(l, v1);
            write(l, string'(" ds2=")); write(l, to_integer(ds2));
            write(l, string'(" v2=0x")); hx8(l, v2);
            file_open(status, f, "lateread.log", append_mode);
            writeline(f, l); file_close(f); n := n + 1;
         end if;
      end if;
   end process;

end architecture;
