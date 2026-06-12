-- mame_inject.lua -- inject a 573 savestate (RAM+VRAM+CPU regs) into a running
-- MAME hyperbbc and let its CORRECT GPU re-render that exact frame, then snapshot.
-- Files (scp'd to dell by the wrapper):
--   /tmp/mame_inj_ram.bin  (2 MiB main RAM)  -> program space @ 0x00000000
--   /tmp/mame_inj_vram.bin (1 MiB VRAM)      -> gpu item 0/p_vram
--   /tmp/mame_inj_regs.lua (CPU regs table)  -> maincpu.state
-- Env: INJ_FRAME (frame to inject at; default 4200), INJ_SNAPAFTER (default 12).
local INJ_FRAME = tonumber(os.getenv("INJ_FRAME") or "4200")
local SNAPAFTER = tonumber(os.getenv("INJ_SNAPAFTER") or "12")
local RAM="/tmp/mame_inj_ram.bin"
local VRAM="/tmp/mame_inj_vram.bin"
local REGS="/tmp/mame_inj_regs.bin"
local f=0
local state=0  -- 0=waiting,1=injected

local function inject()
  local M=manager.machine
  local cpu=M.devices[":maincpu"]
  local sp=cpu.spaces["program"]
  -- main RAM -> 0x00000000.. (write_u32 loop)
  local fh=io.open(RAM,"rb"); local d=fh:read("*a"); fh:close()
  local n=#d
  for i=0,n-4,4 do sp:write_u32(i, (string.unpack("<I4",d,i+1))) end
  emu.print_info("INJECT ram "..n.." bytes")
  -- VRAM -> gpu 0/p_vram (per 16-bit element; offset in bytes)
  local g=M.devices[":gpu"]; local vit=emu.item(g.items["0/p_vram"])
  local vh=io.open(VRAM,"rb"); local v=vh:read("*a"); vh:close()
  local vn=#v
  for i=0,vn-2,2 do vit:write(i, (string.unpack("<I2",v,i+1)), 2) end
  emu.print_info("INJECT vram "..vn.." bytes (item size="..tostring(vit.size)..")")
  -- CPU regs from regs.bin (45 LE u32, fixed order). Read via io (no dofile).
  local rh=io.open(REGS,"rb"); local rd=rh:read("*a"); rh:close()
  local names={"pc","hi","lo","SR","Cause","EPC","BPC","BDA","DCIC","BadA",
    "BDAM","BPCM","PRId","zero","at","v0","v1","a0","a1","a2","a3","t0","t1",
    "t2","t3","t4","t5","t6","t7","s0","s1","s2","s3","s4","s5","s6","s7",
    "t8","t9","k0","k1","gp","sp","fp","ra"}
  local st=cpu.state
  emu.print_info("INJECT state type="..type(st))
  local set,miss=0,0
  for i=1,#names do
    local v=string.unpack("<I4", rd, (i-1)*4+1)
    local nm=names[i]
    local ok=pcall(function() st[nm].value=v end)
    if ok then set=set+1 else miss=miss+1; if miss<=3 then emu.print_info("INJECT regfail "..nm) end end
  end
  emu.print_info("INJECT regs set="..set.." miss="..miss)
end

emu.register_frame_done(function()
  f=f+1
  if state==0 and f>=INJ_FRAME then
    state=1
    local ok,err=pcall(inject)
    emu.print_info("INJECT ok="..tostring(ok)..(err and (" err="..tostring(err)) or ""))
  elseif state==1 and f>=INJ_FRAME+SNAPAFTER then
    state=2
    pcall(function() manager.machine.video:snapshot() end)
    emu.print_info("INJECT snapshot frame "..f)
  end
end)
