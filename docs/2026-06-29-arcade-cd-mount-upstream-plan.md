# Plan — CD-mount-in-arcade as an upstream MiSTer feature (2026-06-29)

**Session type:** planning / research. **No code changed.** This doc + a memory exist so the
decision and its grounding survive a context reset.

One-liner: the 573 is an arcade board, but MiSTer's `_Arcade`/`.mra` path can't mount a live CD.
We will keep shipping `.mgl`-under-Console as the always-works default, and pursue CD-mount-in-
arcade as a **generic upstream feature contributed to `Main_MiSTer`** — sequenced *after* the core
proves out on a real library. There is **no existing PR to adopt**, so we build it.

---

## The decision (recap of how we got here)

- The "arcade can't mount a CD" restriction is **not in anything we vendor or compile.** Our
  `sys/` is the FPGA framework only; the only `unsafe` strings in our HDL are the unrelated PSX
  *consumer* emulator-option warnings (`rtl/emu.sv:485/543`). Our CD mount already works on stock
  firmware via the **S1 slot on the console/`.mgl` path** (`rtl/emu.sv:384`, and the comment at
  `:390`: "mount the CD via the S1 slot, no arcade 'unsafe' guard").
- The restriction lives in the **HPS-side `Main_MiSTer` firmware** that every MiSTer runs and that
  drives *all* cores. So "extend MiSTer to mount CDs in arcade mode" = a **firmware change**, not a
  core change.
- That firmware change is the **one** thing that hard-requires MiSTer adoption (or an unviable
  forked firmware that breaks every other core). The "no guarantee of adoption" worry therefore
  argues *for* staying on `.mgl` as the default (works on stock firmware, self-distributable today)
  and treating arcade-CD as upside, not a dependency.
- The correct version of the idea: contribute the feature **upstream**, as part of an adoption
  push, *after* the core is worth adopting. Once merged, it ships to every MiSTer via the standard
  updater — zero fork, zero distribution problem.

## Adopt-or-build verdict: **BUILD** (no existing effort)

`gh search` over `MiSTer-devel/Main_MiSTer` (verified working via a sanity query) found **no open
or merged PR/issue about mounting CDs in arcade cores.** The full set of recent arcade-feature PRs
is incremental tricks, none CD-related:
- #981 save states in arcade cores (2025)
- #969 arcade cheat support (2025)
- #691 `arcade_vertical` section
- #398 arcade ROM deinterleaver
- #148 original `/arcade` folder + MRA decoding

So there is nothing to adopt; we would author the feature. (If a PR appears later, prefer adopting
+ improving it over a fresh build.)

## Why the build is "unlock + expose," not "build a CD subsystem"

The CHD machinery in `Main_MiSTer` is **core-agnostic plumbing already shipping**, not console-
locked:
- `support/chd/mister_chd.cpp` (`mister_load_chd`) is used by `psx.cpp`, `pcecd`, `3do`, …
- **`ide.h` includes `mister_chd.h`** — the firmware's IDE/ATAPI emulation is already wired to
  CHD. (Directly relevant to the ddrsbm ATAPI work: the host-side ATAPI/CHD path exists.)
- The arcade restriction is just a flag: `is_arcade()` in `user_io.cpp` (set when the loaded file
  ends in `.mra`, per `support/arcade/mra_loader.cpp`), branched on in `menu.cpp`.

So the feature is: extend the `is_arcade()`-gated menu/IO logic to surface the CONF_STR S-slot CD
mount (and optionally add an `.mra` `<disk>`/`<cd>` XML element), reusing plumbing that already
exists. Keep it **generic** — it benefits every console-derived arcade board (Namco System 11/12 =
PS1, Sega ST-V = Saturn, Naomi = Dreamcast), which is also a far easier upstream merge than a
573-only ask.

*Not yet verified (Phase 0 work, not assumed):* the exact lines the `is_arcade()` branch disables,
and whether arcade CONF_STR even processes S-slots today.

## Plan (phased, gated)

| Phase | What | Gate |
|---|---|---|
| **0 — Recon** (cheap, anytime) | Read the `is_arcade()` branch in `menu.cpp`/`user_io.cpp`; pin exactly what's blocked. Also test whether `/dev/MiSTer_cmd` can already mount a CHD to an arcade S-slot index **with zero firmware change** — a possible quick win / fallback. | — |
| **1 — Prove the core** | ddrsbm ATAPI cleared + a handful of CD games actually booting on HW. | **"Enough games working" (Human's gate).** |
| **2 — Build** | Extend the `is_arcade()`-gated logic to expose CONF_STR S-slot CD mounts (optionally an `.mra` `<disk>`/`<cd>` element), reusing `mister_chd` + the existing IDE/ATAPI backing. Generic, not 573-specific. | After Phase 1 |
| **3 — Upstream PR** | Pitch to MiSTer-devel as a platform feature for all console-derived arcade boards. Merged → ships to all via updater. Declined → we lose nothing; `.mgl` still works. | After Phase 2 |

Net posture: `.mgl`-under-Console stays the always-works, self-distributable default for the whole
573 library (every game class, including run-from-CD). Arcade-CD-mount is a sequenced upstream
contribution, never a blocker on the roadmap.

## Sources
- MiSTer CD docs — https://mister-devel.github.io/MkDocs_MiSTer/basics/cd/
- MRA developer docs — https://mister-devel.github.io/MkDocs_MiSTer/developer/mra/
- `mra_loader.cpp` — https://github.com/MiSTer-devel/Main_MiSTer/blob/master/support/arcade/mra_loader.cpp

## See also
- `docs/2026-06-27-powyakex-menu-launch-and-packaging.md` (the packaging-model session this builds on)
- memory: `mister-arcade-cd-packaging`, `573-library-roadmap`, `ddr-bringup-plan`
