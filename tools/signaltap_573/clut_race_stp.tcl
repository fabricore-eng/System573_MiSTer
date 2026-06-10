#!/usr/bin/env tclsh
# =============================================================================
# clut_race_stp.tcl -- GENERATE the SignalTap II .stp for the 573 CLUT-fetch
# race probe (the hyperbbc menu-panel wrong-palette garble).
#
# WHAT IT PROBES
#   The game draws 320 textured 4bpp quads, all requesting CLUT row 491
#   (VRAM y=0x1EB). On HW the pixelpipeline's RESIDENT row (textPalY) ends up
#   a NEIGHBOR row (observed 480-509) -> wrong palette. Palette data in VRAM
#   is byte-correct, GP0 stream is MAME-identical => the loss is inside the
#   GPU's render-time palette-fetch path. Prime suspect: DISPLAY SCANOUT
#   (gpu_videoout) sharing the one VRAM port. gpu.vhd:1620-1623 OR-MERGES all
#   requestors' reqVRAMXPos/YPos/Size onto one bus -- a same-cycle
#   pixelpipeline+videoout request pair corrupts the issued address. The
#   watch list captures both sides of that arbiter so one capture can
#   CONFIRM or REFUTE scanout involvement.
#
# USAGE
#   tclsh clut_race_stp.tcl                  -> writes clut_race.stp here
#   tclsh clut_race_stp.tcl /path/out.stp    -> writes there
#   (Pure Tcl -- no Quartus packages needed; also runs under quartus_stp -t.)
#
# VALIDATE (seconds, no build, no JTAG) -- do this after ANY regeneration:
#   scp clut_race.stp dell:/tmp/ && ssh dell 'docker run --rm -v /tmp:/tmp \
#     raetro/quartus:17.0 quartus_stp -t /tmp/validate_stp.tcl'   # see RUNBOOK
#   (validate_stp.tcl = open_session -name /tmp/clut_race.stp; close_session.
#    quartus_stp rejects malformed .stp at open_session with "syntax error".)
#
# RUNTIME RE-TUNE WITHOUT RECOMPILE: every tapped node is compiled as a
# trigger input, so basic per-bit trigger patterns can be changed by editing
# the TRIGGER TABLE below + regenerating this .stp + re-running the capture.
# The FPGA bitstream does NOT need rebuilding as long as the NODE LIST,
# SAMPLE_DEPTH, storage-qualifier setup and clock are unchanged.
#
# XML schema mirrored from real Quartus 17.0-era GUI-authored .stp files
# (MiSTer DE10-Nano tutorial alanswx/Tutorials_MiSTer lesson9 + two others).
# Known-shaky corners are tagged "SCHEMA-RISK" -- see RUNBOOK open questions.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

# Hierarchy prefixes (derived from the real tree, 2026-06-09):
#   sys_top (top) -> emu:emu (rtl/emu.sv) -> psx_mister:psx (emu.sv:1149)
#   -> psx_top:ipsx_top (psx_mister.vhd:314) -> gpu:igpu (psx_top.vhd:1506)
#   -> gpu_pixelpipeline:igpu_pixelpipeline (gpu.vhd:1397)
set PP "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu|gpu_pixelpipeline:igpu_pixelpipeline"
set GP "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu"

# Capture clock: clk2x (the GPU/pixelpipeline clock; emu.sv:222 wire clk_2x,
# pll outclk_1). Primary = the named net inside emu. FALLBACK if the node
# finder can't resolve it at compile (check the map report):
#   emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[1]
set CLOCK_NODE "emu:emu|clk_2x"

# JTAG identity (from jtagconfig in raetro/quartus:17.0 on dell, 2026-06-09):
#   DE-SoC [1-4] / @1 4BA00477 SOCVHPS / @2 02D020DD 5CSEBA6(.|ES)/5CSEMA6/..
# capture_headless.tcl overrides these at run time anyway (-hardware_name /
# -device_name after live discovery), so they only need to be plausible.
set JTAG_CHAIN  "DE-SoC \[1-4\]"
set JTAG_DEVICE "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

set INSTANCE_NAME "auto_signaltap_0"
set SS_NAME       "ss_clut_race"
set TRIG_NAME     "trig_clut_race"

# Buffer: 4096 samples x ~87 bits -> ~40 M10K (RAM is at 63%, plenty; the
# tight resource is comb ALUTs -- see FIT.md). Trigger position "post" =
# ~7/8 of the buffer is PRE-trigger history (we want the PRECEDING CLUT-fetch
# sequence, not what happens after the mismatch is already latched).
set SAMPLE_DEPTH 4096
set TRIGGER_POSITION "post"   ;# SCHEMA-RISK: samples only show "pre"; "post"
                               # is the GUI's third preset. Validate.

# Storage qualifier: conditional, single node pipeline_busy='1'.
# pipeline_busy (gpu_pixelpipeline.vhd:597) = pipeline_stall OR any stage
# valid; pipeline_stall includes state/=IDLE, so this stores every cycle in
# which pixels flow OR a texture/CLUT fetch is in flight (incl. all CLUTwrenA
# write beats) and skips idle gaps between draws -- stretching the usable
# window. Single node keeps the qualifier syntax in known-good schema
# territory (multi-node OR text form is unverified). Cycles NOT stored:
# textPalReq pending while the pipe is otherwise idle (the fetch FSM picks it
# up 1 cycle later and THAT is stored; record_data_gap marks the seam).
set QUAL_NODE "$PP|pipeline_busy"

# ---------------------------------------------------------------------------
# WATCH LIST -- {name width} ; width>1 expands to name[0]..name[width-1];
# width==0 -> literal single node name (used for enum-state regs).
# ~87 bits total. Keep LEAN: every bit costs trigger+data fabric.
# ---------------------------------------------------------------------------
set NODES [list \
    [list "$PP|stage1_valid"        1] \
    [list "$PP|stage1_palReqY"      9] \
    [list "$PP|textPalY"            9] \
    [list "$PP|textPalReq"          1] \
    [list "$PP|textPalReqY"         9] \
    [list "$PP|CLUTwrenA"           1] \
    [list "$PP|CLUTaddrA"           6] \
    [list "$PP|reqVRAMXPos"        10] \
    [list "$PP|reqVRAMYPos"         9] \
    [list "$PP|state.IDLE"               0] \
    [list "$PP|state.REQUESTMORETEXTURE" 0] \
    [list "$PP|state.REQUESTTEXTURE"     0] \
    [list "$PP|state.WAITTEXTURE"        0] \
    [list "$PP|state.REQUESTPALETTE"     0] \
    [list "$PP|state.WAITPALETTE"        0] \
    [list "$PP|drawMode\[7\]"       0] \
    [list "$PP|drawMode\[8\]"       0] \
    [list "$PP|pipeline_stall"      1] \
    [list "$PP|pipeline_busy"       1] \
    [list "$GP|videoout_reqVRAMEnable" 1] \
    [list "$GP|pipeline_reqVRAMEnable" 1] \
    [list "$GP|reqVRAMEnable"       1] \
    [list "$GP|reqVRAMYPos"         9] \
    [list "$GP|vramState.IDLE"           0] \
    [list "$GP|vramState.WRITESECOND"    0] \
    [list "$GP|vramState.READSECOND"     0] \
    [list "$GP|vramState.READVRAM"       0] \
    [list "$GP|vramState.CLEARLINESTART" 0] \
    [list "$GP|vramState.CLEARLINE"      0] \
    [list "$GP|reqVRAMIdle"         1] \
    [list "$GP|reqVRAMDone"         1] \
    [list "$GP|vram_BUSY"           1] \
    [list "$GP|vram_pause"          1] \
]
# Watch-list rationale (why each group):
#  stage1_palReqY vs textPalY ......... the mismatch itself (required vs resident)
#  textPalReq/textPalReqY ............. the shared request latch (overwrite window)
#  CLUTwrenA/CLUTaddrA ................ which row's data actually lands in iCLUTram
#  PP reqVRAMX/YPos + state.* ......... what Y the fetch FSM ISSUED + FSM phase
#  GP videoout_/pipeline_reqVRAMEnable. the suspected same-cycle collision pair
#  GP reqVRAMYPos (OR-merged bus!) .... the corrupted address, if any (gpu.vhd:1622)
#  vramState.* / vram_BUSY / Idle/Done. who held the port; DDR3 backpressure
#  drawMode[8:7] ...................... palette path (8=0) + color mode (7)

# ---------------------------------------------------------------------------
# TRIGGER (basic, single level, AND of per-bit patterns):
#   stage1_valid='1' AND drawMode(8)='0'  (a CLUT-textured pixel at stage1)
#   AND stage1_palReqY = 0x1EB (491)      (this pixel NEEDS row 491)
#   AND textPalY[3] = '0'                 (resident row is NOT 491)
#
# WHY bit3 and not a full /=: a basic per-bit pattern can't express a 9-bit
# "not equal". 491 = 1_1110_1011 has bit3=1, so textPalY[3]='0' excludes the
# correct row and fires on wrong rows 480-487/496-503 (the dominant observed
# stray, 480, is covered). The bug hits all 320 quads/frame, so any wrong-row
# cube fires within one frame. ALTERNATES if a capture shows the stray row
# has bit3=1 (489-495, 504-509): use textPalY[1]='0' (excludes 491; covers
# 488-489,492-493,496-497,...) or do the RECON pass: trigger only on
# stage1_valid+palReqY==491, read the actual resident row from the CSV, then
# set an exact == pattern here and regenerate (no rebuild needed).
# ---------------------------------------------------------------------------
set TRIGGER_TERMS [list \
    [list "$PP|stage1_valid"          high] \
    [list "$PP|drawMode\[8\]"         low ] \
    [list "$PP|stage1_palReqY\[8\]"   high] \
    [list "$PP|stage1_palReqY\[7\]"   high] \
    [list "$PP|stage1_palReqY\[6\]"   high] \
    [list "$PP|stage1_palReqY\[5\]"   high] \
    [list "$PP|stage1_palReqY\[4\]"   low ] \
    [list "$PP|stage1_palReqY\[3\]"   high] \
    [list "$PP|stage1_palReqY\[2\]"   low ] \
    [list "$PP|stage1_palReqY\[1\]"   high] \
    [list "$PP|stage1_palReqY\[0\]"   high] \
    [list "$PP|textPalY\[3\]"         low ] \
]

# ---------------------------------------------------------------------------
# generation -- no user-serviceable parts below
# ---------------------------------------------------------------------------

set out "clut_race.stp"
if {$argc >= 1} { set out [lindex $argv 0] }

# expand watch list to flat bit list (data_index order = list order, LSB first)
set BITS {}
foreach n $NODES {
    lassign $n name width
    if {$width == 0 || $width == 1} {
        if {$width == 1} { lappend BITS $name } else { lappend BITS $name }
    } else {
        for {set i 0} {$i < $width} {incr i} { lappend BITS "${name}\[$i\]" }
    }
}
set NBITS [llength $BITS]

# trigger pattern lookup
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

# one <node>/<net> line per bit, role attrs per the GUI-authored samples
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
# SCHEMA-RISK: CRC attr -- GUI writes a checksum; semantics unverified. "0"
# accepted = fine; if open_session rejects, try removing the attribute.
puts $f "      <trigger CRC=\"0\" attribute_mem_mode=\"false\" gap_record=\"true\" global_temp=\"1\" is_expanded=\"true\" name=\"$TRIG_NAME\" position=\"$TRIGGER_POSITION\" power_up_trigger_mode=\"false\" record_data_gap=\"true\" segment_size=\"1\" storage_mode=\"conditional\" storage_qualifier_disabled=\"no\" storage_qualifier_port_is_pin=\"false\" storage_qualifier_port_name=\"auto_stp_external_storage_qualifier\" storage_qualifier_port_tap_mode=\"classic\" trigger_type=\"circular\">"
puts $f "        <power_up_trigger position=\"$TRIGGER_POSITION\" storage_qualifier_disabled=\"no\"/>"
puts $f "        <events use_custom_flow_control=\"no\">"
# SCHEMA-RISK: multi-term basic condition text. Wild samples only show single
# terms ("'LED' == rising edge"); " && " joining is the assumed AND form. The
# per-bit level-0 attrs above carry the same condition redundantly. If
# open_session rejects the text, fall back to level-0 attrs + empty text, and
# verify the trigger summary in the map report after synthesis.
set terms {}
foreach t $TRIGGER_TERMS { lassign $t tn tp ; lappend terms "'[xesc $tn]' == $tp" }
# NB: join with XML-escaped ampersands -- raw "&&" is illegal in XML text
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

puts "wrote $out: $NBITS data bits, depth $SAMPLE_DEPTH, trigger=$TRIG_NAME ([llength $TRIGGER_TERMS] terms), qualifier=$QUAL_NODE"
puts "NEXT: validate with open_session in the dell docker image (see RUNBOOK.md step 0)"
