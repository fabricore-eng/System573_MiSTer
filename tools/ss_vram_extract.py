#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# ss_vram_extract.py -- carve the VRAM + main-RAM slices out of a PSX/573
# savestate (.ss) for STAGE-0 static graphics-garble analysis (board-free).
#
# WHY: the hyperbbc garble is a render-time bug we want to isolate WITHOUT the
# alignment confound of comparing free-running HW vs MAME. A HW savestate FREEZES
# our core's complete VRAM, so we can byte-compare the frozen textures/CLUTs vs
# MAME's -- the cheapest rung (Stage 0 of .claude/plans/calm-wiggling-honey.md).
# This tool is the board-free first step the moment a real .ss lands.
#
# A .ss is the raw DDR savestate region: 1048576 little-endian 32-bit DWORDs =
# 4 MiB, laid out per psx/rtl/savestates.vhd `savetypes` (confirmed at
# savestates.vhd:119-121). The two slices that matter for the garble:
#   * VRAM (savetype 15): DWORD 262144.. -> byte 0x100000, 1 MiB.
#       = 1024x512 RGB555 LE (textures + CLUTs + framebuffer the GPU samples).
#   * RAM  (savetype 16): DWORD 524288.. -> byte 0x200000, 2 MiB.
#       = PSX main RAM (game code/data; what the CPU runs when stepped forward).
# Header: DWORD[1] == STATESIZE 0x000FFFFE is the slot-valid magic the in-core
# loader checks (savestates.vhd:557,572) -- identical to the file the MiSTer
# firmware writes for an Alt-F1 HW savestate, and to ddrram_model's ss_out.ss.
#
# The extracted VRAM .bin is EXACTLY the raw format tools/hw_display_frame.py +
# ~/Dev/mister-dev-hub/tools/frame_diff_regions.py already consume (1024x512
# RGB555 LE, stride 2048), so the whole Stage-0 pipeline is:
#
#   tools/ss_vram_extract.py state.ss --vram local/ss_vram.bin
#   tools/hw_display_frame.py local/ss_vram.bin   --window 0,0,1024,512 --out local/ss_vram.png
#   tools/hw_display_frame.py local/mame_vram.bin --window 0,0,1024,512 --out local/mame_vram.png
#   ~/Dev/mister-dev-hub/tools/frame_diff_regions.py \
#       local/mame_vram.png local/ss_vram.png --grid 16x16 --heatmap local/vram_heat.png --json
#
# ...or just run the turnkey wrapper:  tools/ss_garble_probe.sh state.ss mame_vram.bin
#
# Usage:
#   ss_vram_extract.py STATE.ss [--vram OUT.bin] [--ram OUT.bin] [--slot N] [--lenient]
#   ss_vram_extract.py --selftest          # synthesize a .ss, round-trip, assert
#
# Exit: 0 ok / 1 invalid .ss (bad size or magic, unless --lenient) / 2 usage.
# ---------------------------------------------------------------------------
import argparse
import struct
import sys

SLOT_BYTES = 4 * 1024 * 1024        # one savestate slot = 1048576 LE dwords = 4 MiB
STATESIZE  = 0x000FFFFE             # DWORD[1] slot-valid magic (savestates.vhd)

# Slice byte offsets/lengths within a slot (savetype DWORD base * 4):
VRAM_OFF, VRAM_LEN = 0x100000, 0x100000   # savetype 15 @ DWORD 262144, 1 MiB
RAM_OFF,  RAM_LEN  = 0x200000, 0x200000   # savetype 16 @ DWORD 524288, 2 MiB


def dword(buf, idx):
    """Little-endian 32-bit DWORD at dword-index idx."""
    return struct.unpack_from("<I", buf, idx * 4)[0]


def validate(buf, slot=0):
    """Return (ok, [problems]) for the chosen 4-MiB slot of `buf`."""
    problems = []
    need = (slot + 1) * SLOT_BYTES
    if len(buf) < need:
        problems.append(
            f"file is {len(buf)} bytes; slot {slot} needs >= {need} "
            f"({slot + 1} x 4 MiB). Not a {slot + 1}-slot .ss?"
        )
        return False, problems
    base = slot * SLOT_BYTES
    magic = struct.unpack_from("<I", buf, base + 4)[0]   # DWORD[1] of the slot
    if magic != STATESIZE:
        problems.append(
            f"slot {slot} DWORD[1] = 0x{magic:08X}, expected STATESIZE "
            f"0x{STATESIZE:08X}. Wrong-magic / empty slot -> the in-core loader "
            f"would treat it as INVALID (validSStates=0)."
        )
    return (len(problems) == 0), problems


def slice_of(buf, slot, off, length):
    base = slot * SLOT_BYTES
    return buf[base + off: base + off + length]


def extract(path, slot=0, lenient=False):
    """Read `path`, validate, return (vram_bytes, ram_bytes, problems)."""
    with open(path, "rb") as f:
        buf = f.read()
    ok, problems = validate(buf, slot)
    if not ok and not lenient:
        return None, None, problems
    vram = slice_of(buf, slot, VRAM_OFF, VRAM_LEN)
    ram = slice_of(buf, slot, RAM_OFF, RAM_LEN)
    return vram, ram, problems


def synth_ss(seed=0xA5):
    """Build a valid 1-slot synthetic .ss with a deterministic VRAM gradient and
    a magic RAM pattern -- used by --selftest (and as a stand-in for run.sh)."""
    buf = bytearray(SLOT_BYTES)
    # header: DWORD[0]=header_amount (arbitrary), DWORD[1]=STATESIZE magic.
    struct.pack_into("<I", buf, 0, 0x00000007)
    struct.pack_into("<I", buf, 4, STATESIZE)
    # VRAM region: a horizontal RGB555 gradient (so a render is visibly a ramp,
    # and every dword is distinct -> a slice/offset bug shows immediately).
    for i in range(VRAM_LEN // 2):                 # 16-bit pixels
        px = (i & 0x1F) | (((i >> 5) & 0x1F) << 5) | (((i >> 10) & 0x1F) << 10)
        struct.pack_into("<H", buf, VRAM_OFF + i * 2, px & 0x7FFF)
    # RAM region: a recognizable per-dword magic (seed-keyed) for a byte check.
    for i in range(RAM_LEN // 4):
        struct.pack_into("<I", buf, RAM_OFF + i * 4, (seed << 24) | (i & 0xFFFFFF))
    return bytes(buf)


def selftest():
    import os
    import tempfile
    fails = []

    def check(cond, msg):
        print(("  PASS  " if cond else "  FAIL  ") + msg)
        if not cond:
            fails.append(msg)

    blob = synth_ss(seed=0x5A)
    check(len(blob) == SLOT_BYTES, f"synth .ss is exactly 4 MiB ({len(blob)})")
    ok, probs = validate(blob)
    check(ok, "synth .ss validates (magic + size)")

    # corrupt the magic -> must be rejected (and lenient must still carve).
    bad = bytearray(blob)
    struct.pack_into("<I", bad, 4, 0xDEADBEEF)
    ok_bad, _ = validate(bytes(bad))
    check(not ok_bad, "wrong-magic .ss is REJECTED by validate()")

    # truncated file -> rejected.
    ok_short, _ = validate(blob[: SLOT_BYTES - 4])
    check(not ok_short, "truncated .ss is REJECTED by validate()")

    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "synth.ss")
        with open(p, "wb") as f:
            f.write(blob)
        vram, ram, probs = extract(p)
        check(vram is not None and len(vram) == VRAM_LEN,
              f"VRAM slice carved, {VRAM_LEN} bytes")
        check(ram is not None and len(ram) == RAM_LEN,
              f"RAM slice carved, {RAM_LEN} bytes")
        # round-trip: the carved slices equal the source regions exactly.
        check(vram == blob[VRAM_OFF:VRAM_OFF + VRAM_LEN],
              "VRAM slice == source bytes [0x100000:0x200000) (offset exact)")
        check(ram == blob[RAM_OFF:RAM_OFF + RAM_LEN],
              "RAM slice == source bytes [0x200000:0x400000) (offset exact)")
        # spot-check a known VRAM pixel and RAM dword to catch an endian flip.
        first_px = struct.unpack_from("<H", vram, 0)[0]
        check(first_px == 0, "VRAM[0] pixel == 0 (gradient origin, LE intact)")
        px100 = struct.unpack_from("<H", vram, 0x100 * 2)[0]
        check(px100 == (0x100 & 0x1F) | (((0x100 >> 5) & 0x1F) << 5),
              "VRAM[0x100] pixel matches the gradient law (no shift)")
        ram_d3 = struct.unpack_from("<I", ram, 3 * 4)[0]
        check(ram_d3 == (0x5A << 24) | 3, "RAM dword[3] == seeded magic (no shift)")
        # bad-magic file: strict rejects (None), lenient carves anyway.
        bp = os.path.join(d, "bad.ss")
        with open(bp, "wb") as f:
            f.write(bytes(bad))
        v_strict, _, _ = extract(bp)
        check(v_strict is None, "strict extract() of bad-magic .ss returns None")
        v_len, _, _ = extract(bp, lenient=True)
        check(v_len is not None and len(v_len) == VRAM_LEN,
              "--lenient extract() of bad-magic .ss still carves VRAM")

    print("-" * 43)
    if fails:
        print(f"ss_vram_extract selftest: {len(fails)} FAIL")
        return 1
    print("ss_vram_extract selftest: ALL PASS")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Carve VRAM/RAM slices from a 573 .ss")
    ap.add_argument("state", nargs="?", help="input savestate (.ss)")
    ap.add_argument("--vram", help="write the 1 MiB VRAM slice here")
    ap.add_argument("--ram", help="write the 2 MiB main-RAM slice here")
    ap.add_argument("--slot", type=int, default=0,
                    help="slot index if the .ss holds multiple 4-MiB slots (default 0)")
    ap.add_argument("--lenient", action="store_true",
                    help="carve even if the header magic/size check fails (still warns)")
    ap.add_argument("--selftest", action="store_true",
                    help="synthesize a .ss, round-trip, assert; exit 0/1")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.state:
        ap.error("STATE.ss required (or --selftest)")

    vram, ram, problems = extract(args.state, slot=args.slot, lenient=args.lenient)
    for p in problems:
        print(f"WARN: {p}", file=sys.stderr)
    if vram is None:
        print("ERROR: invalid .ss (use --lenient to carve anyway)", file=sys.stderr)
        return 1

    if not args.vram and not args.ram:
        # default: report only, so a bare run is a safe validity check.
        print(f"OK: {args.state} slot {args.slot} is a valid .ss "
              f"(VRAM {len(vram)} B, RAM {len(ram)} B). "
              f"Pass --vram/--ram to write slices.")
        return 0
    if args.vram:
        with open(args.vram, "wb") as f:
            f.write(vram)
        print(f"wrote VRAM slice -> {args.vram} ({len(vram)} bytes, 1024x512 RGB555 LE)")
    if args.ram:
        with open(args.ram, "wb") as f:
            f.write(ram)
        print(f"wrote RAM slice  -> {args.ram} ({len(ram)} bytes, PSX main RAM)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
