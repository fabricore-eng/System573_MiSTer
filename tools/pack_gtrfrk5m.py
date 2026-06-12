#!/usr/bin/env python3
"""Extract the Guitar Freaks 5th Mix (gtrfrk5m) System 573 security-cartridge + flash
data so it can be streamed to the core's ioctl channels (Feature A, ZS01 target):

  ioctl index 2 = onboard flash (.31m/.27m) -> 16 MB flat image (bank 0 pair)
  ioctl index 4 = security EEPROM (.u1)      -> s573_seccart -> zs01 (4116-byte image)
  ioctl index 5 = DS2401 serial (.u6)        -> s573_seccart -> ds2401 (8-byte image)

gtrfrk5m is the CLEAN Feature-A ZS01 validation target: its security cart is a Konami
ZS01 (NS2K001 PIC), and the .u1 is the raw MAME zs01 NVRAM image (machine konami/
zs01.cpp nvram_read order):
  [  0:  3] response-to-reset (5A 53 00 01)
  [  4: 11] command key   (fixed PIC key, same on all ZS01 carts)
  [ 12: 19] data key      (PER-CART -- it is IN the dump, NOT set at runtime)
  [ 20: 27] config regs   (RR = idx4, RC = idx5)
  [ 28:139] 112 data bytes (the authenticated EEPROM body MAME models)
The full gea26jaa.u1 is 4116 bytes = this 140-byte image + zero padding (the real 4 KB
EEPROM body; MAME, and our rtl/zs01.v, only model the first 112 data bytes). The .u1 is
copied verbatim -- rtl/zs01.v's load port consumes the raw image and drops the padding.

NOTE on scope: MAME's gtrfrk5m machine config (k573d + casszi + pccard1_32mb) ALSO lists
a CD image (a26jaa02) and a 32 MB PC-card. The flash + ZS01 packed here is what the core
can currently load; whether gtrfrk5m boots without the CD/pccard is a HARDWARE question
and is out of scope for Feature A (this delivers the SECURITY-CART loadability + a passing
sim of the authenticated read -- NOT a boot claim). gtrfrk8m (gcc08jba.u1, also 4116 B) is
a second ZS01 target that can be packed by changing GAME/PARTS below.

Outputs to dumps/gtrfrk5m/: eeprom.u1, serial.u6, flash16m.bin
"""
import sys, os, zlib, zipfile

ZIP = "dumps/mame573/gtrfrk5m.zip"
OUTDIR = "dumps/gtrfrk5m"

# MAME-listed contents (size + crc32) for gtrfrk5m. The ZS01 .u1 in MAME is a 140-byte
# synthesized BAD_DUMP (crc 5e16a3f1); the REAL dump we have is the full 4116-byte image
# (crc c2725fca) -- a distinct, more complete dump of the same part. We pin its SIZE
# hard (4116) but treat its CRC as advisory (WARN, don't abort), exactly as pack_pnchmn2
# does for its baddump .u1. The flash chips + .u6 are CRC-pinned hard (they match MAME).
#   (size, crc, hard_crc)
PARTS = {
    "gea26jaa.u1":  (4116,    0x5e16a3f1, False),  # ZS01 EEPROM (cassette:game:eeprom) -- full dump, CRC advisory
    "gea26jaa.u6":  (8,       0xce84419e, True),   # DS2401 serial (cassette:game:id)
    "gea26jaa.31m": (2097152, 0x1a25e660, True),   # onboard flash, low  chip (29f016a.31m)
    "gea26jaa.27m": (2097152, 0x345dc5f2, True),   # onboard flash, high chip (29f016a.27m)
}


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    data = {}
    with zipfile.ZipFile(ZIP) as z:
        names = set(z.namelist())
        for name in PARTS:
            if name not in names:
                print(f"!! {name} missing from {ZIP}"); sys.exit(1)
            data[name] = z.read(name)

    print("=== size / CRC32 verification vs MAME gtrfrk5m ===")
    fatal = False
    for name, (sz, crc, hard) in PARTS.items():
        got = zlib.crc32(data[name]) & 0xffffffff
        szok = len(data[name]) == sz
        crcok = got == crc
        if not szok or (not crcok and hard):
            fatal = True
            tag = "FAIL"
        elif not crcok:
            tag = "WARN"   # advisory CRC (full vs MAME's synth baddump); size OK -> proceed
        else:
            tag = "OK "
        note = "" if crcok else (" (full dump; advisory)" if not hard else "")
        print(f"  {tag} {name:13s} {len(data[name]):>8d} B (want {sz})  "
              f"crc={got:08x} want={crc:08x}{note}")
    if fatal:
        print("!! size/CRC mismatch on a hard-pinned part -- aborting"); sys.exit(1)

    # --- security cart parts: copied verbatim ---
    u1 = os.path.join(OUTDIR, "eeprom.u1")
    u6 = os.path.join(OUTDIR, "serial.u6")
    with open(u1, "wb") as f: f.write(data["gea26jaa.u1"])
    with open(u6, "wb") as f: f.write(data["gea26jaa.u6"])

    # --- onboard flash: one 4 MB bank pair, interleaved low=31x / high=27x ---
    # (same interleave as pack_pnchmn2.py / pack_hyperbbc.py: even byte = .31m low chip,
    # odd byte = .27m high chip; bank 0 at image offset 0).
    img = bytearray(b"\xff" * 0x1000000)            # 16 MB, erased 0xFF
    img[0:0x400000:2] = data["gea26jaa.31m"]        # even = low chip
    img[1:0x400000:2] = data["gea26jaa.27m"]        # odd  = high chip
    flash = os.path.join(OUTDIR, "flash16m.bin")
    with open(flash, "wb") as f: f.write(img)

    print("\n=== wrote security cart + flash data ===")
    print(f"  {u1}  ({os.path.getsize(u1)} B)  -> ioctl index 4 (ZS01 EEPROM)")
    print(f"  {u6}  ({os.path.getsize(u6)} B)    -> ioctl index 5 (DS2401 serial)")
    print(f"  {flash}  ({os.path.getsize(flash)} B = 16 MB) -> ioctl index 2 (onboard flash)")
    # decode + echo the ZS01 layout so a human can eyeball it
    d = data["gea26jaa.u1"]
    print(f"  .u1 ZS01 layout: rtr={d[0:4].hex()}  cmd_key={d[4:12].hex()}")
    print(f"                   data_key={d[12:20].hex()}  config={d[20:28].hex()} (RR={d[24]:#04x})")
    print(f"                   data[addr0]={d[28:36].hex()}  data[addr1]={d[36:44].hex()}")
    s = data["gea26jaa.u6"]
    print(f"  .u6 ROM (file order, CRC-first): {s.hex()}  family=0x{s[7]:02x} serial={s[1:7].hex()} crc=0x{s[0]:02x}")
    print("\nLoad on HW with tools/mister_mra.sh:")
    print(f"  tools/mister_mra.sh --eeprom {u1} --serial {u6} \\")
    print(f"    gtrfrk5m_573 dumps/bios/573.bin {flash} dumps/hyperbbc/nvram8k.bin")


if __name__ == "__main__":
    main()
