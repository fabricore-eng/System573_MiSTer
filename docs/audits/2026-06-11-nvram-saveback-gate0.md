# Gate-0: M48T58 NVRAM save-back to SD — Main_MiSTer / hps_io protocol audit

Date: 2026-06-11. Written BEFORE any RTL wiring (gate-0 rule). Sources read at exact
revisions; every claim below has a file:line citation.

Sources:
- **Main** = MiSTer-devel/Main_MiSTer @ `2a2da329e1bd45591ceaac5cc325733b0d36b4ee` (2026-06-11 master)
- **hps_io** = our vendored `sys/hps_io.sv` (sys/ snapshot in this repo — NOT modified by this work)

## 1. What Main does (the `<nvram>` MRA tag + save/load path)

| # | Fact | Citation |
|---|------|----------|
| 1.1 | The MRA `<nvram>` tag has two attributes, `index` and `size`, parsed into `nvram_idx` / `nvram_size`. Both must be non-zero for any save/load to happen (`if(nvram_idx && nvram_size)`). | Main `support/arcade/mra_loader.cpp:703-713` (parse), `:68` + `:92` (gate) |
| 1.2 | **Load**: when the `</nvram>` closing tag is reached during MRA parse, `arcade_nvm_load()` runs: it reads `config/nvram/<mra-name>.nvm` and, if the file exists, sends it to the core as a normal ioctl **download** with `user_io_set_index(nvram_idx)` + `user_io_set_download(1)` + `user_io_file_tx_data(buf, nvram_size)`. If no `.nvm` exists, **nothing is sent** (the `FileLoadConfig` branch is skipped). | Main `support/arcade/mra_loader.cpp:90-117` (function), `:963` (trigger at tag close) |
| 1.3 | Because the load fires at the tag's position in the XML walk, the `<nvram>` tag must be placed **after** `<rom index="3">` in our .mra so the saved image overwrites the factory `nvram.bin` image. First boot (no `.nvm`): factory image alone — existing behavior unchanged. | Main `support/arcade/mra_loader.cpp:963` (SAX callback order = file order) |
| 1.4 | **Save**: `arcade_nvm_save()` = `user_io_set_index(nvram_idx)`; `user_io_set_upload(1)`; `user_io_file_rx_data(buf, nvram_size)`; `user_io_set_upload(0)`; then `FileSave(CONFIG_DIR"/nvram/<mra-name>.nvm", buf, nvram_size)`. Size read from the core = exactly `nvram_size` from the tag. | Main `support/arcade/mra_loader.cpp:66-88` |
| 1.5 | `.nvm` filename = the **.mra filename** with `.mra` → `.nvm` (NOT the setname). For us: `config/nvram/hyperbbc573.nvm`. | Main `support/arcade/mra_loader.cpp:1141-1143` |
| 1.6 | **Save trigger A (explicit)**: OSD → "Save settings" (generic menu case 14) calls `arcade_nvm_save()` for arcade cores (alongside `user_io_status_save`). | Main `menu.cpp:3013-3032` |
| 1.7 | **Save trigger B (core-requested)**: while the generic OSD main menu is open/processing (`MENU_GENERIC_MAIN2`), Main polls `spi_uio_cmd(UIO_CHK_UPLOAD)` (0x3C); non-zero → shows "Saving..." for 1 s and calls `arcade_nvm_save()`. Non-zero happens iff the **core latched an `ioctl_upload_req` rising edge** since the last check (see 2.6). The arcade path ignores the returned index value — any non-zero reply triggers the (MRA-defined) nvram save. | Main `menu.cpp:2234-2243`; `user_io.h:70` |
| 1.8 | **There is NO save on core unload, MiSTer reboot, or power-off.** The only background (non-OSD) `UIO_CHK_UPLOAD` poll is C64/C128-specific (`c64_save_cart`). For arcade, both triggers require the OSD. | Main `user_io.cpp:3759-3763` (c64-only poll); no other `arcade_nvm_save` call sites exist (grep: `menu.cpp:2243`, `menu.cpp:3031` only) |

## 2. hps_io upload protocol — the core's-eye view (WIDE=1, our config)

Our instance: `hps_io #(.CONF_STR(CONF_STR), .WIDE(1), ...)` clocked by `clk_1x` (rtl/emu.sv:568-570). WIDE=1 ⇒ `DW=15` ⇒ `ioctl_din[15:0]`.

| # | Fact | Citation |
|---|------|----------|
| 2.1 | Upload arming: `user_io_set_upload(1)` sends `FIO_FILE_TX` + byte `0xAA` → hps_io sets `ioctl_addr <= 0`, `req_io <= 2'b10`; when the FPGA chip-select drops (`~fp_enable`), `{ioctl_upload, ioctl_download} <= req_io` ⇒ **`ioctl_upload=1`, addr=0**. `ioctl_index` was set beforehand via `FIO_FILE_INDEX` (=3 for our nvram). | Main `user_io.cpp:2050-2061`; hps_io `sys/hps_io.sv:636-642, 668-684`; `user_io.h:81-83` |
| 2.2 | Data phase: `user_io_file_rx_data` = one `FIO_FILE_TX_DAT` command, then `len/2` 16-bit SPI word reads (`spi_read`, wide). **Each word strobe** executes: `ioctl_addr += 2`; `fp_dout <= ioctl_din`; `ioctl_rd <= 1` (1-clk pulse). | Main `user_io.cpp:2063-2069`, `spi.cpp:165-178`; hps_io `sys/hps_io.sv:686-699` |
| 2.3 | **Sampling order** (the critical bit): the HPS handshake (`fpga_spi`: write word+strobe → wait ACK → drop strobe → wait ~ACK → **then** read gpi[15:0]) means the value Main stores for word *k* is `fp_dout` **after** strobe *k* was processed — i.e. `ioctl_din` as sampled **at** strobe *k*, while `ioctl_addr` still held `2k`. So the core's contract is simply: **continuously present `ioctl_din = {byte[ioctl_addr+1], byte[ioctl_addr]}`**; after each strobe the addr advances by 2 and the core has the whole inter-word gap to fetch the next pair. `fp_dout` is returned combinationally on `HPS_BUS[15:0]` while `fp_enable` is high. | Main `fpga_io.cpp:688-721`; hps_io `sys/hps_io.sv:194, 686-699` |
| 2.4 | **WIDE effect on upload** = exact inverse of the download trap that caused the red-N: 2 file bytes per strobe, low byte = even address. Packing must be `{odd, even}`, addr steps by 2. | hps_io `sys/hps_io.sv:677, 688` (`WIDE ? 2'd2 : 2'd1`) |
| 2.5 | **No back-pressure on upload.** `ioctl_wait` is only honored by Main's download paths; `user_io_file_rx_data`/`spi_read` never look at it. The core must have the word ready within one HPS SPI word period. Budget: each word costs ≥2 gpo writes + ≥2 gpi polls through the lightweight bridge plus 2 clk_sys-domain strobe/ack syncs — ≥ several hundred ns ≈ ≥10–20 clk_1x cycles, typically far more. Our fetch FSM refreshes every 4 clk_1x cycles ⇒ safe margin. (Also: the first data strobe arrives ≥ one full EnableFpga+command round-trip after `ioctl_upload` rises — µs-scale — so the FSM's initial fetch latency is covered.) | Main `spi.cpp:165-178`, `fpga_io.cpp:688-721`; hps_io `sys/hps_io.sv:686-699` (no wait check in upload branch) |
| 2.6 | Core-requested save: hps_io edge-detects `ioctl_upload_req` (`~old & new → upload_req <= 1`); the latch is **cleared when Main reads UIO_CHK_UPLOAD** (reply `{ioctl_upload_index, 8'd1}`). A *level* request therefore latches exactly once per rising edge — no "Saving..." spam — and the core re-arms it by deasserting and reasserting. | hps_io `sys/hps_io.sv:275-290, 335` |
| 2.7 | During upload the `FIO_FILE_TX_DAT` strobes fire regardless of index; the core must mux `ioctl_din` by `ioctl_index` itself (only index 3 exists as an upload source in this core). | hps_io `sys/hps_io.sv:686-699` (index-blind) |

## 3. Design consequences (what gets wired)

1. **.mra**: add `<nvram index="3" size="8192"/>` after the `<rom index="3">` row (and in `tools/mister_mra.sh`). Load side needs **zero changes**: the `.nvm` restore arrives as a normal index-3 download through the proven `s573_nvram_loader` path (facts 1.2/1.3).
2. **emu.sv**: connect `ioctl_upload` + `ioctl_din` on the hps_io instance; `nvram_upload = ioctl_upload && ioctl_index==3`; present `{ram[addr+1], ram[addr]}` per fact 2.3/2.4 via a new `s573_nvram_saver` (inverse of the loader's unpack).
3. **m48t58.v**: the 8 KB array is M10K (1 write port + 1 registered game-read port). The saver gets the **write port's idle cycles** (single-port read/write template: write when a bus/loader write is pending, else read `sav_addr`), so the game-side read port and all write behavior are untouched. A `sav_rd_ok` flag (=no write stole the cycle) lets the saver retry; the top-8 RTC bytes are muxed from the live clock registers so the uploaded 8192-byte image mirrors MAME's full timekeeper `.nvm` layout. (The existing loader already drops bytes 8184–8191 on load — restore puts factory/old time in those file bytes nowhere; RTC simply re-runs from reset. Documented, accepted.)
4. **Autosave-on-OSD (fact 1.7/2.6)**: system573_top exports a "game wrote the timekeeper" strobe; emu latches it into a `nvram_dirty` flag driving `ioctl_upload_req` (with `ioctl_upload_index=3`). Cleared when the upload starts (conservative: writes racing the upload re-arm the flag). Result: any OSD-main-menu visit after a write auto-saves (with Main's own "Saving..." splash) — including the menu visit a player makes to exit the core.

## 4. Operational reality (honest notes — when does a player's data actually persist?)

- **Saved**: (a) OSD → Save settings, any time; (b) with our `ioctl_upload_req` dirty-tracking: automatically ~immediately upon **opening the OSD main menu** after any NVRAM write (high score, bookkeeping, install state). Exiting the core the normal way goes through the OSD main menu, so the usual quit flow auto-saves.
- **Lost**: yank-the-power without ever opening the OSD after play. Main has no core-unload/shutdown hook for arcade NVRAM (fact 1.8). This is a Main_MiSTer limitation shared by every arcade core, not something the core can fix from the FPGA side.
- **Not headlessly triggerable**: both triggers live inside menu.cpp's OSD state machine. For HW verification later, the save can be forced by scripting the OSD (or simply: play → open OSD → check `/media/fat/config/nvram/hyperbbc573.nvm` mtime + content). Sim verification (this work) drives the hps_io-equivalent strobe protocol directly.
- The `.nvm` restore-on-boot needs **no new RTL** and silently no-ops until the first save exists.
