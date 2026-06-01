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
