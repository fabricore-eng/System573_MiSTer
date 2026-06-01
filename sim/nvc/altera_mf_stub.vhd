-- Empty altera_mf component package for open-source VHDL simulation (NVC/GHDL).
-- psx/rtl/spu_ram.vhd carries `library altera_mf; use altera_mf.altera_mf_components.all;`
-- but instantiates ZERO altera_mf primitives; the genuinely altera_mf-dependent RAMs
-- (dpram/RamMLAB/SyncRamDualByteEnable in psx/rtl) are replaced in sim by the behavioral
-- models in psx/sim/system/src/mem, exactly as upstream's vcom_all.bat does. This stub
-- just satisfies the dangling use-clause so analysis succeeds without Quartus libraries.
library ieee;
use ieee.std_logic_1164.all;

package altera_mf_components is
end package;
