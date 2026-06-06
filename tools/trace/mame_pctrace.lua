-- =============================================================================
-- mame_pctrace.lua -- MAME 0.288 PC-trace PRODUCER for the System 573 game
--                     hyperbbc, emitting the hub trace_diff.py format so a MAME
--                     "golden" run can be diffed against our core's sim/HW trace.
--
-- WHAT IT PRODUCES (line-oriented ASCII, one record per RETIRED instruction):
--     i=<decimal seq> pc=<8-hex>                          <- the PC stream
--   '#'-prefixed lines are comments/metadata. Hex is lower-case, zero-padded to 8.
--   This is exactly the (PC-only) format consumed by:
--     /Users/human/Dev/mister-dev-hub/tools/trace_diff.py
--   trace_diff is designed to work PC-only (reg columns are an OPTIONAL tie-break
--   used only when BOTH sides supply them), so a PC stream diffs cleanly against
--   our core's PC stream.
--
--   *** WHY PC-ONLY (no v0/a1/sp columns) -- this is deliberate, verified: ***
--   MAME 0.288's native `trace` engine is the only fast per-instruction emitter
--   (the 0.288 lua API has NO per-instruction hook -- no emu.register_instruction,
--   no cpu.debug:set_instruction_hook). Its `tracelog` action CAN format extra
--   columns from debugger expression symbols, BUT on this build those symbols do
--   NOT read the architectural register file at the retired-instruction boundary:
--     - `sp` aliases the PC (mirrors pc exactly), and
--     - `v0`/`a1` read STALE values -- verified at pc=803c1a54 the tracelog gave
--       v0=3c080013 a1=00000000 while the CPU state interface (ground truth) had
--       v0=3c05a001 a1=97b9c8e7.
--   Emitting wrong regs is WORSE than none: trace_diff would treat them as an
--   architectural-state mismatch and false-flag a HARD divergence. So we emit the
--   trustworthy PC stream only. (Correct regs would need a per-instruction lua
--   hook reading cpu.state[name].value -- not available in 0.288. If a future
--   MAME exposes set_instruction_hook, read v0/a1/sp from cpu.state there and
--   append ' v0=.. a1=.. sp=..' to each record; the format already allows it.)
--
-- ---------------------------------------------------------------------------
-- HOW TO RUN (the exact invocation -- run from the repo root
--   /Users/human/Dev/System573_MiSTer so the relative -rompath resolves):
--
--   MAME's lua needs the DEBUGGER enabled to drive the native `trace` engine,
--   so we pass `-debug -debugger none` (enables debug hooks WITHOUT opening the
--   interactive GUI -- headless). Modeled on the project's MAME oracle invocation
--   (mame-reference-oracle.md): `mame hyperbbc -rompath "dumps/mame573;dumps"
--   -video none -sound none -autoboot_script <lua>`.
--
--     mame hyperbbc -rompath "dumps/mame573;dumps" \
--       -skip_gameinfo -video none -sound none \
--       -debug -debugger none \
--       -seconds_to_run 80 \
--       -autoboot_script tools/trace/mame_pctrace.lua
--
--   The trace lands in $HBBC_TRACE_OUT (default /tmp/mame_hbbc_pctrace.log).
--   NB: MAME runs ~6x slower than realtime here, so -seconds_to_run 80 ~ 8 min
--   wall. The post-processing/windowing happens when the machine stops.
--
--   Tunables are read from ENV VARS (all optional -- sane defaults below):
--     HBBC_TRACE_OUT    output file            (default /tmp/mame_hbbc_pctrace.log)
--     HBBC_TRACE_RAW    raw native-trace temp  (default /tmp/mame_hbbc_raw.trace)
--     HBBC_TRACE_START  window-start PC (HEX, 0x optional). Logging begins the
--                       first time pc enters [START, START_HI). Default 80010000
--                       = the game EXE / flash-check region in KSEG0 RAM (skips
--                       the BIOS and the low 8000_0080 exception trampoline).
--                       Set to "0" to log from the very first traced instruction.
--     HBBC_TRACE_START_HI upper bound of the start region (HEX). Default 80200000.
--     HBBC_TRACE_MAX    stop after this many EMITTED records, DECIMAL (default
--                       2000000). (START/START_HI/STOPPC are HEX; MAX is DECIMAL.)
--     HBBC_TRACE_STOPPC optional stop PC (HEX): stop emitting the first time this
--                       pc is reached AFTER the window opened. Default unset.
--                       (e.g. the red-N self-test branch 8015d2d4, or the
--                       post-NVRAM dispatcher state at 8015cf88.)
--
--   Example -- window from the dispatcher, stop at the red-N branch, 500k cap:
--     HBBC_TRACE_START=8015cf88 HBBC_TRACE_STOPPC=8015d2d4 HBBC_TRACE_MAX=500000 \
--       mame hyperbbc -rompath "dumps/mame573;dumps" -skip_gameinfo \
--       -video none -sound none -debug -debugger none -seconds_to_run 80 \
--       -autoboot_script tools/trace/mame_pctrace.lua
--
--   Then diff against our core's trace:
--     ~/Dev/mister-dev-hub/tools/trace_diff.py /tmp/mame_hbbc_pctrace.log OUR.log
--
-- ---------------------------------------------------------------------------
-- SIMPLER ALTERNATIVE (the raw one-liner the spec asks me to document):
--   The MAME debugger's built-in `trace` command logs every retired instruction
--   natively and FAST. The bare command (from the debugger console, or via a
--   `-debugscript` file containing this one line) is:
--
--       trace /tmp/native.trace,:maincpu
--
--   ...but its output is "PC: <disassembly>" (e.g. "80010000: addiu sp,sp,..."),
--   NOT the i=/pc= format, and it is UNBOUNDED (millions of lines). To feed
--   trace_diff you would still post-convert it (gawk, for strtonum):
--
--       gawk -F: '{printf "i=%d pc=%08x\n",NR-1,strtonum("0x"$1)}' /tmp/native.trace
--
--   This script does that conversion itself, in pure lua (portable -- macOS/BSD
--   awk lacks strtonum), AND applies the window (start-region / max-count /
--   stop-pc) the bare command cannot. Use the one-liner for a quick raw dump;
--   use THIS script for a bounded, exactly-formatted, diff-ready trace.
--
-- ---------------------------------------------------------------------------
-- VERIFIED MAME 0.288 lua API facts (all confirmed on this box):
--   * `:maincpu` resolves to a `cxd8530cq` device (the PS1 R3000A / psxcpu);
--     its only address space is named `program`.  (If a tag mismatch ever
--     occurs, change the ':maincpu' in the trace command + the cpu lookup.)
--   * No per-instruction lua hook exists -> we use the native `trace` engine,
--     which requires `-debug -debugger none`.
--   * emu.register_prestart / emu.register_frame_done / emu.add_machine_stop_
--     notifier exist; emu.register_start does NOT.
--   * manager.machine.debugger:command(str) executes a console command;
--     .execution_state = "run" releases the debugger's initial pause.
-- =============================================================================

----------------------------------------------------------------------------
-- config (env with defaults)
----------------------------------------------------------------------------
local function env(name, default)
  local v = os.getenv(name); if v == nil or v == "" then return default end; return v
end
local function hexenv(name, default) -- HEX-valued env -> integer (default already int)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  v = v:gsub("^0[xX]", "")              -- accept optional 0x prefix; value is HEX
  return tonumber(v, 16) or default
end
local function decenv(name, default) -- DECIMAL-valued env -> integer (counts)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return tonumber(v, 10) or default
end

local OUT       = env("HBBC_TRACE_OUT", "/tmp/mame_hbbc_pctrace.log")
local RAW       = env("HBBC_TRACE_RAW", "/tmp/mame_hbbc_raw.trace")
local START     = hexenv("HBBC_TRACE_START", 0x80010000)   -- 0 => from first insn
local START_HI  = hexenv("HBBC_TRACE_START_HI", 0x80200000)
local MAXREC    = decenv("HBBC_TRACE_MAX", 2000000)        -- DECIMAL record cap
local STOPPC    = os.getenv("HBBC_TRACE_STOPPC")           -- nil if unset
if STOPPC ~= nil and STOPPC ~= "" then STOPPC = (STOPPC:gsub("^0[xX]", ""))
  STOPPC = tonumber(STOPPC, 16) else STOPPC = nil end

----------------------------------------------------------------------------
-- arm the native trace as early as possible
----------------------------------------------------------------------------
local armed = false

local function arm()
  if armed then return end
  armed = true
  local ok, err = pcall(function()
    local dbg = manager.machine.debugger
    if dbg == nil then
      manager.machine:logerror(
        "[pctrace] ERROR: debugger nil -- run with `-debug -debugger none`\n")
      return
    end
    -- Enable the native trace engine on :maincpu into the RAW temp file. We
    -- apply the i=/pc= window (start-region, max-count, stop-pc) in the post-pass.
    dbg:command(string.format('trace %s,:maincpu', RAW))
    dbg.execution_state = "run"          -- release the debugger's initial pause
    manager.machine:logerror(string.format(
      "[pctrace] armed: raw=%s start=%08x..%08x max=%d stoppc=%s\n",
      RAW, START, START_HI, MAXREC,
      STOPPC and string.format("%08x", STOPPC) or "none"))
  end)
  if not ok then
    manager.machine:logerror("[pctrace] arm error: " .. tostring(err) .. "\n")
  end
end

-- prestart is the earliest reliable hook; frame_done is the proven fallback.
if emu.register_prestart then emu.register_prestart(arm) end
emu.register_frame_done(arm)

----------------------------------------------------------------------------
-- run-bounding:
--   The run ends on MAME's `-seconds_to_run` (the natural path -- the machine-
--   stop notifier then fires the post-pass). We additionally bound the RAW file
--   so a long -seconds_to_run cannot fill the disk: a periodic watchdog turns
--   the native trace OFF once the live RAW byte-count exceeds a budget derived
--   from MAXREC. (We intentionally do NOT call machine:exit() from the watchdog
--   -- doing so from inside the debugger-driven periodic was observed to bypass
--   the stop notifier on `-debug`; turning the trace off is enough to cap RAW,
--   and -seconds_to_run still terminates the run cleanly so the post-pass runs.)
----------------------------------------------------------------------------
local RAW_BYTE_BUDGET = (MAXREC + 200000) * 256   -- comfortably > what we'll read
local wd_fired = false
local function watchdog()
  if wd_fired or not armed then return end
  local f = io.open(RAW, "r")
  if f == nil then return end
  local size = f:seek("end"); f:close()
  if size ~= nil and size >= RAW_BYTE_BUDGET then
    wd_fired = true
    pcall(function() manager.machine.debugger:command("trace off,:maincpu") end)
    manager.machine:logerror(string.format(
      "[pctrace] watchdog: raw reached %d bytes (budget %d) -> trace OFF " ..
      "(run will end on -seconds_to_run)\n", size, RAW_BYTE_BUDGET))
  end
end
if emu.register_periodic then emu.register_periodic(watchdog) end

----------------------------------------------------------------------------
-- post-process the RAW native trace -> exact i=/pc= window, on machine stop
----------------------------------------------------------------------------
-- RAW line form (native disasm):  "80010000: addiu   sp,sp,...."
-- The authoritative pc is the leading 8-hex token before the first ':'.

-- mask to 32 bits without the '&' operator (portable across lua builds)
local function tohex8(n) return string.format("%08x", n % 0x100000000) end

local function postprocess_body()
  -- NB: we do NOT issue `trace off` here -- by the machine-stop phase the
  -- debugger may be tearing down, and the native trace flushes per-line anyway,
  -- so the RAW file is already complete. We just read it.
  local rin = io.open(RAW, "r")
  if rin == nil then
    manager.machine:logerror(
      "[pctrace] post: cannot open raw " .. RAW .. " (no trace produced?)\n")
    return
  end
  local out = io.open(OUT, "w")
  if out == nil then
    manager.machine:logerror("[pctrace] post: cannot open out " .. OUT .. "\n")
    rin:close(); return
  end

  out:write("# producer=mame mame_version=0.288 rom=hyperbbc " ..
            "cpu=:maincpu(cxd8530cq/psxcpu) space=program\n")
  out:write(string.format("# window: start=%08x..%08x max=%d stoppc=%s\n",
            START, START_HI, MAXREC, STOPPC and tohex8(STOPPC) or "none"))
  out:write("# fields: i=<dec seq> pc=<8hex>\n")

  local seq = 0
  local started = (START == 0)        -- if START==0, log from the first insn
  local stopped = false
  local raw_lines = 0

  for line in rin:lines() do
    raw_lines = raw_lines + 1
    local pc_s = line:match("^(%x+):")     -- native "PC: disasm"
    if pc_s ~= nil then
      local pc = tonumber(pc_s, 16)
      if pc ~= nil then
        -- open the window the first time pc lands in the start region
        if not started and pc >= START and pc < START_HI then started = true end
        if started then
          out:write(string.format("i=%d pc=%s\n", seq, tohex8(pc)))
          seq = seq + 1
          if STOPPC ~= nil and pc == STOPPC then stopped = true end
          if seq >= MAXREC then stopped = true end
        end
      end
    end
    if stopped then break end
  end

  local reason = "eof"
  if stopped then
    reason = (seq >= MAXREC) and "max" or "stoppc"
  end
  out:write(string.format("# end: emitted=%d raw_lines_scanned=%d reason=%s\n",
            seq, raw_lines, reason))
  out:close()
  rin:close()
  manager.machine:logerror(string.format(
    "[pctrace] wrote %d records to %s (scanned %d raw lines, reason=%s)\n",
    seq, OUT, raw_lines, reason))
end

-- wrap so any post-pass error can never silently swallow the trace; the error
-- is reported and we still leave the RAW file for manual conversion.
local function postprocess()
  do local s = io.open("/tmp/PCTRACE_POST_ENTER.txt","w"); if s then s:write("enter\n"); s:close() end end
  local ok, err = pcall(postprocess_body)
  do local s = io.open("/tmp/PCTRACE_POST_ENTER.txt","a"); if s then s:write("ok="..tostring(ok).." err="..tostring(err).."\n"); s:close() end end
  if not ok then
    manager.machine:logerror("[pctrace] post-pass error: " .. tostring(err) ..
      " (RAW left at " .. RAW .. " -- convert with the gawk one-liner)\n")
  end
end

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(postprocess)
else
  -- defensive: every 0.288 build we tested has the notifier.
  manager.machine:logerror(
    "[pctrace] WARN: no stop notifier; run -seconds_to_run then convert RAW " ..
    "manually with the gawk one-liner in the header\n")
end
