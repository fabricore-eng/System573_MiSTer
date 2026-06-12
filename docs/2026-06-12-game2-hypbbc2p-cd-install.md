# Game #2 — hypbbc2p (Hyper Bishi Bashi Champ 2P): first CD-install title boots on hardware

**2026-06-12. HW-confirmed on the de10.** The System 573 core now boots and runs its
first **CD-install** title end-to-end on real hardware — validating the whole
security-cassette + CD/ATAPI install path that gates a large slice of the library.

## What works (the full chain, on silicon)

1. **Security cassette** — the authentic `gx908ja.u1` (X76F100) is loaded via ioctl
   index 4 and **clears the on-screen `-11N` security error**.
2. **CD install** — the BIOS CD/ATAPI installer reads the disc (`hypbbc2p.chd`) and
   **copies it into the onboard 16 MB NOR flash** (writable-flash + DMA-ch5 path). This
   is the **first hardware run of the CD path** — previously sim-only.
3. **ROM check** — the installed game's own ROM self-test reads **all-OK** (the same
   gate that stalled game #1 as the green-0s wall before the bank-decode fix).
4. **Game runs** — the attract/demo loop (`説明中`) plays: title, mascot, GAME OVER, the
   RGB Bishi Bashi buttons, CREDIT.

## The `-11N` root cause (and the wrong turns it cost)

`-11N "SECURITY-CASSETTE ERROR"` is the **573 BIOS *boot-time* cassette SIGNATURE check**
— it runs early in BIOS init (PCs ~0x80037xxx–0x800388xx), *before* the CD installer or
the game's own in-app check. It reads cassette blocks 0,0,1,2 and verifies an authentic
signature in **block 1: `data[8:15] = 81 00 29 00 00 18 eb 52`**. That signature is
authentic-dump data — **not derivable from game plaintext** — so the **real `gx908ja.u1`
is required** (the MAME-`BAD_DUMP`, crc `8900eaff`, is functionally complete and works).

This was diagnosed the hard way. Earlier in the campaign we concluded (wrongly) that:
- "the real dump is never needed / the cassette is fully synthesizable" — **WRONG**; the
  synth `.u1` (`tools/gen_seccart_u1.py`) only satisfies the *in-game* check (fn
  `0x80036ec4`, which runs from the CD-loaded program and is never reached because the
  BIOS boot check fails first).
- "`-11N` is our `x76f100.v` read path / a byte-pointer / read-after-password bug" —
  **WRONG**; the read path matches MAME bit-exact. The `bytec`-8 change (b2732db) and the
  block-0 register-shadow "fix" (d41e8c4) were wrong turns; the shadow was reverted
  (04ebd10) — game #2 runs without it, so the M10K read was fine all along.

The decisive tell, present the whole time: **MAME (the reference oracle) also failed the
check with our synthetic cassette** — i.e. it was a DATA problem, not the core. That
lesson is now institutionalized as **Gate −1** in the hub `CORE_DEV_PLAYBOOK.md` §I.

## How it was verified (objective, not vision)

- **Boot-stage progression**: three game-named captures advancing 1.9 KB → 29 KB → 38 KB,
  each ~88% different — a live, advancing boot, not a single frozen/lucky frame (the
  failure mode of the old green-0s / t24 head-fakes).
- The final frame is an **unambiguous** hypbbc2p attract screen (`local/realcart_test/`).
- Sanity: that game frame is 88.8% different from the earlier noise/wedge frame.

Caveats (honest):
- The **de10 HDMI screenshot capture glitches to noise** on the 573's video mode (odd
  529px width) when the core is loaded via a confounded `killall`+relaunch; a clean OSD
  load captures fine. Prefer the SuperStation capture or a VRAM dump for de10 verdicts.
- **No clean same-scene MAME frame-diff yet** — the existing `mame_ref_hbb2p` frames are a
  different boot moment (SSIM ~0.07 is a scene mismatch, not a failure). A same-scene
  reference capture is a follow-up for the record.

## Requirement for users

hypbbc2p needs the authentic **`gx908ja.u1`** staged at
`games/System573/hypbbc2p.u1` (a user-supplied artifact, like a BIOS). The synthesized
`.u1` from `tools/gen_seccart_u1.py` is for analysis/unit-tests only; it hits `-11N`.

## Remaining for hypbbc2p

- Confirm **gameplay** (button input) + **audio** + a **graphics garble** check (as done
  for game #1).
- **Persistence**: the install currently lives in SDRAM-backed flash; a reload re-blanks
  it (the `.mgl` loads a blank flash each launch). Needs a flash-persistence/savestate
  path to survive a power cycle.
- A same-scene MAME frame-diff for the proof record.

## Next library targets

We hold real cassettes for **pnchmn2** (X76F041) and **gtrfrk5m** (ZS01); they're the
next cassette-game candidates (each also needs its CD and, for the BEMANI/music titles,
the Digital-I/O + MP3 board — the deepest remaining stack). See the library roadmap.
