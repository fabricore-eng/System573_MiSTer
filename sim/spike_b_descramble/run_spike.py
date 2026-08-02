#!/usr/bin/env python3
"""
run_spike.py - Decision-B differential oracle driver.

For each case it:
  1. generates a pseudo-random DRAM image with a FIXED per-case seed, written both
     as a $readmemh word file (for the RTL) and a raw little-endian byte image
     (for the C reference) -- the SAME bytes, two encodings;
  2. runs the RTL vector dumper (real k573_mp3stream + k573_mp3dec) with a
     randomized DEMAND back-pressure pattern and a randomized non-zero-latency
     DRAM backing;
  3. runs the standalone C reference over the byte image;
  4. compares the two emitted byte streams EXACTLY and reports the first
     divergence (index, expected, got) if any.

Neither side sees the other's output. The only value that flows RTL -> C is the
measured pre-reload byte count in the mid-stream-reload cases (the stimulus'
epoch boundary, not an expected value) -- and the harness asserts it landed where
it was asked to.

Usage:
    ./run_spike.py                    # build + run every case
    ./run_spike.py --case 7           # one case
    ./run_spike.py --mutate NO_KEY3_INC   # negative control: build the C ref
                                          # with a deliberate bug, expect FAIL
    ./run_spike.py --bench            # throughput only
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
RTL = os.path.abspath(os.path.join(HERE, "..", "..", "rtl"))

MEMW = 8192          # words in the sim DRAM backing (must match the testbench)

RAND_KEYS = "R"      # placeholder -> per-case random keys


def case_list():
    """(name, words, start_word, ddrsbm, keys, bp, chunk, reload_at, end2_words)

    keys: a (k1,k2,k3) tuple, or RAND_KEYS.
    bp:   0 always-ready | 1 det 1-of-4 | 2 rand ~50% | 3 rand ~1/8
          4 bursty runs  | 5 near-stalled ~1/64
    reload_at: bytes after which to pulse `reload` mid-stream (0 = never).
    end2_words: new window length applied at that reload (0 = unchanged).
    """
    C = []
    add = C.append
    #    name                 words  sw  sbm  keys                 bp ch  rel  e2
    add(("min1word-def",          1,  0, 0, (0x1357, 0x2468, 0x9BDF), 1,  1,   0, 0))
    add(("min1word-sbm",          1,  0, 1, (0x1357, 0x2468, 0x9BDF), 1,  1,   0, 0))
    add(("two-word-def",          2,  0, 0, (0xFFFF, 0xFFFF, 0xFFFF), 2,  1,   0, 0))
    add(("two-word-sbm",          2,  0, 1, (0xFFFF, 0xFFFF, 0xFFFF), 2,  1,   0, 0))
    add(("zerokeys-def",         64,  0, 0, (0x0000, 0x0000, 0x0000), 0, 64,   0, 0))
    add(("zerokeys-sbm",         64,  0, 1, (0x0000, 0x0000, 0x0000), 0, 64,   0, 0))
    add(("oneskeys-def",         64,  0, 0, (0xFFFF, 0xFFFF, 0xFFFF), 1,  3,   0, 0))
    add(("oneskeys-sbm",         64,  0, 1, (0xFFFF, 0xFFFF, 0xFFFF), 1,  3,   0, 0))
    add(("k1msb-set-def",       128,  0, 0, (0x8000, 0x0001, 0x00FF), 2,  7,   0, 0))
    add(("k1msb-clr-def",       128,  0, 0, (0x4000, 0x8001, 0xFF00), 2,  7,   0, 0))
    add(("k3wrap-def",          600,  0, 0, (0x1234, 0x5678, 0xFF00), 3, 16,   0, 0))
    add(("k3wrap2-def",         600,  0, 0, (0xABCD, 0x1111, 0xFFFF), 4, 16,   0, 0))
    add(("randkeys-def-a",      333, 11, 0, RAND_KEYS,                2,  5,   0, 0))
    add(("randkeys-def-b",      777, 64, 0, RAND_KEYS,                4, 13,   0, 0))
    add(("randkeys-sbm-a",      333, 11, 1, RAND_KEYS,                2,  5,   0, 0))
    add(("randkeys-sbm-b",      777, 64, 1, RAND_KEYS,                4, 13,   0, 0))
    add(("offset-window-def",   256, 512, 0, RAND_KEYS,               1,  2,   0, 0))
    add(("offset-window-sbm",   256, 512, 1, RAND_KEYS,               1,  2,   0, 0))
    add(("nearstall-def",        96,  0, 0, RAND_KEYS,                5,  1,   0, 0))
    add(("nearstall-sbm",        96,  0, 1, RAND_KEYS,                5,  1,   0, 0))
    add(("freeflow-def",       2048,  0, 0, RAND_KEYS,                0, 4096, 0, 0))
    add(("freeflow-sbm",       2048,  0, 1, RAND_KEYS,                0, 4096, 0, 0))
    add(("big-def",            4000,  0, 0, RAND_KEYS,                3, 512,  0, 0))
    add(("big-sbm",            4000,  0, 1, RAND_KEYS,                4, 512,  0, 0))
    add(("reload-mid-def",      400,  0, 0, RAND_KEYS,                2, 17, 301, 0))
    add(("reload-mid-sbm",      400,  0, 1, RAND_KEYS,                2, 17, 301, 0))
    add(("reload-extend-def",   200, 32, 0, RAND_KEYS,                4,  9, 150, 512))
    add(("reload-extend-sbm",   200, 32, 1, RAND_KEYS,                4,  9, 150, 512))
    # odd-length window: exercises the (cur+2)>=end boundary off a word grid and
    # the backing's "address bit 0 is ignored" decode.
    add(("odd-window-def",       48,  4, 0, RAND_KEYS,                2,  6,   0, 0))
    add(("odd-window-sbm",       48,  4, 1, RAND_KEYS,                2,  6,   0, 0))
    return C


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build_rtl():
    out = os.path.join(BUILD, "spike_rtl.vvp")
    cmd = ["iverilog", "-g2005-sv", "-Wall", "-o", out,
           os.path.join(RTL, "k573_mp3stream.v"),
           os.path.join(RTL, "k573_mp3dec.v"),
           os.path.join(HERE, "tb_spike_descramble.v")]
    r = sh(cmd)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("iverilog failed")
    if r.stderr.strip():
        print("  [iverilog warnings]\n" + r.stderr.rstrip())
    return out


def build_c(mutations):
    out = os.path.join(BUILD, "spike_c")
    cmd = ["cc", "-O2", "-std=c99", "-Wall", "-Wextra", "-o", out,
           os.path.join(HERE, "spike_main.c"),
           os.path.join(HERE, "s573_descramble.c")]
    for m in mutations:
        cmd.insert(1, "-DS573_MUT_" + m)
    r = sh(cmd)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("cc failed")
    if r.stderr.strip():
        print("  [cc warnings]\n" + r.stderr.rstrip())
    return out


def gen_image(seed, path_hex, path_bin):
    """Pseudo-random DRAM contents, one image in two encodings."""
    rng = random.Random(seed)
    words = [rng.getrandbits(16) for _ in range(MEMW)]
    with open(path_hex, "w") as f:
        f.write("".join("%04x\n" % w for w in words))
    with open(path_bin, "wb") as f:
        f.write(b"".join(w.to_bytes(2, "little") for w in words))
    return words


def read_meta(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            k, _, v = line.strip().partition(" ")
            if k:
                d[k] = int(v)
    return d


def run_case(idx, case, vvp, cexe, verbose):
    (name, words, sw, sbm, keys, bp, chunk, reload_at, e2words) = case
    seed = 1000 + idx

    hexp = os.path.join(BUILD, "c%02d.hex" % idx)
    binp = os.path.join(BUILD, "c%02d.bin" % idx)
    rtlp = os.path.join(BUILD, "c%02d.rtl.bin" % idx)
    cp = os.path.join(BUILD, "c%02d.c.bin" % idx)
    metap = os.path.join(BUILD, "c%02d.meta" % idx)
    gen_image(seed, hexp, binp)

    if keys is RAND_KEYS:
        krng = random.Random(seed ^ 0x5A5A)
        k1, k2, k3 = (krng.getrandbits(16) for _ in range(3))
    else:
        k1, k2, k3 = keys

    start = sw * 2
    end = start + words * 2
    if name.startswith("odd-window"):
        end -= 1                       # window length not a whole number of words
    end2 = (start + e2words * 2) if e2words else 0

    for p in (rtlp, cp, metap):
        if os.path.exists(p):
            os.remove(p)

    t0 = time.time()
    r = sh(["vvp", vvp,
            "+hex=%s" % hexp, "+out=%s" % rtlp, "+meta=%s" % metap,
            "+start=%d" % start, "+end=%d" % end, "+end2=%d" % end2,
            "+key1=%d" % k1, "+key2=%d" % k2, "+key3=%d" % k3,
            "+ddrsbm=%d" % sbm, "+bp=%d" % bp, "+seed=%d" % seed,
            "+reload_at=%d" % reload_at])
    t_rtl = time.time() - t0
    if r.returncode != 0:
        return dict(name=name, ok=False, why="vvp rc=%d\n%s" % (r.returncode, r.stdout + r.stderr))
    meta = read_meta(metap)
    if meta.get("timeout"):
        return dict(name=name, ok=False, why="RTL testbench TIMED OUT: " + r.stdout.strip())

    cut = meta.get("cut", 0)
    if reload_at:
        # the epoch boundary must be where we asked (the sink was quiesced there);
        # anything else means the reload landed somewhere uncontrolled.
        if not (reload_at <= cut <= reload_at + 2):
            return dict(name=name, ok=False,
                        why="reload epoch drifted: asked %d, measured %d" % (reload_at, cut))

    cargs = [cexe, "--bin", binp, "--out", cp,
             "--start", str(start), "--end", str(end),
             "--key1", str(k1), "--key2", str(k2), "--key3", str(k3),
             "--ddrsbm", str(sbm), "--chunk", str(chunk)]
    if reload_at:
        cargs += ["--cut", str(cut)]
        if end2:
            cargs += ["--end2", str(end2)]
    rc = sh(cargs)
    if rc.returncode != 0:
        return dict(name=name, ok=False, why="C rc=%d\n%s" % (rc.returncode, rc.stdout + rc.stderr))

    a = open(rtlp, "rb").read()
    b = open(cp, "rb").read()

    # expected length, computed independently of both sides
    def slen(s, e):
        if e <= s:
            return 0
        return ((e - s + 1) // 2) * 2 - 1
    exp = slen(start, end)
    if reload_at:
        exp = cut + slen(start, end2 if end2 else end)

    div = ""
    ok = True
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            div = ("byte %d: RTL=0x%02x C=0x%02x" % (i, a[i], b[i]))
            ok = False
            break
    if ok and len(a) != len(b):
        div = "length: RTL=%d C=%d (first %d bytes identical)" % (len(a), len(b), n)
        ok = False
    if ok and len(a) != exp:
        div = "length %d != analytic expectation %d" % (len(a), exp)
        ok = False

    return dict(name=name, ok=ok, why=div, nbytes=len(a), cbytes=len(b),
                exp=exp, cut=cut, t=t_rtl, bp=bp, sbm=sbm, words=words,
                keys=(k1, k2, k3), chunk=chunk)


def run_invariance(vvp, cexe):
    """One window + one key set, streamed under every back-pressure pattern and two
    different DRAM-latency seeds. All runs must produce the IDENTICAL byte file --
    and it must equal the C reference. This is the 'pacing cannot change the bytes'
    half of the claim, tested directly instead of inferred."""
    words, sw, sbm = 300, 7, 0
    k1, k2, k3 = 0x4A3B, 0xD10E, 0x00F7
    start, end = sw * 2, sw * 2 + words * 2
    hexp = os.path.join(BUILD, "inv.hex")
    binp = os.path.join(BUILD, "inv.bin")
    gen_image(4242, hexp, binp)

    cp = os.path.join(BUILD, "inv.c.bin")
    rc = sh([cexe, "--bin", binp, "--out", cp, "--start", str(start), "--end", str(end),
             "--key1", str(k1), "--key2", str(k2), "--key3", str(k3),
             "--ddrsbm", str(sbm), "--chunk", "1"])
    if rc.returncode != 0:
        return False, "C rc=%d" % rc.returncode, 0
    ref = open(cp, "rb").read()

    runs = []
    for bp in range(6):
        for lseed in (7, 99):
            outp = os.path.join(BUILD, "inv_bp%d_s%d.bin" % (bp, lseed))
            r = sh(["vvp", vvp, "+hex=%s" % hexp, "+out=%s" % outp,
                    "+start=%d" % start, "+end=%d" % end,
                    "+key1=%d" % k1, "+key2=%d" % k2, "+key3=%d" % k3,
                    "+ddrsbm=%d" % sbm, "+bp=%d" % bp, "+seed=%d" % lseed])
            if r.returncode != 0:
                return False, "vvp bp=%d rc=%d" % (bp, r.returncode), len(runs)
            runs.append(("bp=%d seed=%d" % (bp, lseed), open(outp, "rb").read()))

    for tag, data in runs:
        if data != ref:
            n = min(len(data), len(ref))
            for i in range(n):
                if data[i] != ref[i]:
                    return False, "%s diverges at byte %d (RTL=0x%02x C=0x%02x)" % (tag, i, data[i], ref[i]), len(runs)
            return False, "%s length %d != C %d" % (tag, len(data), len(ref)), len(runs)
    return True, "%d runs x %d bytes all identical" % (len(runs), len(ref)), len(runs) * len(ref)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", type=int, default=None)
    ap.add_argument("--mutate", default="", help="comma list: NO_KEY3_INC,LOW_FIRST,NO_2N1")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--mib", type=int, default=16)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    os.makedirs(BUILD, exist_ok=True)
    if not shutil.which("iverilog") or not shutil.which("vvp"):
        sys.exit("iverilog/vvp not on PATH")

    muts = [m.strip() for m in args.mutate.split(",") if m.strip()]
    if muts:
        print("*** NEGATIVE CONTROL: C reference built with " +
              ", ".join("S573_MUT_" + m for m in muts) + " ***")

    cexe = build_c(muts)

    if args.bench:
        for sbm in (0, 1):
            r = sh([cexe, "--bench", "--mib", str(args.mib), "--ddrsbm", str(sbm)])
            print(r.stdout.strip() or r.stderr.strip())
        return 0

    vvp = build_rtl()
    cases = case_list()
    sel = range(len(cases)) if args.case is None else [args.case]

    npass = nfail = 0
    total_bytes = 0
    first_div = ""
    t0 = time.time()
    for i in sel:
        res = run_case(i, cases[i], vvp, cexe, args.verbose)
        if res["ok"]:
            npass += 1
            total_bytes += res["nbytes"]
            print("  PASS  %-20s %6d bytes  bp=%d sbm=%d  (%.1fs)"
                  % (res["name"], res["nbytes"], res["bp"], res["sbm"], res["t"]))
        else:
            nfail += 1
            print("  FAIL  %-20s  %s" % (res["name"], res["why"]))
            if not first_div:
                first_div = "%s: %s" % (res["name"], res["why"])

    if args.case is None:
        ok, why, nb = run_invariance(vvp, cexe)
        if ok:
            npass += 1
            total_bytes += nb
            print("  PASS  %-20s %s" % ("bp-invariance", why))
        else:
            nfail += 1
            print("  FAIL  %-20s %s" % ("bp-invariance", why))
            if not first_div:
                first_div = "bp-invariance: " + why

    print("-" * 60)
    print("cases: %d/%d passed   bytes compared: %d   wall: %.1fs"
          % (npass, npass + nfail, total_bytes, time.time() - t0))
    if nfail == 0:
        print("RESULT: PASS (byte-exact, %d cases)" % npass)
        return 0
    print("RESULT: FAIL (%d cases)  first divergence: %s" % (nfail, first_div))
    return 1


if __name__ == "__main__":
    sys.exit(main())
