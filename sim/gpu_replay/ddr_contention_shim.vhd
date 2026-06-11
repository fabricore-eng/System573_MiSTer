-- =============================================================================
-- ddr_contention_shim -- VRAM-CONTENTION injector for the GPU-replay rig.
--
-- Sits between psx.gpu and ddrram_model on the READ-REQUEST path ONLY.
-- The stock ddrram_model NEVER asserts DDRAM_BUSY for reads and accepts a read
-- the instant DDRAM_RD rises; real HW (MiSTer f2sdram, shared with the scaler /
-- HPS) can hold off the read ISSUE arbitrarily. This shim recreates that
-- hold-off: during a "contention window" it asserts gpu_BUSY toward the GPU and
-- masks mem_RD toward the model, so the GPU's request sits held (the GPU holds
-- vram_RD + ADDR + BURSTCNT stable while vram_BUSY='1'; see gpu.vhd lines
-- 1640-1643 -- vram_RD is only cleared on a vram_BUSY='0' edge) until the
-- window ends, at which point the still-held request passes through and the
-- model's top-of-loop sampler accepts it. No request is ever dropped because
-- the model only ever sees mem_RD='1' outside windows, when it is guaranteed
-- idle-sampling (it was seeing '0' the whole window).
--
-- Wiring (see tb_gpu_replay.vhd):
--   gpu_RD    <- GPU vram_RD          (read request, pre-shim)
--   mem_RD    -> ddrram_model DDRAM_RD (read request, post-mask)
--   gpu_BUSY  -> OR-ed (in the tb) with the model's DDRAM_BUSY into the GPU's
--                vram_BUSY input. CONT_MODE=0 drives gpu_BUSY='0' => the GPU
--                sees exactly the model's BUSY => bit-identical to the
--                pre-shim rig (pure passthrough, zero behavior change).
--   ADDR/BURSTCNT/DIN/BE/WE/DOUT/DOUT_READY are NOT routed through the shim --
--   they stay wired straight between GPU and model, untouched.
--
-- LIMITATION (deliberate): the WRITE path is NOT gated. ddrram_model's
-- write-burst handshake is quirky (it samples DDRAM_WE at top-of-loop, serves
-- the whole burst from one DIN latch, and with SLOWTIMING=0 its BUSY<='1' /
-- BUSY<='0' pair collapses to no visible BUSY at all); masking WE or gating its
-- BUSY risks breaking write semantics, so mem-side writes pass through
-- untouched. Side effect of asserting gpu_BUSY during a window: the GPU also
-- HOLDS a just-issued vram_WE for the window's duration (gpu.vhd only clears
-- WE on a BUSY='0' edge), so the model -- which is NOT masked -- can re-sample
-- the held WE and service the same single-beat write more than once. That is
-- data-idempotent (same addr, same data, same BE) and only duplicates rows in
-- the .gra write log; it does NOT corrupt VRAM contents. Mode 0 has no such
-- effect (gpu_BUSY='0' always).
--
-- Generics:
--   CONT_MODE   0 = pure passthrough (default; gpu_BUSY<='0', mem_RD<=gpu_RD)
--               1 = periodic windows: BUSY for CONT_LEN clk2x cycles out of
--                   every CONT_PERIOD cycles
--               2 = pseudo-random windows (32-bit Galois LFSR, CONT_SEED):
--                   alternates a gap of 1..CONT_PERIOD cycles with a window of
--                   1..CONT_LEN cycles, both LFSR-drawn
--   CONT_PERIOD periodic period / max random gap (clk2x cycles)
--   CONT_LEN    window length (mode 1) / max random window (mode 2)
--   CONT_SEED   LFSR seed for mode 2 (0 falls back to a fixed nonzero seed)
--
-- Diagnostics: in modes 1/2 the shim reports (stdout) the first 10 delayed
-- read-accepts and every 500th thereafter, plus a final-ish running total --
-- greppable proof that contention actually bit.
--
-- This file is ORIGINAL to this repo (tb-side only; the vendored psx/ submodule
-- is untouched). Analyzed into the tb library by run.sh before tb_gpu_replay.
-- =============================================================================
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ddr_contention_shim is
   generic
   (
      CONT_MODE   : integer := 0;
      CONT_PERIOD : integer := 2000;
      CONT_LEN    : integer := 0;
      CONT_SEED   : integer := 1
   );
   port
   (
      clk      : in  std_logic;   -- clk2x (the DDRAM_CLK domain)
      gpu_RD   : in  std_logic;   -- from GPU vram_RD
      gpu_BUSY : out std_logic;   -- to GPU vram_BUSY (OR-ed with model BUSY in the tb)
      mem_RD   : out std_logic    -- to ddrram_model DDRAM_RD
   );
end entity;

architecture sim of ddr_contention_shim is

   -- '1' while inside a contention window. Single driver: exactly one of the
   -- mode generates below is elaborated; in mode 0 nothing drives it and the
   -- init value '0' holds (pure passthrough).
   signal window_active : std_logic := '0';

begin

   assert not (CONT_MODE = 1 and CONT_LEN >= CONT_PERIOD)
      report "ddr_contention_shim: mode 1 needs CONT_LEN < CONT_PERIOD (otherwise reads are held off forever)"
      severity failure;
   assert CONT_MODE >= 0 and CONT_MODE <= 2
      report "ddr_contention_shim: CONT_MODE must be 0, 1 or 2"
      severity failure;

   gpu_BUSY <= window_active;
   mem_RD   <= gpu_RD and (not window_active);

   -- ------------------------------------------------------------------------
   -- Mode 1: deterministic periodic windows. Free-running counter on clk2x;
   -- window = the first CONT_LEN cycles of every CONT_PERIOD-cycle frame.
   -- ------------------------------------------------------------------------
   gen_mode1 : if CONT_MODE = 1 generate
      process (clk)
         variable cnt : integer := 0;
      begin
         if rising_edge(clk) then
            if cnt >= CONT_PERIOD - 1 then
               cnt := 0;
            else
               cnt := cnt + 1;
            end if;
            if cnt < CONT_LEN then
               window_active <= '1';
            else
               window_active <= '0';
            end if;
         end if;
      end process;
   end generate;

   -- ------------------------------------------------------------------------
   -- Mode 2: pseudo-random windows. 32-bit Galois LFSR (taps 32,22,2,1);
   -- alternates gap (1..CONT_PERIOD cycles) and window (1..CONT_LEN cycles),
   -- each duration drawn from the LFSR low bits. CONT_LEN<=0 degenerates to
   -- never-busy (passthrough).
   -- ------------------------------------------------------------------------
   gen_mode2 : if CONT_MODE = 2 generate
      process (clk)
         function seed_init(s : integer) return std_logic_vector is
         begin
            if s = 0 then
               return x"DEADBEEF";        -- LFSR must not start at 0
            else
               return std_logic_vector(to_unsigned(abs s, 32));
            end if;
         end function;
         variable lfsr  : std_logic_vector(31 downto 0) := seed_init(CONT_SEED);
         variable inwin : boolean := false;
         variable cnt   : integer := 1 + (CONT_PERIOD / 2);   -- start mid-gap
      begin
         if rising_edge(clk) then
            -- Galois LFSR step
            if lfsr(0) = '1' then
               lfsr := ('0' & lfsr(31 downto 1)) xor x"80200003";
            else
               lfsr := '0' & lfsr(31 downto 1);
            end if;

            if cnt > 1 then
               cnt := cnt - 1;
            else
               if inwin or CONT_LEN <= 0 then
                  -- window ends (or windows disabled): draw the next gap
                  inwin := false;
                  window_active <= '0';
                  cnt := 1 + (to_integer(unsigned(lfsr(15 downto 0))) mod CONT_PERIOD);
               else
                  -- gap ends: draw the next window
                  inwin := true;
                  window_active <= '1';
                  cnt := 1 + (to_integer(unsigned(lfsr(15 downto 0))) mod CONT_LEN);
               end if;
            end if;
         end if;
      end process;
   end generate;

   -- ------------------------------------------------------------------------
   -- Diagnostics (modes 1/2 only): count clk2x cycles a read sat held by a
   -- window, and report each delayed read's hold length (first 10, then every
   -- 500th) so a grep of the sim stdout proves contention actually bit.
   -- ------------------------------------------------------------------------
   gen_stats : if CONT_MODE /= 0 generate
      process (clk)
         variable stallcycles : integer := 0;   -- total held cycles
         variable curdelay    : integer := 0;   -- held cycles of the in-flight read
         variable ndelayed    : integer := 0;   -- reads that were held >=1 cycle
      begin
         if rising_edge(clk) then
            if gpu_RD = '1' and window_active = '1' then
               stallcycles := stallcycles + 1;
               curdelay    := curdelay + 1;
            else
               if gpu_RD = '1' and curdelay > 0 then
                  -- read finally presented to the model this edge
                  ndelayed := ndelayed + 1;
                  if ndelayed <= 10 or (ndelayed mod 500) = 0 then
                     report "ddr_contention_shim: delayed read #" & integer'image(ndelayed) &
                            " held " & integer'image(curdelay) & " clk2x cycles" &
                            " (cumulative held cycles=" & integer'image(stallcycles) & ")";
                  end if;
               end if;
               curdelay := 0;
            end if;
         end if;
      end process;
   end generate;

end architecture;
