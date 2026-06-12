-- =============================================================================
-- cass_validate_tap.lua -- pin a cassette read+validate fn's outcome.
--
-- *** CORRECTION (2026-06-12) ***
--   The on-screen "-11N" wall is NOT this fn. -11N is the 573 BIOS BOOT-TIME
--   cassette SIGNATURE check (it reads cassette blocks 0,0,1,2 and verifies an
--   authentic signature in block 1 = 81 00 29 00 00 18 eb 52). That signature is
--   authentic-DUMP data, so clearing -11N requires the real gx908ja.u1 dump --
--   NOT a synthesizable token. HW-confirmed 2026-06-12: with the real dump the
--   board clears -11N and runs. The fn below (0x80036ec4) is the IN-GAME check
--   (runs from the CD program, AFTER boot); its failure code is -3 ("-3N"), and
--   it is reconstructable from game plaintext. The taps still observe a valid
--   cassette read+validate path; just don't attribute -11N to it.
--
-- From the BIOS RAM disasm (workflow keystone):
--   0x80036ec4  IN-GAME cassette read+validate fn (returns v0: 0=ok, -3=incorrect,
--               -12=absent, ...). (Originally mis-labeled as the -11N source; see
--               the correction above -- -11N is the separate BIOS boot signature.)
--   0x80036f3c  jal 0x8003703c  -> v0 = ~(data[0]+data[1]) & 0xff
--   0x80036f44  lbu v1, 0x14(sp) = data[4]
--   0x80036f4c  bne v0,v1 -> 0x80036ef4 (sets s0=-11)  <-- THE -11 GATE
--   0x80038ac0  block-read primitive (a1=offset,a2=dest,a3=count)
--
-- Taps: entry, the 8 bytes actually read (sp+0x10 after the block read), the
-- checksum compare operands, and the final return code. Pure observation; no
-- state mutation.
-- =============================================================================
local PREFIX = os.getenv("CASS_PREFIX") or "/tmp/cassval"
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local f = io.open(PREFIX .. "_trace.txt", "w")
f:setvbuf("line")

local function reg(n)
  local ok,v = pcall(function() return cpu.state[n].value end)
  if ok then return v end
  return 0
end
local function now() return machine.time.seconds + machine.time.attoseconds/1e18 end
local function rb(a)
  local ok,v = pcall(function() return mem:read_u8(a) end)
  if ok then return v end
  return -1
end

_G.taps = {}
local taps = _G.taps
local n_entry, n_cmp, n_blk = 0,0,0

-- read fn entry 0x80036ec4
taps[#taps+1] = mem:install_read_tap(0x80036ec4, 0x80036ec7, "ent", function(off,data,mask)
  n_entry = n_entry + 1
  if n_entry <= 40 then
    f:write(string.format("%10.6f ENTRY  0x80036ec4 a0=%08X a1=%08X\n", now(), reg("A0"), reg("A1")))
  end
end)

-- the checksum compare site 0x80036f4c (bne v0,v1). At this fetch, v0=~(d0+d1)&ff, v1=d4.
-- sp+0x10 holds the 8 bytes just read. Dump them + the compare operands.
taps[#taps+1] = mem:install_read_tap(0x80036f4c, 0x80036f4f, "cmp", function(off,data,mask)
  n_cmp = n_cmp + 1
  if n_cmp <= 40 then
    local sp = reg("SP")
    local b = {}
    for i=0,7 do b[i] = rb(sp + 0x10 + i) end
    f:write(string.format(
      "%10.6f CMP    chk(v0)=%02X data4(v1)=%02X  read8=[%02X %02X %02X %02X %02X %02X %02X %02X]  %s\n",
      now(), reg("V0") & 0xff, reg("V1") & 0xff,
      b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
      ((reg("V0") & 0xff) == (reg("V1") & 0xff)) and "PASS-checksum" or "FAIL->-11"))
  end
end)

-- block-read primitive 0x80038ac0: log offset/count requested
taps[#taps+1] = mem:install_read_tap(0x80038ac0, 0x80038ac3, "blk", function(off,data,mask)
  n_blk = n_blk + 1
  if n_blk <= 60 then
    f:write(string.format("%10.6f BLKRD  off=%d dest=%08X cnt=%d\n", now(), reg("A1"), reg("A2"), reg("A3")))
  end
end)

-- the -11 set site 0x80036ef8 (addiu s0,zero,-0xb) and the ok return path is harder;
-- instead tap the dispatch jr at error handlers: just tap the -11 handler 0x8002568c entry.
taps[#taps+1] = mem:install_read_tap(0x8002568c, 0x8002568f, "h11", function(off,data,mask)
  f:write(string.format("%10.6f HANDLER -11 (SECURITY-CASSETTE ERROR -11N) reached pc-chain\n", now()))
end)
-- and the -3 / -12 / -2 handlers
taps[#taps+1] = mem:install_read_tap(0x80024a80, 0x80024a83, "h3", function(off,data,mask)
  f:write(string.format("%10.6f HANDLER -3 (INCORRECT SECURITY CASSETTE)\n", now()))
end)
taps[#taps+1] = mem:install_read_tap(0x80025718, 0x8002571b, "h12", function(off,data,mask)
  f:write(string.format("%10.6f HANDLER -12 (CASSETTE DOES NOT EXIST)\n", now()))
end)

-- snapshot near the end
local snapped = false
emu.add_machine_frame_notifier(function()
  if not snapped and now() > 8.0 then
    snapped = true
    machine:video():snapshot()
    f:write(string.format("%10.6f SNAPSHOT taken\n", now()))
  end
end)

f:write(string.format("# cass_validate_tap installed machine=%s\n", machine.system.name))
print("cass_validate_tap installed prefix=" .. PREFIX)
