# FALLBACK.md — if SignalTap won't fit / won't behave

## Route B: In-System Memory Content Editor (ISMCE) snapshot of iCLUTram

Near-zero fabric cost (no capture buffer, no trigger logic — just the SLD
hub + runtime-mod plumbing on one RAM), at the price of NO temporal info: it
answers "WHICH row's palette data is resident while the menu is garbled",
not "who stole the bus". Complements SignalTap; pairs well with depth-2048 or
a trimmed watch list if the full probe won't fit.

What exists today: the resident CLUT lives in `iCLUTram` =
4 × `entity work.dpram_dif` (one per texture-filter lane,
psx/rtl/gpu_pixelpipeline.vhd:534; write side 64×64 from `vram_DOUT`, read
side 256×16). `dpram_dif` does not expose runtime modification, so ISMCE
cannot see it without an RTL change — which, per the vendored-pristine rule,
must be a **numbered psx_patch. SKETCH ONLY for patch 0020 (not written):**

- Add `constant DBG_CLUT_ISMCE : std_logic := '0';` (ships OFF, same
  convention as the 0012/0015/0017 probes).
- Under a `generate` on that constant, swap lane 0's iCLUTram instantiation
  for an `altsyncram`-based equivalent with
  `lpm_hint = "ENABLE_RUNTIME_MOD=YES, INSTANCE_NAME=CLT0"` (instance names
  are limited to 4 chars), identical ports/widths/timing (1-cycle read,
  `clken_b = not pipeline_stall`). OFF ⇒ the generate keeps today's
  dpram_dif ⇒ netlist-identical production.
- Verify the debug instantiation maps to a BLOCK ram (M10K): if Quartus
  picks MLAB, runtime-mod support is doubtful — force it
  (`ramstyle`/`RAM_BLOCK_TYPE M10K` on the debug instance). TO VERIFY at
  build time in the fit report.
- Readout (same docker image; `::quartus::insystem_memory_edit` is confirmed
  present in quartus_stp 17.0.2 on dell):
  ```tcl
  package require ::quartus::insystem_memory_edit
  begin_memory_edit -hardware_name "DE-SoC [1-4]" \
      -device_name "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"
  # find -instance_index via get_editable_mem_instances; then:
  read_content_from_memory -instance_index $i -start_address 0 \
      -word_count 256 -content_in_hex
  end_memory_edit
  ```
  (Exact sub-command spelling to be re-checked with `help -pkg
  insystem_memory_edit` in the image — same introspection method that
  verified the stp package.)
- Interpretation: dump the 256 resident 16-bit entries while the garbled
  menu is up; compare against the (already byte-verified) VRAM palette rows.
  A clean match to row 480/485/... pins the resident row exactly and
  confirms "wrong row fetched, data intact"; a row-491 match would instead
  point the finger at the read-side addressing — either way a hard number,
  repeatable per attract loop.
- Passivity: ISMCE attaches over JTAG to the running, MiSTer-configured
  design — no reprogramming, same as the SignalTap flow.

## Route C: JTAG on the SuperStation One (board fallback)

The garble is bit-near-identical across boards (SSIM 0.93 DE10 vs SS1 on the
same menu), so a capture from EITHER board answers the same question. If the
DE10 rig is confounded (blaster flakiness, dell USB, build drift), the same
instrumented .rbf + the same clut_race.stp work on the SS1's Cyclone V SE
part UNCHANGED in principle — the open items are purely physical/practical:
whether the SS1 exposes a usable JTAG header for a USB-Blaster II, and the
device string it enumerates as (regenerate the .stp `JTAG_DEVICE`, or rely
on capture_headless.tcl's runtime discovery, which matches by `*5CSEBA6*`
glob — adjust the glob if the SS1's part ID string differs). Confirm the
header pinout before wiring anything; this is the last-resort path, not the
plan.
