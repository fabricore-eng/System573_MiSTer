-- =============================================================================
-- psx_trace.lua -- System 573 boot trace covering the PSX CORE registers
--                  (0x1f801xxx: IRQ/DMA/timers/GPU/SPU) AND the 573 EXP1
--                  peripherals (0x1f400000-0x1f6fffff), to find what the
--                  installer's "BOOT CHECK" loop POLLS before it proceeds.
--
-- WHY: earlier traces only covered EXP1 and showed the digital board + IN1 are
-- handled, yet the de10 still stalls at "BOOT CHECK" while MAME proceeds to
-- INITIALIZE-FLASH. The untraced suspect is a PSX status POLL (GPUSTAT 0x1f801814,
-- I_STAT 0x1f801070, a DMA/timer reg) that flips "ready" in MAME but never on the
-- de10 (whose PSX behavior is patched). Look for a register read whose VALUE
-- TRANSITIONS right before the I/O goes idle (= the BOOT CHECK passed).
--
-- OUTPUT /tmp/psx_trace.log (LINE-BUFFERED; complete w/o a stop notifier).
--   <R|W> f=<frame> pc=<8hex> a=<8hex full addr> val=<8hex> mask=<8hex> xN  (RLE)
--   + periodic "# frame N r=.. w=.." markers.
-- =============================================================================

local OUT = os.getenv("PSX_TRACE_OUT")
if OUT == nil or OUT == "" then OUT = "/tmp/psx_trace.log" end

local f = io.open(OUT, "w")
f:setvbuf("line")
f:write("# psx_trace: PSX regs 0x1f801000-0x1f801fff + EXP1 0x1f400000-0x1f6fffff (ddrsbm)\n")
f:write("# fields: <R|W> f=<frame> pc=<8hex> a=<8hex> val=<8hex> mask=<8hex> xN\n")

local cpu = manager.machine.devices[":maincpu"]
local pcsym = (cpu ~= nil and cpu.state ~= nil) and cpu.state["pc"] or nil
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame, nread, nwrite = 0, 0, 0
local stopped = false
local last_line, last_cnt = nil, 0
local function flush_rle()
  if last_line ~= nil then
    f:write(last_line .. (last_cnt > 1 and (" x" .. last_cnt) or "") .. "\n")
    last_line, last_cnt = nil, 0
  end
end
local function emit(kind, addr, val, mask)
  if stopped then return end
  local line = string.format("%s f=%d pc=%08x a=%08x val=%08x mask=%08x",
                             kind, frame, pcval(), addr, val, mask)
  if line == last_line then last_cnt = last_cnt + 1
  else flush_rle(); last_line = line; last_cnt = 1 end
end

local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    local space = cpu.spaces["program"]
    if space == nil then manager.machine:logerror("[psx] no program space\n"); return end
    local function rtap(lo, hi, nm)
      space:install_read_tap(lo, hi, nm, function(offset, data, mask)
        nread = nread + 1; emit("R", offset, data, mask); return data end)
    end
    local function wtap(lo, hi, nm)
      space:install_write_tap(lo, hi, nm, function(offset, data, mask)
        nwrite = nwrite + 1; emit("W", offset, data, mask); return data end)
    end
    rtap(0x1f801000, 0x1f801fff, "psx_r"); wtap(0x1f801000, 0x1f801fff, "psx_w")
    rtap(0x1f400000, 0x1f6fffff, "exp1_r"); wtap(0x1f400000, 0x1f6fffff, "exp1_w")
    installed = true
    manager.machine:logerror("[psx] taps installed (PSX regs + EXP1)\n")
  end)
  if not ok then manager.machine:logerror("[psx] install error: " .. tostring(err) .. "\n") end
end

-- DEFER tap install until the BOOT CHECK window: tapping the hot I_STAT/SIO0
-- polls from boot start slows MAME so far it never reaches the decision (~f140).
-- Run full-speed to START_TAP, then capture the window [START_TAP, STOP_EMIT].
local START_TAP  = tonumber(os.getenv("PSX_TRACE_START_FRAME") or "110")
local STOP_EMIT  = tonumber(os.getenv("PSX_TRACE_STOP_FRAME")  or "175")
emu.register_frame_done(function()
  frame = frame + 1
  if not installed and frame >= START_TAP then
    install()
    f:write(string.format("# taps installed at frame %d (window %d..%d)\n",
                          frame, START_TAP, STOP_EMIT))
  end
  if installed and not stopped and frame % 5 == 0 then
    flush_rle()
    f:write(string.format("# frame %d r=%d w=%d\n", frame, nread, nwrite))
  end
  if installed and not stopped and frame > STOP_EMIT then
    flush_rle(); stopped = true
    f:write(string.format("# capture window closed at frame %d (r=%d w=%d)\n", frame, nread, nwrite))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    flush_rle(); f:write(string.format("# end frame=%d r=%d w=%d\n", frame, nread, nwrite)); f:close()
  end)
end
