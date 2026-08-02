-- =============================================================================
-- ddrsbm_desc_arm.lua -- descriptor-ARM vs IDENTIFY-IRQ ordering trace (MAME oracle).
--
-- QUESTION (capture-X verdict, docs/2026-06-30-ddrsbm-capx-verdict.md): on our core the
-- game's IRQ-chain predicate 0x803c7bf0 DECLINES the ATAPI completion IRQ because the
-- pending/owned bit *(0x803cf4fc)+0 bit0 is CLEAR (enable [+4]&1 is set). MAME boots
-- ddrsbm fine -> trace WHO writes the descriptor words and WHEN, relative to the ATA
-- command flow (0xA1 IDENTIFY at pc=0x803cb840, drain reads, ISR reg7 read 0x803cb304).
--
-- Taps (every line carries the CPU PC):
--   A. ATA task-file 0x1f480000..1ff + ctrl 0x1f4c0000..0ff  (proven ddrsbm_ata_full tap)
--   B. WRITE tap on the descriptor POINTER cell 0x?03cf4fc (KUSEG/KSEG0/KSEG1 mirrors)
--   C. WRITE+READ taps on descriptor words [ptr+0 .. ptr+7], installed dynamically the
--      moment *(0x803cf4fc) goes nonzero (frame poll); re-installed if the ptr moves.
--   D. WRITE tap on ISR bookkeeping 0x803d2280..8f (IRQ counter, saved status, state byte).
-- Frame poll (never logged through the taps -- 'polling' flag): ptr cell, desc+0/+4,
-- counter 0x803d2280, state byte 0x803d228f -- logged ON CHANGE as 'POLL' lines.
--
-- Identical consecutive (kind,addr,pc,val) lines are run-length compressed: "xN fA..fB".
-- IRQ note: do NOT tap I_STAT (0x1f801070) -- it aliases the PSX I/O decode and crashes
-- MAME 0.285. The predicate's OWN reads of desc+0 (tap C, pc=0x803c7c10) mark each
-- dispatched IRQ and the exact value the predicate saw -- strictly better than I_STAT.
--
-- OUTPUT /tmp/ddrsbm_desc_arm.log (line-buffered)
-- =============================================================================

local OUT = os.getenv("DESC_TRACE_OUT")
if OUT == nil or OUT == "" then OUT = "/tmp/ddrsbm_desc_arm.log" end

local PTR_CELL = 0x003cf4fc          -- physical (mirror-stripped) descriptor-pointer cell
local BOOK     = 0x003d2280          -- ISR bookkeeping block base (16 bytes)
local MIRRORS  = { 0x00000000, 0x80000000, 0xa0000000 }

local f = io.open(OUT, "w")
f:setvbuf("line")
f:write("# ddrsbm_desc_arm: ATA taps + descriptor-ptr/word taps + ISR-book writes + frame poll\n")
f:write("# fields: <seq> f=<frame> pc=<8hex> <W|R|POLL> <addr8hex> <tag> = <val8hex> [mask] [xN fA..fB]\n")

local cpu = manager.machine.devices[":maincpu"]
local pcsym = (cpu ~= nil and cpu.state ~= nil) and cpu.state["pc"] or nil
local function pcval() if pcsym ~= nil then return pcsym.value else return 0 end end

local frame = 0
local seq = 0
local polling = false          -- true while the frame poll reads memory (suppress taps)
local space = nil

-- ---- run-length-compressed emitter ---------------------------------------
local last = nil               -- {key, line, count, f0, f1}
local function flush()
  if last == nil then return end
  seq = seq + 1
  local sfx = ""
  if last.count > 1 then sfx = string.format("  x%d f%d..f%d", last.count, last.f0, last.f1) end
  f:write(string.format("%-6d %s%s\n", seq, last.line, sfx))
  last = nil
end
local function emit(kind, addr, tag, val, mask)
  local m = ""
  if mask ~= nil then m = string.format(" m=%08x", mask) end
  local key  = string.format("%s|%08x|%08x|%08x|%s", kind, addr, pcval(), val, m)
  if last ~= nil and last.key == key then
    last.count = last.count + 1; last.f1 = frame; return
  end
  flush()
  local line = string.format("f=%d pc=%08x %s %08x %-10s = %08x%s", frame, pcval(), kind, addr, tag, val, m)
  last = { key = key, line = line, count = 1, f0 = frame, f1 = frame }
end

-- ---- ATA regname (proven decode) ------------------------------------------
local function regname(addr)
  local r = addr & 0xf
  if r == 0x0 then return "data"
  elseif r == 0x2 then return "feat/err"
  elseif r == 0x4 then return "seccnt/ir"
  elseif r == 0x6 then return "lbalo"
  elseif r == 0x8 then return "lbamid/bc"
  elseif r == 0xa then return "lbahi/bc"
  elseif r == 0xc then return "drv/head"
  elseif r == 0xe then return "status/CMD"
  else return string.format("?%x", r) end
end

-- ---- tap plumbing ----------------------------------------------------------
local tapn = 0
local function tap(kind, a0, a1, cb)
  tapn = tapn + 1
  local name = string.format("desc_arm_%d", tapn)
  if kind == "r" then space:install_read_tap(a0, a1, name, cb)
  else space:install_write_tap(a0, a1, name, cb) end
end

local desc_ptr = 0             -- last seen *(PTR_CELL) (KSEG-stripped 0 means not set)
local desc_installs = 0

local function install_desc_taps(ptr)
  if desc_installs >= 8 then return end
  desc_installs = desc_installs + 1
  local base = ptr & 0x1fffffff
  for _, mir in ipairs(MIRRORS) do
    local a = base | mir
    tap("w", a, a + 7, function(offset, data, mask)
      if not polling then
        local off = (offset & 0x1fffffff) - base
        emit("W", offset, string.format("desc+%d", off), data, mask)
      end
      return data
    end)
    tap("r", a, a + 7, function(offset, data, mask)
      if not polling then
        local off = (offset & 0x1fffffff) - base
        emit("R", offset, string.format("desc+%d", off), data, mask)
      end
      return data
    end)
  end
  seq = seq + 1; flush()
  f:write(string.format("# f=%d desc taps installed @%08x (install #%d)\n", frame, ptr, desc_installs))
end

local installed = false
local function install()
  if installed then return end
  local ok, err = pcall(function()
    space = cpu.spaces["program"]
    if space == nil then manager.machine:logerror("[desc] no program space\n"); return end

    -- A. ATA task-file + ctrl (absolute addr arrives as `offset`)
    space:install_read_tap(0x1f480000, 0x1f4801ff, "ata_cmd_r",
      function(offset, data, mask) if not polling then emit("R", offset, regname(offset), data) end; return data end)
    space:install_write_tap(0x1f480000, 0x1f4801ff, "ata_cmd_w",
      function(offset, data, mask) if not polling then emit("W", offset, regname(offset), data) end; return data end)
    space:install_read_tap(0x1f4c0000, 0x1f4c00ff, "ata_ctl_r",
      function(offset, data, mask) if not polling then emit("R", offset, "CTL/altst", data) end; return data end)
    space:install_write_tap(0x1f4c0000, 0x1f4c00ff, "ata_ctl_w",
      function(offset, data, mask) if not polling then emit("W", offset, "CTL/devctl", data) end; return data end)

    -- B. descriptor-pointer cell writes (all mirrors)
    for _, mir in ipairs(MIRRORS) do
      local a = PTR_CELL | mir
      tap("w", a, a + 3, function(offset, data, mask)
        if not polling then emit("W", offset, "PTRCELL", data, mask) end
        return data
      end)
    end

    -- D. ISR bookkeeping writes (counter/status-save/state byte)
    for _, mir in ipairs(MIRRORS) do
      local a = BOOK | mir
      tap("w", a, a + 15, function(offset, data, mask)
        if not polling then
          emit("W", offset, string.format("book+%x", (offset & 0x1fffffff) - BOOK), data, mask)
        end
        return data
      end)
    end

    installed = true
    manager.machine:logerror("[desc] taps installed\n")
  end)
  if not ok then manager.machine:logerror("[desc] install error: " .. tostring(err) .. "\n") end
end

-- ---- frame poll ------------------------------------------------------------
local pv = { ptr = -1, d0 = -1, d4 = -1, ctr = -1, st = -1 }
local function poll()
  if space == nil then return end
  polling = true
  local ok, err = pcall(function()
    local ptr = space:read_dword(PTR_CELL | 0x80000000)
    if ptr ~= pv.ptr then
      flush(); seq = seq + 1
      f:write(string.format("%-6d f=%d pc=-------- POLL %08x PTRCELL    = %08x (was %08x)\n",
        seq, frame, PTR_CELL | 0x80000000, ptr, pv.ptr))
      pv.ptr = ptr
      if ptr ~= 0 and (ptr & 0x1fffffff) < 0x00800000 and (ptr & 0x1fffffff) ~= (desc_ptr & 0x1fffffff) then
        desc_ptr = ptr
        install_desc_taps(ptr)
      end
    end
    if desc_ptr ~= 0 then
      local d0 = space:read_dword(desc_ptr)
      local d4 = space:read_dword(desc_ptr + 4)
      if d0 ~= pv.d0 or d4 ~= pv.d4 then
        flush(); seq = seq + 1
        f:write(string.format("%-6d f=%d pc=-------- POLL %08x desc+0/+4  = %08x %08x\n",
          seq, frame, desc_ptr, d0, d4))
        pv.d0 = d0; pv.d4 = d4
      end
    end
    local ctr = space:read_dword(BOOK | 0x80000000)
    local st  = space:read_byte((BOOK | 0x80000000) + 0xf)
    if ctr ~= pv.ctr or st ~= pv.st then
      flush(); seq = seq + 1
      f:write(string.format("%-6d f=%d pc=-------- POLL %08x ctr/state  = %08x %02x\n",
        seq, frame, BOOK | 0x80000000, ctr, st))
      pv.ctr = ctr; pv.st = st
    end
  end)
  polling = false
  if not ok then manager.machine:logerror("[desc] poll error: " .. tostring(err) .. "\n") end
end

if emu.register_prestart then emu.register_prestart(install) end
emu.register_frame_done(function()
  frame = frame + 1
  if not installed then install() end
  poll()
  if frame % 60 == 0 then
    manager.machine:logerror(string.format("[desc] frame=%d seq=%d\n", frame, seq))
  end
end)

if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function()
    flush()
    f:write(string.format("# end frame=%d seq=%d desc_ptr=%08x\n", frame, seq, desc_ptr))
    f:close()
    manager.machine:logerror(string.format("[desc] DONE frame=%d seq=%d\n", frame, seq))
  end)
end
