# ROOT CAUSE — ddrsbm never restored its flash install (and never had)

**Status: FIXED and A/B-verified on de10, 2026-07-31. No FPGA build was needed.**
ddrsbm now cold-boots from the golden `.sav`: POST → `MEMORY CHECK 22H OK / 22J OK` →
`DATA LOADING` → Dancemania attract.

The blocker in `docs/handoffs/573.md` — "golden `.sav` present, checksum-correct, `.s4`
rewritten, boot device Flash, Solo strap set, and it *still* comes up blank" — was two
defects stacked, neither of them in the restore engine. Everything the previous session
verified really was correct; the fault was in **when** the save slot gets mounted.

## The two defects

### 1. Main parses at most SIX .mgl items and silently drops the rest

`Main_MiSTer/support/arcade/mra_loader.h`:

```c
struct mgl_struct { int count; int current; mgl_item_struct item[6]; ... };
```

`mra_loader.cpp:1344` — `else if (inside_mgl && mgl.count < (int)(sizeof(mgl.item)/sizeof(mgl.item[0])))`.
Past six, the item is not parsed, not warned about, and not logged (the `printf` lives
*inside* the accepted branch).

`ddrsbm_console.mgl` carried **eight**: `f0` bios, `f2` blank flash, `f3` nvram, `f4` u1,
`f5` u6, `s1` chd, **`s4` sav**, **reset**. Items 7 and 8 — the slot-4 save mount and the
reset — were **never parsed**.

That is the true explanation of the 2026-07-02 note *"the .mgl's s4 entry did NOT rebind
even though ddrsbm.sav exists"*. It was never a rebinding quirk. The line was never read.

**This is also why only ddrsbm was affected.** `hypbbc2p` and `konam80s` have seven items,
so their `s4` sits at position **six** and survives; only their trailing reset is dropped.
ddrsbm has one extra file item (`f5`, the DS2401 cart serial `.u6`) which pushes `s4` to
position seven. One item of drift decided it.

### 2. The mount that DOES happen fires at core init — before the .mgl's blank flash

`parse_config()` (`user_io.cpp:966-1000`) walks CONF_STR and, for every `SC<n>` entry,
loads `config/<core>.s<n>` and mounts it immediately. `user_io_init()` calls
`parse_config()` at **:1483**, `mgl_parse()` at **:1508** — and the mgl's *first delayed
item* runs later still, from the menu state machine. So for `SC4,SAV,Flash Save;`:

1. **t≈0, core init** — slot 4 mounts from `System573.s4`. `img_mounted[4]` pulses,
   `img_size` = 16 MB. In `emu.sv`, `flash_load_arm` is true *immediately* — there is no
   `flash_download` yet — so the 16 MB restore starts.
2. **t≈2 s** — the .mgl reaches `f2` and downloads `flash16m_blank.bin`. `ch3_dl` outranks
   the saver's ch3 drain (`emu.sv:2414-2419`), and the blank is written over the whole
   `FLASH_START` window — on top of the restore.
3. `flash_load_taken` (`emu.sv:1829`) had already latched, so the load never re-armed.
4. Flash ends up blank → `GQ894 JAA / DO YOU WANT TO INITIALIZE FLASH-ROM?`.

The RISK-R1 guard in `emu.sv` (`~flash_download && ~download_settle_hold`) was written for
exactly this hazard but only blocks the load from *arming during* a download. It cannot help
when the mount legitimately arrives first and the download comes second — which, given
defect 1, is the only ordering ddrsbm ever saw.

**It was never a regression.** ddrsbm has never cold-boot-restored. The 2026-07-02 MEMORY
CHECK was reached through the CD **installer** (which programs the live flash and soft-reboots),
not through a restore; the doc's "a cold boot goes straight to POST/memcheck" was a
projection, never an observation.

## The measurement that broke it open

Before touching anything, ask the HPS whether Main is even reading the file
(`/proc/<MiSTer pid>/io` + `fdinfo`, no core change, no build):

```
5 -> /media/fat/saves/System573/ddrsbm.sav  pos=16777216
rchar: 39126111   wchar: 110643   write_bytes: 0
```

The whole 16 MB **was** streamed in, and `rchar` ≈ 16 MB blank + 16 MB sav + bios + CD. That
killed every "the mount/`.s4`/SD protocol is broken" hypothesis in one shot and moved the
search downstream, to *ordering*. `rchar` then acts as a free discriminator for the rest of
the work: **22 MB** = restore only, **39 MB** = blank + restore, **41 MB** = two restores.

## A/B on de10 (same core `abfe073a`, same golden `.sav` `82243fe3`, de-confounded each time)

| .mgl | items | index-2 blank | rchar | result |
|---|---|---|---|---|
| original | 8 (s4 + reset dropped) | yes | 39 MB | **INITIALIZE FLASH-ROM?** (human-observed on the monitor) |
| test, no blank / no s4 | 6 | no | 22 MB | **MEMORY CHECK 22H OK** → attract (Dancemania) |
| **shipped, no blank, s4 kept** | 6 | no | 41 MB | **MEMORY CHECK 22H/22J OK → DATA LOADING No.17** |

`.sav` md5 unchanged (`82243fe3121cb23e97fec37b9ed0b8ef`) across all three.

## The fixes

**Zero-build (shipping, verified above)** — `mgl/ddrsbm_console.mgl` drops the index-2 blank
flash and the trailing reset, landing at exactly six items with the `s4` mount kept. Nothing
overwrites the restored image, and nothing is silently dropped. A first-ever boot with no
`.sav` does not need the blank: the CD installer erases to 0xFF before programming.

Side effect, expected and documented in the file: the image restores **twice** (core-init
SC4 recall + the `s4` re-arm), so the CPU is pulled back into reset ~60 s in and the boot
visibly restarts. ~60 s to the title, in exchange for a mis-ordered download never being
able to leave a half-restored image.

**Durable, rides the next build** — `rtl/emu.sv`, two lines, so ordering stops mattering:

- `if (flash_download) flash_load_taken <= 1'b0;` — an index-2 download rewrites the whole
  image, so it *invalidates* any restore that already ran; re-arm and run the load again
  once the download and settle hold clear.
- `.reset(RESET | status[0] | flash_download)` on `u_flash_saver` — aborts a load that is
  in flight when a download starts, so it restarts from block 0 instead of finishing with a
  mix of pre- and post-blank words. A `flash_download` only happens at core load, never
  during gameplay, so it can never interrupt a SAVE.

With that on silicon the blank may be restored to the .mgl if a deterministic first-boot
state is ever wanted — but it must stay within six items (drop the reset, which is already
being dropped today).

Suite still 47/47 (`make -C sim` → `ALL TESTS PASSED`). The emu-level ordering logic is not
covered by the iverilog suite — no TB elaborates `emu.sv` — so its evidence is the hardware
A/B above.

## Recipe

`local/tracedig/ddrsbm_noblank_restore.sh` — de-confounded reboot → MENU → `.s4` rewrite +
straps → one `load_core` → frames → the HPS-side `rchar`/`pos` readout. Its header carries
this root cause.

## Carry forward

- **Six items. Every .mgl in this repo, forever.** Over-cap items vanish silently. Audit:
  `for f in mgl/*.mgl; do echo "$f $(grep -c '^  <file \|^  <reset' $f)"; done`.
  `hypbbc2p_console.mgl` and `konam80s_console.mgl` are at seven — their trailing reset is
  being dropped today. Harmless right now; it will not stay harmless if either grows an item.
- **CONF_STR `SC<n>` slots mount at core init, before any .mgl item.** Any RTL that gates on
  "the download has settled" must tolerate the mount arriving *first*.
- **Ask the HPS before instrumenting the fabric.** `/proc/<pid>/io` and `fdinfo` answer
  "did Main actually read/write this image, and how far" for free, and they partition the
  hypothesis space better than any on-core probe.
- **Capture is not the instrument here.** `grab_card.sh` returned luma `0.56` — a dead,
  byte-identical frame — for the entire failing run *and* for the first 120 s of the passing
  one. The human looking at the monitor supplied the control result. Multi-frame agreement
  distinguishes "dead capture" from "static screen" only when the capture is alive at all;
  luma 0.56 with 0.0 % pairwise difference means NO MEASUREMENT.
