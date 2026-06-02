#!/usr/bin/env python3
"""Pack the hyperbbc (Hyper Bishi Bashi Champ) onboard NOR flash into a flat 16 MB
image matching the System 573 core's bank layout.

Interleave (from MAME konami/ksys573.cpp flashbank_map, umask16):
  per 16-bit word W in a 4 MB bank:
    image[base + 2*W + 0] = 31x[W]   (low byte,  umask16 0x00ff)
    image[base + 2*W + 1] = 27x[W]   (high byte, umask16 0xff00)
  banks (control reg 0x1F500000 value -> chip pair), MAME order m,l,j,h:
    bank0 = 31m/27m   bank1 = 31l/27l   bank2 = 31j/27j   bank3 = 31h/27h

NOTE: the bank ORDER (m,l,j,h) is from the investigator's read of flashbank_map and
is being cross-checked against the raw source separately. The packer is parameterized
so re-ordering is a one-line change.
"""
import sys, os, zlib, zipfile

ZIP = "dumps/mame573/hyperbbc.zip"
OUTDIR = "dumps/hyperbbc"
IMG = os.path.join(OUTDIR, "flash16m.bin")
NVR = os.path.join(OUTDIR, "nvram8k.bin")

# MAME known-good CRC32s (from ksys573.cpp ROM_LOAD lines)
CRC = {
    "876ea.31m": 0xa76043cb, "876ea.27m": 0x689ddd94,
    "876ea.31l": 0xd011c7a5, "876ea.27l": 0x950a5267,
    "876ea.31j": 0xae497ebc, "876ea.27j": 0x9c156b1b,
    "876ea.31h": 0x368372fb, "876ea.27h": 0x49175f99,
    "876ea.22h": 0x8e11d196,  # M48T58 NVRAM
}
# bank -> (low '31x', high '27x')
BANKS = [
    ("876ea.31m", "876ea.27m"),  # bank 0
    ("876ea.31l", "876ea.27l"),  # bank 1
    ("876ea.31j", "876ea.27j"),  # bank 2
    ("876ea.31h", "876ea.27h"),  # bank 3
]

def main():
    os.makedirs(OUTDIR, exist_ok=True)
    data = {}
    with zipfile.ZipFile(ZIP) as z:
        for name in CRC:
            data[name] = z.read(name)

    print("=== CRC32 verification vs MAME ===")
    ok = True
    for name, want in CRC.items():
        got = zlib.crc32(data[name]) & 0xffffffff
        status = "OK " if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  {status} {name:12s} {len(data[name]):>8d} B  crc={got:08x} want={want:08x}")
    if not ok:
        print("!! CRC MISMATCH — aborting, will not pack a corrupt image")
        sys.exit(1)

    # sizes
    for name, _ in BANKS:
        assert len(data[name]) == 0x200000, f"{name} not 2MB"

    img = bytearray(b"\xff" * 0x1000000)  # 16 MB, default erased 0xFF
    for bank, (low, high) in enumerate(BANKS):
        base = bank * 0x400000
        img[base + 0 : base + 0x400000 : 2] = data[low]   # even bytes = low (31x)
        img[base + 1 : base + 0x400000 : 2] = data[high]  # odd  bytes = high (27x)

    with open(IMG, "wb") as f:
        f.write(img)
    with open(NVR, "wb") as f:
        f.write(data["876ea.22h"])

    # sanity
    nblank = sum(1 for i in range(0, len(img), 2) if img[i] == 0xff and img[i+1] == 0xff)
    total_words = len(img) // 2
    print(f"\n=== packed {IMG} ({len(img)} bytes = {len(img)//(1024*1024)} MB) ===")
    print(f"  blank (0xFFFF) words: {nblank}/{total_words} = {100*nblank/total_words:.1f}%")
    print(f"  bank0 first 16 words (little-endian, as CPU reads): "
          + " ".join(f"{img[2*w+1]<<8 | img[2*w]:04x}" for w in range(16)))
    # show each bank's first word so a swapped-bank-order bug is visible
    for bank in range(4):
        b = bank * 0x400000
        print(f"  bank{bank} @0x{b:07x}: first word = {img[b+1]<<8 | img[b]:04x}, "
              f"low-chip-byte0=0x{img[b]:02x} high-chip-byte0=0x{img[b+1]:02x}")
    print(f"\n=== NVRAM {NVR} ({os.path.getsize(NVR)} bytes) ===")

if __name__ == "__main__":
    main()
