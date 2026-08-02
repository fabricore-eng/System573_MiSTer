# sta_hdmi.tcl -- is the 573's pll_hdmi setup failure REAL routing or a
# clock-relationship ARTIFACT? Adapted from NetVOB_MiSTer tools/build/sta_clk_check.tcl.
# Test (their finding): levels==1 with a huge arrival cannot be real -- one logic
# level is ~1-3ns. A REAL failure has many levels AND a plausible arrival.
project_open Konami_System_573
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set hdmi {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}

puts "##### WORST pll_hdmi PATHS #####"
set ps [get_timing_paths -setup -to_clock $hdmi -npaths 12 -nworst 12]
if {[get_collection_size $ps] == 0} { puts "(no paths to hdmi clock)" }
foreach_in_collection p $ps {
    set lv [get_path_info $p -num_logic_levels]
    set sl [get_path_info $p -slack]
    set ar [get_path_info $p -arrival_time]
    set rq [get_path_info $p -required_time]
    set fc [get_node_info -name [get_path_info $p -from]]
    set tc [get_node_info -name [get_path_info $p -to]]
    set tag "ARTIFACT?"; if {$lv > 3} { set tag "REAL" }
    puts [format "slack=%-9s levels=%-4s arrival=%-9s required=%-9s %s" $sl $lv $ar $rq $tag]
    puts "    FROM $fc"
    puts "    TO   $tc"
}

puts "##### INTRA-domain only (hdmi -> hdmi): the paths that are unambiguously real #####"
set ps2 [get_timing_paths -setup -from_clock $hdmi -to_clock $hdmi -npaths 5 -nworst 5]
if {[get_collection_size $ps2] == 0} { puts "(none)" }
foreach_in_collection p $ps2 {
    puts [format "slack=%-9s levels=%s" [get_path_info $p -slack] [get_path_info $p -num_logic_levels]]
}
