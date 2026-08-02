# PLAN — k573dio MAS3507D I2C de-stub: clear the ddrsbm BOOT CHECK DIO gate (2026-07-01)

**Approved by Human 2026-07-01 (builds for THIS feature are a go).** Prereq reading:
`docs/2026-07-01-ddrsbm-bootcheck-dio-verdict.md` (the root-cause verdict this plan executes on).
Memory: `[[fabricore-573-digital-bringup]]`. Branch: `feat-digital-bringup`.

## 0. WHY (one paragraph)

ddrsbm's BOOT CHECK freeze is the main game (loaded successfully off the CD — the whole
ATAPI path works) spinning at `0x800aaf68`: it writes `0x3000` to `0x1f6400ac` (k573dio
MAS3507D I2C register; **bit13=SCL, bit12=SDA**, MAME `k573fpga.cpp` ground truth:
`mas_i2c_r = (scl_r<<13)|(sda_r<<12)`) and polls bit `0x2000` (SCL readback) forever.
`rtl/k573dio.v`'s read mux has no `0xac` case → returns 0. Fix = implement the I2C
endpoint + a minimal MAS3507D I2C slave. This is DDR-plan P3's first slice. `atapi.v`
needs NOTHING — do not touch it.

## A0. Oracle recon (build-FREE, do FIRST)

Establish exactly what the boot check does over I2C after the line-echo works, so the
slave model is right the first time:
1. **Source derivation (primary):** MAME 0.285 `src/devices/sound/mas3507d.cpp` (+ .h) —
   the i2c slave state machine: START/STOP conditions, device address byte (write `0x3a`,
   read `0x3b`), subcommand bytes, register/memory read-back paths, and WHAT the version/
   ID read returns. Also re-read `k573fpga.cpp` `mas_i2c_r/w` (already verified:
   scl<<13|sda<<12) and `mas3507d`'s `i2c_scl_r` behavior (does the model ever stretch
   SCL? expected: no — scl readback = written value).
2. **Game side (static):** disasm the caller of the poll loop in `local/ddrsbm_gwait.bin`
   (base 0x800a8000; the I2C helpers live at 0x800aae40-0x800aaf9c: line-set/poll/
   read-fns are already decoded in the verdict doc §4). Walk UP the call graph from
   `0x800aaf40` to enumerate the full I2C transaction sequence (expect: bus-idle check →
   START → addr 0x3a → MAS register ops → version/ID read → compare). capstone 5.0.7.
3. **Dynamic MAME trace (optional confirm):** Lua read/write tap on `0x1f6400a0-0x1f6400bf`
   ONLY (no RAM taps, no ATA taps — RAM-write taps crash MAME 0.285 mid-drive-check;
   a DIO-only tap set is untested but plausible-safe; if MAME dies, fall back to 1+2).
   `tools/trace/ddrsbm_desc_arm.lua` is the tap-pattern reference;
   `~/Dev/fabricore/tools/tools/mame_dell.sh System573_MiSTer ddrsbm "dumps/mame573;dumps" <lua> 20 <out>`.
Deliverable: a written transaction list "the boot check needs: <ops> → <responses>".

## A1. RTL

- `rtl/k573dio.v`:
  - write case `8'hac`: `mas_scl_o <= din[13]; mas_sda_o <= din[12];`
  - read mux `8'hac`: `dout = {2'b00, mas_scl_rb, mas_sda_rb, 12'b0};` with
    `mas_scl_rb = mas_scl_o` (no clock-stretch, per MAME) and
    `mas_sda_rb = mas_sda_o & mas_sda_slave` (open-drain wired-AND — same idiom as the
    DS2401 `ow_line` a few lines up in this file).
  - instantiate the new slave; keep everything else untouched.
- NEW `rtl/mas3507d_i2c.v`: minimal I2C slave FSM clocked on `clk` (the bit-bang is
  kHz-scale; sample scl/sda, detect START (sda↓ while scl=1) / STOP (sda↑ while scl=1),
  shift address byte, ACK `0x3a/0x3b` (drive `sda_slave=0` during the ACK bit), implement
  the register-read path A0 found (version/ID at minimum), NACK/ignore everything else
  cleanly. NO fake shortcuts that lie about protocol state
  ([[no-mask-fault-with-fake-data]] — model the real chip's protocol; unimplemented
  registers read as the real chip's default/0 with correct ACK framing, and every
  unimplemented WRITE is ACKed-and-dropped loudly behind a `DBG`-off `$display` in sim).
- `rtl/k573dio.v` reg `0xae` (fpga_ctrl) already has `fpga_ctrl_rb` (bit12 streaming) —
  verify against `k573fpga.cpp::get_fpga_ctrl` (is_streaming needs start<=cur<end);
  fix only if A0 shows the boot check reads it before passing.
- Wire into the Quartus filelist the same way k573_mp3stream.v is (check
  `Konami_System_573.qsf`/files list for how rtl/*.v are added).

## A2. Simulation (RED → GREEN, before any build)

- `sim/` has the iverilog harness (session-start hook runs `make -C sim`). Add
  `tb_dio_i2c`: drive the EXACT bit-bang sequence from A0 (as the game does: 16-bit
  writes to off 0xac, reads back) against k573dio+slave.
- RED first: the tb must FAIL against the current stub (poll never sees SCL) — proves the
  tb tests the right thing. Then GREEN with the new RTL: ACK observed, version read
  returns the A0-specified bytes, STOP resets the FSM.
- Run the whole `make -C sim` suite (no regressions in the other tbs).

## A3. Build (the approved gate)

1. Commit + push `feat-digital-bringup` FIRST (the launcher builds the ORIGIN ref).
2. `ssh dell 'cd ~/System573_MiSTer && git reset --hard'` (dirty tree aborts checkout).
3. `DELL_PROJECT=573 DELL_TARGET=Konami_System_573 DELL_REPO=System573_MiSTer \
     ~/Dev/fabricore/tools/tools/dell_build.sh feat-digital-bringup`
   (hub launcher ONLY — bare DELL_REPO name; log `/tmp/dellbuild-573.log`; it shows on
   the dashboard + takes a semaphore slot).
4. Fitter expectation: ~92% ALM baseline incl. SignalTap in the last build; this adds
   <150 ALMs, 0 DSP, 0 BRAM. Risk = fitter re-roll of the marginal f2sdram bridge
   placement ([[f2sdram-bridge-placement-marginal]]) — a "wedged boot" after this build
   is FIRST a bridge/de-confound suspect, not the new RTL.

## A4. HW verify (de-confounded; NUMBERS + LOOK)

⚠️ The new rbf has NO SignalTap (the probe lives on the dbg branch) — the steady-state
PC snapshot is NOT available on it. First-line verdicts are frame-based:
1. Deploy rbf to de10 (`tools/mister_*.sh` deploy; de10 is SHARED with dvd — devlock via
   `~/Dev/fabricore/tools/tools/dell_coord.sh devlock de10 acquire 573`, announce in chat,
   release after; reboot ONLY via `devlock de10 reboot 573`).
2. De-confound EVERY run: warm reboot → wait `/tmp/CORENAME` == `MENU` → ONE
   `load_core` of `/media/fat/_Console/DDR Solo Bass Mix (573).mgl` → wait ~75s.
3. PASS metric: the BOOT CHECK screen PROGRESSES (item list appears / screen changes) —
   compare against the MAME oracle frame `local/mame_ddrsbm.png` (INITIALIZE FLASH-ROM
   prompt @ frame ~4500) with `~/Dev/fabricore/tools/tools/frame_diff.py` for a NUMBER,
   and LOOK at the PNG ([[look-before-calling-black]]). Portrait games: HDMI grabs can
   go stale — `tools/mister_vram_dump.sh` is the trustworthy capture.
   NOTE the capture-card gotcha: any de10 reboot mode-change can freeze the capture host's
   publisher (mediamtx->ffmpeg publishes /de10); if the stream lane complains,
   the fix is kill-TERM of the ffmpeg child ON THE CAPTURE HOST (mediamtx respawns) — 573 session
   was permission-blocked from this; ask tools/stream or the human.
4. If it clears the DIO I2C gate but sticks at a NEW gate: OBSERVE FIRST (MAME oracle,
   disasm the new wait loop from a fresh late-frame RAM dump via
   `tools/trace/ddrsbm_dump_late.lua`) before any further RTL. If a PC snapshot becomes
   necessary, build a NEW dbg branch = feat-digital-bringup + the SLD/QSF cherry-picked
   from `dbg-signaltap-atapi-wedge` (NEVER merge that branch).
5. Regression: one boot of powyakex (base board, no DIO) via its .mgl — must still reach
   attract; hyperbbc if time. DIO logic must not disturb non-DIO games.

## A5. Close out

- Results doc `docs/<date>-ddrsbm-dio-i2c-result.md` (PASS or the next gate, with
  numbers + frames); update `[[fabricore-573-digital-bringup]]` banner + MEMORY.md hook.
- Commit as Fabricore, push PRIVATE (`origin`); public repo is release-only.
- Chat: post the outcome as `573`; keep the status card current
  (`dell_coord.sh status set 573 --stage build|verify ...`), live progress bars on all
  long steps (`tools/with_progress.sh` / builds self-scrape).

## Budget & pause points

- Builds for this feature: approved. Keep observe-first BETWEEN builds; if the gate isn't
  cleared after ~2-3 builds' worth of iteration, STOP and write a handoff instead of
  fix-swinging (the ATAPI saga's core lesson).
- Scope stop: anything beyond "the MAS3507D answers I2C + the boot check's next screen"
  (e.g. actual MP3 audio = DDR plan P4 HPS-side minimp3 + PCM transport; transport choice
  bridge-FIFO vs ALSA-mix is an OPEN P4 decision) is out of scope — note it and pause.

## Phase B (context only, NOT this session): P4 MP3 lane

MSU-1 precedent: ARM-side ring buffer → FIFO into fabric (misterfpga.org t=120), or the
dummy-ALSA mix path (bridge-free but mixes downstream of the core's DIO volume regs).
Decision + design doc comes AFTER the boot layer is cleared. `k573_mp3stream.v` (data
path/descrambler) already exists; `mp3_out_byte/valid` dangle at emu.sv — that wiring is
P4's entry point.
