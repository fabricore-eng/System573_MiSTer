-- mame_screen_probe.lua -- "what screen is the game actually ON?" diagnostic.
--
-- Companion to mame_dio_regs.lua. That script answers "what does the game write";
-- this one answers the question that has to be settled FIRST: is the game playing,
-- or parked at a prompt waiting for input that headless MAME will never deliver?
-- Without it, a log with no MP3 activity has two completely different readings and
-- no way to tell them apart -- the same trap that has bitten this session repeatedly.
--
-- Writes /tmp/screen_probe.log plus periodic PNGs into the snapshot dir.
--
-- LIFETIME: every MAME Lua handle here is GC-owned; discard it and the subscription
-- is silently removed (see mame_dio_regs.lua's header for the full post-mortem).
-- Hence the _G.SP table. Do not demote these to locals.

SP = {}

SP.f = io.open("/tmp/screen_probe.log", "w")
local function say(s) SP.f:write(s .. "\n"); SP.f:flush() end

say("# screen probe")

SP.cpu = manager.machine.devices[":maincpu"]

local function now()
  local ok, t = pcall(function() return manager.machine.time:as_double() end)
  if ok and t then return t end
  return -1
end

local function pc()
  local ok, v = pcall(function() return SP.cpu.state["pc"].value end)
  if ok and v then return v end
  return 0
end

-- Enumerate the input ports ONCE so we know what could be pressed if the game is
-- in fact waiting on a button. Printing them is free and saves a guessing round.
local ok_io = pcall(function()
  for pname, port in pairs(manager.machine.ioport.ports) do
    for fname, field in pairs(port.fields) do
      say(string.format("# input %s :: %s", pname, fname))
    end
  end
end)
if not ok_io then say("# WARNING: could not enumerate ioport") end

SP.frames = 0
SP.snaps = 0
SP.pcmin, SP.pcmax = 0xffffffff, 0

SP.sub = emu.add_machine_frame_notifier(function()
  SP.frames = SP.frames + 1
  local p = pc()
  if p < SP.pcmin then SP.pcmin = p end
  if p > SP.pcmax then SP.pcmax = p end

  -- every 10 emulated seconds: a snapshot + the PC range since the last one.
  if SP.frames % 600 == 0 then
    local okv = pcall(function() manager.machine.video:snapshot() end)
    SP.snaps = SP.snaps + 1
    say(string.format("# t=%.1f frames=%d snap=%d(ok=%s) pc_range=%08x..%08x",
      now(), SP.frames, SP.snaps, tostring(okv), SP.pcmin, SP.pcmax))
    SP.pcmin, SP.pcmax = 0xffffffff, 0
  end
end)
if SP.sub == nil then say("# WARNING: frame notifier returned nil -- no liveness") end

SP.stop = emu.add_machine_stop_notifier(function()
  say(string.format("# DONE t=%.1f frames=%d snaps=%d", now(), SP.frames, SP.snaps))
  SP.f:flush()
end)
