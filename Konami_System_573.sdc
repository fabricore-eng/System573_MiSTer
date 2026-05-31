# =============================================================================
# Konami System 573 - timing constraints
#
# The bulk of the MiSTer clock definitions (CLK_50M, the PLL outputs, the HPS
# SDRAM/DDR3 interfaces) are declared in sys/sys.sdc. This file holds only the
# core-specific constraints. With the sys submodule in place, sys/sys.sdc is
# included via the project (see Konami_System_573.qsf).
# =============================================================================

# Placeholder core clock until the PLL is brought up (see rtl/emu.sv).
create_clock -name CLK_50M -period 20.000 [get_ports {CLK_50M}]

derive_pll_clocks
derive_clock_uncertainty
