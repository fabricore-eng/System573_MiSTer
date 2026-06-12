#!/usr/bin/env tclsh
# =============================================================================
# clut_race_stp.tcl -- GENERATE the SignalTap II .stp for the 573 CLUT-fetch
# race probe (the hyperbbc menu-panel wrong-palette garble).
#
# WHAT IT PROBES (BUILD #9 -- dual-boundary observation, BUILD9_PLAN.md Opt B)
#   The GP0 command words arrive at the GPU with the CLUT halfword MANGLED
#   (true 0x7AC0 / row 491 -> 0x7800/0x7840 family / rows 480-481). Every RTL
#   stage simulated clean and a full-cycle CAS-latency change altered nothing,
#   so this build puts the corruption ON CAMERA at two named boundaries
#   simultaneously:
#     sdram->dma : sdram:sdram dma_data[31:0]/dma_wr   (clk1x regs, sdram.sv)
#     dma->gpu   : dma:idma DMA_GPU_write[31:0]/writeEna (clk1x regs,
#                  dma.vhd:699-700)
#   plus the GPU-side witnesses rec_textPalY (gpu_poly decode of the
#   post-FIFO word) and the pixelpipeline request/latch trio. Verdict matrix
#   in BUILD9_PLAN.md section 5: mangled@both = SDRAM read capture confirmed;
#   clean@sdram+mangled@dma = dma word path; clean@both = GPU-internal.
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

# Hierarchy prefixes (derived from the real tree, 2026-06-09; build9 adds
# verified 2026-06-10):
#   sys_top (top) -> emu:emu (rtl/emu.sv) -> psx_mister:psx (emu.sv:1149)
#   -> psx_top:ipsx_top (psx_mister.vhd:314) -> gpu:igpu (psx_top.vhd:1506)
#   -> gpu_pixelpipeline:igpu_pixelpipeline (gpu.vhd:1397)
#   dma:idma      at psx_top.vhd:1259 (idma : entity work.dma)
#   gpu_poly      at gpu.vhd:1289 (igpu_poly)
#   sdram:sdram   at rtl/emu.sv:1882 (instance label "sdram"; the second
#                 instance "sdram2" at :1966 is the 573-flash one -- NOT ours)
set PP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu|gpu_pixelpipeline:igpu_pixelpipeline"
set GP  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu"
set PY  "emu:emu|psx_mister:psx|psx_top:ipsx_top|gpu:igpu|gpu_poly:igpu_poly"
set DMA "emu:emu|psx_mister:psx|psx_top:ipsx_top|dma:idma"
set SDR "emu:emu|sdram:sdram"

# Capture clock: clk2x (the GPU/pixelpipeline clock; emu.sv:222 wire clk_2x,
# pll outclk_1). Primary = the named net inside emu. FALLBACK if the node
# finder can't resolve it at compile (check the map report):
#   emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[1]
set CLOCK_NODE {emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[1]}

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

# Storage qualifier: conditional, single node DMA_GPU_writeEna='1' -- store
# ONLY dma->gpu write beats. 4096 samples / 2 (clk2x double-samples each
# clk1x beat) ~= 2048 GP0 words ~= 227 of the 320 quads' 9-word packets
# around the trigger: the buffer IS a GP0 stream dump at the boundary,
# directly diffable against the MAME GP0 oracle. The sdram-side dma_data and
# the GPU-side witnesses are still sampled at every stored beat. Single node
# keeps the qualifier syntax in known-good schema territory (identical shape
# to build #8's pipeline_busy qualifier; zero new schema risk).
set QUAL_NODE "$DMA|DMA_GPU_writeEna"

# ---------------------------------------------------------------------------
# WATCH LIST -- {name width} ; width>1 expands to name[0]..name[width-1];
# width==0 -> literal single node name (used for enum-state regs).
# BUILD9_PLAN.md Option B (dual-boundary): exactly 87 bits.
# Clock-domain safety @ clk2x capture: DMA_GPU_* and sdram dma_* are clk1x
# registers (exact 2:1 same-PLL in-phase -> each beat sampled twice, dedup
# offline); rec_textPalY/pixelpipeline nets are clk2x-native. NO clk3x sdram
# node is tapped (dq_reg/state/ch*_rq/dma_done are clk3x -- aliased at clk2x).
# ---------------------------------------------------------------------------
set NODES [list \
    [list "$DMA|DMA_GPU_writeEna"   1] \
    [list "$DMA|DMA_GPU_write"     32] \
    [list "$SDR|dma_wr"             1] \
    [list "$SDR|dma_data"          32] \
    [list "$PY|rec_textPalY"        9] \
    [list "$PP|stage1_valid"        1] \
    [list "$PP|textPalReq"          1] \
    [list "$PP|textPalReqY"         9] \
    [list "$PP|textPalFetched"      1] \
]
# 1+32+1+32+9+1+1+9+1 = 87 bits (the cap, exactly).
# Watch-list rationale (why each group):
#  SDR dma_wr/dma_data ........... sdram->dma handoff (clk_base=clk1x regs,
#                                  sdram.sv:164-217 always @(posedge clk_base))
#  DMA_GPU_write/writeEna ........ dma->gpu handoff (clk1x regs, dma.vhd:699-700)
#  rec_textPalY .................. gpu_poly decode of the POST-FIFO word
#                                  (gpu_poly.vhd:537) -- brackets the GPU FIFO
#  stage1_valid/textPalReq/ReqY .. the pixelpipeline request latch (what row
#                                  render actually asked for)
#  textPalFetched ................ fetch-complete flag (0019 cache-hit gate)

# ---------------------------------------------------------------------------
# TRIGGER (basic, single level, AND of per-bit patterns) -- BUILD9_PLAN.md s3.
# Fire on a MANGLED CLUT beat at the dma->gpu boundary:
#   writeEna='1' AND DMA_GPU_write[31:16] == 0111 1000 0x00 0000
#   (0x7800 / 0x7840: clutY in {480,481}, clutX=0, halfword bit15=0).
# Bit map (gpu_poly.vhd:536-537): clutY[8:0]=w[30:22], clutX[5:0]=w[21:16].
#   true  491: 0x7AC0 -> w[30:22] = 1 1 1 1 0 1 0 1 1
#   mangled family:      w[30:22] = 1 1 1 1 0 0 0 0 x   (w22 = only dont-care)
# w25/w23 are LOW here but HIGH in true 491 -> can NEVER fire on a correct
# word. The 0x2C opcode term is deliberately ABSENT: opcode (W0) and CLUT
# halfword (W2) are different beats; a single-level basic trigger ANDs one
# sample, so including it would be unsatisfiable by construction. The opcode
# is in the stored stream two beats earlier; sequencing is done offline.
# NO-FIRE IS INFORMATIVE: storage is qualified on writeEna, so a capture that
# never triggers while garble is on screen = the mangled value does NOT exist
# at the dma->gpu boundary -> fault is GPU-internal (FIFO/decode); run
# RECON=stream in the same session for the positive-control stream.
# ---------------------------------------------------------------------------
set TRIGGER_TERMS [list \
    [list "$DMA|DMA_GPU_writeEna"      high] \
    [list "$DMA|DMA_GPU_write\[31\]"   low ] \
    [list "$DMA|DMA_GPU_write\[30\]"   high] \
    [list "$DMA|DMA_GPU_write\[29\]"   high] \
    [list "$DMA|DMA_GPU_write\[28\]"   high] \
    [list "$DMA|DMA_GPU_write\[27\]"   high] \
    [list "$DMA|DMA_GPU_write\[26\]"   low ] \
    [list "$DMA|DMA_GPU_write\[25\]"   low ] \
    [list "$DMA|DMA_GPU_write\[24\]"   low ] \
    [list "$DMA|DMA_GPU_write\[23\]"   low ] \
    [list "$DMA|DMA_GPU_write\[21\]"   low ] \
    [list "$DMA|DMA_GPU_write\[20\]"   low ] \
    [list "$DMA|DMA_GPU_write\[19\]"   low ] \
    [list "$DMA|DMA_GPU_write\[18\]"   low ] \
    [list "$DMA|DMA_GPU_write\[17\]"   low ] \
    [list "$DMA|DMA_GPU_write\[16\]"   low ] \
]

# ---------------------------------------------------------------------------
# RECON trigger modes (regenerate-only -- NO rebuild: all 87 nodes are
# compiled as trigger inputs, so any per-bit retune is runtime-armable).
# The storage qualifier (DMA_GPU_writeEna) is COMPILED-IN and identical in
# every mode; only the trigger pattern changes.
# Overrides live HERE (before validation/TPAT) so RECON terms are checked
# against the watch list and the per-bit level-0 attrs match the active
# trigger.
# ---------------------------------------------------------------------------
# RECON=stream: stream-dump mode. Fire on the FIRST 0x2C-family opcode beat
# (0x2C..0x2F = 001011xx in bits[31:24]) and let the writeEna-qualified
# buffer do the work: offline diff vs the MAME GP0 oracle finds every mangled
# word, no trigger expressiveness needed.
if {[info exists ::env(RECON)] && $::env(RECON) eq "stream"} {
    set TRIGGER_TERMS [list \
        [list "$DMA|DMA_GPU_writeEna"      high] \
        [list "$DMA|DMA_GPU_write\[31\]"   low ] \
        [list "$DMA|DMA_GPU_write\[30\]"   low ] \
        [list "$DMA|DMA_GPU_write\[29\]"   high] \
        [list "$DMA|DMA_GPU_write\[28\]"   low ] \
        [list "$DMA|DMA_GPU_write\[27\]"   high] \
        [list "$DMA|DMA_GPU_write\[26\]"   high] ]
    puts "RECON-stream MODE: trigger = first 0x2C-family opcode beat (stream dump)"
}
# RECON=anydma: liveness -- fire on ANY dma->gpu write during the scene.
if {[info exists ::env(RECON)] && $::env(RECON) eq "anydma"} {
    set TRIGGER_TERMS [list [list "$DMA|DMA_GPU_writeEna" high]]
    puts "RECON-anydma MODE: trigger = any DMA->GPU write"
}
# RECON=framedump: trigger on the 0x60 frame-clear word; with TRIG_POS=pre the
# ~3584 post-trigger samples (~1792 words) cover the ENTIRE menu list.
if {[info exists ::env(RECON)] && $::env(RECON) eq "framedump"} {
    set terms {}
    set TRIGGER_TERMS [list [list "$DMA|DMA_GPU_writeEna" high]]
    foreach b {31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0} {
        set pol [expr {($b == 30 || $b == 29) ? "high" : "low"}]
        lappend TRIGGER_TERMS [list "$DMA|DMA_GPU_write\[$b\]" $pol]
    }
    puts "RECON-framedump MODE: trigger = word==0x60000000 at writeEna"
}
# RECON=word: exact 32-bit word match at the dma->gpu boundary. Value from
# env TRIG_WORD (0x... literal). Used for the FONT-UPLOAD boundary capture
# (2026-06-10): trigger on a known MAME upload pixel word -- a LANDED word as
# the positive control / burst anchor, a GAPPED word as the decisive
# crosses-vs-never-crosses bit. 33 terms (writeEna + 32 exact bits).
if {[info exists ::env(RECON)] && $::env(RECON) eq "word"} {
    if {![info exists ::env(TRIG_WORD)]} {
        puts stderr "FATAL: RECON=word requires TRIG_WORD=0xXXXXXXXX in env"; exit 1
    }
    set tw [expr {$::env(TRIG_WORD) + 0}]
    set TRIGGER_TERMS [list [list "$DMA|DMA_GPU_writeEna" high]]
    for {set b 31} {$b >= 0} {incr b -1} {
        set pol [expr {(($tw >> $b) & 1) ? "high" : "low"}]
        lappend TRIGGER_TERMS [list "$DMA|DMA_GPU_write\[$b\]" $pol]
    }
    puts [format "RECON-word MODE: trigger = word==0x%08X at writeEna" $tw]
}
if {[info exists ::env(TRIG_POS)]} { set TRIGGER_POSITION $::env(TRIG_POS) }
# RECON=true491x: relaxed true-491 -- clut ROW exact (w[30:22]=111101011),
# clutX DON'T-CARE (the over-constraint that mis-aimed the first runs).
# Fire => intact 491 attributes cross the dma->gpu boundary (bug GPU-side).
# Silent during garble => the RAM list never contains 491 (game-computed).
if {[info exists ::env(RECON)] && $::env(RECON) eq "true491x"} {
    set TRIGGER_TERMS [list \
        [list "$DMA|DMA_GPU_writeEna" high] \
        [list "$DMA|DMA_GPU_write\[31\]" low ] \
        [list "$DMA|DMA_GPU_write\[30\]" high] [list "$DMA|DMA_GPU_write\[29\]" high] \
        [list "$DMA|DMA_GPU_write\[28\]" high] [list "$DMA|DMA_GPU_write\[27\]" high] \
        [list "$DMA|DMA_GPU_write\[26\]" low ] [list "$DMA|DMA_GPU_write\[25\]" high] \
        [list "$DMA|DMA_GPU_write\[24\]" low ] [list "$DMA|DMA_GPU_write\[23\]" high] \
        [list "$DMA|DMA_GPU_write\[22\]" high] ]
    puts "RECON-true491x MODE: trigger = row-491 clut attr, any clutX"
}
# RECON=true491: positive control. Same as the main trigger but w25/w23/w22
# HIGH = the TRUE CLUT word 0x7AC0 (row 491). Proves clean beats traverse the
# boundary and the tap itself isn't lying.
if {[info exists ::env(RECON)] && $::env(RECON) eq "true491"} {
    set TRIGGER_TERMS [list \
        [list "$DMA|DMA_GPU_writeEna"      high] \
        [list "$DMA|DMA_GPU_write\[31\]"   low ] \
        [list "$DMA|DMA_GPU_write\[30\]"   high] \
        [list "$DMA|DMA_GPU_write\[29\]"   high] \
        [list "$DMA|DMA_GPU_write\[28\]"   high] \
        [list "$DMA|DMA_GPU_write\[27\]"   high] \
        [list "$DMA|DMA_GPU_write\[26\]"   low ] \
        [list "$DMA|DMA_GPU_write\[25\]"   high] \
        [list "$DMA|DMA_GPU_write\[24\]"   low ] \
        [list "$DMA|DMA_GPU_write\[23\]"   high] \
        [list "$DMA|DMA_GPU_write\[22\]"   high] \
        [list "$DMA|DMA_GPU_write\[21\]"   low ] \
        [list "$DMA|DMA_GPU_write\[20\]"   low ] \
        [list "$DMA|DMA_GPU_write\[19\]"   low ] \
        [list "$DMA|DMA_GPU_write\[18\]"   low ] \
        [list "$DMA|DMA_GPU_write\[17\]"   low ] \
        [list "$DMA|DMA_GPU_write\[16\]"   low ] ]
    puts "RECON-true491 MODE: trigger = TRUE CLUT word 0x7AC0 (positive control)"
}
# RECON=491: fire the moment textPalReqY EVER holds 491 (any cycle) --
# render-side witness, kept from build #8 (node still tapped).
if {[info exists ::env(RECON)] && $::env(RECON) eq "491"} {
    set TRIGGER_TERMS [list \
        [list "$PP|textPalReqY\[8\]" high] [list "$PP|textPalReqY\[7\]" high] \
        [list "$PP|textPalReqY\[6\]" high] [list "$PP|textPalReqY\[5\]" high] \
        [list "$PP|textPalReqY\[4\]" low ] [list "$PP|textPalReqY\[3\]" high] \
        [list "$PP|textPalReqY\[2\]" low ] [list "$PP|textPalReqY\[1\]" high] \
        [list "$PP|textPalReqY\[0\]" high] ]
    puts "RECON-491 MODE: trigger = textPalReqY==0x1EB (any cycle)"
}
# RECON=rec491: fire when gpu_poly's DECODED clut row register holds 491 --
# kept from build #8 (node still tapped).
if {[info exists ::env(RECON)] && $::env(RECON) eq "rec491"} {
    set TRIGGER_TERMS [list \
        [list "$PY|rec_textPalY\[8\]" high] [list "$PY|rec_textPalY\[7\]" high] \
        [list "$PY|rec_textPalY\[6\]" high] [list "$PY|rec_textPalY\[5\]" high] \
        [list "$PY|rec_textPalY\[4\]" low ] [list "$PY|rec_textPalY\[3\]" high] \
        [list "$PY|rec_textPalY\[2\]" low ] [list "$PY|rec_textPalY\[1\]" high] \
        [list "$PY|rec_textPalY\[0\]" high] ]
    puts "RECON-rec491 MODE: trigger = gpu_poly rec_textPalY==0x1EB"
}
# (build #8 modes RECON=1/instrobe/anystrobe removed: their nodes
#  (stage1-only / pipeline_textPalNew / pipeline_textPalY) are no longer in
#  the Option-B watch list.)

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
puts $f "      <trigger CRC=\"573C1EB1\" attribute_mem_mode=\"false\" gap_record=\"true\" global_temp=\"1\" is_expanded=\"true\" name=\"$TRIG_NAME\" position=\"$TRIGGER_POSITION\" power_up_trigger_mode=\"false\" record_data_gap=\"true\" segment_size=\"1\" storage_mode=\"conditional\" storage_qualifier_disabled=\"no\" storage_qualifier_port_is_pin=\"false\" storage_qualifier_port_name=\"auto_stp_external_storage_qualifier\" storage_qualifier_port_tap_mode=\"classic\" trigger_type=\"circular\">"
puts $f "        <power_up_trigger position=\"$TRIGGER_POSITION\" storage_qualifier_disabled=\"no\"/>"
puts $f "        <events use_custom_flow_control=\"no\">"
# SCHEMA-RISK: multi-term basic condition text. Wild samples only show single
# terms ("'LED' == rising edge"); " && " joining is the assumed AND form. The
# per-bit level-0 attrs above carry the same condition redundantly. If
# open_session rejects the text, fall back to level-0 attrs + empty text, and
# verify the trigger summary in the map report after synthesis.
# (RECON trigger overrides are applied up in the CONFIG section, before
# validation/TPAT, so the level-0 attrs and this text always agree.)
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
