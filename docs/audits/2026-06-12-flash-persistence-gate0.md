# Gate-0: 16 MB onboard-flash PERSISTENCE for CD-install games — Main_MiSTer / hps_io protocol audit

Date: 2026-06-12. Written BEFORE any RTL wiring (gate-0 rule). Board-free, no build.
Every load-bearing claim has a file:line citation. Sources read at the revisions below.

**Goal.** A user installs a CD-install game (hypbbc2p, konam80s, …) once; the 16 MB onboard
flash image the installer programs into SDRAM survives reboot / power-cycle, saved to **their**
SD card. We ship only the core (a blank flash + the loader RTL), never game data.

Sources:
- **Main** = MiSTer-devel/Main_MiSTer @ `master` (fetched 2026-06-12). Line numbers are
  approximate (±, from text search of the raw master files) — flagged `~` where not exact.
  Re-pin to a commit hash before wiring (see RISK R7).
- **hps_io** = vendored `sys/hps_io.sv` (this repo; NOT modified by this work) — EXACT lines.
- **emu** / **rtl** = this repo's RTL — EXACT lines.

The critical reframe up front: this is **NOT** an ioctl-upload save (the mechanism the NVRAM
save-back audit, `2026-06-11-nvram-saveback-gate0.md`, uses). The CD-install games launch as a
**console `.mgl`** (`is_arcade_type=0`), so the arcade `arcade_nvm_save` path does not exist for
them. The right template is the **PSX memory card**: a writable **`S`-slot virtual drive** that
Main mounts from `saves/System573/<name>.sav` and writes through **in real time** via the
`sd_lba/sd_rd/sd_wr/sd_ack/sd_buff` block protocol — no OSD-gated upload, no `<nvram>` tag.

---

## 1. How a CONSOLE core persists a writable virtual drive (the S-slot block protocol)

| # | Fact | Citation |
|---|------|----------|
| 1.1 | A writable save is a **mounted image** (`S`-slot in CONF_STR), persisted via the **block protocol**, not an ioctl upload. Main's SD poller reads the core's per-drive request word (`UIO_GET_SDSTAT`): `op = c & 3` (1=read, 2=write), `disk = (c>>2)&0xF`, then the 32-bit `lba` (`lba = (lba & 0xFFFF) | (spi_w(0) << 16)`), block count, and block size. | Main `user_io.cpp` `user_io_poll()` SD handler (~L3025–3250); request decode ~L2940 |
| 1.2 | **Write-through is immediate.** On `op==2` Main reads the sector from the core (`spi_block_read`) then `FileSeek(&sd_image[disk], lba*blksz, SEEK_SET)` + `FileWriteAdv(...)` to the mounted file — opened `O_RDWR | O_SYNC`. Every block the core writes lands on the SD card right away. **No OSD step, no upload arming.** | Main `user_io.cpp` write branch ~L1505–1530 (also surfaced in the poll loop); `O_SYNC` on open |
| 1.3 | **Read-on-mount is the same channel reversed.** On `op&1` (read) Main does `FileSeek(lba*blksz)` + `FileReadAdv` from the mounted file and ships the sector back (`spi_block_write`). This is how a saved image is *loaded*: the core requests block 0..N and gets the saved bytes. | Main `user_io.cpp` read branch ~L1570–1585 |
| 1.4 | **LBA is 32-bit** on both sides. Main assembles `lba` from two 16-bit SPI words; hps_io's `sd_lba[]` is `[31:0]` per drive. A 16 MB image addressed in ≥512 B blocks needs ≤ a 15-bit block count — well inside 32 bits. (Contrast: the existing memcard drives use only `reg [6:0] sd_lba2/3` — far too narrow for flash; the CD drive uses the full-width `wire [31:0] sd_lba1`.) | hps_io `sys/hps_io.sv:133` (`input [31:0] sd_lba[VDNUM]`); emu `rtl/emu.sv:529-530` (7-bit memcard lba), `:528` (32-bit `sd_lba1`) |
| 1.5 | **Auto-create on first write.** When a drive is mounted with the pre-allocate flag (`pre=1`), Main sets `sd_image[index].type = 2` and reports `size = pre_size` to the core **without** the file existing. The file is created (`FileOpenEx(..., O_CREAT|O_RDWR|O_SYNC)`) the first time the core writes **LBA 0** (`if (sd_image[disk].type==2 && !lba)`). So a brand-new card needs no pre-staged file. | Main `user_io.cpp` `user_io_file_mount` pre-branch ~L1481 (`type=2`, `size=pre_size`); create-on-lba0 ~L1505–1515 |
| 1.6 | **`pre_size` is `int`** in `user_io_file_mount(const char *name, unsigned char index, char pre, int pre_size)`. 16 MB = 16,777,216 fits in a signed 32-bit `int` with vast headroom; it is widened to the 64-bit `size` sent to the core. **No size cap** is enforced in the mount or SD-poll paths. | Main `user_io.cpp` `user_io_file_mount` signature ~L1450; size send (`spi32_w(size); spi32_w(size>>32)` / 64-bit) |
| 1.7 | **Save path & filename.** `FileGenerateSavePath(name, out, ext_replace)` → `SAVE_DIR/CoreName2/<basename-of-name>[.sav]`. `CoreName2` is the core/`setname`; ours is **`System573`** (the `.mgl` `<setname>`). So the persistent file is **`saves/System573/<name>.sav`**, NOT under `config/`. | Main `file_io.cpp` `FileGenerateSavePath` (full body quoted in §appendix); `.mgl` `<setname>System573</setname>` (`mgl/konam80s_console.mgl`) |
| 1.8 | **`img_mounted` / `img_size` reach the core** on mount: hps_io pulses `img_mounted[index]`, sets `img_readonly` and the 64-bit `img_size`. The core uses these to gate its load FSM (the existing memcard path keys off `img_mounted[2]/[3]` + `img_size>0` → `memcardX_load`). | hps_io `sys/hps_io.sv:128-130, 460-466` (`img_mounted`/`img_readonly`/`img_size` send); emu `rtl/emu.sv:876-905` (memcard mount → load) |

## 2. The PSX memcard — the exact working template (slots 2/3)

| # | Fact | Citation |
|---|------|----------|
| 2.1 | **Mount is automatic on game load — via the CD-mount callback.** `psx_mount_cd()` calls `psx_mount_save(last_dir)`, gated `if (!user_io_status_get("[63]"))` (status bit 63 = "Automount Memory Card 1", inverted). So mounting a disc auto-mounts the save. **Key consequence for us:** our CD-install `.mgl` mounts a `.chd` on `S` index 1, which drives `psx_mount_cd()` → an auto-mount hook already runs on these exact launches. | Main `support/psx/psx.cpp` `psx_mount_save` def ~L319; sole call site in `psx_mount_cd()` ~L569 (`if(!user_io_status_get("[63]")) psx_mount_save(last_dir)`) |
| 2.2 | `psx_mount_save()` = `user_io_set_index(2); FileGenerateSavePath(filename, buf, 0); user_io_file_mount(buf, 2, 1, MCD_SIZE); StoreIdx_S(2, buf);` — i.e. **pre-allocate (`pre=1`) a fixed-size (`MCD_SIZE`) writable image** and remember the slot path. The blank-card data is pre-filled by the core/Main on first read (`psx_fill_blanksave` seeds an `mcdheader`). | Main `support/psx/psx.cpp` `psx_mount_save` body ~L319-327; `#define MCD_SIZE (128*1024)` ~L317; `psx_fill_blanksave` |
| 2.3 | **Core side (the FSM we clone).** `memcard.vhd` runs a block loop: latch `save`/`load`, drive `memcard_lba <= blockCnt`, raise the read/write request, wait `memcard_ack`, stream a block via `mem_addrA` 0..127, advance `blockCnt`, repeat. `load` only runs when `mounted='1'`; `save` runs when `saveLatched`. This is exactly a read-on-mount + write-on-dirty block engine over the SD protocol. | psx `psx/rtl/memcard.vhd:12,18,37-40,94-180,202-234` |
| 2.4 | **In emu.sv** the memcard is wired to hps_io slots 2/3: `sd_rd[2]/sd_wr[2]` ← `memcard1_rd/wr`, `sd_lba2` ← `memcard1_lba` (7-bit), `sd_buff_din2` ← `memcard1_dataOut`, `sd_buff_dout`/`sd_buff_addr`/`sd_buff_wr` shared. `img_mounted[2]` → `sd_mounted2` → `memcard1_load`; `bk_save`/`bk_save_a` → `memcard_save`. **The save trigger is purely core-internal** — `bk_save = status[13]` ("RD,Save Memory Cards") or `bk_save_a = OSD_STATUS & ~status[71]` ("O[71] Save to SDCard, On Open OSD"). Once `memcard_save` fires the FSM streams dirty blocks out via `sd_wr` and Main writes them through (fact 1.2). | emu `rtl/emu.sv:343-360` (memcard ports), `:771-777, 915-918` (`bk_save`/`bk_save_a`/`memcard_save`), `:1341-1349` (slot-2 wiring), CONF_STR `:404-408` |
| 2.5 | **hps_io supports 4 drives** (`.VDNUM(4)`), block size 1024 B (`.BLKSZ(3)` → `1<<(3+7)`), `.WIDE(1)` (16-bit `sd_buff`). Slots in use: 0 unused, 1 = ATAPI CD (read-only), 2/3 = memcards. **A 5th drive needs `VDNUM=5`** (drives the `[VD:0]` bus widths and the `sd_lba[]` array length). | emu `rtl/emu.sv:598` (`.WIDE(1), .VDNUM(4), .BLKSZ(3)`); hps_io `sys/hps_io.sv:35,133-143,182` (`VD=VDNUM-1`) |
| 2.6 | **Per-SPI-transfer ceiling.** hps_io's contract: `(sd_blk_cnt+1)*(1<<(BLKSZ+7)) must be <= 16384`. At `BLKSZ=3` (1024 B), that's ≤ 16 blocks (16 KB) per `sd_rd/sd_wr` request. A 16 MB image = **16,384 one-KB blocks**; the saver simply iterates the LBA across many single-block (or ≤16-block) requests — exactly as the memcard FSM iterates `blockCnt`. No single transfer ever exceeds 16 KB. | hps_io `sys/hps_io.sv:134` (the `<=16384` rule); block-count math (BLKSZ=3 → 1024 B/block, 16 MB/1024 = 16384 blocks) |

## 3. Where the 16 MB flash actually lives, and why there is no Linux dump path

| # | Fact | Citation |
|---|------|----------|
| 3.1 | The 16 MB onboard flash is backed in the **FPGA's SDRAM** at `FLASH_START = 27'h0100_0000` (relocated from 0x02000000 so it fits a 32 MB module). Byte addr = `FLASH_START + (word<<1)`. | emu `rtl/emu.sv:733` (`FLASH_START`), `:723-732` (relocation rationale) |
| 3.2 | Flash **READ** is a line-fill: `s573_flash` (SIM_BACKING=0) requests 128-bit bursts on **sdram ch4** (`flash_mem_req/addr → flash_mem_q/ready`), addressed `flash_ch4_addr = FLASH_START + {flash_mem_addr[25:0],1'b0}`. | emu `rtl/emu.sv:1519-1523, 1672-1674, 2058-2062`; `rtl/s573_flash.v:180-352` |
| 3.3 | Flash **WRITE-BACK already exists** (the installer programs flash): `s573_flash` emits one 16-bit NOR program word on **sdram ch3** (`flash_wr_req/busy/addr/data → flash_wr_ack`); emu muxes it onto ch3 (`flash_wr_ch3_addr = FLASH_START + {flash_wr_addr[25:0],1'b0}`, byte-enable `4'b0011`). So after a CD install the programmed image is coherent in SDRAM at FLASH_START. | emu `rtl/emu.sv:1526-1542, 1534-1536, 2044-2056`; `rtl/s573_flash.v:86-107, 275-294` |
| 3.4 | **The SDRAM is NOT HPS-mmap-able.** Only the DDR3 VRAM at `0x30000000` is reachable from Linux (`FB_BASE`); the SDRAM flash region has **no `/dev/mem` path**. Therefore persistence MUST go through the FPGA (a core-side save FSM over the SD block protocol), not a host-side `dd`. This is the central design constraint. | emu `rtl/emu.sv:209` (`FB_BASE=0x30000000` DDR3); the SDRAM module (`rtl/emu.sv:1998-2068`) is FPGA-private; no HPS bridge to FLASH_START exists in this repo |
| 3.5 | **Today the install is volatile.** The `.mgl` loads `flash16m_blank.bin` as `type="f" index="2"` on **every** launch (→ `flash_download`, written to SDRAM @FLASH_START). A reboot/relaunch re-blanks the install. The install runner explicitly documents this as the unsolved "OPEN QUESTION". | `mgl/konam80s_console.mgl` (`<file ... index="2" path=".../flash16m_blank.bin"/>`); `tools/mister_cd_install.sh:32-62` (OPEN QUESTION block) |

## 4. The two halves of persistence (what this audit must wire)

| # | Fact / required behavior | Citation / basis |
|---|------|------|
| 4.1 | **SAVE half** = a core FSM that, on a trigger, reads the 16 MB SDRAM flash region block-by-block and presents each block on `sd_buff_din[newslot]` while pulsing `sd_wr[newslot]` and stepping `sd_lba[newslot]` 0..16383; Main writes each through to `saves/System573/<name>.sav` (facts 1.2, 2.3). | template: `psx/rtl/memcard.vhd` save loop; write-through: §1.2 |
| 4.2 | **LOAD half** = on `img_mounted[newslot]` with `img_size>0`, the same FSM reads blocks 0..N from Main (the saved file) and writes them into SDRAM @FLASH_START via a ch3 writer, **overriding** the `.mgl`'s blank flash. Because the `.mgl` blank load and the save-mount both happen at launch, **ordering matters** (RISK R1). | facts 1.3, 3.3, 3.5; emu memcard load §2.4 |
| 4.3 | **SDRAM access for the FSM.** READ-back-for-save can reuse **ch4** (the existing flash read line-fill port — idle except during BIOS flash reads) OR a dedicated ch4 transaction; WRITE-on-load reuses the **ch3** flash-write-back path (already built, fact 3.3). The simplest reuse: the FSM speaks to `s573_flash`'s existing ports, or emu adds a thin SDRAM-DMA helper that shares ch3 (write) / ch4 (read) the same way the install write-back does. No new SDRAM channel is strictly required. | emu ch3/ch4 muxing `rtl/emu.sv:2044-2062`; `rtl/s573_flash.v` ports |
| 4.4 | **SAVE trigger options** (all already present): (a) `bk_save = status[13]` ("RD,Save Memory Cards") — reuse or add a parallel "Save Flash" `R` bit; (b) `bk_save_a = OSD_STATUS & ~status[71]` (auto-save on OSD open) — the same dirty-on-OSD flow the memcard uses; (c) a core-internal "install finished" strobe (the installer's last `flash_wr_ack`, or `s573_flash` bank/program activity going idle) latched into a dirty flag. Console cores have **no unload/power-off hook** (same Main limitation noted in the NVRAM audit §4) — the OSD-open path is the realistic auto-trigger. | emu `rtl/emu.sv:771-777, 915-918`; CONF_STR `:404-405`; NVRAM audit fact 1.8 (no unload hook) |

---

## FEASIBILITY VERDICT

**FEASIBLE — as a 5th writable `S`-slot virtual drive, using the PSX-memcard mechanism, with
zero Main_MiSTer changes.** Every required primitive exists and is already exercised by this core:

- Main persists a writable console save **purely through the block protocol** (`sd_lba/sd_rd/
  sd_wr/sd_ack/sd_buff`), writing each block **through to disk immediately** with `O_SYNC`
  (§1.2). No `<nvram>` tag, no ioctl upload, no arcade path — so the console-`.mgl` blocker that
  killed the arcade save route **does not apply**.
- Main **auto-creates** the file on first write (`pre=1`, `type=2`, create-on-LBA-0) at any
  `pre_size`; **16 MB fits the `int pre_size` with no cap** and `sd_lba` is 32-bit (§1.5, 1.6,
  1.4). The save lands at **`saves/System573/<name>.sav`** (§1.7).
- The mount is **already triggered on our exact launches**: our CD-install `.mgl` mounts a `.chd`
  → `psx_mount_cd()` → `psx_mount_save()` auto-mount hook (§2.1). We can ride that, or add an
  explicit mount.
- The SAVE/LOAD FSM is a **direct clone of the working `memcard.vhd` block engine** (§2.3),
  and the SDRAM read/write plumbing it needs (**ch4 read, ch3 write-back**) is **already built
  and proven** by the installer's flash write-back (§3.3).

**What it needs (none of it is a Main change):**
1. Bump `hps_io` to **`.VDNUM(5)`** and add one `S`-slot (32-bit `sd_lba`, full-width) for the
   flash save image (§2.5, 1.4). The memcard 7-bit LBA is too narrow — use a CD-style 32-bit LBA.
2. A new RTL block (`s573_flash_saver`) implementing the SAVE (SDRAM→`sd_buff_din`) and
   LOAD (`sd_buff_dout`→SDRAM) block loops, wired to the new slot and to ch3/ch4.
3. CONF_STR: one `S`-slot line (+ optional `R` save bit / status mount-control), plus a Main-side
   mount call OR reuse the `psx_mount_save`-style auto-mount. (If we cannot rely on the PSX
   support file mounting a 16 MB image on **our** flash slot, we add an explicit
   `user_io_file_mount` for slot index 4 — see RISK R4.)
4. Ordering glue so the **saved image loads AFTER the `.mgl` blank** (RISK R1).

**One honest caveat (does NOT block feasibility, changes the UX):** like every MiSTer console
save, there is **no power-off / core-unload flush** (§4.4, NVRAM audit fact 1.8). Persistence
fires on an explicit/auto trigger (OSD-open auto-save, or an "install finished" strobe). After a
CD install the user must let one save fire (open the OSD, or the install-done strobe) before
pulling power. This is identical to memcard-save behavior and is acceptable.

---

## IMPLEMENTATION PLAN

### A. hps_io / emu.sv wiring
1. **`hps_io #(... .VDNUM(5) ...)`** (emu `rtl/emu.sv:598`). Add `sd_lba4` as **`reg [31:0]`**
   (CD-style width, not the 7-bit memcard width), `sd_rd[4]`, `sd_wr[4]`, `sd_ack[4]`,
   `sd_buff_din4`, and route `img_mounted[4]`/`img_size`. Extend the `sd_lba`/`sd_rd`/`sd_wr`/
   `sd_buff_din` packed-array literals to 5 entries.
2. New module **`s573_flash_saver`** (clone `memcard.vhd`'s block FSM, in Verilog to match the
   573 modules):
   - **SAVE path:** on trigger, for `lba = 0..16383`: read 1 KB (8×128-bit ch4 bursts, or
     reuse `s573_flash`'s line-fill) from SDRAM `FLASH_START + lba*1024`, present each 16-bit
     word on `sd_buff_din4` indexed by `sd_buff_addr`, pulse `sd_wr[4]`, wait `sd_ack[4]`,
     advance `lba`. (Block ≤16 KB/transfer per §2.6 — single-block is simplest.)
   - **LOAD path:** on `img_mounted[4] && img_size>0`, for `lba = 0..(img_size/1024)-1`: pulse
     `sd_rd[4]`, wait `sd_ack[4]`, capture `sd_buff_dout`/`sd_buff_wr`/`sd_buff_addr` into a
     1 KB staging buffer, then stream it into SDRAM @`FLASH_START + lba*1024` via the **ch3
     write-back** mux (reuse `flash_wr_*` plumbing, `rtl/emu.sv:1526-1542`).
3. **SDRAM mux:** extend the ch3 owner select (`rtl/emu.sv:2050-2056`) to add the saver's
   load-writes (priority below an HPS download, peer-or-above the flash program write-back —
   the saver only runs at mount/trigger time, never concurrently with a CD install). Reuse ch4
   read for the save read-back (it's idle outside BIOS flash reads).

### B. CONF_STR (emu `rtl/emu.sv:373-520`)
- Add an `S`-slot for the flash save, e.g. `"SC4,SAV,Flash Save;"` (BLKSZ index `C`), so an
  image can be mounted to drive index 4. Optionally `"O[..],Automount Flash Save,Yes,No;"`
  mirroring the memcard `O[63]`, and `"R..,Save Flash;"` mirroring `RD`.
- The save trigger: OR a flash-dirty flag into the same OSD-open auto-save logic as
  `bk_save_a` (`OSD_STATUS & ~status[71]`), set by an "install activity then idle" strobe from
  `s573_flash` (or simply: any `flash_wr_ack` during a CD-boot session marks dirty).

### C. The mount (Main side — reuse, don't modify)
- **Preferred:** ride the existing `psx_mount_save` auto-mount — but that hard-codes slot **2**
  and `MCD_SIZE` (128 KB), so it will **not** mount our 16 MB slot-4 image. Therefore:
- **Realistic:** the `.mgl` adds the flash save as a mounted `S` entry, OR (if `.mgl` can't
  express a pre-sized save) we rely on Main's generic save-mount for the console `setname`. The
  cleanest no-Main-patch route is a **`.mgl` `<file ... type="s" index="4" .../>`** pointing at
  `saves/System573/<name>.sav`, with the core's auto-create handling the first-run blank
  (§1.5). **Verify** the `.mgl` schema permits an `s`-slot at a save path (RISK R4) — if not,
  the smallest Main-side change is one `user_io_file_mount(savepath, 4, 1, 16*1024*1024)` in the
  PSX support file's load callback (one line, upstreamable).

### D. The load-overrides-blank ordering
- The `.mgl` loads `flash16m_blank.bin` (index 2) AND mounts the save (slot 4) at launch. The
  saver's LOAD must run **after** the blank `flash_download` completes so it overwrites it. Gate
  the LOAD FSM on `~flash_download & download_settle_hold-cleared & img_mounted[4]` and hold the
  CPU in reset until the load finishes (extend `reset_or` / `download_settle_hold`,
  `rtl/emu.sv:354-362`). First boot (empty save, `type=2`, nothing to read until the core writes
  LBA 0) → blank flash stands, installer runs, save is created on first write-back. Subsequent
  boots → save loads over blank, game boots from flash, **CD not needed**.

### E. Sim red-green test strategy (the gate-0 deliverable's proof)
- **RED:** an HW-realistic testbench `sim/tb_s573_flash_saver.v` drives the **block protocol the
  way Main does** (the `sd_rd/sd_wr/sd_ack/sd_buff` handshake, 32-bit `sd_lba`, 1 KB blocks),
  with a model SDRAM preloaded with a known 16 MB pattern. Assert SAVE streams the **exact**
  SDRAM bytes out in LBA order, and LOAD writes the **exact** mounted bytes back into SDRAM
  @FLASH_START — byte-identical, all 16384 blocks. Prove it FAILS on a deliberately broken
  byte-lane / LBA-step (mirror the NVRAM saver's "fails on the byte-drop" discipline,
  `s573_nvram_saver.v` header + its TB).
- **Round-trip:** preload SDRAM → SAVE to a memory-backed file model → wipe SDRAM to blank →
  LOAD → assert SDRAM == original. 100% match required.
- **Integration:** extend the existing `sim/system573` boot harness so a post-install SDRAM
  flash image survives a simulated "reboot" (blank reload + save-mount-load) and the BIOS
  flash-boot signature `"PS-X EXE"` reads back correctly from FLASH_START.
- Reuse `s573_nvram_saver`/`memcard.vhd` as the structural reference; verify with a NUMBER
  (byte-diff count == 0), never vision.

---

## RISK LIST

- **R1 (ordering, MEDIUM).** The `.mgl` blank-flash load and the save-mount both fire at launch;
  if the LOAD FSM races the `flash_download`, the blank can overwrite the restored image (or vice
  versa). Mitigation: gate LOAD on `flash_download` complete + hold CPU reset until LOAD done
  (Plan D). This is the single most likely source of a "lost install" bug.
- **R2 (mount of a 16 MB slot, MEDIUM).** `psx_mount_save` hard-codes slot 2 + 128 KB, so it
  will NOT mount our slot-4 16 MB image. We must mount via the `.mgl` `s`-slot or a one-line
  Main call (Plan C). If neither works cleanly, persistence can't be auto-mounted and the user
  would have to mount the save manually via OSD each launch — degraded but still functional.
- **R3 (no power-off flush, LOW/UX).** Console cores have no unload/shutdown save hook (§4.4).
  Persistence requires an explicit/auto trigger before power-off. Acceptable (same as memcards),
  but must be documented for the user; an "install finished → auto-save" strobe makes it
  near-transparent.
- **R4 (`.mgl` `s`-slot-to-save-path schema, MEDIUM — UNVERIFIED).** I did not confirm that a
  `.mgl` `<file type="s">` can point at a `saves/...sav` path AND trigger Main's pre-allocate
  auto-create. The memcard precedent uses a Main-side `user_io_file_mount(..., pre=1, size)`, not
  a `.mgl` line. **Verify against Main's `.mgl` parser before committing to the no-Main-patch
  route.** If it fails, the fallback is the one-line `user_io_file_mount` in the PSX support file.
- **R5 (16 MB write-through latency, LOW).** A full 16 MB save = 16384 SD block writes with
  `O_SYNC`. On the OSD-open auto-save this could stall for a noticeable fraction of a second.
  Mitigation: only save on the **install-finished** strobe (rare), or dirty-track which 1 KB
  blocks the installer actually programmed and save only those (a bitmap over the write-back
  port). Start simple (full image), optimize if the stall is real.
- **R6 (SDRAM channel contention, LOW).** The saver shares ch3/ch4 with the BIOS flash path and
  the install write-back. The saver runs only at mount/trigger time (never during an active CD
  install), so contention is avoidable with the priority mux (Plan A.3) — but verify the
  install-then-save and load-then-boot sequences never overlap a live BIOS flash read.
- **R7 (Main line numbers approximate, LOW/process).** Main citations were read from `master`
  with text-search line numbers (`~`). Before wiring, re-pin Main to the **exact commit** the
  target board runs (the install runner notes the de10 ran Main 250828 / `3d14fe8`,
  `tools/mister_cd_install.sh:71-72`) and re-confirm `user_io_file_mount` / SD-poll line numbers
  and the `psx_mount_save` slot/size. The mechanism is stable across versions; the line numbers
  are not.

---

## Appendix — key Main source (quoted)

`FileGenerateSavePath` (file_io.cpp, master):
```c
void FileGenerateSavePath(const char *name, char* out_name, int ext_replace)
{
    create_path(SAVE_DIR, CoreName2);
    sprintf(out_name, "%s/%s/", SAVE_DIR, CoreName2);
    char *fname = out_name + strlen(out_name);
    const char *p = strrchr(name, '/');
    if (p) strcat(fname, p+1); else strcat(fname, name);
    char *e = strrchr(fname, '.');
    if (ext_replace && e) strcpy(e,".sav"); else strcat(fname, ".sav");
    printf("SavePath=%s\n", out_name);
}
```
→ our save = `SAVE_DIR/System573/<name>.sav`.

`psx_mount_save` (support/psx/psx.cpp, ~L319):
```c
static void psx_mount_save(const char *filename) {
    user_io_set_index(2);
    if (strlen(filename)) {
        FileGenerateSavePath(filename, buf, 0);
        user_io_file_mount(buf, 2, 1, MCD_SIZE);   // pre=1, pre_size=128KB
        StoreIdx_S(2, buf);
    } else { user_io_file_mount("", 2); StoreIdx_S(2, ""); }
}
```
called once, in `psx_mount_cd()` (~L569): `if(!user_io_status_get("[63]")) psx_mount_save(last_dir);`

`user_io_file_mount` pre-allocate + create-on-first-write (user_io.cpp, ~L1481 / ~L1505):
```c
// mount, pre=1: report size without the file existing
if (!ret && pre) { sd_image[index].type = 2; strcpy(sd_image[index].path, name); size = pre_size; }
...
// SD write op, first sector of a type-2 image: create it now
if (sd_image[disk].type == 2 && !lba) {
    if (FileOpenEx(&sd_image[disk], sd_image[disk].path, O_CREAT | O_RDWR | O_SYNC)) { ... }
}
```
