-- dump_code.lua -- one-shot dump of the ddrsbm installer code from RAM, so we can
-- disassemble the BOOT CHECK routine offline (capstone) and READ the branch it
-- gates on. No per-access taps (full emulation speed); a single 64KB read at a
-- target frame after the code is resident.
local DUMP_AT = tonumber(os.getenv("DUMP_FRAME") or "130")
local LO = tonumber(os.getenv("DUMP_LO") or "0x803c0000")
local HI = tonumber(os.getenv("DUMP_HI") or "0x803d0000")
local OUT = os.getenv("DUMP_OUT") or "/tmp/ddrsbm_code.bin"

local cpu = manager.machine.devices[":maincpu"]
local frame, done = 0, false

local function dump()
  local sp = cpu.spaces["program"]
  local f = io.open(OUT, "wb")
  for a = LO, HI - 1 do f:write(string.char(sp:read_u8(a) % 256)) end
  f:close()
  manager.machine:logerror(string.format(
    "[dump_code] wrote %s : 0x%08x..0x%08x (%d bytes) at frame %d\n",
    OUT, LO, HI, HI - LO, frame))
end

emu.register_frame_done(function()
  frame = frame + 1
  if not done and frame >= DUMP_AT then
    done = true
    local ok, err = pcall(dump)
    if not ok then manager.machine:logerror("[dump_code] error: " .. tostring(err) .. "\n") end
  end
end)
