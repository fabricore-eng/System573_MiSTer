-- =============================================================================
-- exp1_trace.lua -- System 573 EXP1 PERIPHERAL bus tap (NOT the flash/code region).
--
-- PURPOSE: boundary-diff oracle. The DIO-only trace proved the digital board is
-- handled in the first ~3 s and is NOT what gates the 75 s "BOOT CHECK" ->
-- "INITIALIZE FLASH-ROM" transition. This taps the WHOLE 573 I/O peripheral
-- region so we can see WHICH peripheral read the game waits on at the transition,
-- then compare each distinct read value to the de10 RTL response.
--
-- TAP RANGE 0x1f400000..0x1f6fffff  (peripherals only):
--   40=ASIC/sec-cart I/O  48/4c=ATAPI  50=bankctl/sec-ctrl  52=jvsclr  56=idereset
--   5c=wdog  60=digout  62=RTC/NVRAM  64=DIO board  68=JVS data  6a=sec latch
--   (the flash/code window 0x1f000000-0x1f3fffff is DELIBERATELY excluded -- it is
--    instruction fetch + flash data and would bury the trace in millions of lines.)
--
-- OUTPUT /tmp/exp1_trace.log  (LINE-BUFFERED; complete even w/o a stop notifier).
--   Records (run-length-encoded -- a poll loop collapses to one line + xN):
--     <R|W> f=<frame> pc=<8hex> a=<6hex addr&0xffffff> val=<8hex> mask=<8hex> xN
--   Plus periodic "# frame N reads=.. writes=.." markers so we can confirm the
--   trace covered the full run and locate the transition (~frame 4500 = 75 s).
-- =============================================================================

local OUT = os.getenv("EXP1_TRACE_OUT")
if OUT == nil or OUT == "" then OUT = "/tmp/exp1_trace.log" end

local f = io.open(OUT, "w")
f:setvbuf("line")
f:write("# exp1_trace: System 573 I/O region 0x1f400000..0x1f6fffff (ddrsbm)\n")
f:write("# fields: <R|W> f=<frame> pc=<8hex> a=<6hex> val=<8hex> mask=<8hex> xN\n")

local cpu = manager.machine.devices[":maincpu"]
local pcsym = (cpu ~= nil and cpu.state ~= nil) and cpu.state["pc"] or nil
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame, nread, nwrite = 0, 0, 0

local last_line, last_cnt = nil, 0
local function flush_rle()
  if last_line ~= nil then
    f:write(last_line .. (last_cnt > 1 and (" x" .. last_cnt) or "") .. "\n")
    last_line, last_cnt = nil, 0
  end
end
local function emit(kind, addr, val, mask)
  local line = string.format("%s f=%d pc=%08x a=%06x val=%08x mask=%08x",
                             kind, frame, pcval(), addr % 0x1000000, val, mask)
  if line == last_line then last_cnt = last_cnt + 1
  else flush_rle(); last_line = line; last_cnt = 1 end
end

local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    local space = cpu.spaces["program"]
    if space == nil then manager.machine:logerror("[exp1] no program space\n"); return end
    space:install_read_tap(0x1f400000, 0x1f6fffff, "exp1_rtap",
      function(offset, data, mask) nread = nread + 1; emit("R", offset, data, mask); return data end)
    space:install_write_tap(0x1f400000, 0x1f6fffff, "exp1_wtap",
      function(offset, data, mask) nwrite = nwrite + 1; emit("W", offset, data, mask); return data end)
    installed = true
    manager.machine:logerror("[exp1] taps installed @ 0x1f400000..0x1f6fffff\n")
  end)
  if not ok then manager.machine:logerror("[exp1] install error: " .. tostring(err) .. "\n") end
end

if emu.register_prestart then emu.register_prestart(install) end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then install() end
  if frame % 300 == 0 then
    flush_rle()
    f:write(string.format("# frame %d reads=%d writes=%d\n", frame, nread, nwrite))
    manager.machine:logerror(string.format("[exp1] frame=%d r=%d w=%d\n", frame, nread, nwrite))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    flush_rle()
    f:write(string.format("# end frame=%d reads=%d writes=%d\n", frame, nread, nwrite))
    f:close()
  end)
end
