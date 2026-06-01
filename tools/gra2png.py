#!/usr/bin/env python3
"""Convert the PSX-core sim .gra ASCII framebuffer dump to PNG (or PPM).

The .gra format (psx/sim/system/src/tb/framebuffer.vhd and ddrram_model.vhd):
  line 1 : "W#H#scale"      e.g. "640#480#2"   (width, height, scale factor)
  line N : "COLOR#x#y"      COLOR = 24-bit packed RGB (0x00RRGGBB), x, y pixel coords

Pixels not written stay black. Later writes to the same (x,y) overwrite earlier
ones, matching how the .gra accumulates over frames.

Usage:
  tools/gra2png.py in.gra out.png          # PNG if Pillow available, else PPM
  tools/gra2png.py in.gra out.ppm          # always writes a P6 PPM
  tools/gra2png.py in.gra                   # -> in.png (or in.ppm fallback)

Exit status:
  0 ok, 2 if the .gra has only a header / no pixels (reports that fact).
"""
import sys
import os


def parse_gra(path):
    with open(path, "r") as f:
        header = f.readline().strip()
        parts = header.split("#")
        if len(parts) < 2:
            raise ValueError(f"bad .gra header: {header!r}")
        w = int(parts[0])
        h = int(parts[1])
        # framebuffer.gra y can exceed declared H when interlaced; grow as needed.
        pixels = {}
        maxx = 0
        maxy = 0
        n = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            c = line.split("#")
            if len(c) != 3:
                continue
            color = int(c[0])
            x = int(c[1])
            y = int(c[2])
            pixels[(x, y)] = color
            maxx = max(maxx, x)
            maxy = max(maxy, y)
            n += 1
    # honor declared dims but never clip real pixels
    w = max(w, maxx + 1)
    h = max(h, maxy + 1)
    return w, h, pixels, n


def write_ppm(path, w, h, pixels):
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode("ascii"))
        row = bytearray(w * 3)
        for y in range(h):
            for x in range(w):
                c = pixels.get((x, y), 0)
                i = x * 3
                row[i] = (c >> 16) & 0xFF
                row[i + 1] = (c >> 8) & 0xFF
                row[i + 2] = c & 0xFF
            f.write(row)


def write_png(path, w, h, pixels):
    try:
        from PIL import Image
    except ImportError:
        return False
    img = Image.new("RGB", (w, h), (0, 0, 0))
    px = img.load()
    for (x, y), c in pixels.items():
        if 0 <= x < w and 0 <= y < h:
            px[x, y] = ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
    img.save(path)
    return True


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    inp = argv[1]
    if len(argv) >= 3:
        out = argv[2]
    else:
        out = os.path.splitext(inp)[0] + ".png"

    w, h, pixels, n = parse_gra(inp)
    nonblack = sum(1 for c in pixels.values() if c != 0)
    print(f"{inp}: {w}x{h}, {n} pixel records, {len(pixels)} unique coords, "
          f"{nonblack} non-black")

    if n == 0:
        print("WARNING: .gra contains no pixel data (header only) -- "
              "the video path produced no active pixels.")

    ext = os.path.splitext(out)[1].lower()
    if ext == ".ppm":
        write_ppm(out, w, h, pixels)
        print(f"wrote {out} (PPM)")
    else:
        if write_png(out, w, h, pixels):
            print(f"wrote {out} (PNG)")
        else:
            out = os.path.splitext(out)[0] + ".ppm"
            write_ppm(out, w, h, pixels)
            print(f"Pillow not available; wrote {out} (PPM) instead")

    return 0 if n > 0 else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
