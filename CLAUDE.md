# System 573 MiSTer core — session non-negotiables

A MiSTer FPGA core (PlayStation-based Konami **System 573** arcade). It SHARES hardware, the
build box (`dell`), and a group chat with other core sessions (the DVD/MPEG2 core `dvd`, the
human-run `cockpit`). This file auto-loads every session — read it first. Full detail lives in
this project's memory (`MEMORY.md` + `memory/`) and the hub (`~/Dev/mister-dev-hub/`:
`PROTOCOL.md`, `docs/CORE_DEV_PLAYBOOK.md`, `LESSONS.md`).

## Non-negotiables (these get forgotten across context resets — don't)

1. **Build ONLY via the shared hub launcher** — never a hand-rolled `docker run`/build script
   (those are invisible to the human's dashboard AND bypass the cap-2 build semaphore, so two cores
   can thrash `dell` into swap):
   ```
   DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=~/System573_MiSTer \
     ~/Dev/mister-dev-hub/tools/dell_build.sh feat-flash-load
   ```
   It runs detached, namespaces the log (`/tmp/dellbuild-573.log`) + container (`quartus-573`),
   claims a semaphore slot, applies the psx_patches, and logs to `/tmp/mister-dell-coord.log`.

2. **Verify with a NUMBER, never vision.** A "boots / works / renders / fixed" claim needs an
   objective measurement *first* — an image diff (`~/Dev/mister-dev-hub/tools/frame_diff.py`,
   SSIM/%diff), a state byte, or a trace divergence. A screenshot read by eye is for forming
   hypotheses, never for verdicts. One un-reproduced screenshot is never evidence. (Earned the
   hard way — three false milestones this project; see `CORE_DEV_PLAYBOOK.md`.)

3. **De-confounded HW test, ALWAYS.** Before any HW capture or verdict: warm-reboot the MiSTer,
   verify `/proc/uptime` < ~60 s, then do EXACTLY ONE `load_core`. `load_core` inherits the prior
   core's stale HPS↔FPGA f2sdram bridge, and a dirty bridge mimics a total boot wedge.

4. **Git:** work on `feat-flash-load`, **never `main`**. Commit/push there.

5. **Coordination (shared `dell` + test HW).** Use the hub build/device locks. Group chat is
   `~/mister-shared/dell_coord.sh chat` — read your mentions with `chat unread 573`, post as
   `573` (wrap drafts in `chat composing 573 on`…`off` for the live typing bubble). `human`,
   `cockpit`, `dvd` are reserved keys — never post as them.

6. **Vendored `psx/` stays pristine.** Every edit to the PSX core is a numbered
   `psx_patches/NNNN-*.patch` applied by `tools/apply_psx_patches.sh` (the submodule pointer
   never moves). DEBUG probes are gated by a constant/localparam shipping OFF.

## Map
- **Test HW:** `ssh mister` (the MiSTer). **Build box:** `ssh dell`.
- **Memory:** `MEMORY.md` (index) + `memory/*.md` (per-session recall).
- **Hub (shared):** `~/Dev/mister-dev-hub/` — protocol, playbook, lessons, shared tools.
- **HW tools:** `tools/mister_*.sh` (deploy/shot/filmstrip/vram_dump), `tools/trace/`.
