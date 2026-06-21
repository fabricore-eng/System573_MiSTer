#!/usr/bin/env bash
# =============================================================================
# mame_capture.sh -- System 573 MAME REFERENCE PRODUCER (display frame + VRAM)
#                    for the A/V evaluation tooling suite (framebuffer-diff
#                    pillar, AV_EVAL_TOOLING_SPEC.md section 6).
#
# WHAT IT IS. A thin, 573-specific wrapper over the SHARED hub MAME-on-dell
# runner (~/Dev/tools/tools/mame_dell.sh) so reference capture runs on
# the headless `dell` box, OFF the Mac (MAME on the Mac steals input/focus and
# competes with the human's own workstation use; see mame573.sh). It produces the
# objective ground-truth artifacts the framebuffer diff compares OUR core's
# render against:
#
#   local/<prefix>.png        MAME's NATIVE-resolution display frame (e.g. 368x240
#                             or 320x240 -- the active GPU display window, NO host
#                             downscale), 8bpc RGB PNG = the CORRECT render.
#   local/<prefix>_vram.bin   MAME GPU VRAM, raw 1024x1024x2 = 2097152 bytes,
#                             RGB555 LE, 1024 px/row, stride 2048 (the displayed
#                             PSX framebuffer is rows 0..511). Byte-comparable
#                             with our core's HW VRAM dumps (mister_vram_dump.sh).
#
# It writes a lua autoboot script that, at a target frame near the end of the
# run, calls machine.video:snapshot() (native res) AND dumps the GPU 'p_vram'
# save-item via emu.item(...):read_block(0, 1048576*2), copying BOTH to known
# /tmp/<prefix>.* paths that the hub runner then pulls back into ./local/.
#
# Usage:
#   tools/mame_capture.sh <emulated_seconds> <out_prefix> [<extra_lua_optional>]
#     emulated_seconds : MAME -seconds_to_run (the emulated boot time to reach
#                        the scene you want -- e.g. ~60-90s to reach the title).
#     out_prefix       : basename for the outputs -> local/<prefix>.png +
#                        local/<prefix>_vram.bin. (No path; no extension.)
#     extra_lua        : OPTIONAL path to a lua file whose body is appended to
#                        the generated capture lua (e.g. extra item dumps). The
#                        capture logic still runs; the extra lua just rides along.
#
#   Optional ENV:
#     MAME_CAP_FRAME   : explicit target frame number to capture at (DECIMAL).
#                        Default = floor(emulated_seconds * 60) - 3, i.e. just
#                        before the run ends (the steady scene). If the run ends
#                        before this frame, capture fires once at machine stop.
#
# Examples:
#   # Capture hyperbbc's title scene at ~75 emulated seconds:
#   tools/mame_capture.sh 75 mame_title
#     -> local/mame_title.png (native frame) + local/mame_title_vram.bin (2 MB)
#
#   # Capture a specific frame:
#   MAME_CAP_FRAME=4200 tools/mame_capture.sh 75 mame_title
#
# SELF-TEST (no MAME, no dell):
#   tools/mame_capture.sh --selftest
#     -> validates arg parsing + that the hub runner exists & is executable;
#        prints "SELFTEST PASS" and exits 0. (Proves the wrapper logic on
#        synthetic args without touching MAME.)
#
# NB on MAME snapshots (verified live on dell, MAME 0.285):
#   * machine.video:snapshot() writes into <snapshot_directory>/<rom>/NNNN.png at
#     MAME's NATIVE display resolution (256x240 / 320x240 / 368x240 as the GPU
#     display window dictates) -- it does NOT honor a path argument in 0.285, so
#     the lua reads the snapshot_directory option, grabs the newest PNG it just
#     produced, and copies it to /tmp/<prefix>.png (done INSIDE the same frame
#     callback, before MAME's exit auto-snapshot, so the newest file is ours).
#   * The GPU VRAM item is items["0/p_vram"] (a save-item HANDLE/index in 0.285);
#     the readable object is emu.item(handle), then :read_block(0, 1048576*2).
# =============================================================================
set -euo pipefail

PROG="$(basename "$0")"
HUB_RUNNER="${MISTER_HUB:-$HOME/Dev/tools}/tools/mame_dell.sh"
# The 573-specific MAME-on-dell wrapper (fills romset/rompath); we shell to the
# hub runner directly so we control the exact outfile list + lua.
ROMSET="${ROMSET:-hyperbbc}"          # env-overridable: capture any 573 romset (e.g. ROMSET=konam80s)
ROMPATH="${ROMPATH:-dumps/mame573;dumps}"
DELL_REPO="${DELL_REPO:-System573_MiSTer}"

# ---------------------------------------------------------------------------
# --selftest : prove arg parsing + hub-runner presence on synthetic data.
#   No MAME, no dell, no network. Exits 0 with "SELFTEST PASS".
#   Defined as a function so it runs AFTER gen_lua is defined (bash needs the
#   function defined/executed before it can be called); dispatched at the end.
# ---------------------------------------------------------------------------
do_selftest() {
  fail=0
  echo "== mame_capture.sh --selftest =="

  # (1) hub runner must exist and be executable.
  if [ -x "$HUB_RUNNER" ]; then
    echo "  [ok] hub runner present + executable: $HUB_RUNNER"
  else
    echo "  [FAIL] hub runner missing or not executable: $HUB_RUNNER"; fail=1
  fi

  # (2) arg-parsing: simulate the default-target-frame computation for a few
  #     (secs) values and assert it matches floor(secs*60)-3.
  for s in 1 6 75 90; do
    got=$(awk -v s="$s" 'BEGIN{ f=int(s*60)-3; if(f<0)f=0; print f }')
    exp=$(python3 - "$s" <<'PY'
import sys,math
s=float(sys.argv[1]); f=int(math.floor(s*60))-3
print(max(f,0))
PY
)
    if [ "$got" = "$exp" ]; then
      echo "  [ok] default frame for secs=$s -> $got"
    else
      echo "  [FAIL] default frame for secs=$s: got=$got exp=$exp"; fail=1
    fi
  done

  # (3) arg-count validation: too few args must be rejected.
  #     (We exercise the same guard the live path uses, in a subshell.)
  if ( set -- ; [ "$#" -lt 2 ] ); then
    echo "  [ok] arg-count guard: <2 positional args is rejected"
  else
    echo "  [FAIL] arg-count guard broken"; fail=1
  fi

  # (4) prefix sanitization: a prefix with a slash/space must be rejected.
  bad_prefix="a/b c"
  if printf '%s' "$bad_prefix" | grep -qE '[^A-Za-z0-9._-]'; then
    echo "  [ok] prefix sanitizer flags unsafe prefix '$bad_prefix'"
  else
    echo "  [FAIL] prefix sanitizer failed"; fail=1
  fi

  # (5) emit a sample lua to a temp file and assert it contains the load-bearing
  #     API calls (snapshot + p_vram read_block) -- proves the generator works.
  tmp_lua="$(mktemp -t mamecap_selftest_XXXX.lua)"
  gen_lua "$tmp_lua" "selftest" "120" ""
  if grep -q 'machine.video:snapshot()' "$tmp_lua" \
     && grep -q '0/p_vram' "$tmp_lua" \
     && grep -q 'read_block(0, 1048576\*2)' "$tmp_lua"; then
    echo "  [ok] generated lua contains snapshot + p_vram read_block(0,1048576*2)"
  else
    echo "  [FAIL] generated lua missing required API calls"; fail=1
  fi
  rm -f "$tmp_lua"

  if [ "$fail" = 0 ]; then echo "SELFTEST PASS"; return 0
  else echo "SELFTEST FAIL"; return 1; fi
}

# ---------------------------------------------------------------------------
# gen_lua <out_lua_path> <prefix> <target_frame> <extra_lua_path_or_empty>
#   Writes the capture autoboot lua. Defined as a function so --selftest can
#   exercise it without running MAME.
# ---------------------------------------------------------------------------
gen_lua() {
  local out="$1" prefix="$2" target="$3" extra="$4"
  local png_dest="/tmp/${prefix}.png"
  local vram_dest="/tmp/${prefix}_vram.bin"
  local info_dest="/tmp/${prefix}.info.txt"

  cat > "$out" <<LUA
-- =============================================================================
-- mame_capture autoboot lua (GENERATED by tools/mame_capture.sh) -- prefix=${prefix}
-- At target frame ${target} (or at machine stop if never reached) it:
--   1. machine.video:snapshot()      -> native-res PNG, copied to ${png_dest}
--   2. emu.item(gpu '0/p_vram'):read_block(0, 1048576*2) -> ${vram_dest} (2 MB)
--   3. writes a small ${info_dest} (frame/w/h) for provenance.
-- Verified API on MAME 0.285 (dell): snapshot() ignores its path arg, writes
-- into <snapshot_directory>/<rom>/NNNN.png; p_vram is a save-item HANDLE indexed
-- through emu.item(); read_block(0, 1048576*2) == exactly 2097152 bytes.
-- =============================================================================
local TARGET   = ${target}
local PNG_DEST  = "${png_dest}"
local VRAM_DEST = "${vram_dest}"
local INFO_DEST = "${info_dest}"
local fired = false

-- Resolve the rom name (snapshot subdir) and the snapshot directory.
local function romname()
  local ok, n = pcall(function() return manager.machine.system.name end)
  if ok and n then return n end
  return "${ROMSET}"
end
local function snapdir()
  local ok, v = pcall(function()
    return manager.options.entries["snapshot_directory"]:value()
  end)
  if ok and v and v ~= "" then return v end
  return "snap"  -- MAME default relative dir
end

-- newest *.png in <snapdir>/<rom>/ by mtime (the file snapshot() just wrote).
local function newest_png()
  local dir = snapdir() .. "/" .. romname()
  local p = io.popen("ls -t '" .. dir .. "'/*.png 2>/dev/null | head -1")
  if p == nil then return nil end
  local line = p:read("*l"); p:close()
  return line
end

local function copyfile(src, dst)
  if src == nil then return false, 0 end
  local i = io.open(src, "rb"); if i == nil then return false, 0 end
  local d = i:read("*a"); i:close()
  local o = io.open(dst, "wb"); if o == nil then return false, 0 end
  o:write(d); o:close()
  return true, #d
end

local function current_screen()
  for _, s in pairs(manager.machine.screens) do return s end
  return nil
end

-- The capture itself (idempotent; runs once).
local function capture(reason)
  if fired then return end
  fired = true
  local info = io.open(INFO_DEST, "w")
  local function L(s)
    if info then info:write(s .. "\n") end
    pcall(function() manager.machine:logerror("[mame_capture] " .. s .. "\n") end)
  end
  L("capture reason=" .. tostring(reason) .. " target_frame=" .. TARGET)

  -- (1) native-res display snapshot -> copy newest produced PNG to PNG_DEST.
  local scr = current_screen()
  if scr ~= nil then
    L("screen w=" .. tostring(scr.width) .. " h=" .. tostring(scr.height) ..
      " frame=" .. tostring(scr:frame_number()))
  end
  local sok = pcall(function() manager.machine.video:snapshot() end)
  L("snapshot() ok=" .. tostring(sok))
  local src = newest_png()
  local cok, clen = copyfile(src, PNG_DEST)
  L("png src=" .. tostring(src) .. " copied=" .. tostring(cok) .. " bytes=" .. clen)

  -- (2) GPU VRAM dump -> VRAM_DEST (2097152 bytes).
  local vok = pcall(function()
    local handle = manager.machine.devices[":gpu"].items["0/p_vram"]
    local it = emu.item(handle)
    local data = it:read_block(0, 1048576*2)
    local vf = io.open(VRAM_DEST, "wb"); vf:write(data); vf:close()
    L("vram bytes=" .. tostring(#data) .. " (expect 2097152)")
  end)
  L("vram dump ok=" .. tostring(vok))
  if info then info:close() end
end

-- Fire at the target frame; fall back to machine-stop if never reached.
local function on_frame()
  local scr = current_screen()
  if scr == nil then return end
  if (not fired) and scr:frame_number() >= TARGET then
    capture("target_frame")
  end
end
emu.register_frame_done(on_frame)
if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function() capture("machine_stop") end)
end

LUA

  # Append the optional extra lua body (rides along; capture still runs).
  if [ -n "$extra" ]; then
    if [ -f "$extra" ]; then
      {
        echo ""
        echo "-- ---- appended extra lua: $extra ----"
        cat "$extra"
      } >> "$out"
    else
      echo "warning: extra lua not found, ignoring: $extra" >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# Dispatch --selftest now that gen_lua is defined (it exercises gen_lua).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  do_selftest
  exit $?
fi

# ---------------------------------------------------------------------------
# Live path: parse args, generate lua, invoke the hub runner, verify outputs.
# ---------------------------------------------------------------------------
if [ "$#" -lt 2 ]; then
  echo "usage: $PROG <emulated_seconds> <out_prefix> [<extra_lua>]" >&2
  echo "       $PROG --selftest" >&2
  exit 1
fi

SECS="$1"; PREFIX="$2"; EXTRA="${3:-}"

# secs must be a positive number.
if ! printf '%s' "$SECS" | grep -qE '^[0-9]+([.][0-9]+)?$'; then
  echo "error: emulated_seconds must be a positive number, got: $SECS" >&2
  exit 1
fi
# prefix must be a safe basename (no slashes/spaces) -- it becomes /tmp + local paths.
if printf '%s' "$PREFIX" | grep -qE '[^A-Za-z0-9._-]'; then
  echo "error: out_prefix must be [A-Za-z0-9._-] only (no path/space), got: $PREFIX" >&2
  exit 1
fi

# Default target frame = floor(secs*60)-3 (just before the run ends), unless
# MAME_CAP_FRAME overrides it.
if [ -n "${MAME_CAP_FRAME:-}" ]; then
  TARGET="$MAME_CAP_FRAME"
  if ! printf '%s' "$TARGET" | grep -qE '^[0-9]+$'; then
    echo "error: MAME_CAP_FRAME must be a non-negative integer, got: $TARGET" >&2
    exit 1
  fi
else
  TARGET=$(awk -v s="$SECS" 'BEGIN{ f=int(s*60)-3; if(f<0)f=0; print f }')
fi

# The hub runner must exist (live path needs it).
if [ ! -x "$HUB_RUNNER" ]; then
  echo "error: hub runner not found/executable: $HUB_RUNNER" >&2
  echo "       (expected the shared tools mame_dell.sh)" >&2
  exit 1
fi

PNG_OUT="${PREFIX}.png"
VRAM_OUT="${PREFIX}_vram.bin"
INFO_OUT="${PREFIX}.info.txt"
LUA_FILE="$(mktemp -t mame_capture_${PREFIX}_XXXX.lua)"
trap 'rm -f "$LUA_FILE"' EXIT

gen_lua "$LUA_FILE" "$PREFIX" "$TARGET" "$EXTRA"

echo "== mame_capture: rom=$ROMSET secs=$SECS prefix=$PREFIX target_frame=$TARGET =="
echo "   lua=$LUA_FILE"
echo "   -> local/$PNG_OUT (native frame) + local/$VRAM_OUT (2 MB VRAM)"

# Invoke the SHARED hub runner: it scp's the lua to dell, runs MAME headless,
# and pulls each named /tmp/<file> back into ./local/. Run from the repo root so
# ./local/ resolves correctly. We pull the PNG, the VRAM, and the info sidecar.
"$HUB_RUNNER" "$DELL_REPO" "$ROMSET" "$ROMPATH" "$LUA_FILE" "$SECS" \
  "$PNG_OUT" "$VRAM_OUT" "$INFO_OUT"

# Verify the two primary artifacts came back and are well-formed.
rc=0
PNG_LOCAL="local/$PNG_OUT"
VRAM_LOCAL="local/$VRAM_OUT"

if [ -f "$PNG_LOCAL" ]; then
  # PNG magic = 89 50 4E 47.
  if [ "$(head -c8 "$PNG_LOCAL" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    dims="$( (command -v file >/dev/null && file "$PNG_LOCAL" | sed -n 's/.*PNG image data, \([0-9]* x [0-9]*\).*/\1/p') || true )"
    echo "  [ok] $PNG_LOCAL is a valid PNG ${dims:+($dims)}"
  else
    echo "  [FAIL] $PNG_LOCAL is not a valid PNG"; rc=1
  fi
else
  echo "  [FAIL] $PNG_LOCAL not produced"; rc=1
fi

if [ -f "$VRAM_LOCAL" ]; then
  sz="$(wc -c < "$VRAM_LOCAL" | tr -d ' ')"
  if [ "$sz" = "2097152" ]; then
    echo "  [ok] $VRAM_LOCAL is $sz bytes (1024x1024x2 RGB555)"
  else
    echo "  [FAIL] $VRAM_LOCAL is $sz bytes (expected 2097152)"; rc=1
  fi
else
  echo "  [FAIL] $VRAM_LOCAL not produced"; rc=1
fi

if [ "$rc" = 0 ]; then echo "CAPTURE OK"; else echo "CAPTURE INCOMPLETE"; fi
exit $rc
