#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# gen_seccart_u1.py - synthesize a System 573 X76F100 security-cassette .u1 image
#
# *** SCOPE / IMPORTANT (corrected 2026-06-12 after the first HW boot of hypbbc2p) ***
#   This synthesized .u1 satisfies ONLY the IN-GAME security check (game fn
#   0x80036ec4, which runs from the CD-loaded program). It does NOT satisfy the
#   573 BIOS BOOT-TIME cassette SIGNATURE check -- the wall that shows on-screen
#   as "-11N". The BIOS reads cassette blocks 0,0,1,2 at boot and verifies an
#   authentic signature in block 1 (data[8:15] = 81 00 29 00 00 18 eb 52). That
#   signature is authentic-DUMP data: it is NOT derivable from anything the game
#   plaintext carries. So to actually BOOT hypbbc2p on hardware you MUST stage the
#   real gx908ja.u1 dump (as games/System573/hypbbc2p.u1) -- treat it like a BIOS,
#   a required user-supplied artifact. The MAME-"BAD_DUMP" gx908ja.u1 (crc
#   8900eaff) is functionally complete and works.
#
#   This script remains useful for ANALYZING / unit-testing the in-game check; it
#   does NOT replace the real dump. (HW-confirmed 2026-06-12: the synth .u1 stalls
#   at the BIOS -11N before the CD program ever loads, so fn 0x80036ec4 is never
#   reached; with the real gx908ja.u1 the board boots and runs.)
#
# WHAT THE SYNTHESIZED TOKEN COVERS (the in-game check only):
#   The hypbbc2p in-game security check is fn 0x80036ec4 (disassembled in workflow
#   w135q1s92). It:
#     (1) checks DSR presence,
#     (2) identifies the cart type via the X76F100 response-to-reset
#         (19 00 AA 55 = X76F100),
#     (3) READS the X76F100 by sending an 8-byte READ PASSWORD that the game
#         carries IN PLAINTEXT:  e9 34 df 40 7a d1 a7 ff
#         (the chip NAKs on mismatch -> the game returns -3 = the on-screen
#          "-3N INCORRECT SECURITY CASSETTE" wall),
#     (4) checks ONLY data[0],data[1] == "JA" (0x4a,0x41) for the region and the
#         checksum byte data[4] == (~(data[0]+data[1]) & 0xff) (= 0x74 for "JA");
#         everything else is don't-care,
#     (5) the write-back path is always skipped.
#   The in-game token above is reconstructable from plaintext the game carries --
#   but, again, that only matters AFTER the CD program loads, which only happens
#   once the BIOS -11N signature check (real-dump-only) has passed.
#
# IMAGE LAYOUT (MAME machine/x76f100.cpp nvram order; 132 bytes total):
#   [  0:  4] response-to-reset : 19 00 AA 55       (hard-wired in RTL rtr_val())
#   [  4: 12] write password    : 00 * 8            (write-back is skipped)
#   [ 12: 20] read  password    : e9 34 df 40 7a d1 a7 ff   (the plaintext key)
#   [ 20:132] 112 data bytes    : data[0]=region0, data[1]=region1,
#                                 data[4]=~(data0+data1)&0xff, rest 0x00
#
# The RTL x76f100 load port stores [4:12]->wpw, [12:20]->rpw, [20:132]->data and
# drops [0:4] (RtR is constant). emu.sv latches a 132-byte image as X76F100
# (size tiers: >=560 ZS01, >=256 X76F041, else X76F100).
# -----------------------------------------------------------------------------
import argparse
import os
import sys

RTR        = bytes([0x19, 0x00, 0xAA, 0x55])
WRITE_PW   = bytes(8)  # 00 * 8 -- write-back path is always skipped
READ_PW    = bytes([0xe9, 0x34, 0xdf, 0x40, 0x7a, 0xd1, 0xa7, 0xff])

# Region variants: (data[0], data[1]); data[4] is derived as ~(d0+d1)&0xff.
REGIONS = {
    "JAA": (0x4a, 0x41),  # Japan  -- "JA" -> data[4] = 0x74
    "KAA": (0x4b, 0x41),  # Korea  -- "KA" -> data[4] = 0x73
}


def build_u1(region: str) -> bytes:
    d0, d1 = REGIONS[region]
    d4 = (~(d0 + d1)) & 0xff
    data = bytearray(112)
    data[0] = d0
    data[1] = d1
    # data[2], data[3] = 0x00 (don't-care)
    data[4] = d4
    # data[5:112] = 0x00 (don't-care)
    img = RTR + WRITE_PW + READ_PW + bytes(data)
    assert len(img) == 132, f"image must be 132 bytes, got {len(img)}"
    return img


def main() -> int:
    ap = argparse.ArgumentParser(description="synthesize a hypbbc2p X76F100 .u1")
    ap.add_argument("--region", default="JAA", choices=sorted(REGIONS),
                    help="region variant (default JAA = Japan)")
    ap.add_argument("-o", "--out", default=None,
                    help="output path (default: hypbbc2p[_<region>].u1 next to this script's repo games dir)")
    ap.add_argument("--all", action="store_true",
                    help="emit every region variant alongside the default output")
    ap.add_argument("--hexdump", action="store_true",
                    help="also print a hexdump of the emitted JAA image to stdout")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    games = os.path.join(repo, "games", "System573")
    os.makedirs(games, exist_ok=True)

    def emit(region: str, path: str) -> bytes:
        img = build_u1(region)
        with open(path, "wb") as f:
            f.write(img)
        print(f"gen_seccart_u1: wrote {path} ({len(img)} bytes, region {region})")
        return img

    if args.all:
        jaa = emit("JAA", args.out or os.path.join(games, "hypbbc2p.u1"))
        for region in REGIONS:
            if region == "JAA":
                continue
            emit(region, os.path.join(games, f"hypbbc2p_{region.lower()}.u1"))
        img = jaa
    else:
        out = args.out or os.path.join(games, "hypbbc2p.u1")
        img = emit(args.region, out)

    if args.hexdump:
        for off in range(0, len(img), 16):
            chunk = img[off:off + 16]
            hx = " ".join(f"{b:02x}" for b in chunk)
            print(f"{off:04x}: {hx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
