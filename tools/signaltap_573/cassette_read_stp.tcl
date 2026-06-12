#!/usr/bin/env tclsh
# =============================================================================
# cassette_read_stp.tcl -- GENERATE the SignalTap II .stp for the 573 SECURITY
# CASSETTE (Xicor X76F100) read probe. Root-causes the hypbbc2p installer's
# SECURITY-CASSETTE ERROR -11N that survives a clean rebuild: SIM says the
# block-0 read returns data[0..7] (e.g. 4a/41/74 at offsets 0/1/4) and PASSES
# the installer's Gate-A checksum (data[4] == ~(data[0]+data[1])); HARDWARE
# returns something that FAILS it. This puts the silicon read ON CAMERA.
#
# WHAT IT PROBES (three hypotheses, one watch list, retunable trigger):
#   (a) data[] never loaded right on silicon  -> watch the LOAD port
#       (ram_we/ram_waddr/ram_wdata) at boot: did 4a/41/74 land at off 0/1/4?
#   (b) data[] loaded fine but the READ returns wrong-offset/garbage bytes
#       during the installer's access pattern -> watch the READ port
#       (rd_addr/rd_oob/data_rdata) + the read FSM (state/bitc/bytec/command)
#       as block 0 streams out. data_rdata at each byte's bit0 IS the value the
#       device shifts onto SDA -- compare to 4a/41/74.
#   (c) bit-bang timing / metastability on the real cassette lines -> watch the
#       serial pins (cs/scl/sda_i/sda_o/sec_rst) + the seccart readback sec_io0,
#       byte-aligned against the FSM, vs the clean MSB-first protocol.
#
# THE data[] ARRAY IS M10K BLOCK RAM (x76f100.v:70-72 -- single sync write port +
# registered read port, by design, to avoid 896 FFs). Its individual elements
# (data[0] etc.) are NOT preservable register nodes -- they are cells inside an
# M10K and SignalTap CANNOT tap them (RUNBOOK: "elaboration-folded nodes
# unpreservable"). So we observe the loaded values through the PORTS that are
# real registers:
#   * ram_wdata/ram_waddr/ram_we  -- every byte AS IT IS WRITTEN at load (hyp a)
#   * data_rdata/rd_addr/rd_oob   -- every byte AS IT IS READ during Gate A (hyp b)
# data_rdata at bitc==0 of an ST_READ byte == the value driven MSB-first onto
# sda_o for that byte. That is the authoritative "what the cassette returns".
#
# USAGE
#   tclsh cassette_read_stp.tcl                 -> writes cassette_read.stp here
#   tclsh cassette_read_stp.tcl /path/out.stp   -> writes there
#   RECON=load    tclsh ...  -> retune trigger to the BOOT LOAD window (hyp a)
#   RECON=anyread tclsh ...  -> trigger on ANY ST_READ entry (liveness)
#   RECON=rtr     tclsh ...  -> trigger on response-to-reset (protocol anchor)
#   (Pure Tcl -- no Quartus packages; also runs under quartus_stp -t.)
#
# VALIDATE (seconds, no build) -- after ANY regeneration (RUNBOOK.md step 0):
#   scp cassette_read.stp dell:/tmp/ && ssh dell 'docker run --rm -v /tmp:/tmp \
#     raetro/quartus:17.0 quartus_stp -t /tmp/validate_stp.tcl'
#
# RUNTIME RE-TUNE WITHOUT RECOMPILE: every tapped node is compiled as a trigger
# input, so the trigger pattern can change by editing the TRIGGER TABLE +
# regenerating + re-running the capture. The bitstream does NOT need rebuilding
# unless the NODE LIST, SAMPLE_DEPTH, storage-qualifier setup or CLOCK change.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

# Hierarchy prefixes. The cassette runs entirely in the clk_1x domain:
#   sys_top (top) -> emu:emu (rtl/emu.sv)
#   -> system573_top:u_s573 (emu.sv:1755, "system573_top u_s573")
#   -> s573_seccart:u_seccart (system573_top.v:179)
#   -> x76f100:eeprom100      (s573_seccart.v:89)
# Verilog instances appear in Quartus 17.0 node paths as module:instance, same
# as the VHDL nodes in clut_race_stp.tcl (emu:emu, sdram:sdram are Verilog too).
set SEC  "emu:emu|system573_top:u_s573|s573_seccart:u_seccart"
set EEP  "emu:emu|system573_top:u_s573|s573_seccart:u_seccart|x76f100:eeprom100"

# Capture clock: clk_1x (the cassette/seccart clock; emu.sv:230 outclk_0).
# The cassette FSM, the M10K read/write ports, and the seccart latch are ALL
# clk_1x-native -- so unlike the CLUT probe (clk_2x) the acq clock is outclk_0.
# Per the RUNBOOK this MUST be the real PLL net, never an elaboration-folded
# alias. FALLBACK if the finder can't resolve it (check the map report):
#   emu:emu|clk_1x  (the named wire) -- but folded wires are unpreservable, so
#   the PLL outclk net is the safe primary.
set CLOCK_NODE {emu:emu|pll:pll|pll_0002:pll_inst|altera_pll:altera_pll_i|outclk_wire[0]}

# JTAG identity (overridden at run time by capture_headless.tcl after live
# discovery, so they only need to be plausible).
set JTAG_CHAIN  "DE-SoC \[1-4\]"
set JTAG_DEVICE "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"

set INSTANCE_NAME "auto_signaltap_0"
set SS_NAME       "ss_cassette_read"
set TRIG_NAME     "trig_cassette_read"

# Buffer: the cassette is bit-banged S-L-O-W (the BIOS toggles SCL over many
# clk_1x cycles per bit, ~hundreds of clk_1x per serial bit). A block-0 read is
# command(9 clk) + 8 password(72 clk) + verify(9 clk) + 8 data bytes(72 clk),
# each serial bit spanning ~100s of clk_1x at full rate -> the whole block-0
# transaction is FAR more than 4096 clk_1x cycles if sampled raw.
# THEREFORE storage-qualify on serial ACTIVITY (a rising-SCL edge proxy) so we
# store ~1 sample per protocol bit, not per idle clk_1x. Even so, 8192 deep
# gives generous margin for the whole password+data block. M10K budget: 8192 x
# ~76 bits ~= 60 M10K. RAM is at ~63% in the production fit (FIT.md) but this is
# a DEBUG branch -- if M10K overflows, drop SAMPLE_DEPTH to 4096 (still covers
# the 8 data bytes + verify, which is the decisive window).
set SAMPLE_DEPTH 8192
set TRIGGER_POSITION "post"   ;# ~7/8 PRE-trigger history: when we trigger on the
                               # FIRST ST_READ byte we want the PRECEDING cmd +
                               # password + verify in the buffer too.

# Storage qualifier (single node -- known-good schema, same shape as the CLUT
# probe's writeEna qualifier). The cassette is bit-banged: the BIOS holds SCL
# high/low for MANY clk_1x cycles per serial bit, so a raw clk_1x capture would
# flood the buffer with idle. We store only when SCL is HIGH (d_q[1]=1) -- the
# data-stable plateau of each clocked bit. This roughly halves idle and, because
# data_rdata/sda_o/shift are all stable across the SCL-high plateau, every
# protocol bit is still represented. It is a COARSE bound (not 1-sample/bit);
# the decisive protection is that we TRIGGER at the END of the block-0 read
# (state==ST_READ,bitc==0) with TRIG_POS=post, so the 8192-deep buffer's
# pre-trigger history holds the whole cmd+password+verify+read-byte-0 window
# even at this qualifier granularity. RECON=load overrides QUAL_NODE to ram_we
# (store only the boot-load write beats -- the load stream, no idle).
set QUAL_NODE "$SEC|d_q\[1\]"   ;# d_q[1] = SCL (registered cassette latch)

# ---------------------------------------------------------------------------
# WATCH LIST -- {name width}; width>1 expands to name[0]..name[width-1];
# width==1 (or 0) -> single node. ~76 bits total.
# Clock domain: EVERYTHING here is a clk_1x register (the cassette/seccart are
# clk_1x). The acq clock IS clk_1x -> no oversampling, no aliasing. Clean.
# ---------------------------------------------------------------------------
set NODES [list \
    [list "$EEP|state"          3] \
    [list "$EEP|bitc"           4] \
    [list "$EEP|bytec"          8] \
    [list "$EEP|command"        8] \
    [list "$EEP|shift"          8] \
    [list "$EEP|data_rdata"     8] \
    [list "$EEP|rd_addr"        7] \
    [list "$EEP|rd_oob"         1] \
    [list "$EEP|ram_we"         1] \
    [list "$EEP|ram_waddr"      7] \
    [list "$EEP|ram_wdata"      8] \
    [list "$EEP|pw_ok"          1] \
    [list "$SEC|d_q"            5] \
    [list "$EEP|sda_o"          1] \
]
# 3+4+8+8+8+8+7+1+1+7+8+1+5+1 = 70 bits.
# Watch-list rationale (which hypothesis each group serves):
#  state ......... read FSM state (ST_STOP/RTR/CMD/PW/VERIFY/READ/WRITE). The
#                  TRIGGER anchor + lets us byte-align the stream offline.
#  bitc/bytec .... bit index (0..8) + byte index within the block. bytec at an
#                  ST_READ byte == the data[] offset being streamed (hyp b: does
#                  Gate A land at offset 0?).
#  command ....... the latched command byte (bit7,bit0 => READ; bits[4:1] =
#                  block select). Confirms this is the block-0 READ.
#  shift ......... the serial shift register (input MSB-first / output drains
#                  MSB-first). Cross-checks the byte being clocked.
#  data_rdata .... THE registered M10K read byte (hyp b): at bitc==0 of an
#                  ST_READ byte this IS what gets driven onto SDA. Compare to
#                  4a/41/74. (We can't tap data[0/1/4] -- M10K cells -- so this
#                  port is the authoritative loaded-value witness for the read.)
#  rd_addr/rd_oob  the read address driven one cycle ahead + the >=112 OOB flag.
#                  rd_addr tracks {command[4:1],3'b000}+bytec; confirms the read
#                  pointer lands where Gate A expects (hyp b: wrong-offset read).
#  ram_we/waddr/wdata  THE M10K WRITE port (hyp a): every byte AS IT IS WRITTEN
#                  from the .u1 at boot. RECON=load triggers here to verify
#                  4a@0 / 41@1 / 74@4 actually LANDED in the RAM on silicon.
#  pw_ok ......... password-compare result; the installer reads AFTER a password
#                  auth (multi-read context) -- this confirms the auth path ran.
#  d_q[4:0] ...... THE BIT-BANG LINES (hyp c). d_q is the seccart's REGISTERED
#                  cassette latch (s573_seccart.v:88-91, clocked on latch_we) --
#                  what the BIOS WROTE to drive the chip. Wiring (MEMORY_MAP +
#                  the seccart comment):
#                    d_q[0]=SDA (host, ==x76f100 sda_i)  d_q[1]=SCL  d_q[2]=CS
#                    d_q[3]=RST  d_q[4]=DS2401 driver
#                  Tapped as registers (not the folded chip-input pins, which
#                  Quartus 17.0 QSF can't KEEP -- Error 125048).
#  sda_o ......... what the DEVICE drives back. For an X76F100 cart
#                  sda_o == eeprom_sda_o == sec_io0 (the EXACT bit the BIOS reads
#                  at 0x1f400006[2]) -- so sda_o IS the seccart readback witness.
#                  If sda_o's MSB at each ST_READ byte != data_rdata's MSB that's
#                  a shift/timing fault (hyp c); if it tracks data_rdata cleanly
#                  the serial path is good and the fault is the loaded VALUE.

# ---------------------------------------------------------------------------
# TRIGGER (basic, single level, AND of per-bit patterns) -- DEFAULT = READ.
# Fire on the FIRST ST_READ data-output cycle: state == ST_READ (3'd5) AND
# bitc == 0 (the cycle where data_rdata is latched onto sda_o MSB). With
# TRIG_POS=post the ~7/8 pre-trigger history captures the cmd+password+verify
# that PRECEDED this read -- the full Gate-A transaction lands in one buffer.
#   ST_READ = 3'd5 = 101b  -> state[2]=1 state[1]=0 state[0]=1
#   bitc    = 4'd0 = 0000b  -> all four bitc bits low
# This robustly marks "the device is about to drive the first data byte" -- the
# decisive instant for hyp (b): data_rdata HERE is byte 0, and bytec HERE is the
# offset. NO-FIRE IS INFORMATIVE: if state never reaches ST_READ while the
# installer runs, the read never even started -> the fault is upstream (password
# verify NAK'd, or the BIOS never issued the READ command) = a DIFFERENT bug
# than the checksum mismatch (run RECON=anyread / RECON=rtr to localize).
# ---------------------------------------------------------------------------
set TRIGGER_TERMS [list \
    [list "$EEP|state\[2\]"  high] \
    [list "$EEP|state\[1\]"  low ] \
    [list "$EEP|state\[0\]"  high] \
    [list "$EEP|bitc\[3\]"   low ] \
    [list "$EEP|bitc\[2\]"   low ] \
    [list "$EEP|bitc\[1\]"   low ] \
    [list "$EEP|bitc\[0\]"   low ] \
]

# ---------------------------------------------------------------------------
# RECON trigger modes (regenerate-only -- NO rebuild). The storage qualifier is
# compiled-in; only the trigger pattern changes. Overrides live HERE (before
# validation/TPAT) so the per-bit level-0 attrs match the active trigger.
# ---------------------------------------------------------------------------
# RECON=load: hyp (a). Trigger on a data[] WRITE during the boot LOAD window
# (ram_we high). With TRIG_POS=pre the post-trigger samples sweep the whole
# 132-byte .u1 load -> offline read ram_waddr/ram_wdata to confirm 4a@0/41@1/
# 74@4 landed. (The load happens once at boot, ~T0; capture EARLY -- arm right
# after load_core, like the boot-window flow in RUNBOOK.) Also flips the
# storage qualifier to ram_we so the buffer is the LOAD STREAM, not idle.
if {[info exists ::env(RECON)] && $::env(RECON) eq "load"} {
    set TRIGGER_TERMS [list [list "$EEP|ram_we" high]]
    set QUAL_NODE "$EEP|ram_we"
    set TRIGGER_POSITION "pre"
    puts "RECON-load MODE: trigger = first data\[\] write (hyp a, boot-load window)"
}
# RECON=anyread: liveness. Fire the instant state enters ST_READ (any bitc) --
# proves the read FSM reached data output at all.
if {[info exists ::env(RECON)] && $::env(RECON) eq "anyread"} {
    set TRIGGER_TERMS [list \
        [list "$EEP|state\[2\]" high] \
        [list "$EEP|state\[1\]" low ] \
        [list "$EEP|state\[0\]" high] ]
    puts "RECON-anyread MODE: trigger = state==ST_READ (any cycle, liveness)"
}
# RECON=rtr: protocol anchor. Fire on response-to-reset (state==ST_RTR=3'd1) --
# the BIOS's first cassette poke. Confirms the bus is alive + the model resets.
if {[info exists ::env(RECON)] && $::env(RECON) eq "rtr"} {
    set TRIGGER_TERMS [list \
        [list "$EEP|state\[2\]" low ] \
        [list "$EEP|state\[1\]" low ] \
        [list "$EEP|state\[0\]" high] ]
    puts "RECON-rtr MODE: trigger = state==ST_RTR (response-to-reset anchor)"
}
# RECON=verify: fire when the password VERIFY completes (state==ST_VERIFY=3'd4,
# bitc==0) -- the gate just before READ. pw_ok in the buffer tells us whether
# auth passed; the installer reads AFTER auth, so a NAK here is the real fault.
if {[info exists ::env(RECON)] && $::env(RECON) eq "verify"} {
    set TRIGGER_TERMS [list \
        [list "$EEP|state\[2\]" high] \
        [list "$EEP|state\[1\]" low ] \
        [list "$EEP|state\[0\]" low ] \
        [list "$EEP|bitc\[3\]"  low ] \
        [list "$EEP|bitc\[2\]"  low ] \
        [list "$EEP|bitc\[1\]"  low ] \
        [list "$EEP|bitc\[0\]"  low ] ]
    puts "RECON-verify MODE: trigger = state==ST_VERIFY, bitc==0 (auth gate)"
}
if {[info exists ::env(TRIG_POS)]} { set TRIGGER_POSITION $::env(TRIG_POS) }

# ---------------------------------------------------------------------------
# generation -- no user-serviceable parts below (mirrors clut_race_stp.tcl)
# ---------------------------------------------------------------------------

set out "cassette_read.stp"
if {$argc >= 1} { set out [lindex $argv 0] }

# expand watch list to flat bit list (data_index order = list order, LSB first)
set BITS {}
foreach n $NODES {
    lassign $n name width
    if {$width == 0 || $width == 1} {
        lappend BITS $name
    } else {
        for {set i 0} {$i < $width} {incr i} { lappend BITS "${name}\[$i\]" }
    }
}
set NBITS [llength $BITS]

# trigger pattern lookup + validation against the watch list
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
# CRC: a NONZERO self-consistency token (RUNBOOK 'CRC gate' -- a zero CRC makes
# the runtime REFUSE to arm even when it matches; --enable copies this into the
# crc[] vcc/gnd tie pattern). Distinct token for this probe.
puts $f "      <trigger CRC=\"76F100A0\" attribute_mem_mode=\"false\" gap_record=\"true\" global_temp=\"1\" is_expanded=\"true\" name=\"$TRIG_NAME\" position=\"$TRIGGER_POSITION\" power_up_trigger_mode=\"false\" record_data_gap=\"true\" segment_size=\"1\" storage_mode=\"conditional\" storage_qualifier_disabled=\"no\" storage_qualifier_port_is_pin=\"false\" storage_qualifier_port_name=\"auto_stp_external_storage_qualifier\" storage_qualifier_port_tap_mode=\"classic\" trigger_type=\"circular\">"
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

puts "wrote $out: $NBITS data bits, depth $SAMPLE_DEPTH, trigger=$TRIG_NAME ([llength $TRIGGER_TERMS] terms), qualifier=$QUAL_NODE, clock=$CLOCK_NODE"
puts "NEXT: validate with open_session in the dell docker image (see RUNBOOK.md step 0)"
