-- mame_main_menu.lua
-- Reach the hyperbbc OPERATOR MAIN MENU (I/O CHECK / LAMP CHECK / SCREEN CHECK /
-- COLOR CHECK / FLASH ROM CHECK / ... / GAME MODE) by HOLDING the ":IN3" "Service
-- Mode" input field active EVERY frame (test switch ON at power-on and kept on ->
-- after the boot self-tests the game parks on the operator MAIN MENU, which is the
-- stable, non-animating verification target). Snapshot a WIDE frame sweep so we
-- catch the menu after the (1-2 emulated-minute) boot + self-test chain.
--
-- Mirrors tools/mame_service_menu.lua's known-good snapshot/discover pattern; the
-- only behavioural change is: never release Service Mode (the operator menu path),
-- and sweep much later frames.

local PREFIX = "mm"   -- /tmp/mm_fNNNN.png

-- Boot CLEAN (no service) to attract, then PRESS the test button mid-attract; the
-- operator MAIN MENU then appears. Snapshot densely AFTER the press to catch it.
local PRESS_AT = 4000   -- frame to assert Service Mode (attract is running by here)
local shots = {}
for _, fr in ipairs({4060, 4120, 4200, 4320, 4500, 4800, 5100, 5400, 6000, 6600, 7200}) do
  shots[fr] = string.format("f%04d", fr)
end

local function romname()
  local ok, n = pcall(function() return manager.machine.system.name end)
  if ok and n then return n end
  return "hyperbbc"
end
local function snapdir()
  local ok, v = pcall(function()
    return manager.options.entries["snapshot_directory"]:value()
  end)
  if ok and v and v ~= "" then return v end
  return "snap"
end
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

local svc_fields = {}
local logged = false
local function discover_fields()
  if logged then return end
  logged = true
  for ptag, port in pairs(manager.machine.ioport.ports) do
    for fname, field in pairs(port.fields) do
      if fname:lower() == "service mode" then
        table.insert(svc_fields, field)
      end
    end
  end
  manager.machine:logerror(string.format("[mm] holding %d Service Mode field(s)\n", #svc_fields))
end

-- Test switch held FROM power-on parks at "TEST SWITCH IS STILL ON / RELEASE IT" and
-- holding it through boot then releasing just boots to ATTRACT (title/demo). The
-- operator MAIN MENU is entered by PRESSING the test button DURING attract (== MAME
-- F2 mid-game). So boot clean, then assert + hold Service Mode from PRESS_AT on.
local frame = 0
emu.register_frame_done(function()
  discover_fields()
  local val = (frame >= PRESS_AT) and 1 or 0
  for _, f in ipairs(svc_fields) do
    pcall(function() f:set_value(val) end)
  end
  frame = frame + 1
  local nm = shots[frame]
  if nm then
    local sok = pcall(function() manager.machine.video:snapshot() end)
    local src = newest_png()
    local cok, clen = copyfile(src, "/tmp/" .. PREFIX .. "_" .. nm .. ".png")
    manager.machine:logerror(string.format(
      "[mm] snap frame=%d -> %s_%s.png ok=%s copied=%s bytes=%d\n",
      frame, PREFIX, nm, tostring(sok), tostring(cok), clen))
  end
end)
