-- =============================================================================
-- ddrsbm_dio_tap.lua -- DIO-window MMIO tap: the GOLDEN I2C byte stream oracle.
--
-- Taps ONLY 0x1f6400a0..0x1f6400cf (k573dio MAS3507D I2C reg 0xac + fpga_ctrl
-- 0xae + mpeg_ctrl 0xaa + 0xba + mp3 counters 0xca/cc/ce). NO RAM taps, NO ATA
-- taps -- those crash MAME 0.285 mid-drive-check (see silicon-hang heuristics
-- memory + docs/2026-07-01-ddrsbm-bootcheck-dio-verdict.md par.6). The a0..cf
-- MMIO window is the same access class as the proven ATA task-file taps.
--
-- PURPOSE (de-stub plan A0 step 3): MAME's ddrsbm BOOT CHECK PASSES, so every
-- write to 0xac here is the exact line-level I2C sequence a correct MAS3507D
-- slave must accept -- including the WRITE_MEM cmd byte that lives in a lookup
-- table outside our RAM dumps. Decode offline with the sibling
-- tools/trace/dio_i2c_decode.py. Also answers: does the (undumped) top-level
-- boot check poll 0xaa/0xae/0xcc after dio_mas_init?
--
-- Identical consecutive (kind,addr,pc,val,mask) lines RLE-compress: "xN fA..fB".
-- OUTPUT /tmp/ddrsbm_dio_tap.log (line-buffered; -video none truncates the tail
-- mid-line on exit -- benign, do not rely on the stop notifier).
-- =============================================================================

local OUT = "/tmp/ddrsbm_dio_tap.log"
local f = io.open(OUT, "w")
f:setvbuf("line")
f:write("# ddrsbm_dio_tap: R/W 0x1f6400a0..0x1f6400cf\n")
f:write("# fields: <seq> f=<frame> pc=<8hex> <W|R> <addr8hex> = <data8hex> [m=<mask8hex>] [xN fA..fB]\n")

local cpu = manager.machine.devices[":maincpu"]
local pcsym = (cpu ~= nil and cpu.state ~= nil) and cpu.state["pc"] or nil
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame, seq = 0, 0

-- ---- run-length-compressed emitter (pattern from ddrsbm_desc_arm.lua) ------
local last = nil
local function flush()
  if last == nil then return end
  seq = seq + 1
  local sfx = ""
  if last.count > 1 then sfx = string.format("  x%d f%d..f%d", last.count, last.f0, last.f1) end
  f:write(string.format("%-6d %s%s\n", seq, last.line, sfx))
  last = nil
end
local function emit(kind, addr, data, mask)
  local m = ""
  if mask ~= nil then m = string.format(" m=%08x", mask) end
  local key = string.format("%s|%08x|%08x|%08x|%s", kind, addr, pcval(), data, m)
  if last ~= nil and last.key == key then
    last.count = last.count + 1; last.f1 = frame; return
  end
  flush()
  local line = string.format("f=%d pc=%08x %s %08x = %08x%s", frame, pcval(), kind, addr, data, m)
  last = { key = key, line = line, count = 1, f0 = frame, f1 = frame }
end

-- ---- taps -------------------------------------------------------------------
local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    local space = cpu.spaces["program"]
    if space == nil then manager.machine:logerror("[dio] no program space\n"); return end
    space:install_read_tap(0x1f6400a0, 0x1f6400cf, "dio_r",
      function(offset, data, mask) emit("R", offset, data, mask); return data end)
    space:install_write_tap(0x1f6400a0, 0x1f6400cf, "dio_w",
      function(offset, data, mask) emit("W", offset, data, mask); return data end)
    installed = true
    f:write("# taps installed\n")
    manager.machine:logerror("[dio] taps installed\n")
  end)
  if not ok then manager.machine:logerror("[dio] install error: " .. tostring(err) .. "\n") end
end

if emu.register_prestart then emu.register_prestart(install) end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then install() end
  if frame % 300 == 0 then
    flush()
    manager.machine:logerror(string.format("[dio] frame=%d seq=%d\n", frame, seq))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    flush()
    f:write(string.format("# end frame=%d seq=%d\n", frame, seq))
    f:close()
    manager.machine:logerror(string.format("[dio] DONE frame=%d seq=%d\n", frame, seq))
  end)
end
