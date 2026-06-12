-- cass_outcome_tap.lua -- detect which cassette error string (if any) is DRAWN.
-- The on-screen text-draw reads string bytes from RAM. We tap DATA reads of the
-- first byte of each error/status literal; whichever fires tells us the verdict.
--   0x8002011c  "SECURITY-CASSETTE ERROR(-11N) ver.ERROR"  (region/-11N wall lit)
--   0x8002084c  "SECURITY-CASSETTE ERROR (-11N)"           (-11 handler)
--   0x8002088c  "  THE INSTALLED SECURITY CASSETTE DOES"   (-3 handler)
--   0x800208d0  "SECURITY-CASSETTE DOES NOT EXIST."        (-12 handler)
--   0x80020488  "SECURITY-PCB ERROR (%dN)"                 (-2/-1 handler)
--   0x80020143  "FLASH ROM CHECK"  (boot ADVANCED past cassette -> next phase)
local PREFIX = os.getenv("CASS_PREFIX") or "/tmp/cassout"
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local f = io.open(PREFIX .. "_trace.txt", "w")
f:setvbuf("line")
local function now() return machine.time.seconds + machine.time.attoseconds/1e18 end
local function pc()
  local ok,v = pcall(function() return cpu.state["CURPC"].value end)
  if ok then return v end
  return 0
end
_G.taps = {}
local taps = _G.taps
local seen = {}
local function watch(addr, label)
  local base = addr & ~3              -- align to word
  taps[#taps+1] = mem:install_read_tap(base, base + 3, "w_"..label, function(off,data,mask)
    local k = label
    seen[k] = (seen[k] or 0) + 1
    if seen[k] <= 3 then
      f:write(string.format("%10.6f STRING-READ [%s] base=%08X pc=%08X\n", now(), label, base, pc()))
    end
  end)
end
watch(0x8002011c, "-11N_wall")
watch(0x8002084c, "-11_handler")
watch(0x8002088c, "-3_incorrect")
watch(0x800208d0, "-12_absent")
watch(0x80020488, "-2_pcb")
watch(0x80020143, "FLASH_ROM_CHECK_advanced")
f:write(string.format("# cass_outcome_tap installed machine=%s\n", machine.system.name))
print("cass_outcome_tap installed prefix=" .. PREFIX)
