-- =============================================================================
-- dio_trace.lua -- System 573 DIGITAL I/O board (k573dio @ 0x1f640000) bus tap.
--
-- PURPOSE: MAME-oracle trace of WHAT a digital-board game (e.g. ddrsbm) reads &
-- writes in the k573dio register window during boot, so the de10's stubbed/
-- dangling DIO can be compared register-by-register against MAME's working DIO.
-- Pins which DIO response gates the "BOOT CHECK" -> "INITIALIZE FLASH-ROM" step.
--
-- OUTPUT  /tmp/dio_trace.log  (LINE-BUFFERED -- every line flushed to disk on
--   write, so the log is COMPLETE even if MAME 0.285 never fires its machine-
--   stop notifier; do NOT depend on the stop notifier for the trace).
--   Records (run-length-encoded: a tight poll loop collapses to one line + xN):
--     <R|W> f=<frame> pc=<8hex> off=<2hex> val=<8hex> mask=<8hex> xN
--   off = register offset within the 256-byte window (addr % 0x100).
--   val = the full bus value MAME returned (read) / wrote; 16-bit regs use low half.
--   xN  = this (kind,pc,off,val) record repeated N consecutive times (poll loop).
--
-- RUN (via the hub MAME runner, which scp's this + pulls the log back):
--   ~/Dev/fabricore/tools/tools/mame_dell.sh System573_MiSTer ddrsbm \
--     "dumps/mame573;dumps" tools/trace/dio_trace.lua 80 dio_trace.log
--
-- NB no -debug needed: install_read_tap / install_write_tap work on the live
-- address space without the debugger. PC is read from the maincpu state IF.
-- =============================================================================

local OUT = os.getenv("DIO_TRACE_OUT")
if OUT == nil or OUT == "" then OUT = "/tmp/dio_trace.log" end

local f = io.open(OUT, "w")
f:setvbuf("line")                      -- flush every line: complete log w/o stop notifier
f:write("# dio_trace: k573dio window 0x1f640000..0x1f6400ff (ddrsbm DIGITAL board)\n")
f:write("# fields: <R|W> f=<frame> pc=<8hex> off=<2hex off%0x100> val=<8hex> mask=<8hex> xN\n")

local cpu = manager.machine.devices[":maincpu"]

-- read PC from the device state interface (no debugger required)
local pcsym = nil
if cpu ~= nil and cpu.state ~= nil then pcsym = cpu.state["pc"] end
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame   = 0
local nread   = 0
local nwrite  = 0

-- run-length encoder: collapse consecutive identical records to one line + xN
local last_line = nil
local last_cnt  = 0
local function flush_rle()
  if last_line ~= nil then
    f:write(last_line .. (last_cnt > 1 and (" x" .. last_cnt) or "") .. "\n")
    last_line = nil; last_cnt = 0
  end
end
local function emit(kind, off, val, mask)
  local line = string.format("%s f=%d pc=%08x off=%02x val=%08x mask=%08x",
                             kind, frame, pcval(), off % 0x100, val, mask)
  if line == last_line then last_cnt = last_cnt + 1
  else flush_rle(); last_line = line; last_cnt = 1 end
end

local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    local space = cpu.spaces["program"]
    if space == nil then
      manager.machine:logerror("[dio_trace] ERROR: no :maincpu program space\n"); return
    end
    space:install_read_tap(0x1f640000, 0x1f6400ff, "dio_rtap",
      function(offset, data, mask) nread = nread + 1; emit("R", offset, data, mask); return data end)
    space:install_write_tap(0x1f640000, 0x1f6400ff, "dio_wtap",
      function(offset, data, mask) nwrite = nwrite + 1; emit("W", offset, data, mask); return data end)
    installed = true
    manager.machine:logerror("[dio_trace] taps installed @ 0x1f640000..0x1f6400ff\n")
  end)
  if not ok then manager.machine:logerror("[dio_trace] install error: " .. tostring(err) .. "\n") end
end

if emu.register_prestart then emu.register_prestart(install) end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then install() end
  if frame % 600 == 0 then
    flush_rle()                        -- bound the open run so progress is visible
    manager.machine:logerror(string.format(
      "[dio_trace] frame=%d reads=%d writes=%d\n", frame, nread, nwrite))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    flush_rle()
    f:write(string.format("# end frame=%d reads=%d writes=%d\n", frame, nread, nwrite))
    f:close()
    manager.machine:logerror(string.format(
      "[dio_trace] DONE frame=%d reads=%d writes=%d\n", frame, nread, nwrite))
  end)
end
