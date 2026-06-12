# =============================================================================
# capture_headless.tcl -- armed, GUI-less SignalTap capture for the CLUT-race
# probe. Runs under quartus_stp -t inside raetro/quartus:17.0 on dell (the
# DE10-Nano's USB-Blaster II is plugged into dell).
#
#   quartus_stp -t capture_headless.tcl \
#       [-stp <file.stp>] [-csv <out.csv>] [-timeout <sec>] \
#       [-hw <glob>] [-dev <glob>] [-signal_set <ss>] [-trigger <trig>]
#
# PASSIVE ATTACH ONLY. The MiSTer configures the FPGA itself (.rbf via the
# HPS); this script must NEVER reprogram the device. It only uses the
# ::quartus::stp acquisition API (open_session/run/export_data_log/
# close_session -- verified present in the 17.0.2 image, 2026-06-09), which
# talks to the SLD hub of the ALREADY-RUNNING design over JTAG. There is no
# programming command anywhere in this file; keep it that way.
#
# Exit codes: 0 = triggered + CSV exported; 2 = timeout (no trigger);
#             1 = any other failure.
# NOTE: close_session writes the captured data log back INTO the .stp --
# run this against a scratch COPY of clut_race.stp (capture.sh does this)
# so the repo checkout on dell stays clean.
# =============================================================================

package require ::quartus::stp
# ::quartus::jtag (get_hardware_names / get_device_names) is auto-loaded by
# the quartus_stp executable.

# ---- defaults (container paths; capture.sh overrides via argv) -------------
set opt(stp)        "/work/run.stp"
set opt(csv)        "/work/clut_race.csv"
set opt(timeout)    300
set opt(hw)         "DE-SoC*"
set opt(dev)        "*5CSEBA6*"
set opt(signal_set) "ss_clut_race"
set opt(trigger)    "trig_clut_race"
set opt(instance)   "auto_signaltap_0"
set opt(data_log)   "log_capture"

foreach {k v} $argv {
    set k [string trimleft $k -]
    if {![info exists opt($k)]} { puts "ERROR: unknown arg -$k"; exit 1 }
    set opt($k) $v
}

proc die {msg} { puts "CAPTURE-FAIL: $msg" ; catch {close_session} ; exit 1 }

# ---- discover JTAG hardware + device (overrides whatever the .stp stored) --
set hwname ""
if {[catch {get_hardware_names} hwlist]} { die "get_hardware_names: $hwlist" }
foreach h $hwlist { if {[string match $opt(hw) $h]} { set hwname $h ; break } }
if {$hwname eq ""} { die "no JTAG hardware matching '$opt(hw)' (saw: $hwlist). Is the USB-Blaster II visible? Try: jtagconfig" }

set devname ""
if {[catch {get_device_names -hardware_name $hwname} devlist]} { die "get_device_names: $devlist" }
foreach d $devlist { if {[string match $opt(dev) $d]} { set devname $d ; break } }
if {$devname eq ""} { die "no device matching '$opt(dev)' on '$hwname' (saw: $devlist)" }

puts "CAPTURE: hardware='$hwname' device='$devname'"
puts "CAPTURE: stp=$opt(stp) trigger=$opt(trigger) timeout=$opt(timeout)s"

# ---- open + arm + wait ------------------------------------------------------
if {[catch {open_session -name $opt(stp)} err]} { die "open_session: $err" }

# NO -check: the .stp carries no .sof reference; the design was configured by
# the MiSTer. If the running bitstream does not contain this SignalTap
# instance, run errors out ("Trigger not compatible with device") -- that is
# the integrity check that you deployed the INSTRUMENTED .rbf.
set rc [catch {
    run -instance   $opt(instance)   \
        -signal_set $opt(signal_set) \
        -trigger    $opt(trigger)    \
        -data_log   $opt(data_log)   \
        -timeout    $opt(timeout)    \
        -hardware_name $hwname       \
        -device_name   $devname
} err]

if {$rc} {
    puts "CAPTURE-RESULT: run failed or timed out: $err"
    catch {stop -instance $opt(instance)}
    catch {close_session}
    if {[string match -nocase "*timeout*" $err] || [string match -nocase "*did not occur*" $err]} { exit 2 }
    exit 1
}
puts "CAPTURE-RESULT: TRIGGERED -- exporting CSV"

if {[catch {
    export_data_log -instance   $opt(instance)   \
                    -signal_set $opt(signal_set) \
                    -trigger    $opt(trigger)    \
                    -data_log   $opt(data_log)   \
                    -filename   $opt(csv)        \
                    -format     csv
} err]} { die "export_data_log: $err" }

# close_session persists the data log into the (scratch) .stp as a bonus copy
if {[catch {close_session} err]} { puts "WARN: close_session: $err" }

puts "CAPTURE-OK: $opt(csv)"
exit 0
