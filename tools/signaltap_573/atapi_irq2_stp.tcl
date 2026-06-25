#!/usr/bin/env tclsh
# =============================================================================
# atapi_irq2_stp.tcl -- v2 SignalTap probe: WHERE does the CPU go + does the
# data drain, during ddrsbm's stuck ATAPI data-in IRQ.
#
# v1 PROVED (local/signaltap/20260624_18*): IRQ delivery works end-to-end
# (irq_out -> I_STATUS[10] latch -> I_MASK[10] enabled -> CPU exception[4]),
# but a DATA-IN data-ready IRQ (r_status=0x48 DRQ, ireason=0x2) is serviced
# ~96us LATE and the DATA NEVER DRAINS (DRQ stuck, no completion). The MAME
# handler trace (0x803cb2dc) shows a straight-line ISR: bump counter -> read
# reg7 (INTRQ ack) -> dispatch on a SW state byte -> ch5 DMA (disc) / PIO drain.
# The 96us gap is BETWEEN the CPU taking the exception and the handler reading
# reg7 -- i.e. in the kernel/BIOS dispatcher (0x80000000 region, not in the
# game dump). This probe taps the CPU PC + the atapi drain index to SEE it:
#   * PC[31:0]  -- is the CPU stuck in the BIOS dispatcher (0x80000xxx), the
#                  game handler (0x803cbxxx), the DMA arm (0x803cddb8), or a
#                  wait loop?  Resolves suspect (a) dispatcher vs (c) DMA.
#   * ridx[12:0]-- the atapi data-in index: ADVANCES iff data is being drained
#                  (DMA or PIO both drive it). Stuck => no drain.
#   * r_bclo/r_bchi -- byte count (0x0800 sector read vs small drive-check cmd).
# Trigger: I_STATUS[10] & I_MASK[10] high (the game's IRQ-driven context),
# position PRE -> ~105us of aftermath AFTER the latch (the 96us gap + handler).
#
# ALL REGISTERS (PRESERVE_REGISTER). Emits .stp + matching .qsf snippet.
# Hierarchy/clock/CRC machinery identical to atapi_irq_stp.tcl (proven).
# =============================================================================

set AT  "emu:emu|system573_top:u_s573|atapi:u_atapi"
set IQ  "emu:emu|psx_mister:psx|psx_top:ipsx_top|irq:iirq"
set PT  "emu:emu|psx_mister:psx|psx_top:ipsx_top"
set CP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|cpu:icpu"

set CLOCK_NODE {emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[1]}
set JTAG_CHAIN  "DE-SoC \[1-4\]"
set JTAG_DEVICE "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"
set INSTANCE_NAME "auto_signaltap_0"
set SS_NAME       "ss_atapi_irq"
set TRIG_NAME     "trig_atapi_irq"
set SAMPLE_DEPTH 8192
set TRIGGER_POSITION "pre"
if {[info exists ::env(TRIG_POS)]} { set TRIGGER_POSITION $::env(TRIG_POS) }
set QUAL_NODE "$PT|ce"

# WATCH LIST -- {fullbase width kind}. ALL reg (PRESERVE_REGISTER).
set NODES [list \
    [list "$CP|PC"          32 reg] \
    [list "$AT|ridx"        13 reg] \
    [list "$AT|r_status"     8 reg] \
    [list "$AT|r_ireason"    8 reg] \
    [list "$AT|r_bclo"       8 reg] \
    [list "$AT|r_bchi"       8 reg] \
    [list "$AT|irq_out"      1 reg] \
    [list "$AT|irq_pending"  1 reg] \
    [list "$IQ|I_STATUS\[10\]" 1 reg] \
    [list "$IQ|I_MASK\[10\]"   1 reg] \
    [list "$PT|ce"           1 reg] \
]
# 32+13+8+8+8+8+1+1+1+1+1 = 82 data bits.

# TRIGGER: the game's IRQ-driven latch -- I_STATUS[10] & I_MASK[10] high.
set TRIGGER_TERMS [list \
    [list "$IQ|I_STATUS\[10\]" high] \
    [list "$IQ|I_MASK\[10\]"   high] ]

# RECON=irqout : fire on the device INTRQ level (catch the event even if the
# latch is somehow missed). RECON=any-pc : fire on ridx!=0 (data moving).
if {[info exists ::env(RECON)] && $::env(RECON) eq "irqout"} {
    set TRIGGER_TERMS [list [list "$AT|irq_out" high]]
    puts "RECON=irqout: trigger = irq_out high"
}
if {[info exists ::env(RECON)] && $::env(RECON) eq "drain"} {
    # fire when ridx has advanced past 0 -- proves data IS draining
    set TRIGGER_TERMS [list [list "$AT|ridx\[3\]" high]]
    puts "RECON=drain: trigger = ridx\[3\] high (>=8 words drained)"
}
# RECON=pc : trigger on PC == PC_TRIG (default 0x803cb2dc, the ATAPI handler
# entry). pre-pos -> capture the handler's execution forward; ridx advancing
# afterwards = the handler DOES drain (bug = the ~96us deferral); ridx stuck =
# the handler runs but does NOT drain (bug = handler logic / our core's path).
if {[info exists ::env(RECON)] && $::env(RECON) eq "pc"} {
    set tw 0x803cb2dc
    if {[info exists ::env(PC_TRIG)]} { set tw $::env(PC_TRIG) }
    set tw [expr {$tw + 0}]
    set TRIGGER_TERMS {}
    for {set b 31} {$b >= 0} {incr b -1} {
        set pol [expr {(($tw >> $b) & 1) ? "high" : "low"}]
        lappend TRIGGER_TERMS [list "$CP|PC\[$b\]" $pol]
    }
    puts [format "RECON=pc MODE: trigger = PC==0x%08X (ATAPI handler entry)" $tw]
}

# ---------------------------------------------------------------------------
# generation (identical machinery to atapi_irq_stp.tcl)
# ---------------------------------------------------------------------------
set out "atapi_irq2.stp"
if {$argc >= 1} { set out [lindex $argv 0] }

set BITS {}
set QSF {}
foreach n $NODES {
    lassign $n name width kind
    if {$width == 1} {
        lappend BITS $name ; lappend QSF [list $name $kind]
    } else {
        for {set i 0} {$i < $width} {incr i} {
            lappend BITS "${name}\[$i\]" ; lappend QSF [list "${name}\[$i\]" $kind]
        }
    }
}
set NBITS [llength $BITS]

array set TPAT {}
foreach t $TRIGGER_TERMS { lassign $t tn tp ; set TPAT($tn) $tp }
foreach tn [array names TPAT] {
    if {[lsearch -exact $BITS $tn] < 0} { puts stderr "FATAL: trigger node not in watch list: $tn"; exit 1 }
}
if {[lsearch -exact $BITS $QUAL_NODE] < 0} { puts stderr "FATAL: qualifier not in watch list: $QUAL_NODE"; exit 1 }

proc xesc {s} { string map {& &amp; < &lt; > &gt; \" &quot;} $s }
proc leaf_attrs {idx name} {
    global TPAT QUAL_NODE
    set a "data_index=\"$idx\" duplicate_name_allowed=\"false\" is_data_input=\"true\" is_node_valid=\"true\" is_selected=\"false\""
    if {$name eq $QUAL_NODE} { append a " is_storage_input=\"true\"" } else { append a " is_storage_input=\"false\"" }
    append a " is_trigger_input=\"true\""
    if {[info exists TPAT($name)]} { append a " level-0=\"$TPAT($name)\"" } else { append a " level-0=\"dont_care\"" }
    append a " name=\"[xesc $name]\""
    if {$name eq $QUAL_NODE} {
        append a " pwr_storage-0=\"dont_care\" pwr_storage-1=\"dont_care\" pwr_storage-2=\"dont_care\""
        append a " storage-0=\"high\" storage-1=\"dont_care\" storage-2=\"dont_care\" storage_index=\"0\""
    }
    append a " tap_mode=\"classic\" trigger_index=\"$idx\" type=\"unknown\""
    return $a
}

set f [open $out w]
puts $f "<session jtag_chain=\"[xesc $JTAG_CHAIN]\" jtag_device=\"[xesc $JTAG_DEVICE]\" sof_file=\"\">"
puts $f "  <display_tree gui_logging_enabled=\"0\">"
puts $f "    <display_branch instance=\"$INSTANCE_NAME\" log=\"USE_GLOBAL_TEMP\" signal_set=\"USE_GLOBAL_TEMP\" trigger=\"USE_GLOBAL_TEMP\"/>"
puts $f "  </display_tree>"
puts $f "  <instance enabled=\"true\" entity_name=\"sld_signaltap\" is_auto_node=\"yes\" is_expanded=\"true\" name=\"$INSTANCE_NAME\" source_file=\"sld_signaltap.vhd\">"
puts $f "    <node_ip_info instance_id=\"0\" mfg_id=\"110\" node_id=\"0\" version=\"6\"/>"
puts $f "    <signal_set global_temp=\"1\" is_expanded=\"true\" name=\"$SS_NAME\">"
puts $f "      <clock name=\"[xesc $CLOCK_NODE]\" polarity=\"posedge\" tap_mode=\"classic\"/>"
puts $f "      <config pipeline_level=\"0\" ram_type=\"AUTO\" reserved_data_nodes=\"0\" reserved_storage_qualifier_nodes=\"0\" reserved_trigger_nodes=\"0\" sample_depth=\"$SAMPLE_DEPTH\" trigger_in_enable=\"no\" trigger_out_enable=\"no\"/>"
puts $f "      <top_entity/>"
puts $f "      <signal_vec>"
puts $f "        <trigger_input_vec>"
foreach b $BITS { puts $f "          <wire name=\"[xesc $b]\" tap_mode=\"classic\"/>" }
puts $f "        </trigger_input_vec>"
puts $f "        <data_input_vec>"
foreach b $BITS { puts $f "          <wire name=\"[xesc $b]\" tap_mode=\"classic\"/>" }
puts $f "        </data_input_vec>"
puts $f "        <storage_qualifier_input_vec>"
puts $f "          <wire name=\"[xesc $QUAL_NODE]\" tap_mode=\"classic\"/>"
puts $f "        </storage_qualifier_input_vec>"
puts $f "      </signal_vec>"
puts $f "      <presentation>"
puts $f "        <unified_setup_data_view>"
set i 0 ; foreach b $BITS { puts $f "          <node [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </unified_setup_data_view>"
puts $f "        <data_view>"
set i 0 ; foreach b $BITS { puts $f "          <net [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </data_view>"
puts $f "        <setup_view>"
set i 0 ; foreach b $BITS { puts $f "          <net [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </setup_view>"
puts $f "        <trigger_in_editor/>"
puts $f "        <trigger_out_editor/>"
puts $f "      </presentation>"
puts $f "      <trigger CRC=\"573A7A20\" attribute_mem_mode=\"false\" gap_record=\"true\" global_temp=\"1\" is_expanded=\"true\" name=\"$TRIG_NAME\" position=\"$TRIGGER_POSITION\" power_up_trigger_mode=\"false\" record_data_gap=\"true\" segment_size=\"1\" storage_mode=\"conditional\" storage_qualifier_disabled=\"no\" storage_qualifier_port_is_pin=\"false\" storage_qualifier_port_name=\"auto_stp_external_storage_qualifier\" storage_qualifier_port_tap_mode=\"classic\" trigger_type=\"circular\">"
puts $f "        <power_up_trigger position=\"$TRIGGER_POSITION\" storage_qualifier_disabled=\"no\"/>"
puts $f "        <events use_custom_flow_control=\"no\">"
set terms {} ; foreach t $TRIGGER_TERMS { lassign $t tn tp ; lappend terms "'[xesc $tn]' == $tp" }
puts $f "          <level enabled=\"yes\" name=\"condition1\" type=\"basic\">[join $terms { &amp;&amp; }]"
puts $f "            <power_up enabled=\"yes\">"
puts $f "            </power_up><op_node/>"
puts $f "          </level>"
puts $f "        </events>"
puts $f "        <storage_qualifier_events>"
puts $f "          <transitional>1"
puts $f "            <pwr_up_transitional>1</pwr_up_transitional>"
puts $f "          </transitional>"
puts $f "          <storage_qualifier_level type=\"basic\">'[xesc $QUAL_NODE]' == high"
puts $f "            <power_up>"
puts $f "            </power_up>"
puts $f "            <op_node/>"
puts $f "          </storage_qualifier_level>"
puts $f "          <storage_qualifier_level type=\"basic\">"
puts $f "            <power_up></power_up><op_node/>"
puts $f "          </storage_qualifier_level>"
puts $f "          <storage_qualifier_level type=\"basic\">"
puts $f "            <power_up></power_up><op_node/>"
puts $f "          </storage_qualifier_level>"
puts $f "        </storage_qualifier_events>"
puts $f "        <log>"
puts $f "          <data global_temp=\"1\" name=\"log: empty\"/>"
puts $f "          <extradata/>"
puts $f "        </log>"
puts $f "      </trigger>"
puts $f "    </signal_set>"
puts $f "    <position_info>"
puts $f "      <single attribute=\"active tab\" value=\"1\"/>"
puts $f "    </position_info>"
puts $f "  </instance>"
puts $f "  <mnemonics/>"
puts $f "  <static_plugin_mnemonics/>"
puts $f "  <global_info>"
puts $f "    <single attribute=\"active instance\" value=\"0\"/>"
puts $f "  </global_info>"
puts $f "</session>"
close $f

set qsfout [file rootname $out].qsf.snippet
set qf [open $qsfout w]
puts $qf "# atapi_irq2.qsf.snippet -- GENERATED by atapi_irq2_stp.tcl (single-sourced)."
puts $qf "# v2 PC+drain probe. Append to Konami_System_573.qsf on the dbg branch;"
puts $qf "# then SLD-expand (quartus_stp ... --stp_file atapi_irq2.stp --enable). NO WILDCARDS."
puts $qf "set_global_assignment -name ENABLE_SIGNALTAP ON"
foreach q $QSF {
    lassign $q path kind
    if {$kind eq "reg"} { puts $qf "set_instance_assignment -name PRESERVE_REGISTER ON -to \"$path\"" } \
    else { puts $qf "set_instance_assignment -name KEEP ON -to \"$path\"" }
}
puts $qf "set_global_assignment -name ENABLE_LOGIC_ANALYZER_INTERFACE ON"
close $qf

puts "wrote $out: $NBITS data bits, depth $SAMPLE_DEPTH, trigger=$TRIG_NAME ([llength $TRIGGER_TERMS] terms), qualifier=$QUAL_NODE"
puts "wrote $qsfout: [llength $QSF] PRESERVE lines"
