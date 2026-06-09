-- mame_service_menu.lua
-- Boot hyperbbc (System 573) into its OPERATOR / SERVICE-TEST menu by HOLDING the
-- ":IN3" "Service Mode" input field active every frame, and snapshot at several
-- frame milestones so we catch the test menu after boot + ROM check.
--
-- Each snapshot() writes <snapshot_directory>/<rom>/NNNN.png; we copy the newest
-- produced PNG to /tmp/<name>.png so the hub runner can pull it back into ./local/.
-- Verified API/pattern on MAME 0.285 (dell), per tools/mame_capture.sh.

local PREFIX = "svc"   -- /tmp/svc_fNNNN.png  (one per milestone)

-- Milestones in FRAMES (~60 fps). Spread across the run to catch the menu after
-- boot+ROM-check (573 boot can take 1-2 emulated minutes).
local shots = {
  [1800]  = "f1800",  -- release prompt
  [1900]  = "f1900",  -- version banner
  [1980]  = "f1980",  -- version banner
  [2040]  = "f2040",  -- FLASH ROM CHECK (settling)
  [2100]  = "f2100",  -- FLASH ROM CHECK (stable)
  [2160]  = "f2160",  -- FLASH ROM CHECK (stable)
  [2220]  = "f2220",  -- FLASH ROM CHECK (stable)
  [2280]  = "f2280",  -- FLASH ROM CHECK (stable)
  [2340]  = "f2340",  -- end of FLASH ROM CHECK
}

-- ---------------------------------------------------------------------------
-- snapshot dir helpers (mirrors tools/mame_capture.sh, known-good on 0.285)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Find the "Service Mode" field on port :IN3 (and log all fields once for proof).
-- ---------------------------------------------------------------------------
local svc_fields = {}   -- list of ioport_field to force HIGH each frame
local logged = false

local function discover_fields()
  if logged then return end
  logged = true
  local f = io.open("/tmp/svc_fields.txt", "w")
  local function L(s)
    if f then f:write(s .. "\n") end
    pcall(function() emu.print_info(s) end)
  end
  L("[svc] ===== ioport field dump =====")
  for ptag, port in pairs(manager.machine.ioport.ports) do
    for fname, field in pairs(port.fields) do
      L(string.format("[svc] port=%s field=%q", ptag, fname))
      -- Match the Service Mode toggle. Prefer :IN3 / "Service Mode", but also
      -- grab any field literally named "Service Mode" on any port as a fallback.
      local n = fname:lower()
      if n == "service mode" then
        table.insert(svc_fields, field)
        local tinfo = ""
        pcall(function()
          tinfo = string.format(" type=%s mask=%s toggle=%s defval=%s",
            tostring(field.type), tostring(field.mask),
            tostring(field.is_toggle), tostring(field.defvalue))
        end)
        L(string.format("[svc]  -> HOLDING %s / %q%s", ptag, fname, tinfo))
      end
    end
  end
  L(string.format("[svc] holding %d field(s)", #svc_fields))
  if f then f:close() end
end

-- 573 boots into the TEST MENU only if the test switch was ON at power-on AND is
-- then RELEASED. Held continuously it parks at "TEST SWITCH IS STILL ON / PLEASE
-- RELEASE IT". So: hold Service Mode through boot, then release it.
local RELEASE_AT = 1850   -- frame to release the test switch (~31s; right as the prompt appears)

local frame = 0
emu.register_frame_done(function()
  discover_fields()
  -- Hold Service Mode active until RELEASE_AT, then release (drive to 0).
  local val = (frame < RELEASE_AT) and 1 or 0
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
      "[svc] snap frame=%d -> %s_%s.png ok=%s copied=%s bytes=%d\n",
      frame, PREFIX, nm, tostring(sok), tostring(cok), clen))
  end
end)
