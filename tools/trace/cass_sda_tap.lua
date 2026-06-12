-- cass_sda_tap.lua -- capture the X76F100 SDA-OUT the BIOS samples.
-- From disasm: chip data-in = (lhu[0x1f400006] >> 2) & 1, accumulated MSB-first
-- into a byte over 8 clocks. We tap reads of 0x1f400004..0x1f400007 and log the
-- bit-2 value + PC, so we can reconstruct the bytes the chip actually returns.
local PREFIX = os.getenv("CASS_PREFIX") or "/tmp/cassda"
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local f = io.open(PREFIX .. "_trace.txt", "w")
f:setvbuf("line")
local function pc()
  local ok,v = pcall(function() return cpu.state["CURPC"].value end)
  if ok then return v end
  local ok2,v2 = pcall(function() return cpu.state["PC"].value end)
  if ok2 then return v2 end
  return 0
end
local function now() return machine.time.seconds + machine.time.attoseconds/1e18 end
_G.taps = {}
local taps = _G.taps
local n = 0
-- Tap the read-back word page. 0x1f400004 (word containing byte 6 in upper half).
taps[#taps+1] = mem:install_read_tap(0x1f400004, 0x1f400007, "sda", function(off,data,mask)
  n = n + 1
  if n <= 4000 then
    local b6 = (data >> 16) & 0xff       -- byte at +6 (upper half of the word read at +4)
    local sda = (b6 >> 2) & 1
    -- only log when sampled by the read-bit loop (pc ~ 0x80037540) to reduce noise
    local p = pc()
    if p >= 0x80037500 and p <= 0x80037560 then
      f:write(string.format("%10.6f SDA off=%X data=%08X b6=%02X sda=%d pc=%08X\n", now(), off, data, b6, sda, p))
    end
  end
end)
f:write(string.format("# cass_sda_tap installed machine=%s\n", machine.system.name))
print("cass_sda_tap installed prefix=" .. PREFIX)
