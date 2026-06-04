# =============================================================================
# timing_triage.tcl -- post-fit timing triage for the Konami System 573 core.
#
# Runs under quartus_sta on an ALREADY-FITTED project (uses the db/ netlist; does
# NOT re-fit). Prints, for the core PSX clocks, every NEGATIVE-slack endpoint with
# its From/To node + launch clock, then the worst-slack path for each CDR-relevant
# block (atapi / system573_top / cd_top / EXP1 master). The point is to answer one
# question fast after any rebuild: "are the failing paths in the CDR path or not?"
#
# Clock map (same VCO = emu|pll general[0].FRACTIONAL_PLL; all edge-aligned):
#   general[0] divclk  33.87 MHz  = clk_1x  (PSX CPU + EXP1 bus + atapi/s573 + IRQ)
#   general[1] divclk  67.74 MHz  = clk_2x
#   general[2] divclk 101.61 MHz  = clk_3x  (SDRAM controller)
#
# Usage (on the dell build box, repo dir mounted at /work in the Quartus image):
#   docker run --rm -v "$PWD":/work -w /work --entrypoint quartus_sta \
#     raetro/quartus:17.0 -t tools/timing_triage.tcl
# (tools/dell_timing.sh wraps this.)
# =============================================================================
project_open Konami_System_573
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set CLK(0) {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set CLK(1) {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set CLK(2) {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}

proc short {n} {
  regsub {emu:emu\|psx_mister:psx\|psx_top:ipsx_top\|} $n "" n
  regsub {emu:emu\|} $n "" n
  return $n
}
proc clkshort {n} {
  regsub {emu\|pll\|pll_inst\|altera_pll_i\|} $n "" n
  regsub {.gpll.*} $n "" n
  return $n
}

puts "===================== NEGATIVE-SLACK CORE-CLOCK ENDPOINTS ====================="
foreach idx {0 1 2} {
  foreach ty {setup hold} {
    set paths [get_timing_paths -$ty -npaths 400 -to_clock $CLK($idx) -nworst 1 -detail path_only]
    foreach_in_collection p $paths {
      set s [get_path_info $p -slack]
      if {$s < 0} {
        set from [short [get_node_info [get_path_info $p -from] -name]]
        set to   [short [get_node_info [get_path_info $p -to] -name]]
        set fc   [clkshort [get_clock_info [get_path_info $p -from_clock] -name]]
        puts [format "NEG %-5s -> general\[%d\]  slack=%-7s  from_clk=%-11s  %s  ->  %s" $ty $idx $s $fc $from $to]
      }
    }
  }
}

puts "===================== CDR-RELEVANT BLOCK WORST SLACK (sanity) ================="
foreach pat {*atapi* *system573_top* *cd_top* *exp1* *memctrl*MC_EXP1*} {
  set k [get_keepers $pat]
  if {[get_collection_size $k] > 0} {
    set paths [get_timing_paths -setup -npaths 1 -nworst 1 -to $k -detail path_only]
    foreach_in_collection p $paths {
      puts [format "CDR %-22s keepers=%-5d worst_setup_slack=%-7s to=%s" \
        $pat [get_collection_size $k] [get_path_info $p -slack] \
        [short [get_node_info [get_path_info $p -to] -name]]]
    }
  } else {
    puts [format "CDR %-22s keepers=0 (no match)" $pat]
  }
}
project_close
