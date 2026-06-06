-- tb_irq10.vhd - focused NVC test of the VENDORED psx/rtl/irq.vhd bit10 path.
--
-- Drives irq_LIGHTPEN (= exp_irq10 = atapi INTRQ) with a pulse train and a bus model
-- of the BIOS interrupt handler (read I_STATUS, write-1-to-clear bit10), under two
-- conditions:
--   (1) ce held '1' (normal BIOS execution)            -> baseline
--   (2) ce gated low across the LIGHTPEN pulse         -> hypothesis (B): does ce
--                                                          gating drop the edge?
-- and one stuck-level case:
--   (3) irq_LIGHTPEN held HIGH across two "events"     -> hypothesis (A): proves a
--                                                          level that never returns
--                                                          low yields NO 2nd edge.
--
-- Pass criteria: a clean LOW->HIGH on irq_LIGHTPEN, with ce='1' on the sampling edge,
-- sets I_STATUS bit10 exactly once; the BIOS W1C ack clears it; the NEXT clean edge
-- re-sets it. A level that stays high (no intervening low) does NOT re-set after ack.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_irq10 is
end entity;

architecture sim of tb_irq10 is
   signal clk1x   : std_logic := '0';
   signal ce      : std_logic := '1';
   signal reset   : std_logic := '1';

   signal lightpen : std_logic := '0';   -- = exp_irq10 / atapi INTRQ

   signal bus_addr      : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read      : std_logic := '0';
   signal bus_write     : std_logic := '0';
   signal bus_dataRead  : std_logic_vector(31 downto 0);
   signal irqRequest    : std_logic;
   signal export_irq    : unsigned(15 downto 0);

   signal ss_zero32 : std_logic_vector(31 downto 0) := (others => '0');

   constant TCK : time := 10 ns;
   signal done : boolean := false;
   signal errors : integer := 0;

   -- helper: read I_STATUS bit10 from the exported status
   function status10 (e : unsigned(15 downto 0)) return std_logic is
   begin
      return e(10);
   end function;
begin

   uut : entity work.irq
      port map (
         clk1x        => clk1x,
         ce           => ce,
         reset        => reset,
         irq_VBLANK   => '0',
         irq_GPU      => '0',
         irq_CDROM    => '0',
         irq_DMA      => '0',
         irq_TIMER0   => '0',
         irq_TIMER1   => '0',
         irq_TIMER2   => '0',
         irq_PAD      => '0',
         irq_SIO      => '0',
         irq_SPU      => '0',
         irq_LIGHTPEN => lightpen,
         bus_addr     => bus_addr,
         bus_dataWrite=> bus_dataWrite,
         bus_read     => bus_read,
         bus_write    => bus_write,
         bus_dataRead => bus_dataRead,
         irqRequest   => irqRequest,
         export_irq   => export_irq,
         SS_reset     => '0',
         SS_DataWrite => ss_zero32,
         SS_Adr       => "0",
         SS_wren      => '0',
         SS_rden      => '0',
         SS_DataRead  => open,
         SS_idle      => open
      );

   clkgen : process
   begin
      while not done loop
         clk1x <= '0'; wait for TCK/2;
         clk1x <= '1'; wait for TCK/2;
      end loop;
      wait;
   end process;

   stim : process
      -- write-1-to-clear I_STATUS bit10 (the BIOS ack); note irq.vhd uses AND-mask
      -- semantics: I_STATUS := I_STATUS and bus_dataWrite, so to CLEAR bit10 the BIOS
      -- writes a word with bit10 = '0' and all other bits '1'.
      procedure ack_bit10 is
      begin
         wait until rising_edge(clk1x);
         bus_addr      <= x"0";                              -- I_STATUS @ offset 0
         bus_dataWrite <= (others => '1');
         bus_dataWrite(10) <= '0';                           -- clear bit10, keep rest
         bus_write     <= '1';
         wait until rising_edge(clk1x);
         bus_write     <= '0';
         bus_dataWrite <= (others => '0');
      end procedure;

      procedure check(cond : boolean; msg : string) is
      begin
         if not cond then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
         else
            report "  ok: " & msg;
         end if;
      end procedure;
   begin
      -- unmask bit10 in I_MASK (offset 4) so irqRequest reflects bit10
      wait for 4*TCK;
      reset <= '0';
      wait until rising_edge(clk1x);
      bus_addr      <= x"4";                                 -- I_MASK
      bus_dataWrite <= (others => '0');
      bus_dataWrite(10) <= '1';
      bus_write     <= '1';
      wait until rising_edge(clk1x);
      bus_write     <= '0';
      bus_dataWrite <= (others => '0');
      wait until rising_edge(clk1x);

      ----------------------------------------------------------------------------
      -- CASE 1: ce='1', clean pulse -> bit10 sets, irqRequest asserts
      ce <= '1';
      lightpen <= '1';                                       -- rising edge
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);                          -- let latch settle
      check(status10(export_irq) = '1', "case1: clean LIGHTPEN rise sets I_STATUS bit10");
      check(irqRequest = '1',           "case1: irqRequest asserted");
      lightpen <= '0';                                       -- drop (atapi reg7 read)
      wait until rising_edge(clk1x);
      -- BIOS ack: clear bit10
      ack_bit10;
      wait until rising_edge(clk1x);
      check(status10(export_irq) = '0', "case1: ack cleared I_STATUS bit10");
      check(irqRequest = '0',           "case1: irqRequest deasserted after ack");

      ----------------------------------------------------------------------------
      -- CASE 2: SECOND clean pulse after a low gap -> bit10 RE-SETS (re-arm works)
      lightpen <= '1';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);
      check(status10(export_irq) = '1', "case2: 2nd clean rise RE-SETS I_STATUS bit10");
      lightpen <= '0';
      wait until rising_edge(clk1x);
      ack_bit10;
      wait until rising_edge(clk1x);
      check(status10(export_irq) = '0', "case2: 2nd ack clears bit10");

      ----------------------------------------------------------------------------
      -- CASE 3 (hyp A): LEVEL stays HIGH across an ack -> NO new edge -> bit10 does
      -- NOT re-set after ack (this is the stuck-level failure mode the atapi-side
      -- test reproduces when the ISR does not read reg7 to drop INTRQ).
      lightpen <= '1';                                       -- rise: sets bit10
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);
      check(status10(export_irq) = '1', "case3: level rise sets bit10");
      ack_bit10;                                             -- ack WITHOUT dropping lightpen
      wait until rising_edge(clk1x);
      -- lightpen still '1', no new rising edge -> bit10 must stay CLEARED
      check(status10(export_irq) = '0',
            "case3: with LIGHTPEN stuck HIGH, ack leaves bit10 CLEARED (no re-latch) => stuck-level loses the interrupt (hyp A)");
      lightpen <= '0';
      wait until rising_edge(clk1x);
      ack_bit10;
      wait until rising_edge(clk1x);

      ----------------------------------------------------------------------------
      -- CASE 4 (hyp B): pulse occurs entirely while ce='0' (a 1-cycle-wide pulse
      -- straddled by a ce-low window). irq.vhd only updates irqIn_1 when ce='1', so a
      -- pulse that rises AND falls during ce=0 leaves irqIn_1 unchanged and is MISSED.
      -- atapi INTRQ on real HW is many cycles wide and ce is '1' during BIOS polling,
      -- so this is a theoretical check, not the live failure.
      ce <= '0';
      lightpen <= '1';
      wait until rising_edge(clk1x);
      lightpen <= '0';                                       -- whole pulse inside ce=0
      wait until rising_edge(clk1x);
      ce <= '1';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);
      if status10(export_irq) = '1' then
         report "  note(case4): a ce=0 pulse was still captured (irqIn sampled high at ce resume)";
      else
         report "  note(case4): a pulse fully inside ce=0 was MISSED (hyp B is a real hazard IF atapi INTRQ could be that narrow; on HW it is not)";
      end if;
      ack_bit10;

      ----------------------------------------------------------------------------
      if errors = 0 then
         report "RESULT: PASS (irq10) - clean rises re-latch bit10 every time; stuck-level (case3) loses the 2nd interrupt as predicted";
      else
         report "RESULT: FAIL (irq10)" severity error;
      end if;
      done <= true;
      wait;
   end process;

end architecture;
