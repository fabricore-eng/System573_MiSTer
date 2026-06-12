-- tb_sio_dsr.vhd - red/green NVC test of the System 573 SIO1 DSR cassette-presence
-- patch (psx_patches/0024-s573-sio1-dsr-presence.patch).
--
-- MECHANISM UNDER TEST: the Konami BIOS presence leaf 0x80038A28 polls SIO1_STAT
-- (0x1F801054) bit 7 (DSR). Every real security cassette asserts the slot's DSR
-- line electrically (MAME k573cass raises it at device_start). The vendored
-- psx/rtl/sio.vhd stub hardwires SIO_STAT = x"00000005" (and the CTRL bit22
-- soft-reset path re-forces it), so bit7 = 0 -> BIOS -12 -> "SECURITY-CASSETTE
-- DOES NOT EXIST".
--
-- The DUT is instantiated WITHOUT binding dsr_in: the port is DEFAULTED ('1' =
-- cassette installed) in the 0024 patch, so this same testbench elaborates on
-- BOTH trees and a true red is possible:
--   * pre-0024 (pristine/0001..0023 stack): STAT reads x"00000005", bit7=0
--     (byte-identical to the 0x0005 our silicon BIOS read)        -> RED (FAIL)
--   * 0024 tree: STAT reads x"00000085" -- bit7=1 with the low bits 0000101
--     preserved (the 0x85-class value MAME's run-A trace shows)   -> GREEN (PASS)
-- plus the CTRL-reset hardening check: writing SIO_CTRL (offset 8, writeMask
-- "1100") with bit22=1 re-forces the internal SIO_STAT register to x"00000005";
-- bit 7 must STILL read 1 afterwards (the patch ORs DSR at READBACK exactly so
-- this re-force cannot clear presence).
--
-- Run: sim/nvc/run_sio_dsr.sh
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_sio_dsr is
end entity;

architecture sim of tb_sio_dsr is
   signal clk1x         : std_logic := '0';
   signal ce            : std_logic := '1';
   signal reset         : std_logic := '1';

   signal bus_addr      : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_read      : std_logic := '0';
   signal bus_write     : std_logic := '0';
   signal bus_writeMask : std_logic_vector(3 downto 0) := (others => '0');
   signal bus_dataRead  : std_logic_vector(31 downto 0);

   signal ss_zero32 : std_logic_vector(31 downto 0) := (others => '0');

   constant TCK : time := 10 ns;
   signal done   : boolean := false;
   signal errors : integer := 0;
begin

   -- dsr_in is deliberately NOT associated here: pre-0024 the port does not exist
   -- (same TB elaborates), post-0024 the default '1' models the installed cassette.
   uut : entity work.sio
      port map (
         clk1x             => clk1x,
         ce                => ce,
         reset             => reset,
         bus_addr          => bus_addr,
         bus_dataWrite     => bus_dataWrite,
         bus_read          => bus_read,
         bus_write         => bus_write,
         bus_writeMask     => bus_writeMask,
         bus_dataRead      => bus_dataRead,
         loading_savestate => '0',
         SS_reset          => '0',
         SS_DataWrite      => ss_zero32,
         SS_Adr            => "000",
         SS_wren           => '0',
         SS_rden           => '0',
         SS_DataRead       => open
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
      variable stat1, stat2 : std_logic_vector(31 downto 0);

      -- one registered bus read of SIO halfword offset a: strobe for one ce cycle,
      -- capture bus_dataRead the cycle AFTER the strobe (sio.vhd registers it).
      procedure bus_rd (a : in unsigned(3 downto 0);
                        d : out std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= a;
         bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         wait until rising_edge(clk1x);   -- registered read data now valid
         d := bus_dataRead;
      end procedure;

      procedure check (cond : boolean; msg : string) is
      begin
         if not cond then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
         else
            report "  ok: " & msg;
         end if;
      end procedure;
   begin
      wait for 4*TCK;
      wait until rising_edge(clk1x);
      reset <= '0';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);

      -------------------------------------------------------------------------
      -- (1) the BIOS presence poll: read SIO1_STAT (offset 4)
      bus_rd(x"4", stat1);
      report "SIO1_STAT after reset = 0x" & to_hstring(stat1) &
             " (silicon BIOS read 0x0005; MAME cassette run-A read 0x85)";
      check(stat1(7) = '1',
            "STAT bit7 (DSR) = 1 -> cassette PRESENT (RED pre-0024: reads 0, the -12 path)");
      check(stat1(6 downto 0) = "0000101",
            "STAT low bits 0000101 (TX ready/idle) preserved");

      -------------------------------------------------------------------------
      -- (2) SIO_CTRL write with bit22=1 (offset 8, writeMask "1100"): the stub's
      -- soft-reset path re-forces SIO_STAT <= x"00000005". Presence must survive.
      wait until rising_edge(clk1x);
      bus_addr      <= x"8";
      bus_dataWrite <= (others => '0');
      bus_dataWrite(22) <= '1';            -- SIO_CTRL reset bit
      bus_writeMask <= "1100";             -- upper-halfword write = CTRL
      bus_write     <= '1';
      wait until rising_edge(clk1x);
      bus_write     <= '0';
      bus_writeMask <= "0000";
      bus_dataWrite <= (others => '0');
      wait until rising_edge(clk1x);

      bus_rd(x"4", stat2);
      report "SIO1_STAT after CTRL bit22 soft-reset = 0x" & to_hstring(stat2);
      check(stat2(7) = '1',
            "STAT bit7 STILL 1 after the CTRL-reset STAT re-force (OR-at-readback holds)");
      check(stat2(6 downto 0) = "0000101",
            "STAT low bits still 0000101 after CTRL reset");

      -------------------------------------------------------------------------
      if errors = 0 then
         report "RESULT: PASS (sio_dsr) - STAT=0x" & to_hstring(stat1) &
                ", post-CTRL-reset STAT=0x" & to_hstring(stat2) &
                " - bit7 presence held through the re-force";
      else
         report "RESULT: FAIL (sio_dsr) - STAT=0x" & to_hstring(stat1) &
                ", post-CTRL-reset STAT=0x" & to_hstring(stat2) severity error;
      end if;
      done <= true;
      wait;
   end process;

end architecture;
