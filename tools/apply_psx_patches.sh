#!/usr/bin/env bash
# Apply the System 573's local modifications to the vendored PSX_MiSTer submodule.
#
# psx/ is a git submodule pinned to an upstream SHA we cannot push to, but the 573
# integration must edit the PlayStation core (EXP1 routing, later 2 MB VRAM, DMA ch5).
# Those GPL-2.0 edits are kept as isolated, offer-back-able patch files under
# psx_patches/ and (re)applied to the submodule working tree before any sim or Quartus
# build. The submodule pointer itself never moves.
#
# Safe + idempotent: uses reverse-apply checks so it never re-applies an applied patch,
# and only ever resets the FILES A PATCH TOUCHES (never your unrelated psx/ edits), and
# only when a hunk is in a conflicted/partial state. --check never writes.
#
# Usage:  tools/apply_psx_patches.sh            # apply (idempotent)
#         tools/apply_psx_patches.sh --check     # report apply-ability, write nothing
#         tools/apply_psx_patches.sh --revert    # remove our patches (reverse-apply)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSX="$ROOT/psx"
PIN=67153439fbb8e85e4108b9f0ff474d37aa6f7f5b
PATCHES=( "$ROOT/psx_patches/0001-s573-exp1-widening.patch" \
          "$ROOT/psx_patches/0002-s573-nvc-cd-positionInIndex-init.patch" \
          "$ROOT/psx_patches/0003-s573-nvc-gpu-videoout-linemax-clamp.patch" \
          "$ROOT/psx_patches/0004-s573-cpu-icache-redirect-fix.patch" \
          "$ROOT/psx_patches/0005-s573-cpu-bios-uncached.patch" \
          "$ROOT/psx_patches/0006-s573-exp1-flash-wait.patch" \
          "$ROOT/psx_patches/0007-sdram-ch4-flash.patch" \
          "$ROOT/psx_patches/0008-s573-disable-cheats-engine.patch" \
          # 0009 (ext_data_new byte-lane fix) REMOVED: it deterministically stalls the boot
          # pre-EXP1 (fit-marginality on the 97%-ALM die, STA-clean). Per workflow w20walw69 the
          # byte-lane fix moves OFF the psx ext_data_new mux into the EXP1 slave (system573_top.v);
          # the sig is handled meanwhile by the sigpass BIOS (dumps/hyperbbc/573_sigpass.bin).
          #   "$ROOT/psx_patches/0009-s573-exp1-byte-read-lane.patch"
          # 0010 plumbs the CPU load width (reqsize_buf) out of memorymux -> psx_top ->
          # psx_mister as exp1_reqsize, so the EXP1 SLAVE (system573_top.v) can byte-align
          # its 16-bit halfword-native read return without touching the fragile ext_data_new mux.
          "$ROOT/psx_patches/0010-s573-exp1-reqsize.patch" \
          # 0011 removes the dormant consumer-PSX CD-ROM controller (cd_top + cd_xa helpers)
          # from psx_top -- the 573 drives its own ATAPI optical drive via rtl/atapi.v over EXP1
          # and never uses cd_top (confirmed dormant by 4 BIOS scans). Its outputs are tied to
          # safe idle constants (SS_Idle_cd/Pause_idle_cd held '1' so savestate/pause complete;
          # region_out passed straight through). Frees ~2.9k ALMs on the ALM/LAB-bound 573 die.
          "$ROOT/psx_patches/0011-s573-remove-cd-top.patch" \
          # 0012 is a DEBUG-ONLY probe: recolors textured pixels by their drawMode
          # color-mode (4bpp=RED/8bpp=BLUE/15bit=YELLOW) so one screenshot reveals which
          # texture mode the green-striped polys use. Gated by DBG_TEXMODE_MAP in
          # gpu_pixelpipeline.vhd; set '0' (constant-folds away) before any production rbf.
          "$ROOT/psx_patches/0012-s573-debug-texmode-flagcolor.patch" \
          # 0013: CLUT-cache coherency fix. gpu.vhd invalidated only the TEXTURE cache
          # (not the palette cache) on VRAM writes (fill/cpu2vram/vram2vram), so a palette
          # uploaded to a cached CLUT row was ignored -> stale CLUT -> the hyperbbc green
          # foreground-quad garble. Asserts pipeline_clearCachePalette too. Production fix.
          "$ROOT/psx_patches/0013-s573-clut-cache-coherency.patch" \
          # 0014: EXPERIMENT (bisection). Disables the GPU CLUT palette cache -> every textured
          # primitive re-fetches its palette from VRAM (never serves a cached one). Tests whether
          # the hyperbbc garble is a stale/mis-invalidated palette cache (fix) vs a VRAM
          # write-after-read ordering bug (persists). Gated by DISABLE_CLUT_CACHE in
          # gpu_pixelpipeline.vhd (set '1' for this build; '0' = no-op normal cache).
          "$ROOT/psx_patches/0014-s573-disable-clut-cache.patch" \
          # 0015 is a PROBE: for the hyperbbc panel's 4bpp CLUT-(0,491) draws it overrides the
          # CLUT index with the screen-x position so the panel renders the 16 LIVE CLUT-cache
          # entries as 16px colour bands into the framebuffer (which a savestate captures). The
          # wrong (red) palette lives only in the draw-time cache; this is the on-HW way to read
          # it. Gated by DBG_CLUT_STRIPE in gpu_pixelpipeline.vhd ('1' = probe; '0' = no-op).
          "$ROOT/psx_patches/0015-s573-clut-stripe-probe.patch" \
          # 0016 is the PRODUCTION FIX: a CLUT-resident interlock. The hyperbbc panel garble is a
          # consume-before-refill race -- a quad's 2nd triangle + later scanlines bypass gpu_poly IDLE
          # so their pixels emit before this primitive's CLUT row is loaded and read the PRIOR quad's
          # resident palette (HW-probe-confirmed: panel read row ~482 not 491). 0016 stalls stage0/1
          # CLUT-textured pixels until their requested row is resident (and lets the fetch start while
          # they're parked, to avoid deadlock). Gated by CLUT_INTERLOCK in gpu_pixelpipeline.vhd
          # ('1' = fix; '0' = no-op). NVC-analyze-clean; HW-A/B is the arbiter (bug is HW-timing-only).
          "$ROOT/psx_patches/0016-s573-clut-resident-interlock.patch" \
          # 0017 is a NUMERIC PROBE (decisive, unconfounded): for every 4bpp-CLUT textured pixel it
          # overrides pixelColor with the RAW fetched CLUT row number textPalY (encoded 0x7E00|row,
          # bit15=0 so no mask-blocking). A savestate then reads back the EXACT row(s) the hyperbbc
          # panel fetched -- no band-colour inference. 491(0x1EB)=correct; anything else = the CLUT
          # address/latch is wrong (and shows which row, and one-row vs many). Also turns the failed
          # 0016 interlock OFF (CLUT_INTERLOCK='0'). Gated DBG_ROWDUMP in gpu_pixelpipeline.vhd
          # ('1' = probe; '0' = no-op, constant-folds away). Set '0' for any production rbf.
          "$ROOT/psx_patches/0017-s573-clut-rowdump-probe.patch" \
          # 0018 = the PRODUCTION FIX (CLUT row-lock). Per-pixel snapshot of the required CLUT row +
          # stall stage0/1 until the RESIDENT row matches the pixel's OWN snapshot + drive the fetch from
          # the parked pixel's row (the shared textPalReqY gets overwritten by the next quad before the
          # panel pixels read). Fixes the HW read-race 0016 could not. Gated CLUT_ROWLOCK ('1'=fix).
          "$ROOT/psx_patches/0018-s573-clut-rowlock.patch" \
          # 0019 = restore stock CLUT cache (DISABLE_CLUT_CACHE=0) + qualify 0013 (palette cache survives
          # vramFill screen-clears) + turn off the failed CLUT_ROWLOCK (0018). The 320 row-491 menu/panel
          # quads then fetch the palette ONCE and reuse it instead of re-fetching+racing per quad.
          "$ROOT/psx_patches/0019-s573-clut-cache-restore.patch" \
          # 0020 = SDRAM CAS latency 2->3: CL2 @ 101.6 MHz is out of SDR spec; the 573's
          # continuous flash traffic collects the margin debt as deterministic low-bit
          # miscapture on GPU-DMA reads (clut 491 -> 480/481). Audit: docs/audits/2026-06-10.
          "$ROOT/psx_patches/0020-sdram-cas-latency-3.patch" \
          # 0021 = 2 MB VRAM (the 573's CXD8561Q drives 1024 VRAM rows; the vendored core
          # implements 512 and truncates Y to 9 bits, so boot-time uploads to y>=512 WRAP
          # onto y-512 and corrupt the visible half -- the font-atlas/garble root cause).
          # Widens dst/src/scissor/texpage/CLUT Y to 10 bits per MAME psxgpu (gputype 2)
          # and maps row-bit-9 to DDR3 page 0x08 (+8MB; clear of memcard/SPU/framebuffer
          # pages). Scanout untouched (display reads stay bit-identical). Red/green sim
          # proof: sim/gpu_replay/run_vram2mb.sh + docs/audits/2026-06-10-vram-2mb-redgreen.md.
          "$ROOT/psx_patches/0021-gpu-2mb-vram-10bit-y.patch" \
          # 0022: 4 MB main-RAM decode (PLATFORM.md Main RAM row, constants-class bug #3).
          # The 573 has 4 MB RAM (MAME ksys573.cpp "4M"); the pristine core decodes only
          # 2 MB (ram8mb=0) or 8 MB linear (ram8mb=1), so +4MB accesses silently hit the
          # wrong SDRAM cells. Adds an opt-in ram4mb port (default '0' = pristine
          # behavior): masks RAM-region address bit 22 at the psx_top ram_Adr chokepoint
          # (CPU + icache + DMA reads) and at the dma.vhd write-back fifo insert --
          # matching MAME's DMA n_adrmask = ramsize-1 = 0x3fffff (cpu/psx/dma.cpp).
          # emu.sv enables it via S573_RAM4MB. Red/green: sim/system573/run_ram_mirror.sh.
          "$ROOT/psx_patches/0022-s573-main-ram-4mb.patch" \
          # 0023 = ATAPI CD-ROM on DMA channel 5 (the hard gate for every CD-installer
          # game). The BIOS's only sector-read data path is DMA mode (mode byte = 2 ->
          # ISR arms ch5: MADR=buf, BCR=bytes>>2, CHCR=0x11050100 manual+chop32); the
          # vendored core's ch5 is dead (request tied '0', no trigger, no WORKING arm
          # -> 'severity failure'). Adds the SPU-pattern 16-bit read trio
          # (atapi_dmaRequest/DMA_ATA_readEna/DMA_ATA_read) threaded dma -> psx_top ->
          # psx_mister -> emu.sv -> system573_top/atapi.v. readEna is ce-qualified
          # (the 573 fabric free-runs on clk1x). Device->RAM only (CHCR bit0 forced 0).
          # Red/green: sim/tb_cdboot.v (BIOS ch5 contract BFM, 32-word chopped bursts).
          "$ROOT/psx_patches/0023-s573-dma-ch5-atapi.patch" \
          # 0024 = SIO1 DSR cassette presence: the BIOS leaf 0x80038A28 polls SIO1_STAT
          # (0x1F801054) bit 7 (DSR); every real security cassette asserts slot DSR
          # (local/seccart_presence/) show ZERO SIO1 writes, so no IRQ work is needed.
          "$ROOT/psx_patches/0024-s573-sio1-dsr-presence.patch" \
          # 0025 = audio IIR low-pass -> PASSTHROUGH (resource recovery): frees ~436
          # ALM + 8 DSP so the 16 MB flash-saver (persistence) fits + clears the 100%
          # DSP wall. LOW risk: HPS-configured framework filter, zero boot exposure;
          # drops only the optional audio low-pass. docs/audits/2026-06-12-resource-recovery-scope.md
          "$ROOT/psx_patches/0025-s573-audio-iir-passthrough.patch" \
          # 0026 = resource-recovery candidate #3 (~575 ALM): strip the PSX controller
          # + light-gun paths. The 573 is a JAMMA/JVS arcade board with NO PSX
          # controller port -- gameplay input arrives over the JAMMA register in
          # s573_io.v (0x1f400008, fed by emu.sv ~{joy}), entirely independent of the
          # PSX SIO0 pad path. Removes joypad.vhd's ijoypad_pad SM (~534 ALM) and the
          # gpu_videoout.vhd justifier_sensor x2 + gpu_crosshair x2 (~41 ALM), tying
          # the shared SIO0 OR-bus (receiveValidPad/receiveBufferPad/ackPad/isActivePad)
          # and the gun overlay/IRQ10 terms to benign idle so the bus + GPU video mux
          # read exactly as "no pad/gun present". KEEPS joypad_mem + memcard1 (DDR /
          # Dancing-Stage edit data saves to the PS1 card). NVC-elaborate clean.
          # docs/audits/2026-06-12-resource-recovery-scope.md (cand #3).
          "$ROOT/psx_patches/0026-s573-strip-psx-joypad-pad-lightgun.patch" \
          # 0027 = resource-recovery candidate #4 (~64 ALM): drop the 2nd PS1 memory
          # card (joypad_mem #2) + the SNAC pad passthrough paths inside joypad.vhd.
          # Only card 1 is a real 573 use; no 573 game mounts a 2nd card, and the 573
          # never enables SNAC (a physical DE10 user-IO controller path -- emu.sv ties
          # snacport1/2 = 0). The mem2 master-port outputs are tied idle (no DDR3
          # traffic) and the SNAC select/clock lines are tied '0', which is exactly the
          # "no card-2 / no SNAC" state the surrounding SIO0 logic already special-cases
          # (selectedPortXSnac=0 -> actionNextCombine=actionNext + stock port select).
          # Stacks on 0026 (same file, joypad.vhd). NVC-elaborate clean.
          # docs/audits/2026-06-12-resource-recovery-scope.md (cand #4).
          "$ROOT/psx_patches/0027-s573-strip-memcard2-snac.patch" )

if [ ! -e "$PSX/.git" ]; then
  echo "error: psx submodule not initialised. Run: git submodule update --init psx" >&2
  exit 1
fi
cd "$PSX"
mode="${1:-apply}"

# files a patch touches (relative to psx/), for scoped resets only
touched_files() { for p in "${PATCHES[@]}"; do sed -n 's#^+++ b/##p' "$p"; done | sort -u; }

case "$mode" in
  --check)
    # Validate the patch STACK, not each patch in isolation. Later patches
    # (e.g. 0006/0007) extend the same files/regions earlier ones (0001) add, so
    # a per-patch reverse/forward check against the live tree gives false
    # "WILL NOT APPLY" once the stack is applied. Instead, reconstruct the pinned
    # baseline of every touched file in a scratch dir and apply the patches there
    # in order -- exactly the sequence `apply` produces -- writing NOTHING to the
    # real psx working tree.
    rc=0
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    # Seed scratch with the pinned (PIN) version of each touched file.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mkdir -p "$scratch/$(dirname "$f")"
      git show "$PIN:$f" > "$scratch/$f" 2>/dev/null \
        || { echo "error: cannot read pinned $f" >&2; exit 1; }
    done < <(touched_files)
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      # Apply (check, then apply) into the scratch tree so later patches in the
      # stack see earlier ones. `git apply -p1` operates on the files in $scratch
      # without needing it to be a git repo (we run it with the scratch dir as cwd).
      if ( cd "$scratch" && git apply -p1 --check "$p" 2>/dev/null \
                          && git apply -p1         "$p" 2>/dev/null ); then
        echo "applies cleanly:  $(basename "$p")"
      else
        echo "WILL NOT APPLY:   $(basename "$p")"
        ( cd "$scratch" && git apply -p1 --check "$p" ) || true
        rc=1
      fi
    done
    exit $rc
    ;;
  --revert)
    for ((i=${#PATCHES[@]}-1; i>=0; i--)); do
      p="${PATCHES[$i]}"
      if git apply --reverse --check "$p" 2>/dev/null; then git apply --reverse "$p"; fi
    done
    echo "psx: reverted local patches (pristine pinned core)."
    exit 0
    ;;
  apply|"")
    head="$(git rev-parse HEAD)"
    [ "$head" = "$PIN" ] || echo "warning: psx at $head, expected pinned $PIN; patches may not apply cleanly." >&2
    # Fast path: the patches form a STACK (later ones extend the same regions
    # earlier ones add). The topmost patch on each file reverse-checks clean iff
    # the whole stack is already applied; so if the LAST patch reverse-applies,
    # everything is in place -- skip the per-patch dance (whose isolated reverse-
    # check gives false negatives on bottom-of-stack patches like 0001, forcing an
    # unnecessary reset+reapply of the whole tree).
    if [ "${#PATCHES[@]}" -gt 0 ] && \
       git apply --reverse --check "${PATCHES[${#PATCHES[@]}-1]}" 2>/dev/null; then
      for p in "${PATCHES[@]}"; do echo "already applied: $(basename "$p")"; done
      exit 0
    fi
    for p in "${PATCHES[@]}"; do
      [ -f "$p" ] || { echo "error: missing patch $p" >&2; exit 1; }
      if git apply --reverse --check "$p" 2>/dev/null; then
        echo "already applied: $(basename "$p")"
      elif git apply --check "$p" 2>/dev/null; then
        git apply "$p"; echo "applied: $(basename "$p")"
      else
        # partial/conflicted: reset ONLY this patch's files to the pinned state, then apply
        echo "note: resetting patch-touched files to pinned state, then applying $(basename "$p")" >&2
        # shellcheck disable=SC2046
        git checkout -- $(touched_files)
        git apply "$p"; echo "applied (after reset): $(basename "$p")"
      fi
    done
    exit 0
    ;;
  *)
    echo "usage: $0 [apply|--check|--revert]" >&2; exit 2
    ;;
esac
