-- =============================================================================
-- ddrsbm_ata_full.lua -- COMPLETE ddrsbm drive-check ATA/ATAPI handshake tap.
--
-- Capture EVERY read+write to the 573 IDE task-file (0x1f480000..1ff) AND the
-- control/altstatus block (0x1f4c0000..0ff) from the FIRST access, in access
-- ORDER. Every write logged with reg name + value, so the command-issue
-- mechanism (PACKET 0xA0 + CDB to reg0, vs direct CMD to reg e) is unambiguous.
--
-- IRQ note: the maincpu I_STAT tap crashed MAME 0.285 (it aliases the PSX I/O
-- decode), so IRQ is inferred from the data-phase structure (status poll ends,
-- ireason flips C/D|I/O, byte-count appears) per the task brief's fallback.
--
-- OUTPUT  /tmp/ddrsbm_ata_full.log (line-buffered)
--   <seq> f=<frame> pc=<8hex> <R|W> <addr8hex> <reg> = <val4hex>
-- =============================================================================

local OUT = os.getenv("ATA_TRACE_OUT")
if OUT == nil or OUT == "" then OUT = "/tmp/ddrsbm_ata_full.log" end

local f = io.open(OUT, "w")
f:setvbuf("line")
f:write("# ddrsbm_ata_full: task-file 0x1f480000..1ff + ctrl 0x1f4c0000..0ff\n")
f:write("# fields: <seq> f=<frame> pc=<8hex> <R|W> <addr8hex> <reg> = <val4hex>\n")

local cpu = manager.machine.devices[":maincpu"]
local pcsym = (cpu ~= nil and cpu.state ~= nil) and cpu.state["pc"] or nil
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame = 0
local seq = 0

local function regname(addr)
  local r = addr & 0xf
  if r == 0x0 then return "data    "
  elseif r == 0x2 then return "feat/err"
  elseif r == 0x4 then return "seccnt/ir"
  elseif r == 0x6 then return "lbalo   "
  elseif r == 0x8 then return "lbamid/bc"
  elseif r == 0xa then return "lbahi/bc"
  elseif r == 0xc then return "drv/head"
  elseif r == 0xe then return "status/CMD"
  else return string.format("?%x      ", r) end
end

local function emit(kind, addr, val)
  seq = seq + 1
  f:write(string.format("%-6d f=%d pc=%08x %s %08x %s = %04x\n",
    seq, frame, pcval(), kind, addr, regname(addr), val & 0xffff))
end

local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    local space = cpu.spaces["program"]
    if space == nil then manager.machine:logerror("[ata] no program space\n"); return end

    space:install_read_tap(0x1f480000, 0x1f4801ff, "ata_cmd_r",
      function(offset, data, mask) emit("R", 0x1f480000 + offset, data); return data end)
    space:install_write_tap(0x1f480000, 0x1f4801ff, "ata_cmd_w",
      function(offset, data, mask) emit("W", 0x1f480000 + offset, data); return data end)

    space:install_read_tap(0x1f4c0000, 0x1f4c00ff, "ata_ctl_r",
      function(offset, data, mask)
        seq = seq + 1
        f:write(string.format("%-6d f=%d pc=%08x R %08x CTL/altst = %04x\n",
          seq, frame, pcval(), 0x1f4c0000 + offset, data & 0xffff)); return data end)
    space:install_write_tap(0x1f4c0000, 0x1f4c00ff, "ata_ctl_w",
      function(offset, data, mask)
        seq = seq + 1
        f:write(string.format("%-6d f=%d pc=%08x W %08x CTL/devctl = %04x\n",
          seq, frame, pcval(), 0x1f4c0000 + offset, data & 0xffff)); return data end)

    installed = true
    manager.machine:logerror("[ata] taps installed\n")
  end)
  if not ok then manager.machine:logerror("[ata] install error: " .. tostring(err) .. "\n") end
end

if emu.register_prestart then emu.register_prestart(install) end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then install() end
  if frame % 20 == 0 then
    manager.machine:logerror(string.format("[ata] frame=%d seq=%d\n", frame, seq))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    f:write(string.format("# end frame=%d seq=%d\n", frame, seq))
    f:close()
    manager.machine:logerror(string.format("[ata] DONE frame=%d seq=%d\n", frame, seq))
  end)
end
