# Headless MENU-core navigation (DE10/MiSTer, no human at the controls)

Proven 2026-06-11 on `de10` (fresh boot -> MENU -> launched
`_Console/hyperbbc (573, console).mgl` purely via the virtual keyboard;
`/tmp/CORENAME` flipped `MENU` -> core at the final ENTER).

## The primitive

`tools/mister_press.py` (runs ON the board, stdlib python3) `key` mode now takes
a comma-separated SEQUENCE pressed on ONE virtual uinput keyboard — one ~6 s
enumeration wait total, `--gap` seconds between presses:

```sh
scp tools/mister_press.py de10:/tmp/mister_press.py
ssh de10 'python3 /tmp/mister_press.py key f12,home,down,down,enter,h,enter --gap 1.2'
```

Single keys work too: `key f12`, `key up`, `key down`, `key enter`, `key esc`,
`key home` (full table in the script: F1-F12, arrows, nav cluster, letters,
digits, modifiers; combos like `alt+f1` still work; raw codes `0x..` too).

## The exact working sequence (root -> _Console -> hyperbbc .mgl)

Board state: fresh boot parked in MENU core (`/tmp/CORENAME` == `MENU`).

```
key f12,home,down,down,enter,h,enter   --gap 1.2
    f12    open the file browser OSD
    home   normalize cursor to the TOP entry (Arcade)
    down   -> Computer
    down   -> Console          (sort: Arcade, Computer, Console,
                                Console (autoboot), LLAPI, Other, Utility —
                                "_Console" sorts BEFORE "_Console (autoboot)":
                                NUL < space)
    enter  enter _Console (cursor lands on the top entry)
    h      letter-jump to the first H entry = "hyperbbc (573, console).mgl"
           (verify it is the ONLY h/H entry first: ls /media/fat/_Console/)
    enter  launch the .mgl
```

Then poll the state byte (12-30 s for rbf + mgl file uploads):

```sh
until [ "$(ssh de10 cat /tmp/CORENAME)" != "MENU" ]; do sleep 5; done
```

## Gotchas (all hit while proving this)

1. **Screenshots NEVER show the OSD.** `echo screenshot > /dev/MiSTer_cmd`
   captures the scaler framebuffer BEFORE the OSD overlay is composited. You
   cannot see the browser/cursor in any capture — navigation is blind.
   Plan deterministic sequences (HOME to normalize, letter-jump to address by
   name) and verify by STATE BYTES (`/tmp/CORENAME`, `/tmp/RBFNAME`), never by
   screenshot.
2. **The MENU background is ANIMATED dither** — two no-press screenshots 3 s
   apart differ by ~50 % of pixels (measured 50.02 %). A whole-frame pixel diff
   can NOT prove a keypress registered (our F12 press measured 51.04 % — same
   as the no-press control). Registration proof = a state change
   (`/tmp/CORENAME` flip) or a controlled-region diff, not raw %pixels.
3. **CONF_STR name gotcha:** the 573 core's CONF_STR begins `"PSX;..."`
   (rtl/emu.sv) — loaded via .mgl/console path, `/tmp/CORENAME` and
   `/tmp/RBFNAME` both read **`PSX`**, NOT `Konami_System_573`/`hyperbbc573`
   (those names only appear for .mra arcade loads, from `<setname>`).
   `CORENAME==PSX` after launching the hyperbbc .mgl is SUCCESS, but it is
   ambiguous with the real `PSX_20250825.rbf` sitting in the same folder —
   disambiguate by behavior (video/VRAM numbers) if it matters.
4. **Keyboard enumeration needs the ~6 s `--pre` wait** before the first press
   (same as the gamepad mode). `--gap 1.2` between presses was reliable.
5. The reboot path is `dell_coord.sh devlock de10` only, and a devlock-issued
   restart WIPES the on-board lock — re-acquire after the board returns.

## Fallback (untested tonight — keyboard worked first try)

If keyboard keys ever stop registering, the same script's GAMEPAD mode is the
fallback: dpad = ABS_X/ABS_Y (extend with axis presses), face buttons
`b1..b4`/`start`/`coin` already work (`python3 /tmp/mister_press.py b3` = A).
MENU treats gamepad A as ENTER, B as back.

## UPDATE (2026-06-11 night): load_core of a .mgl IS the primary headless path
Contrary to the earlier session's finding, `echo "load_core /media/fat/_Console/x.mgl" \
> /dev/MiSTer_cmd` DOES process the .mgl <file> loads on the de10's installed Main
(proven: CORENAME flip + screenshots named after the mgl's last file + the 573 BIOS
on screen). The key-nav sequence above FAILED on re-test (keys delivered, Main opened
the device, no CORENAME flip) — treat key-nav as the unreliable fallback and
load_core-of-mgl as the deterministic headless launch. May be Main-version-dependent;
re-verify per board.
