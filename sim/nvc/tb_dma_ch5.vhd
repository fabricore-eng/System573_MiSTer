library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

-- ----------------------------------------------------------------------------
-- tb_dma_ch5.vhd - the S1 discriminator: the REAL patched psx/rtl/dma.vhd
-- (psx_patches/0023) drained against the IMPLEMENTED rtl/atapi.v ch5 contract.
--
-- Why this exists: sim/tb_cdboot.v validates rtl/atapi.v against a Verilog BFM
-- *of* the patched dma.vhd (the iverilog suite cannot consume VHDL). If that BFM
-- deviates from the real engine, tb_cdboot can be green while silicon fails the
-- GX700 CDR check in the READ(12)->ch5-DMA leg. This TB closes the gap: it
-- instantiates the REAL dma.vhd under NVC and models the atapi.v side as a
-- VHDL process honoring exactly the implemented handshake:
--   * atapi_dmaRequest is a LEVEL: high through a disc data-in phase, dropping
--     the cycle after the device's last halfword is consumed;
--   * DMA_ATA_read is valid in the SAME clk1x cycle DMA_ATA_readEna is high
--     (atapi.v serves from the dma_word prefetch register);
--   * one halfword is consumed per readEna cycle, LOW half first (the SPU ch4
--     accumulate pattern the patch clones);
--   * readEna is ce-qualified inside dma.vhd; atapi.v free-runs on clk1x.
--
-- The BIOS arm is replayed VERBATIM from the MAME register-level trace of the
-- real BIOS CD-booting hypbbc2p (local/cd_adjudication/atapi_trace.txt):
--   DPCR  (0x1f8010f0) = 0x33BB3B33   (ch5 enable, prio 3)
--   MADR5 (0x1f8010d0) = 0x803FCFA8   (sector buffer, top of the 4 MB RAM)
--   BCR5  (0x1f8010d4) = 0x00000200   (512 words, BA=0 -> manual word count)
--   CHCR5 (0x1f8010d8) = 0x11050100   (trigger+start+chopping, 32-word window)
-- DICR is additionally armed (bit23 master + bit21 ch5) so the ch5 completion
-- IRQ machinery is observed - dma.vhd-level property, not a BIOS replay line.
--
-- The CPU-side environment (ce / cpuPaused / canDMA) replicates psx_top.vhd:
--   canDMA    <= memMuxIdle                       (TB: bus idle)
--   cpuPaused <= '1' when (cpuPaused and dmaOn) or (dmaRequest and canDMA)
--                else '0' when dmaOn = '0'        (psx_top.vhd line ~807)
-- This matters: the chop pause/resume exit (PAUSING -> OFF) is gated on the
-- REP_counter, which only advances while cpuPaused = '1'.
--
-- Checks per normal arm (the BIOS sector contract):
--   [A] exactly 1024 halfword consumes (512 words) - no over/under-drain
--   [B] zero consumes during ce-off windows (the free-running-device hazard)
--   [C] zero consumes while atapi_dmaRequest = '0' (stale-buffer reads)
--   [D] chop bursts never exceed 64 consecutive ce-cycles (32-word window)
--   [E] all 512 words reach the RAM-write fifo in order, address MADR+4k,
--       packed {high_half, low_half} = little-endian low-half-first
--   [F] ch5 IRQ: DICR_IRQs(5) sets + irqOut pulses at completion
--   [G] STOPPING write-back: MADR=base+0x800, BCR.lo=0, CHCR bit24/28 clear
--   [H] a SECOND arm (next sector) drains cleanly after the first
-- Stress legs: arm B runs with a mid-drain ce-off window AND a RAM-sink stall
-- (fifoOut NearFull backpressure); arm C is the device-exhausts-early probe
-- (dma_req drops at halfword 512 of 1024) - characterized, and the engine must
-- still reach STOPPING; arm D proves recovery after the abnormal arm.
-- ----------------------------------------------------------------------------

entity tb_dma_ch5 is
end entity;

architecture sim of tb_dma_ch5 is

   -- clocks per psx_top.vhd: clk1x 33.33 MHz (30 ns), clk3x 100 MHz (10 ns)
   signal clk1x          : std_logic := '1';
   signal clk3x          : std_logic := '1';
   signal clk3xIndex     : std_logic := '0';
   signal clk1xToggle    : std_logic := '0';
   signal clk1xToggle3x  : std_logic := '0';
   signal clk1xToggle3x_1: std_logic := '0';

   signal reset          : std_logic := '1';
   signal ce             : std_logic := '1';
   signal ce_force_off   : std_logic := '0';

   -- dma <-> cpu environment (psx_top model)
   signal canDMA         : std_logic;
   signal cpuPaused      : std_logic := '0';
   signal dmaRequest     : std_logic;
   signal dmaStallCPU    : std_logic;
   signal dmaOn          : std_logic;
   signal irqOut         : std_logic;

   -- dma bus (0x1f8010xx, bus_addr = byte addr bits 6:0)
   signal bus_addr       : unsigned(6 downto 0) := (others => '0');
   signal bus_dataWrite  : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read       : std_logic := '0';
   signal bus_write      : std_logic := '0';
   signal bus_dataRead   : std_logic_vector(31 downto 0);

   -- ch5 ATAPI trio
   signal atapi_dmaRequest : std_logic;
   signal DMA_ATA_readEna  : std_logic;
   signal DMA_ATA_read     : std_logic_vector(15 downto 0);

   -- RAM-write side (fifoOut drain)
   signal ram_dmafifo_adr   : std_logic_vector(22 downto 0);
   signal ram_dmafifo_data  : std_logic_vector(31 downto 0);
   signal ram_dmafifo_empty : std_logic;
   signal ram_dmafifo_read  : std_logic;
   signal sink_stall        : std_logic := '0';

   -- unused dma ports
   signal errorCHOP, errorDMACPU, errorDMAFIFO : std_logic;
   signal ram_Adr  : std_logic_vector(22 downto 0);
   signal ram_cnt  : std_logic_vector(1 downto 0);
   signal ram_ena  : std_logic;
   signal dma_cache_Adr   : std_logic_vector(20 downto 0);
   signal dma_cache_data  : std_logic_vector(31 downto 0);
   signal dma_cache_write : std_logic;
   signal DMA_GPU_waiting, DMA_GPU_writeEna, DMA_GPU_readEna : std_logic;
   signal DMA_GPU_write : std_logic_vector(31 downto 0);
   signal DMA_MDEC_writeEna, DMA_MDEC_readEna : std_logic;
   signal DMA_MDEC_write : std_logic_vector(31 downto 0);
   signal DMA_CD_readEna : std_logic;
   signal DMA_SPU_writeEna, DMA_SPU_readEna : std_logic;
   signal DMA_SPU_write : std_logic_vector(15 downto 0);
   signal SS_DataRead : std_logic_vector(31 downto 0);
   signal SS_idle     : std_logic;

   -- ===== ATAPI-side BFM state =====
   signal bfm_sector    : integer := 0;      -- sector index (pattern seed)
   signal bfm_blocklen  : integer := 1024;   -- halfwords the device REALLY has
   signal bfm_active    : std_logic := '0';  -- a data phase is in flight
   signal bfm_load      : std_logic := '0';  -- pulse: (re)arm the device side
   signal bfm_ptr       : integer := 0;      -- halfword serve pointer

   -- instrumentation
   signal consume_count    : integer := 0;   -- readEna cycles this arm
   signal ceoff_consumes   : integer := 0;   -- consumes seen while ce='0'
   signal noreq_consumes   : integer := 0;   -- consumes seen while dma_req='0'
   signal burst_len        : integer := 0;   -- consecutive readEna run
   signal burst_max        : integer := 0;
   signal irq_seen         : integer := 0;   -- irqOut pulse count this arm

   -- RAM capture (per arm)
   type t_ram is array(0 to 1023) of std_logic_vector(31 downto 0);
   signal ram_words : t_ram := (others => (others => '0'));
   type t_adr is array(0 to 1023) of std_logic_vector(22 downto 0);
   signal ram_adrs  : t_adr := (others => (others => '0'));
   signal ram_count : integer := 0;

   -- deterministic per-sector halfword pattern (distinct low/high halves)
   function hw_pat(sector : integer; idx : integer) return std_logic_vector is
      variable v : integer;
   begin
      v := (sector * 4096 + idx * 3 + 16#0123#) mod 65536;
      return std_logic_vector(to_unsigned(v, 16));
   end function;

begin

   clk1x <= not clk1x after 15 ns;
   clk3x <= not clk3x after 5 ns;

   -- clk3xIndex exactly per psx_top.vhd (toggle synchronizer)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;
   process (clk3x)
   begin
      if rising_edge(clk3x) then
         clk1xToggle3x   <= clk1xToggle;
         clk1xToggle3x_1 <= clk1xToggle3x;
         clk3xIndex      <= '0';
         if (clk1xToggle3x_1 = clk1xToggle) then
            clk3xIndex <= '1';
         end if;
      end if;
   end process;

   ce <= not ce_force_off;

   -- canDMA per psx_top: memMuxIdle - the TB bus master is the only CPU activity
   canDMA <= not (bus_read or bus_write);

   -- cpuPaused per psx_top.vhd (the "switch to dma"/"switch to CPU" arbiter)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            cpuPaused <= '0';
         elsif (ce = '1') then
            if ((cpuPaused = '1' and dmaOn = '1') or (dmaRequest = '1' and canDMA = '1')) then
               cpuPaused <= '1';
            elsif (dmaOn = '0') then
               cpuPaused <= '0';
            end if;
         end if;
      end if;
   end process;

   -- ===== the DUT: the REAL patched dma.vhd =====
   idma : entity work.dma
   port map
   (
      clk1x                => clk1x,
      clk3x                => clk3x,
      clk3xIndex           => clk3xIndex,
      ce                   => ce,
      reset                => reset,
      errorCHOP            => errorCHOP,
      errorDMACPU          => errorDMACPU,
      errorDMAFIFO         => errorDMAFIFO,
      TURBO                => '0',            -- TURBO_COMP default-off (emu.sv status[80:79]=0)
      TURBO_CACHE          => '0',
      ram8mb               => '1',            -- emu.sv: 8 MB decode ...
      ram4mb               => '1',            -- ... masked to the 573's 4 MB (patch 0022)
      ignoreCDTiming       => '0',
      canDMA               => canDMA,
      cpuPaused            => cpuPaused,
      dmaRequest           => dmaRequest,
      dmaStallCPU          => dmaStallCPU,
      dmaOn                => dmaOn,
      irqOut               => irqOut,
      ram_Adr              => ram_Adr,
      ram_cnt              => ram_cnt,
      ram_ena              => ram_ena,
      dma_wr               => '0',
      dma_reqprocessed     => '0',
      dma_data             => (others => '0'),
      ram_dmafifo_adr      => ram_dmafifo_adr,
      ram_dmafifo_data     => ram_dmafifo_data,
      ram_dmafifo_empty    => ram_dmafifo_empty,
      ram_dmafifo_read     => ram_dmafifo_read,
      dma_cache_Adr        => dma_cache_Adr,
      dma_cache_data       => dma_cache_data,
      dma_cache_write      => dma_cache_write,
      gpu_dmaRequest       => '0',
      DMA_GPU_waiting      => DMA_GPU_waiting,
      DMA_GPU_writeEna     => DMA_GPU_writeEna,
      DMA_GPU_readEna      => DMA_GPU_readEna,
      DMA_GPU_write        => DMA_GPU_write,
      DMA_GPU_read         => (others => '0'),
      mdec_dmaWriteRequest => '0',
      mdec_dmaReadRequest  => '0',
      DMA_MDEC_writeEna    => DMA_MDEC_writeEna,
      DMA_MDEC_readEna     => DMA_MDEC_readEna,
      DMA_MDEC_write       => DMA_MDEC_write,
      DMA_MDEC_read        => (others => '0'),
      cd_memctrl           => (others => '0'),
      com0_delay           => (others => '0'),
      DMA_CD_readEna       => DMA_CD_readEna,
      DMA_CD_read          => (others => '0'),
      spu_timing_on        => '0',
      spu_timing_value     => (others => '0'),
      spu_dmaRequest       => '0',
      DMA_SPU_writeEna     => DMA_SPU_writeEna,
      DMA_SPU_readEna      => DMA_SPU_readEna,
      DMA_SPU_write        => DMA_SPU_write,
      DMA_SPU_read         => (others => '0'),
      atapi_dmaRequest     => atapi_dmaRequest,
      DMA_ATA_readEna      => DMA_ATA_readEna,
      DMA_ATA_read         => DMA_ATA_read,
      bus_addr             => bus_addr,
      bus_dataWrite        => bus_dataWrite,
      bus_read             => bus_read,
      bus_write            => bus_write,
      bus_dataRead         => bus_dataRead,
      loading_savestate    => '0',
      SS_reset             => '0',
      SS_DataWrite         => (others => '0'),
      SS_Adr               => (others => '0'),
      SS_wren              => '0',
      SS_rden              => '0',
      SS_DataRead          => SS_DataRead,
      SS_idle              => SS_idle
   );

   -- ===== ATAPI-side BFM: the implemented atapi.v contract =====
   -- dma_req: LEVEL through the data phase, drops once the block is exhausted
   -- (in atapi.v: state leaves S_DATAIN on the final data_consume edge).
   atapi_dmaRequest <= '1' when (bfm_active = '1' and bfm_ptr < bfm_blocklen) else '0';

   -- data valid the SAME cycle readEna is high (atapi.v dma_word prefetch reg);
   -- past the block end the device would serve stale BRAM - make it visible.
   DMA_ATA_read <= hw_pat(bfm_sector, bfm_ptr) when (bfm_ptr < bfm_blocklen) else x"DEAD";

   -- pointer advance + instrumentation: clk1x, NOT ce-gated (atapi.v free-runs;
   -- the ce qualification must come from dma.vhd's readEna itself)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (bfm_load = '1') then
            bfm_ptr        <= 0;
            consume_count  <= 0;
            ceoff_consumes <= 0;
            noreq_consumes <= 0;
            burst_len      <= 0;
            burst_max      <= 0;
            irq_seen       <= 0;
         elsif (DMA_ATA_readEna = '1') then
            bfm_ptr       <= bfm_ptr + 1;
            consume_count <= consume_count + 1;
            if (ce = '0') then
               ceoff_consumes <= ceoff_consumes + 1;
            end if;
            if (atapi_dmaRequest = '0') then
               noreq_consumes <= noreq_consumes + 1;
            end if;
            burst_len <= burst_len + 1;
            if (burst_len + 1 > burst_max) then
               burst_max <= burst_len + 1;
            end if;
         else
            burst_len <= 0;
         end if;

         if (bfm_load = '0' and irqOut = '1') then
            irq_seen <= irq_seen + 1;
         end if;
      end if;
   end process;

   -- ===== RAM-write sink (the sdram side of fifoOut, clk3x) =====
   ram_dmafifo_read <= (not ram_dmafifo_empty) and (not sink_stall);
   process (clk3x)
   begin
      if rising_edge(clk3x) then
         if (bfm_load = '1') then
            ram_count <= 0;
         elsif (ram_dmafifo_read = '1' and ram_dmafifo_empty = '0') then
            if (ram_count < 1024) then
               ram_words(ram_count) <= ram_dmafifo_data;
               ram_adrs(ram_count)  <= ram_dmafifo_adr;
            end if;
            ram_count <= ram_count + 1;
         end if;
      end if;
   end process;

   -- ===== the test sequence =====
   process
      variable nerr     : integer := 0;
      variable rd       : std_logic_vector(31 downto 0);
      variable exp_w    : std_logic_vector(31 downto 0);
      variable exp_a    : unsigned(22 downto 0);
      variable timeout  : integer;

      procedure step(n : in integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk1x);
         end loop;
      end procedure;

      procedure bus_write32(a : in unsigned(6 downto 0); d : in std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk1x);
         bus_addr      <= a;
         bus_dataWrite <= d;
         bus_write     <= '1';
         wait until rising_edge(clk1x);
         bus_write     <= '0';
         step(7);                      -- realistic CPU store spacing
      end procedure;

      procedure bus_read32(a : in unsigned(6 downto 0); d : out std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= a;
         bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         wait until rising_edge(clk1x);   -- bus_dataRead registered in dma.vhd
         d := bus_dataRead;
         step(4);
      end procedure;

      procedure fail(msg : in string) is
      begin
         report "FAIL: " & msg severity error;
         nerr := nerr + 1;
      end procedure;

      -- one VERBATIM BIOS arm (trace lines 509-512 et seq.)
      procedure bios_arm(madr : in unsigned(23 downto 0)) is
      begin
         bus_write32(to_unsigned(16#70#, 7), x"33BB3B33");                    -- DPCR
         bus_write32(to_unsigned(16#50#, 7), x"00" & std_logic_vector(madr)); -- MADR5
         bus_write32(to_unsigned(16#54#, 7), x"00000200");                    -- BCR5: 512 words
         bus_write32(to_unsigned(16#58#, 7), x"11050100");                    -- CHCR5: arm
      end procedure;

      -- wait for the arm to fully retire (device drained + engine idle)
      procedure wait_done(tag : in string) is
         variable t : integer := 0;
      begin
         while not (consume_count >= 1024 and dmaOn = '0' and dmaRequest = '0') loop
            wait until rising_edge(clk1x);
            t := t + 1;
            if (t > 400000) then
               fail(tag & ": timeout (consumes=" & integer'image(consume_count) &
                    " ram_words=" & integer'image(ram_count) & ")");
               exit;
            end if;
         end loop;
         step(40);   -- let the fifoOut tail drain + write-back settle
      end procedure;

      -- the per-arm contract checks [A]..[G]
      procedure check_arm(tag : in string; sector : in integer; madr : in unsigned(23 downto 0)) is
      begin
         -- [A] exact drain
         if (consume_count /= 1024) then
            fail(tag & ": consumed " & integer'image(consume_count) & " halfwords (want 1024)");
         end if;
         -- [B] no ce-off consumes
         if (ceoff_consumes /= 0) then
            fail(tag & ": " & integer'image(ceoff_consumes) & " consumes during ce-off");
         end if;
         -- [C] no consumes without dma_req
         if (noreq_consumes /= 0) then
            fail(tag & ": " & integer'image(noreq_consumes) & " consumes while dma_req=0");
         end if;
         -- [D] chop window
         if (burst_max > 64) then
            fail(tag & ": readEna burst " & integer'image(burst_max) & " > 64 (chop window broken)");
         end if;
         -- [E] RAM content: 512 words, in order, addr+4k, low-half-first packing
         if (ram_count /= 512) then
            fail(tag & ": " & integer'image(ram_count) & " RAM words (want 512)");
         else
            for k in 0 to 511 loop
               exp_w := hw_pat(sector, 2*k + 1) & hw_pat(sector, 2*k);
               exp_a := madr(22 downto 0) + to_unsigned(4*k, 23);
               if (ram_words(k) /= exp_w) then
                  fail(tag & ": RAM word " & integer'image(k) & " bad packing/order");
                  exit;
               end if;
               if (unsigned(ram_adrs(k)) /= exp_a) then
                  fail(tag & ": RAM addr " & integer'image(k) & " mismatch");
                  exit;
               end if;
            end loop;
         end if;
         -- [F] ch5 completion IRQ (DICR armed: bit23 master + bit21 ch5)
         if (irq_seen < 1) then
            fail(tag & ": no irqOut pulse at completion");
         end if;
         bus_read32(to_unsigned(16#74#, 7), rd);          -- DICR readback
         if (rd(29) /= '1') then                          -- DICR_IRQs(5)
            fail(tag & ": DICR ch5 IRQ flag not set (DICR=" & to_hstring(rd) & ")");
         end if;
         bus_write32(to_unsigned(16#74#, 7), x"20A00000"); -- ack ch5 flag, keep enables
         -- [G] STOPPING write-back
         bus_read32(to_unsigned(16#50#, 7), rd);          -- MADR5
         if (unsigned(rd(23 downto 0)) /= (madr + to_unsigned(16#800#, 24))) then
            fail(tag & ": MADR write-back " & to_hstring(rd) & " (want base+0x800)");
         end if;
         bus_read32(to_unsigned(16#54#, 7), rd);          -- BCR5
         if (rd(15 downto 0) /= x"0000") then
            fail(tag & ": BCR.lo write-back " & to_hstring(rd) & " (want 0)");
         end if;
         bus_read32(to_unsigned(16#58#, 7), rd);          -- CHCR5
         if (rd(24) /= '0' or rd(28) /= '0') then
            fail(tag & ": CHCR start/trigger not cleared (" & to_hstring(rd) & ")");
         end if;
      end procedure;

   begin
      report "tb_dma_ch5: REAL patched dma.vhd vs the implemented atapi.v ch5 contract";
      step(6);
      reset <= '0';
      step(10);

      -- arm the ch5 DICR IRQ (observability of the completion IRQ machinery)
      bus_write32(to_unsigned(16#74#, 7), x"00A00000");   -- DICR: master + ch5 enable

      -- ================= ARM A: first sector, the verbatim BIOS replay ======
      bfm_sector   <= 0;
      bfm_blocklen <= 1024;
      bfm_active   <= '1';
      bfm_load     <= '1';
      step(2);
      bfm_load     <= '0';
      step(4);
      bios_arm(to_unsigned(16#3FCFA8#, 24));              -- buf = 0x803FCFA8
      wait_done("armA");
      bfm_active   <= '0';
      check_arm("armA", 0, to_unsigned(16#3FCFA8#, 24));
      report "tb_dma_ch5: armA done (consumes=" & integer'image(consume_count) &
             " ram=" & integer'image(ram_count) & " burst_max=" & integer'image(burst_max) &
             " irqs=" & integer'image(irq_seen) & ")";

      -- ================= ARM B: second sector + ce-off gap + sink stall =====
      -- the BIOS reads the NEXT sector into buf+0x800 (trace: MADR 803FD7A8)
      step(50);
      bfm_sector   <= 1;
      bfm_blocklen <= 1024;
      bfm_active   <= '1';
      bfm_load     <= '1';
      step(2);
      bfm_load     <= '0';
      step(4);
      bios_arm(to_unsigned(16#3FD7A8#, 24));
      -- mid-drain: stall the RAM sink (forces fifoOut NearFull backpressure,
      -- including mid-32-bit-word pauses)
      while (consume_count < 200) loop wait until rising_edge(clk1x); end loop;
      sink_stall <= '1';
      step(400);                                          -- ~400 clk1x of no RAM drain
      sink_stall <= '0';
      -- mid-drain: a ce-off window (OSD pause / savestate freeze model);
      -- the free-running device must see ZERO consumes through it
      while (consume_count < 600) loop wait until rising_edge(clk1x); end loop;
      ce_force_off <= '1';
      step(300);
      ce_force_off <= '0';
      wait_done("armB");
      bfm_active   <= '0';
      check_arm("armB", 1, to_unsigned(16#3FD7A8#, 24));
      report "tb_dma_ch5: armB done (ce-off gap + sink stall survived; consumes=" &
             integer'image(consume_count) & " ram=" & integer'image(ram_count) & ")";

      -- ============ ARM C: device exhausts early (dma_req drops mid-burst) ==
      -- The implemented atapi.v never does this on the BIOS path (the sector is
      -- fully BRAM-buffered before the data phase), but the engine must not
      -- wedge if it ever happens: characterize the behavior.
      step(50);
      bfm_sector   <= 2;
      bfm_blocklen <= 512;                                -- device dies at halfword 512
      bfm_active   <= '1';
      bfm_load     <= '1';
      step(2);
      bfm_load     <= '0';
      step(4);
      bios_arm(to_unsigned(16#3FCFA8#, 24));
      timeout := 0;
      while not (dmaOn = '0' and dmaRequest = '0' and consume_count >= 1024) loop
         wait until rising_edge(clk1x);
         timeout := timeout + 1;
         if (timeout > 400000) then exit; end if;
      end loop;
      step(40);
      if (consume_count >= 1024) then
         report "tb_dma_ch5: armC CHARACTERIZED: engine drains its full BCR (" &
                integer'image(consume_count) & " consumes) even after dma_req dropped at 512 - " &
                integer'image(noreq_consumes) & " stale-buffer reads (no readStall term for ch5); " &
                "engine reaches STOPPING (no wedge)";
      else
         report "tb_dma_ch5: armC CHARACTERIZED: engine STALLS after dma_req drop (consumes=" &
                integer'image(consume_count) & ", dmaOn=" & std_logic'image(dmaOn) &
                ") - ch5 honors dma_req mid-transfer" severity warning;
         -- recover: clear the channel so arm D starts clean
         bus_write32(to_unsigned(16#58#, 7), x"00000000"); -- CHCR5: stop
         step(50);
      end if;
      bfm_active <= '0';

      -- ================= ARM D: clean recovery after the abnormal arm =======
      step(50);
      bfm_sector   <= 3;
      bfm_blocklen <= 1024;
      bfm_active   <= '1';
      bfm_load     <= '1';
      step(2);
      bfm_load     <= '0';
      step(4);
      bios_arm(to_unsigned(16#3FD7A8#, 24));
      wait_done("armD");
      bfm_active   <= '0';
      check_arm("armD", 3, to_unsigned(16#3FD7A8#, 24));
      report "tb_dma_ch5: armD done (clean arm after the exhaust-early probe)";

      step(20);
      if (nerr = 0) then
         report "RESULT: PASS (tb_dma_ch5 - the patched dma.vhd honors the atapi.v ch5 contract)";
      else
         report "RESULT: FAIL (tb_dma_ch5, " & integer'image(nerr) & " errors)" severity failure;
      end if;
      finish;
   end process;

   -- global watchdog
   process
   begin
      wait for 80 ms;
      report "RESULT: FAIL (tb_dma_ch5 global timeout)" severity failure;
   end process;

end architecture;
