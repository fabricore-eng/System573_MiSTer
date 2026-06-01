# Dumps manifest

Drop the real dumps here at the **exact paths** below. The actual binaries are
git-ignored (`*.bin`, CD images, etc.) — only this manifest is committed. I check
for each file's presence before the phase that needs it and proceed automatically
once it's there; if it's missing I pause and name it.

**Easiest single source:** a MAME `ksys573` romset for your target game bundles
the BIOS, the CD/flash/card image(s), the security-cart default data, and the
DS2401 ids. Point me at the set and I'll sort files into the layout below.

Replace `<game>` with a short slug, e.g. `bishi` (Hyper Bishi Bashi Champ) or
`80sgallery` (Konami 80's Arcade Gallery) — the recommended first targets.

---

## Order I use them

### 1. BIOS POST (Phase 3 — needed first)
| Path | What | Size | Consumed by |
|------|------|------|-------------|
| `dumps/bios/573.bin` | Konami System 573 boot BIOS | 512 KB | PSX core BIOS region |
| `dumps/bios/cart/ds2401.bin` | an installed security cart's DS2401 serial | 8 bytes | `s573_seccart`/`ds2401` |
| `dumps/bios/cart/x76f100.bin` | that cart's secure-EEPROM contents | 112 B (+pw) | `x76f100` |
| `dumps/bios/cart/m48t58.bin` *(optional)* | RTC/NVRAM seed if the BIOS wants one | 8 KB | `m48t58` |

> The BIOS POSTs with an acceptable cart installed. Any simple X76F100 cart the
> BIOS trusts works for the POST milestone.

### 2. First game (Phase 5)
| Path | What | Format | Consumed by |
|------|------|--------|-------------|
| `dumps/<game>/cd.chd` *(or `cd.bin` + `cd.cue`)* | the game disc | CHD or BIN/CUE | `atapi` disc store |
| `dumps/<game>/security/ds2401.bin` | the game cart's DS2401 serial | 8 bytes | `s573_seccart` |
| `dumps/<game>/security/x76f100.bin` | the game cart's secure EEPROM | 112 B (+pw) | `x76f100` |
| `dumps/<game>/m48t58.bin` *(optional)* | seeded RTC/NVRAM | 8 KB | `m48t58` |

### 3. Security variants (Phase 6)
| Path | What | Consumed by |
|------|------|-------------|
| `dumps/<game>/security/x76f041.bin` | X76F041 cart contents | `x76f041` |
| `dumps/<game>/security/zs01.bin` | ZS01 cart data (+ per-cart data key) | `zs01` |

### 4. Flash / PCMCIA install-type games (Phase 7)
| Path | What | Format | Consumed by |
|------|------|--------|-------------|
| `dumps/<game>/flash.bin` | onboard 16 MB NOR flash image | raw | `s573_flash`/`flash_nor` |
| `dumps/<game>/pccard.bin` | PCMCIA flash-card image | raw | `s573_flash` PCMCIA banks |

### 5. BEMANI / MP3 titles (Phase 9)
| Path | What | Consumed by |
|------|------|-------------|
| `dumps/<game>/dio_ds2401.bin` | Digital I/O board DS2401 serial | `k573dio` board id |
| *(the scrambled MP3 audio + the key1/2/3 live in the game data on the CD/flash — no separate dump)* | | `k573_mp3stream`/`k573_mp3dec` |

---

## Directory layout

```
dumps/
  README.md                ← this file (committed)
  bios/
    573.bin
    cart/{ds2401.bin, x76f100.bin, m48t58.bin}
  <game>/
    cd.chd            (or cd.bin + cd.cue)
    flash.bin         (install-type only)
    pccard.bin        (card games only)
    dio_ds2401.bin    (BEMANI only)
    m48t58.bin        (optional)
    security/{ds2401.bin, x76f100.bin | x76f041.bin | zs01.bin}
```

## Notes
- **Endianness / layout:** I'll match each blob to how its module expects it
  (e.g. DS2401 byte order, EEPROM page layout). If a dump's layout is ambiguous
  I'll cross-check against MAME's loader for that device.
- **CD:** CHD preferred (I extract sectors with `chdman`); BIN/CUE also fine.
- **Security data:** if you only have the MAME nvram/romset blobs, drop them as-is
  and tell me — I'll split/convert them into the files above.
- Nothing here is committed; see `.gitignore`.

---

## What's in this checkout (Present / Missing)

Staged from the two source archives (`sys573.zip`, `konami-system-573-redump.zip`,
both kept here and git-ignored).

**Present:**
| Path | Source | Notes |
|------|--------|-------|
| `bios/573.bin` | `sys573.zip` → `700a01.22g` | standard 512 KB 573 boot BIOS |
| `bios/700a01.22g`, `700b01.22g` | `sys573.zip` | raw BIOS revs (a/b) |
| `bios/700a01(gchgchmp).22g` | `sys573.zip` | **Gachaga Champ game-in-BIOS** — POSTs and boots its built-in game with **no CD and no security cart**, so CPU+video bring-up can start before any security dump exists |
| `bios/h8a01.bin`, `h8b01.bin` | `sys573.zip` | 64 B H8 MCU dumps |
| `bishi/cd.bin` + `cd.cue` | redump → *Hyper Bishi Bashi Champ (World)* | first-target disc (Phase 5); cue rewritten to reference `cd.bin` |
| `mame573/*.zip` | MAME `ksys573` romsets | **raw security-cart source** — each zip holds a game's security cassette (X76/ZS01 EEPROM + DS2401 id). Not yet split into per-game `security/*.bin`; that happens per title at bring-up. See "Extracting cart data" below. |

`mame573/` currently holds: `ddr2m, ddr3mk, ddr3mp, ddr4m, ddr4mp, ddr4mps, ddr4ms,
ddr5m, ddrextrm, ddrmax, ddrmax2, ddrs2k, ddrsbm` (DDR-family carts). Of these, only
`ddr3mk` (3rd Mix), `ddr3mp` (3rd Mix Plus), `ddr2m` (→ Club Kit/2nd-Mix-you) and
`ddrsbm` (Solo Bass Mix) have a matching disc in the Redump set so far; the rest are
valid 573 carts without a local CD yet. These are **MAME merged-set** zips (a parent
zip also contains its clones). Source: archive.org `mame-0.221-roms-merged`.

> **Only System 573 romsets belong in `mame573/`.** Verify a candidate against MAME's
> `konami/ksys573.cpp` (it must appear in a `GAME(...)` line there) before adding it.
> Non-573 look-alikes that have been rejected: `ddribble` (Double Dribble, 1986 ROM
> board), `ddrdismx`/`ddrfammt`/`ddrstraw` (DDR plug-and-play TV games — single 2 MB
> ROM, not 573).

## Extracting cart data from a `mame573/` romset

Each romset zip contains the cassette EEPROM + DS2401 id as MAME ROM files (sizes are
the tell: `0x84`=X76F100, `0x224`=X76F041, `0x8c`=ZS01; an `0x8`-byte file = DS2401).
At bring-up for a given title, unzip it and map those files into the device names the
core expects under `dumps/<slug>/security/` (`ds2401.bin`, `x76f100.bin` /
`x76f041.bin` / `zs01.bin`), cross-checking layout against MAME's loader for that
device. Most cassette files are flagged `baddump` in MAME — that is normal for the 573
and they still work.

**Missing — must be sourced from a MAME `ksys573` romset / nvram (not in Redump CDs
or the BIOS set):**
| Path | What | Needed for |
|------|------|-----------|
| `bios/cart/ds2401.bin`, `bios/cart/x76f100.bin` | a master security cart the BIOS trusts | BIOS POST past the security check (Phase 3) |
| `bishi/security/ds2401.bin`, `bishi/security/x76f100.bin` | Bishi's per-game cart | booting Bishi (Phase 5) |
| `<game>/security/*`, `<game>/m48t58.bin` | per-game security + RTC/NVRAM | each title as it comes up |

> Until the cart dumps arrive, use `700a01(gchgchmp).22g` as the BIOS to exercise
> the PSX core + fabric (CPU fetch, video, watchdog, RTC, ASIC I/O) without a
> security handshake.

## Redump disc → slug map

The full set lives in `konami-system-573-redump.zip`; only Bishi is extracted (disk).
Extract any other on demand:

```sh
unzip -p konami-system-573-redump.zip "<exact disc name>.zip" > /tmp/g.zip
mkdir -p dumps/<slug> && unzip /tmp/g.zip -d dumps/<slug>/
# then rename the BIN/CUE to cd.bin/cd.cue and fix the cue's FILE line
```

Roles drive which peripherals a title exercises. **Confirm the exact security chip
(X76F100 / X76F041 / ZS01) and DIO-board use per game against MAME's
`konami/ksys573.cpp` before relying on it** — grouped here by behaviour, not asserted
per-disc.

| Slug | Disc | Role |
|------|------|------|
| `bishi` | Hyper Bishi Bashi Champ (World) | plain — JAMMA + CD, X76F100 (**first target, extracted**) |
| `darkhorse` | Dark Horse Legend (Japan) | plain |
| `salaryman` | Salaryman Champ - Tatakau Salaryman (Japan) | plain |
| `ppex` | Jikkyou Powerful Pro Yakyuu EX (Japan) | plain |
| `ppex98` | Jikkyou Powerful Pro Yakyuu EX '98 (Japan) | plain |
| `bassangler` | Bass Angler (Japan) | analog I/O board (ADC) + fishing controller |
| `fishbait_uaa` | Fisherman's Bait - A Bass Challenge (USA) (UAA) | analog I/O board |
| `fishbait_uab` | Fisherman's Bait - A Bass Challenge (USA) (UAB) | analog I/O board |
| `fishbait_marlin` | Fisherman's Bait - Marlin Challenge (World) | analog I/O board |
| `punchmania` | Punch Mania - Hokuto no Ken 2 ... (Japan) | special I/O (punch sensors) |
| `mambo` | Mambo a Go Go (Japan) | BEMANI — DIO board + MP3 |
| `ddr3_jp` | Dance Dance Revolution 3rd Mix (Japan) | BEMANI MP3 (Phase 9 candidate) |
| `ddr3_asia` | Dance Dance Revolution 3rd Mix (Asia) | BEMANI MP3 |
| `ddr3_kor` | Dance Dance Revolution 3rd Mix - Ver. Korea 2 (Korea) | BEMANI MP3 |
| `ddr3plus` | Dance Dance Revolution 3rd Mix Plus (Japan) | BEMANI MP3 |
| `ddr_irkit` | Dance Dance Revolution - Internet Ranking Kit (Japan) | BEMANI MP3 |
| `ddr_solobass` | Dance Dance Revolution Solo - Bass Mix (Japan) | BEMANI MP3 |
| `ddr_clubkit` | Dance Dance Revolution Club Kit ... 2nd Mix-you (Japan) | BEMANI MP3 |
| `dancingstage_tkd` | Dancing Stage featuring True Kiss Destination (Japan) | BEMANI MP3 |
| `gf1` | GuitarFreaks (World) | BEMANI MP3 |
| `gf2` | GuitarFreaks 2nd Mix (Japan) | BEMANI MP3 |
| `gf3` | GuitarFreaks 3rd Mix (Japan) | BEMANI MP3 |
| `gf4` | GuitarFreaks 4th Mix (Japan) | BEMANI MP3 |
| `gf5` | GuitarFreaks 5th Mix (Japan) | BEMANI MP3 |
| `gf8` | GuitarFreaks 8th Mix - Power-Up Ver. (Japan) | BEMANI MP3 |
| `gf9` | GuitarFreaks 9th Mix (Japan) | BEMANI MP3 |
| `gf10` | GuitarFreaks 10th Mix (Japan) (e-Amusement Disc) | BEMANI MP3 |
| `gf_linkkit1` | GuitarFreaks Link Kit 1 (Japan) (Memory Card Taiou) | BEMANI MP3 |
| `dm1` | DrumMania (Japan) | BEMANI MP3 |
| `dm2` | DrumMania 2nd Mix (Japan) | BEMANI MP3 |
| `dm6` | DrumMania 6th Mix (Japan) | BEMANI MP3 |
| `dm6_multi` | DrumMania 6th Mix (Japan) (MultiSession) | BEMANI MP3 |
| `dm8` | DrumMania 8th Mix (Japan) | BEMANI MP3 |
| `dm8_multi` | DrumMania 8th Mix (Japan) (MultiSession) | BEMANI MP3 |
| `dm9_game` | DrumMania 9th Mix (Japan) (Game Disc) | BEMANI MP3 |
| `dm9_multi` | DrumMania 9th Mix (Japan) (MultiSession Disc) | BEMANI MP3 |
| `dm9_eamuse` | DrumMania 9th Mix (Japan) (e-Amusement Disc) | BEMANI MP3 |
| `dm9_update` | DrumMania 9th Mix (Japan) (Update Disc) | update/patch disc |
| `dm10_app` | DrumMania 10th Mix (Japan) (Application Disc) | BEMANI MP3 |
| `dm10_multi` | DrumMania 10th Mix (Japan) (MultiSession Disc) | BEMANI MP3 |
| `dm10_eamuse` | DrumMania 10th Mix (Japan) (e-Amusement Disc) | BEMANI MP3 |
| `gfdm_session2` | Session Power Up Kit for DrumMania 2nd / PercussionFreaks 2nd (Japan, Asia) | BEMANI MP3 |
| `gx700_updater` | GX700 Series CD-ROM Drive Updater (World) | utility — CD drive firmware, not a game |
| `gx700_updater2` | GX700 Series CD-ROM Drive Updater 2.0 (World) | utility — CD drive firmware, not a game |
