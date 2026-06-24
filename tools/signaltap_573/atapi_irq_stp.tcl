#!/usr/bin/env tclsh
# =============================================================================
# atapi_irq_stp.tcl -- GENERATE the SignalTap II .stp (and matching .qsf
# PRESERVE snippet) for the 573 ATAPI completion-IRQ probe.
#
# THE QUESTION (docs/2026-06-24-ddrsbm-bootcheck-handoff.md + the MAME oracle):
#   ddrsbm's BOOT CHECK drive check IRQ-waits (at 0x803cb4b8) on a SINGLE
#   non-data command: PACKET 0xA0 / CDB[0]=0x00 = TEST UNIT READY. The device
#   (rtl/atapi.v:319-325) raises irq_pending+irq_event for it; MAME shows that
#   one completion IRQ bumps the in-RAM counter [0x803d2280] (2->3, IRQ #8) and
#   releases the spin. On the de10 the core WEDGES at BOOT CHECK. Static
#   analysis says the atapi_intrq -> exp_irq10 -> irqIn(10) -> I_STATUS[10]
#   chain is correct and a single held-high IRQ is always caught -- so this
#   probe puts the runtime ON CAMERA to decide between:
#     (a) IRQ never asserts on silicon  (irq_out/irq_event quiet)
#     (b) asserts but never latched      (irq_out high, I_STATUS[10] stays 0)
#     (c) latched but never serviced     (I_STATUS[10]=1 but irq_pending never
#                                         falls / I_STATUS[10] never clears /
#                                         cpu exception[4] never pulses)
#
# ALL NODES ARE REGISTERS (PRESERVE_REGISTER) -- exp_irq10 is reconstructed
# offline from irq_out & ~r_devctl[1], so there is NO combinational tap (no
# "dangling comb net reads garbage" risk; RUNBOOK trap #1 avoided entirely).
#
# USAGE
#   tclsh atapi_irq_stp.tcl                 -> writes atapi_irq.stp + .qsf.snippet here
#   tclsh atapi_irq_stp.tcl /path/out.stp   -> writes there (+ sibling .qsf.snippet)
#   RECON=<mode> tclsh atapi_irq_stp.tcl    -> alternate trigger (no rebuild needed;
#                                              every node is a compiled trigger input)
#
# VALIDATE (seconds, no build) -- see RUNBOOK.md step 0:
#   scp atapi_irq.stp dell:/tmp/ && ssh dell 'docker run --rm -v /tmp:/tmp \
#     raetro/quartus:17.0 quartus_stp -t /tmp/validate_stp.tcl'   # expect OPEN-OK
#
# Hierarchy + names CONFIRMED 2026-06-24 from the recent map.rpt on dell
# (commit 76f0274): VHDL signals keep src name + [i]; Verilog regs keep src
# name. NO WILDCARDS (Quartus 17.0 silently drops PRESERVE_REGISTER wildcards).
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIG -- hierarchy prefixes (verbatim from map.rpt, leading |sys_top| omitted)
# ---------------------------------------------------------------------------
set AT  "emu:emu|system573_top:u_s573|atapi:u_atapi"
set IQ  "emu:emu|psx_mister:psx|psx_top:ipsx_top|irq:iirq"
set PT  "emu:emu|psx_mister:psx|psx_top:ipsx_top"
set CP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|cpu:icpu"

# Capture clock: clk2x (PROVEN node from the CLUT probe; outclk_1 of the main
# PLL). All probe signals are clk1x-domain -> sampled 2:1; dedup offline using
# the ce qualifier (we store ce=1 beats only). clk1x (outclk_wire[0]) would be
# the natural domain but is UNPROVEN as a SignalTap acquisition clock here;
# clk2x is the de-risked choice.
set CLOCK_NODE {emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[1]}

set JTAG_CHAIN  "DE-SoC \[1-4\]"
set JTAG_DEVICE "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

set INSTANCE_NAME "auto_signaltap_0"
set SS_NAME       "ss_atapi_irq"
set TRIG_NAME     "trig_atapi_irq"

# Buffer. ~67 data bits; depth 8192 ~= 74% M10K (FIT.md / netname-agent audit:
# RAM is roomy, the binding resource is comb/LAB which is unchanged by depth).
# 8192 @ clk2x ~= 121 us raw, longer with ce-qualified storage -- ample for the
# microsecond-scale TEST-UNIT-READY dispatch->IRQ->latch->ack sequence and the
# game's retry loop.
set SAMPLE_DEPTH 8192
set TRIGGER_POSITION "center"   ;# see lead-up AND aftermath of the event
if {[info exists ::env(TRIG_POS)]} { set TRIGGER_POSITION $::env(TRIG_POS) }
if {[info exists ::env(DEPTH)]}    { set SAMPLE_DEPTH $::env(DEPTH) }

# Storage qualifier: store only real clk1x beats (ce=high) -> drops the clk2x
# oversample duplicates, doubles the effective time window. ce is the PSX
# clk1x clock-enable (psx_top.vhd:249), mostly '1' during normal boot.
set QUAL_NODE "$PT|ce"

# ---------------------------------------------------------------------------
# WATCH LIST -- {fullbase width kind} ; width>1 -> base[0]..base[width-1];
# width==1 -> literal (base may already carry a [i]). kind: reg (PRESERVE_REGISTER).
# ALL registers -> the .qsf gets only PRESERVE_REGISTER lines (no KEEP/comb).
# ---------------------------------------------------------------------------
set NODES [list \
    [list "$AT|irq_event"   1 reg] \
    [list "$AT|irq_out"     1 reg] \
    [list "$AT|irq_pending" 1 reg] \
    [list "$AT|state"       3 reg] \
    [list "$AT|r_status"    8 reg] \
    [list "$AT|r_ireason"   8 reg] \
    [list "$AT|r_devctl"    8 reg] \
    [list "$AT|pkt_idx"     7 reg] \
    [list "$IQ|I_STATUS"   11 reg] \
    [list "$IQ|I_MASK"     11 reg] \
    [list "$IQ|irqIn_1\[10\]" 1 reg] \
    [list "$PT|ce"          1 reg] \
    [list "$CP|exception"   5 reg] \
]
# 1+1+1+3+8+8+8+7 + 11+11+1 + 1 + 5 = 67 data bits.
#  atapi irq_event/out/pending ... the device side: did it raise INTRQ?
#  state[2:0] (S_IDLE0 S_PKT1 S_DATAIN2 ..) + r_status/r_ireason/pkt_idx ......
#                                 identify TEST-UNIT-READY (no S_DATAIN) vs data cmds
#  r_devctl[1]=nIEN (INTRQ device-mask), [2]=SRST
#  I_STATUS[10]=ATAPI IRQ latched ; I_MASK[10]=IRQ10 enabled ; full[0..10]=context
#  irqIn_1[10] = the edge-detect prior sample (the miss bit)
#  ce = clk1x enable (qualifier) ; cpu exception[4]=interrupt slot taken

# ---------------------------------------------------------------------------
# TRIGGER (basic, single level, AND of per-bit patterns).
# DEFAULT = the completion-event signature: a fresh ATAPI interrupt event
# (irq_event=1) at command completion (state=S_IDLE=000, ireason=C/D|I/O=0x03,
# status=DRDY|DSC=0x50). This fires on the TEST-UNIT-READY drive-check gate
# (and the setup-PACKET completions); the game retries it in a loop so the
# analyzer triggers quickly. Center position captures the latch+ack aftermath.
# r_status bits: DRDY=0x40 (bit6), DSC=0x10 (bit4). r_ireason: CD=bit0, IO=bit1.
# ---------------------------------------------------------------------------
set TRIGGER_TERMS [list \
    [list "$AT|irq_event"      high] \
    [list "$AT|state\[2\]"     low ] \
    [list "$AT|state\[1\]"     low ] \
    [list "$AT|state\[0\]"     low ] \
    [list "$AT|r_ireason\[1\]" high] \
    [list "$AT|r_ireason\[0\]" high] \
    [list "$AT|r_status\[6\]"  high] \
    [list "$AT|r_status\[4\]"  high] \
]

# RECON modes (regenerate-only, NO rebuild) ----------------------------------
# RECON=any : broadest -- fire on ANY fresh ATAPI interrupt event.
if {[info exists ::env(RECON)] && $::env(RECON) eq "any"} {
    set TRIGGER_TERMS [list [list "$AT|irq_event" high]]
    puts "RECON=any: trigger = any irq_event pulse"
}
# RECON=istat10 : did IRQ10 EVER latch? fire when I_STATUS bit10 is high.
if {[info exists ::env(RECON)] && $::env(RECON) eq "istat10"} {
    set TRIGGER_TERMS [list [list "$IQ|I_STATUS\[10\]" high]]
    puts "RECON=istat10: trigger = I_STATUS\[10\]==1 (ATAPI IRQ latched)"
}
# RECON=irqout : fire while the device INTRQ level is asserted.
if {[info exists ::env(RECON)] && $::env(RECON) eq "irqout"} {
    set TRIGGER_TERMS [list [list "$AT|irq_out" high]]
    puts "RECON=irqout: trigger = atapi irq_out==1 (INTRQ asserted)"
}
# RECON=except : fire when the CPU takes an interrupt-class exception.
if {[info exists ::env(RECON)] && $::env(RECON) eq "except"} {
    set TRIGGER_TERMS [list [list "$CP|exception\[4\]" high]]
    puts "RECON=except: trigger = cpu exception\[4\]==1 (interrupt taken)"
}
# RECON=pktdispatch : fire as the 6th CDB word lands (state=S_PKT, pkt_idx=10).
if {[info exists ::env(RECON)] && $::env(RECON) eq "pktdispatch"} {
    set TRIGGER_TERMS [list \
        [list "$AT|state\[2\]" low ] [list "$AT|state\[1\]" low ] [list "$AT|state\[0\]" high] \
        [list "$AT|pkt_idx\[3\]" high] [list "$AT|pkt_idx\[1\]" high] ]
    puts "RECON=pktdispatch: trigger = S_PKT & pkt_idx==0x0A (CDB complete)"
}

# ---------------------------------------------------------------------------
# generation -- machinery mirrored from clut_race_stp.tcl (proven XML shape)
# ---------------------------------------------------------------------------
set out "atapi_irq.stp"
if {$argc >= 1} { set out [lindex $argv 0] }

# expand watch list to flat bit list (data_index order = list order, LSB first)
set BITS {}
set QSF {}
foreach n $NODES {
    lassign $n name width kind
    if {$width == 1} {
        lappend BITS $name
        lappend QSF [list $name $kind]
    } else {
        for {set i 0} {$i < $width} {incr i} {
            lappend BITS "${name}\[$i\]"
            lappend QSF [list "${name}\[$i\]" $kind]
        }
    }
}
set NBITS [llength $BITS]

array set TPAT {}
foreach t $TRIGGER_TERMS { lassign $t tn tp ; set TPAT($tn) $tp }
foreach tn [array names TPAT] {
    if {[lsearch -exact $BITS $tn] < 0} {
        puts stderr "FATAL: trigger node not in watch list: $tn"; exit 1
    }
}
if {[lsearch -exact $BITS $QUAL_NODE] < 0} {
    puts stderr "FATAL: storage-qualifier node not in watch list: $QUAL_NODE"; exit 1
}

proc xesc {s} { string map {& &amp; < &lt; > &gt; \" &quot;} $s }

proc leaf_attrs {idx name} {
    global TPAT QUAL_NODE
    set a "data_index=\"$idx\" duplicate_name_allowed=\"false\" is_data_input=\"true\" is_node_valid=\"true\" is_selected=\"false\""
    if {$name eq $QUAL_NODE} {
        append a " is_storage_input=\"true\""
    } else {
        append a " is_storage_input=\"false\""
    }
    append a " is_trigger_input=\"true\""
    if {[info exists TPAT($name)]} {
        append a " level-0=\"$TPAT($name)\""
    } else {
        append a " level-0=\"dont_care\""
    }
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
set i 0
foreach b $BITS { puts $f "          <node [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </unified_setup_data_view>"
puts $f "        <data_view>"
set i 0
foreach b $BITS { puts $f "          <net [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </data_view>"
puts $f "        <setup_view>"
set i 0
foreach b $BITS { puts $f "          <net [leaf_attrs $i $b]/>" ; incr i }
puts $f "        </setup_view>"
puts $f "        <trigger_in_editor/>"
puts $f "        <trigger_out_editor/>"
puts $f "      </presentation>"
puts $f "      <trigger CRC=\"573A7A10\" attribute_mem_mode=\"false\" gap_record=\"true\" global_temp=\"1\" is_expanded=\"true\" name=\"$TRIG_NAME\" position=\"$TRIGGER_POSITION\" power_up_trigger_mode=\"false\" record_data_gap=\"true\" segment_size=\"1\" storage_mode=\"conditional\" storage_qualifier_disabled=\"no\" storage_qualifier_port_is_pin=\"false\" storage_qualifier_port_name=\"auto_stp_external_storage_qualifier\" storage_qualifier_port_tap_mode=\"classic\" trigger_type=\"circular\">"
puts $f "        <power_up_trigger position=\"$TRIGGER_POSITION\" storage_qualifier_disabled=\"no\"/>"
puts $f "        <events use_custom_flow_control=\"no\">"
set terms {}
foreach t $TRIGGER_TERMS { lassign $t tn tp ; lappend terms "'[xesc $tn]' == $tp" }
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
puts $f "            <power_up>"
puts $f "            </power_up>"
puts $f "            <op_node/>"
puts $f "          </storage_qualifier_level>"
puts $f "          <storage_qualifier_level type=\"basic\">"
puts $f "            <power_up>"
puts $f "            </power_up>"
puts $f "            <op_node/>"
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

# --- emit the matching .qsf PRESERVE snippet (single-sourced from NODES) -----
set qsfout [file rootname $out].qsf.snippet
set qf [open $qsfout w]
puts $qf "# ============================================================================="
puts $qf "# atapi_irq.qsf.snippet -- QSF additions for the ATAPI completion-IRQ probe."
puts $qf "# GENERATED by atapi_irq_stp.tcl from the SAME node list as atapi_irq.stp"
puts $qf "# (single-sourced -> the .stp watch list and these preserves cannot drift)."
puts $qf "# Append to Konami_System_573.qsf on the dbg branch; then RUNBOOK 1b SLD"
puts $qf "# expansion (quartus_stp ... --enable). NO WILDCARDS. All nodes are regs."
puts $qf "# ============================================================================="
puts $qf "set_global_assignment -name ENABLE_SIGNALTAP ON"
foreach q $QSF {
    lassign $q path kind
    if {$kind eq "reg"} {
        puts $qf "set_instance_assignment -name PRESERVE_REGISTER ON -to \"$path\""
    } else {
        puts $qf "set_instance_assignment -name KEEP ON -to \"$path\""
    }
}
puts $qf "set_global_assignment -name ENABLE_LOGIC_ANALYZER_INTERFACE ON"
close $qf

puts "wrote $out: $NBITS data bits, depth $SAMPLE_DEPTH, trigger=$TRIG_NAME ([llength $TRIGGER_TERMS] terms), qualifier=$QUAL_NODE"
puts "wrote $qsfout: [llength $QSF] PRESERVE_REGISTER lines"
puts "NEXT: validate (RUNBOOK step 0), then SLD-expand on dell (RUNBOOK 1b)"
