-- mame_flash_install.lua -- drive ddrsbm's flash installer in headless MAME.
--
-- WHY: dell's ~/.mame/nvram/ddrsbm/ was ASSUMED to hold a working installed flash.
-- It does not. Screen probe (2026-07-31) caught the emulated game parked on
--   "DO YOU WANT TO INITIALIZE FLASH-ROM?  Yes: Please press test button"
-- -- the same screen the real hardware was stuck on -- with the PC pinned in a
-- 0x60-byte poll loop and zero DIO MP3 activity for the whole run. Every "the game
-- never enables MP3" reading off that log was measuring a button that nobody pressed.
--
-- So: press the test button, let the installer run, and let MAME persist nvram on
-- exit. After one successful pass the oracle runs boot straight into the game.
--
-- Snapshots go to $HOME/.mame/snap/ddrsbm/ (MAME's snapshot_directory -- NOT the
-- working dir, which is where they were first looked for and not found).
--
-- LIFETIME: handles are GC-owned; keep them in globals. See mame_dio_regs.lua.

FI = {}

FI.f = io.open("/tmp/flash_install.log", "w")
local function say(s) FI.f:write(s .. "\n"); FI.f:flush() end

say("# ddrsbm flash installer driver")

FI.cpu = manager.machine.devices[":maincpu"]

local function now()
  local ok, t = pcall(function() return manager.machine.time:as_double() end)
  if ok and t then return t end
  return -1
end

local function pc()
  local ok, v = pcall(function() return FI.cpu.state["pc"].value end)
  if ok and v then return v end
  return 0
end

-- Locate the test button. On sys573 it is the "Service Mode" field.
FI.svc = nil
for pname, port in pairs(manager.machine.ioport.ports) do
  for fname, field in pairs(port.fields) do
    if fname == "Service Mode" then
      FI.svc = field
      say("# found test button: " .. pname .. " :: " .. fname)
    end
  end
end
if FI.svc == nil then say("# FATAL: no 'Service Mode' field -- cannot press test") end

-- Press schedule, in emulated seconds. The prompt is up by t~20; press at 45 to be
-- safely past boot, hold ~2 s, then leave it alone and watch.
local PRESS_AT, RELEASE_AT = 45.0, 47.0

FI.frames = 0
FI.snaps = 0
FI.pressed = false
FI.released = false
FI.pcmin, FI.pcmax = 0xffffffff, 0

FI.sub = emu.add_machine_frame_notifier(function()
  FI.frames = FI.frames + 1
  local t = now()
  local p = pc()
  if p < FI.pcmin then FI.pcmin = p end
  if p > FI.pcmax then FI.pcmax = p end

  if FI.svc then
    if (not FI.pressed) and t >= PRESS_AT then
      FI.pressed = true
      local ok = pcall(function() FI.svc:set_value(1) end)
      say(string.format("%8.3f TEST BUTTON DOWN (ok=%s)", t, tostring(ok)))
    elseif FI.pressed and (not FI.released) and t >= RELEASE_AT then
      FI.released = true
      local ok = pcall(function() FI.svc:set_value(0) end)
      say(string.format("%8.3f TEST BUTTON UP (ok=%s)", t, tostring(ok)))
    end
  end

  if FI.frames % 600 == 0 then
    pcall(function() manager.machine.video:snapshot() end)
    FI.snaps = FI.snaps + 1
    say(string.format("# t=%.1f snap=%d pc_range=%08x..%08x",
      t, FI.snaps, FI.pcmin, FI.pcmax))
    FI.pcmin, FI.pcmax = 0xffffffff, 0
  end
end)
if FI.sub == nil then say("# WARNING: frame notifier nil -- no liveness") end

FI.stop = emu.add_machine_stop_notifier(function()
  say(string.format("# DONE t=%.1f frames=%d snaps=%d pressed=%s released=%s",
    now(), FI.frames, FI.snaps, tostring(FI.pressed), tostring(FI.released)))
  FI.f:flush()
end)
