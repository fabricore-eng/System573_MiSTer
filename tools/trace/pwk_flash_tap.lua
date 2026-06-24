-- =============================================================================
-- pwk_flash_tap.lua -- MAME oracle trace of powyakex's BIOS "FLASH ROM CHECK".
--
-- Question being answered: MAME boots powyakex from ALL-BLANK onboard flash (all
-- 8x 29f016a nvram = 0xFF, J/H included) and PASSES the check, while the de10
-- HALTS with upper banks J/H BAD on the same blank flash. So: WHAT does the check
-- read per bank, and how does it accept blank J/H? That tells us what the de10
-- must return.
--
-- Taps (bank-tagged via the 0x1f500000 control reg, all with PC + timestamp):
--   * CTL   bank/control 0x1f500000 writes (selects which onboard bank, value&0x3f)
--   * FW-W  flash window 0x1f000000-0x1f3fffff WRITES = the JEDEC command stream
--           (unlock AA/55, autoselect 90, reset F0, program A0, erase 80/30/10)
--   * FW-R  flash window READS -- COUNTED per bank (so a bulk array/checksum scan
--           shows as a huge count), but only the LOW within-bank region (<0x40,
--           i.e. the autoselect MFR/DEV/status words 0/1/2..) is LOGGED, capped.
--           Running per-bank read counts are flushed at every bank switch.
--
-- Run (headless on dell, MAME 0.285, all-blank onboard flash):
--   ~/Dev/fabricore/tools/tools/mame_dell.sh System573_MiSTer powyakex \
--     "dumps/mame573;dumps" tools/trace/pwk_flash_tap.lua 45 pwktap_trace.txt
--   -> pulls /tmp/pwktap_trace.txt into ./local/.
-- Adapted from tools/trace/sec_wd_tap.lua.
-- =============================================================================
local PREFIX  = "/tmp/pwktap"
local machine = manager.machine
local cpu     = machine.devices[":maincpu"]
local mem     = cpu.spaces["program"]
local f = io.open(PREFIX .. "_trace.txt", "w")
f:setvbuf("line")

local function pc()
  local ok, v = pcall(function() return cpu.state["CURPC"].value end); if ok then return v end
  local ok2, v2 = pcall(function() return cpu.state["PC"].value end); if ok2 then return v2 end
  return 0
end
local function now() return machine.time.seconds + machine.time.attoseconds/1e18 end

_G.taps = {}
local taps    = _G.taps
local cur_bank = -1
local rd      = {}      -- [bank] = total reads
local lg      = {}      -- [bank] = logged low-offset reads
local LOGCAP  = 4000

local function dump_counts()
  local s = "# RDCOUNT"
  for bb = -1, 8 do if rd[bb] then s = s .. string.format(" b%d=%d", bb, rd[bb]) end end
  f:write(s .. string.format("  (t=%.3f)\n", now()))
end

-- bank/control reg 0x1f500000 writes -- selects the onboard bank (value & 0x3f)
taps[#taps+1] = mem:install_write_tap(0x1f500000, 0x1f500003, "ctlw", function(off, data, mask)
  local nb = data & 0x3f
  if nb ~= cur_bank then                            -- only on a real bank change (skip the cassette io-dir bit-bang on bit6)
    dump_counts()                                   -- flush running per-bank read counts at each switch
    cur_bank = nb
    f:write(string.format("%10.6f CTL  bank=%02X data=%08X pc=%08X\n", now(), cur_bank, data, pc()))
  end
end)

-- flash window WRITES = the JEDEC command stream (unlock/autoselect/reset/program/erase)
taps[#taps+1] = mem:install_write_tap(0x1f000000, 0x1f3fffff, "fww", function(off, data, mask)
  local boff = (off - 0x1f000000) & 0x3fffff
  f:write(string.format("%10.6f FW-W bank=%02X boff=%06X data=%08X m=%08X pc=%08X\n",
                        now(), cur_bank, boff, data, mask, pc()))
end)

-- flash window READS: count ALL per bank; LOG only the low (ID/status) region
taps[#taps+1] = mem:install_read_tap(0x1f000000, 0x1f3fffff, "fwr", function(off, data, mask)
  local b = cur_bank
  rd[b] = (rd[b] or 0) + 1
  local boff = (off - 0x1f000000) & 0x3fffff
  if boff < 0x40 and (lg[b] or 0) < LOGCAP then
    lg[b] = (lg[b] or 0) + 1
    f:write(string.format("%10.6f FW-R bank=%02X boff=%06X data=%08X m=%08X pc=%08X\n",
                          now(), b, boff, data, mask, pc()))
  end
end)

f:write(string.format("# pwk_flash_tap installed machine=%s (low-offset reads logged, all reads counted)\n",
                      machine.system.name))
print("pwk_flash_tap installed")
