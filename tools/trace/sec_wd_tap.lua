-- =============================================================================
-- sec_wd_tap.lua -- MAME (0.288) tap answering the cassette-presence workflow's
--                   OPEN QUESTION 3: does the BIOS/game kick the WATCHDOG
--                   (0x1f5c0000 page) INSIDE an X76 security-cartridge
--                   transaction (between a CS-select on the 0x1f6a0000 latch and
--                   its completion)?
--
-- If YES, the d_latch combinational-follow bug (rtl/system573_top.v wires
-- s573_seccart.d_latch straight from live exp1_wdata, so ANY EXP1-region write
-- rewrites CS/SCL/SDA/RST mid-transaction) is REQUIRED for MAME parity; if NO it
-- ships as hardening only. Adapted from local/seccart_presence/sec_tap.lua /
-- local/cd_adjudication/atapi_tap.lua.
--
-- Taps (all with timestamps + PC):
--   * security latch 0x1f6a0000 writes+reads  (SEC-W / SEC-R)
--   * watchdog page  0x1f5c0000-0x1f5fffff writes (WDOG-W)  <- MAME ksys573 maps
--     watchdog_w at 0x1f5c0000; the page-wide tap also catches mirrored kicks.
--   * bank/control   0x1f500000 writes (CTL-W) -- the OTHER EXP1-region write
--     that can glitch the combinational latch, logged for completeness.
--
-- Run (headless, from the repo root; ~35 emulated s covers the BIOS cassette
-- phase at ~5.06s plus the game-side boot):
--   SECWD_PREFIX=/tmp/wdtap mame hypbbc2p -rompath dumps/mame573 \
--     -video none -sound none -nothrottle -seconds_to_run 35 \
--     -autoboot_script tools/trace/sec_wd_tap.lua
--
-- Verdict: any WDOG-W timestamped between a SEC-W with bit2=0 (CS low =
-- selected) and the next SEC-W with bit2=1 (deselect) = a kick INSIDE the
-- transaction (answer YES).
-- =============================================================================

local PREFIX = os.getenv("SECWD_PREFIX") or "/tmp/wdtap"
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local f = io.open(PREFIX .. "_trace.txt", "w")
f:setvbuf("line")

local function pc()
  local ok, v = pcall(function() return cpu.state["CURPC"].value end)
  if ok then return v end
  local ok2, v2 = pcall(function() return cpu.state["PC"].value end)
  if ok2 then return v2 end
  return 0
end
local function now() return machine.time.seconds + machine.time.attoseconds/1e18 end

_G.taps = {}
local taps = _G.taps

-- ---- security latch 0x1f6a0000 (every write; reads capped) ----
local sec_w_n, sec_r_n = 0, 0
taps[#taps+1] = mem:install_write_tap(0x1f6a0000, 0x1f6a0003, "secw", function(offset, data, mask)
  sec_w_n = sec_w_n + 1
  if sec_w_n <= 20000 then
    f:write(string.format("%10.6f SEC-W   %08X=%08X m=%08X pc=%08X\n", now(), offset, data, mask, pc()))
  end
end)
taps[#taps+1] = mem:install_read_tap(0x1f6a0000, 0x1f6a0003, "secr", function(offset, data, mask)
  sec_r_n = sec_r_n + 1
  if sec_r_n <= 20000 then
    f:write(string.format("%10.6f SEC-R   %08X=%08X m=%08X pc=%08X\n", now(), offset, data, mask, pc()))
  end
end)

-- ---- watchdog page 0x1f5c0000 (MB3773 kick; every write, with timestamp) ----
local wd_n = 0
taps[#taps+1] = mem:install_write_tap(0x1f5c0000, 0x1f5fffff, "wdw", function(offset, data, mask)
  wd_n = wd_n + 1
  if wd_n <= 20000 then
    f:write(string.format("%10.6f WDOG-W  %08X=%08X m=%08X pc=%08X\n", now(), offset, data, mask, pc()))
  end
end)

-- ---- bank/control reg 0x1f500000 writes (the other mid-transaction EXP1 write) ----
taps[#taps+1] = mem:install_write_tap(0x1f500000, 0x1f500003, "ctlw", function(offset, data, mask)
  f:write(string.format("%10.6f CTL-W   %08X=%08X m=%08X pc=%08X\n", now(), offset, data, mask, pc()))
end)

-- NOTE: no stop hook -- MAME 0.288's autoboot Lua env has no emu.register_stop;
-- the trace file is line-buffered so it is complete when MAME exits.
f:write(string.format("# sec_wd_tap installed, prefix=%s machine=%s\n", PREFIX, machine.system.name))
print("sec_wd_tap installed, prefix=" .. PREFIX)
