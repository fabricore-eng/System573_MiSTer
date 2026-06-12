#!/usr/bin/env python3
"""Extract the Punch Mania 2 (pnchmn2) System 573 security-cartridge data so it can
be streamed to the core's NEW security ioctl channels (Feature A):

  ioctl index 4 = security EEPROM (.u1)  -> s573_seccart -> x76f041 (548-byte image)
  ioctl index 5 = DS2401 serial (.u6)    -> s573_seccart -> ds2401  (8-byte image)

The .u1 / .u6 files are copied verbatim (the X76F041 model's load port consumes the
raw 548-byte MAME nvram image, and the DS2401 model consumes the raw 8-byte 1-Wire
ROM -- both byte layouts are documented in rtl/x76f041.v and rtl/ds2401.v headers).

It ALSO packs the two onboard-flash chips (gqa09ja.31m / .27m, one 4 MB bank pair)
into a flat 16 MB flash image in the SAME interleave the core expects (even byte =
low '31x' chip, odd byte = high '27x' chip), so a future full pnchmn2 boot can stream
bios+flash+.u1+.u6 in one .mra. NOTE: pnchmn2 is a CD-based game (it also needs its
a09jaa02 CHD), so this flash image alone is NOT a complete game -- the deliverable
here is the SECURITY CART data; the flash/CD path is out of scope for Feature A.

Outputs to dumps/pnchmn2/: eeprom.u1, serial.u6, flash16m.bin
"""
import sys, os, zlib, zipfile

ZIP = "dumps/mame573/pnchmn2.zip"
OUTDIR = "dumps/pnchmn2"

# MAME-listed contents (size + crc32) for pnchmn2. The X76F041 .u1 (and historically
# the .u6) are flagged `baddump` in MAME; the .u1 dump WE have (and that this project
# was given) is crc e1e4108f, which differs from MAME's recorded 5923bba3 -- it is a
# distinct dump of the same bad part. We pin its SIZE (548) hard but treat its CRC as
# advisory (WARN, don't abort): it is the only image we have and is byte-identical to
# the copy the task supplied. The flash chips + .u6 are CRC-pinned hard.
#   (size, crc, hard_crc)
PARTS = {
    "gqa09ja.u1":  (548,     0x5923bba3, False),  # X76F041 EEPROM (cassette:game:eeprom) -- baddump, CRC advisory
    "gqa09ja.u6":  (8,       0xce84419e, True),   # DS2401 serial  (cassette:game:id)
    "gqa09ja.31m": (2097152, 0xb1043a91, True),   # onboard flash, low  chip (29f016a.31m)
    "gqa09ja.27m": (2097152, 0x09b1a70b, True),   # onboard flash, high chip (29f016a.27m)
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

    print("=== size / CRC32 verification vs MAME pnchmn2 ===")
    fatal = False
    for name, (sz, crc, hard) in PARTS.items():
        got = zlib.crc32(data[name]) & 0xffffffff
        szok = len(data[name]) == sz
        crcok = got == crc
        if not szok or (not crcok and hard):
            fatal = True
            tag = "FAIL"
        elif not crcok:
            tag = "WARN"   # advisory CRC (baddump); size OK -> proceed
        else:
            tag = "OK "
        note = "" if crcok else (" (baddump; advisory)" if not hard else "")
        print(f"  {tag} {name:12s} {len(data[name]):>8d} B (want {sz})  "
              f"crc={got:08x} want={crc:08x}{note}")
    if fatal:
        print("!! size/CRC mismatch on a hard-pinned part -- aborting"); sys.exit(1)

    # --- security cart parts: copied verbatim ---
    u1 = os.path.join(OUTDIR, "eeprom.u1")
    u6 = os.path.join(OUTDIR, "serial.u6")
    with open(u1, "wb") as f: f.write(data["gqa09ja.u1"])
    with open(u6, "wb") as f: f.write(data["gqa09ja.u6"])

    # --- onboard flash: one 4 MB bank pair, interleaved low=31x / high=27x ---
    img = bytearray(b"\xff" * 0x1000000)            # 16 MB, erased 0xFF
    base = 0                                         # bank 0
    img[base + 0 : base + 0x400000 : 2] = data["gqa09ja.31m"]   # even = low chip
    img[base + 1 : base + 0x400000 : 2] = data["gqa09ja.27m"]   # odd  = high chip
    flash = os.path.join(OUTDIR, "flash16m.bin")
    with open(flash, "wb") as f: f.write(img)

    print(f"\n=== wrote security cart data ===")
    print(f"  {u1}  ({os.path.getsize(u1)} B)  -> ioctl index 4 (X76F041 EEPROM)")
    print(f"  {u6}  ({os.path.getsize(u6)} B)    -> ioctl index 5 (DS2401 serial)")
    # decode + echo the layout so a human can eyeball it
    d = data["gqa09ja.u1"]
    print(f"  .u1 layout: RTR={d[0:4].hex()}  wpw={d[4:12].hex()}  rpw={d[12:20].hex()}")
    print(f"              cpw={d[20:28].hex()}  creg={d[28:36].hex()}  data[0:5]={d[36:41].hex()}")
    s = data["gqa09ja.u6"]
    print(f"  .u6 ROM (file order, CRC-first): {s.hex()}  family=0x{s[7]:02x} serial={s[1:7].hex()} crc=0x{s[0]:02x}")
    print(f"  {flash}  ({os.path.getsize(flash)} B = 16 MB) -> ioctl index 2 (onboard flash)")

if __name__ == "__main__":
    main()
