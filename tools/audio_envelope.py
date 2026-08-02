#!/usr/bin/env python3
"""Per-second loudness envelope of a WAV capture -- "does the audio ever STOP?"

Built for the 573 MP3 question. The reported symptom is that music keeps playing
when it should stop. A single RMS number over a whole capture cannot answer that:
a track that correctly stops half the time and one that never stops can average to
the same value. What distinguishes them is the SHAPE over time -- specifically
whether there are silent stretches at all, and how long the longest one is.

ddrsbm's attract loop alternates roughly 23.5 s of music with a gap (measured in
the MAME oracle). So a healthy core shows a clear on/off pattern; a core that
never stops shows a continuous floor well above silence.

Usage: tools/audio_envelope.py capture.wav [--window 1.0] [--silence -45]
"""
import array
import sys
import wave

def db(rms, full=32768.0):
    if rms <= 0:
        return -120.0
    import math
    return 20.0 * math.log10(rms / full)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "capture.wav"
    win = 1.0
    silence_db = -45.0
    if "--window" in sys.argv:
        win = float(sys.argv[sys.argv.index("--window") + 1])
    if "--silence" in sys.argv:
        silence_db = float(sys.argv[sys.argv.index("--silence") + 1])

    w = wave.open(path, "rb")
    ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    if sw != 2:
        print(f"expected 16-bit, got {sw*8}-bit", file=sys.stderr)
        return 1
    print(f"# {path}: {ch}ch {sr}Hz {n/sr:.1f}s   window={win}s  silence<{silence_db}dBFS")

    per = int(sr * win)
    rows = []
    while True:
        raw = w.readframes(per)
        if not raw:
            break
        a = array.array("h")
        a.frombytes(raw)
        if not len(a):
            break
        acc = 0
        for v in a:
            acc += v * v
        rows.append(db((acc / len(a)) ** 0.5))
    w.close()

    # envelope
    for i, d in enumerate(rows):
        t = i * win
        bar = "#" * max(0, int((d + 80) / 3))
        mark = "  <-- SILENT" if d < silence_db else ""
        print(f"{t:7.1f}s  {d:7.1f} dBFS  {bar}{mark}")

    # the actual verdict
    sil = [d < silence_db for d in rows]
    total = len(rows)
    nsil = sum(sil)

    def longest(pred):
        best = cur = 0
        for p in pred:
            cur = cur + 1 if p else 0
            best = max(best, cur)
        return best

    lsil = longest(sil)
    lloud = longest([not s for s in sil])
    print()
    print(f"-- {total} windows: {nsil} silent ({100.0*nsil/max(total,1):.0f}%), "
          f"{total-nsil} loud")
    print(f"-- longest SILENT run: {lsil*win:.0f}s     longest CONTINUOUS-AUDIO run: {lloud*win:.0f}s")

    # ORDER MATTERS. The first version fell through to the "alternating" branch on an
    # ALL-SILENT capture and printed "audio starts and stops repeatedly" for 900
    # windows of digital zero -- a confident verdict on the one input that carries no
    # information at all. Handle the degenerate cases FIRST and refuse to conclude.
    floor = max(rows) if rows else -120.0
    if total == 0:
        print("-- NO DATA: capture contained no samples.")
    elif nsil == total:
        print("-- NO CONCLUSION: every window is silent. This says NOTHING about whether "
              "the core stops audio correctly.")
        if floor <= -119.0:
            print("--   Peak window is digital ZERO (<= -119 dBFS): the capture path itself "
                  "is a prime suspect, not just a quiet game.")
        print("--   Before reading anything into this: prove the subject was MAKING SOUND "
              "during the capture (screenshot the game past its boot/loading screens, and "
              "get a positive control from a source known to be audible).")
    elif nsil == 0:
        print("-- VERDICT: audio NEVER drops to silence in this capture.")
    elif lloud * win > 90:
        print(f"-- VERDICT: audio does stop, but ran {lloud*win:.0f}s continuously at least once.")
    else:
        print("-- VERDICT: audio starts and stops repeatedly -- consistent with the game "
              "controlling playback.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
