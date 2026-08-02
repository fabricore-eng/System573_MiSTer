#!/usr/bin/env python3
"""Summarise a k573dio oracle log (tools/mame_dio_regs.lua) into an audio timeline.

The raw log mixes boot traffic, network polling, lamp writes and DRAM bursts. What
matters for the MP3 investigation is a short list of events:

  * fpga_ctrl (0xae) writes  -- MP3_ENABLE / STREAMING_ENABLE / frame-counter-enable
  * mpeg_ctrl (0xaa) writes
  * mp3_start / mp3_end setup (0xa0/0xa2/0xa4/0xa6)
  * MAS3507D output-gain writes over I2C -- including MUTE (all-zero gains)

The gain decode is the point. MAME's mas3507d maps bank-1 addresses 0x7f8..0x7fb to the
output gain matrix (left->left, left->right, right->left, right->right) and treats a value
of 0 as a mute (`if(val == 0) return 0`). The 20-bit word packing, confirmed against
MAME's i2c_device_got_byte and cross-checked against this lane's own July transaction
list (docs/2026-07-01-ddrsbm-dio-i2c-transactions.md, T1 OutputConfig = 0x00030), is:

    val = ((b3 & 0x0f) << 16) | (b0 << 8) | b1        # b2 unused

Usage:  tools/dio_log_summary.py local/dio_regs.log [--all]
"""
import re
import sys

I2C = re.compile(r"^\s*([\d.]+)\s+pc=([0-9a-f]+)\s+I2C#(\d+)\s+(\S+)\s+addr=\S+\s+(\S+)\s+\[(\d+) bytes: ([0-9a-f ]+)\]")
REG = re.compile(r"^\s*([\d.]+)\s+pc=([0-9a-f]+)\s+off=([0-9a-f]{2})\s+data=([0-9a-f]{4})")
REP = re.compile(r"repeated x(\d+)")

AUDIO_REGS = {0xa0: "mp3_start hi", 0xa2: "mp3_start lo",
              0xa4: "mp3_end hi",   0xa6: "mp3_end lo",
              0xa8: "crypto_key1",  0xea: "crypto_key2", 0xec: "crypto_key3",
              0xaa: "mpeg_ctrl",    0xae: "fpga_ctrl"}

GAIN_NAMES = ["L->L", "L->R", "R->L", "R->R"]


def word(b):
    """4 payload bytes -> the 20-bit value MAS3507D actually receives."""
    return ((b[3] & 0x0F) << 16) | (b[0] << 8) | b[1]


def decode_i2c(hexstr, ctrl=None):
    """Return a human string for a MAS3507D transaction, or None if uninteresting.

    `ctrl` is the last fpga_ctrl value seen. It is the whole discriminator for the
    open bug: a MUTE issued while STREAMING_ENABLE is still SET means the game is
    silencing playback through the decoder chip -- a path rtl/mas3507d_i2c.v ACKs
    and DROPS, so we would keep playing. A mute *after* the enables already cleared
    is just belt-and-braces on a stop we already handled.
    """
    b = [int(x, 16) for x in hexstr.split()]
    if len(b) >= 2 and b[0] == 0x3A and b[1] == 0x69:
        return None                      # frame-counter poll: noise
    if len(b) >= 1 and (b[0] & 0xFE) == 0x3A and b[0] & 1:
        return None                      # read side of the poll
    if len(b) >= 8 and b[0] == 0x3A and b[1] == 0x68:
        cmd, nwords = b[2], (b[4] << 8) | b[5]
        adr = (b[6] << 8) | b[7]
        payload = b[8:]
        vals = [word(payload[i * 4:i * 4 + 4])
                for i in range(min(nwords, len(payload) // 4))]
        bank = 1 if cmd == 0xB0 else 0
        if bank == 1 and adr == 0x7F8 and vals:
            muted = all(v == 0 for v in vals)
            body = "  ".join(f"{GAIN_NAMES[i]}={v:#07x}" for i, v in enumerate(vals))
            tag = ""
            if muted:
                tag = "  <<< MUTE (all gains 0)"
                if ctrl is not None:
                    st, en = (ctrl >> 14) & 1, (ctrl >> 13) & 1
                    if st and en:
                        tag += ("  *** WHILE STILL STREAMING -- this is the path we DROP ***")
                    else:
                        tag += "  (enables already clear; stop already handled)"
            return f"GAIN  {body}{tag}"
        if bank == 0 and adr == 0x32F:
            return f"OutputConfig = {vals[0]:#07x}" if vals else "OutputConfig"
        return f"WRITE_MEM bank{bank} adr={adr:#05x} words={vals}"
    if len(b) == 4 and b[0] == 0x3A and b[1] == 0x68:
        return f"RUN {(b[2] << 8) | b[3]:#06x}"
    return f"raw [{hexstr}]"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "local/dio_regs.log"
    show_all = "--all" in sys.argv
    last_ctrl = None
    n = 0
    with open(path, errors="replace") as fh:
        for line in fh:
            m = I2C.match(line)
            if m:
                t, pc, _, _, _, _, hexstr = m.groups()
                s = decode_i2c(hexstr, last_ctrl)
                if s:
                    print(f"{float(t):9.3f}  pc={pc}  I2C  {s}")
                    n += 1
                continue
            m = REG.match(line)
            if m:
                t, pc, off, data = m.groups()
                off, data = int(off, 16), int(data, 16)
                if off not in AUDIO_REGS and not show_all:
                    continue
                extra = ""
                if off == 0xAE:
                    # Bit assignment is MAME k573fpga.h: MP3_ENABLE=13,
                    # STREAMING_ENABLE=14, FRAME_COUNTER_ENABLE=15. Matches our
                    # rtl/k573_mp3stream.v:140 stream_en = fpga_ctrl[13] & [14].
                    fce, st, en = (data >> 15) & 1, (data >> 14) & 1, (data >> 13) & 1
                    playing = st and en
                    extra = f"   fce={fce} STREAM_EN={st} MP3_EN={en}"
                    if last_ctrl is not None:
                        pst, pen = (last_ctrl >> 14) & 1, (last_ctrl >> 13) & 1
                        if en != pen:
                            extra += f"   <<< MP3_ENABLE {pen}->{en}"
                        if st != pst:
                            extra += f"   <<< STREAMING {pst}->{st}"
                        if (pst and pen) and not playing:
                            extra += "   *** PLAYBACK STOPS ***"
                        elif playing and not (pst and pen):
                            extra += "   *** PLAYBACK STARTS ***"
                    last_ctrl = data
                print(f"{float(t):9.3f}  pc={pc}  {AUDIO_REGS[off]:<13} {data:#06x}{extra}")
                n += 1
                continue
            if show_all and REP.search(line):
                print(line.rstrip())
    print(f"\n-- {n} audio-relevant events --")


if __name__ == "__main__":
    main()
