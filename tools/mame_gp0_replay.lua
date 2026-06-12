-- mame_gp0_replay.lua -- render an exact 573 draw list through MAME's CORRECT GPU.
-- Parks MAME's CPU in a self-loop + stops its GPU DMA so the GPU is isolated, then
-- injects our VRAM (textures) and replays our GP0/GP1 command stream into the GPU
-- ports. MAME renders exactly our commands -> the correct version of our frame,
-- with NO CPU resume / coherence problem. Then snapshots.
--   /tmp/mame_inj_vram.bin   : 1 MiB VRAM (textures+fb) to preload (optional)
--   /tmp/mame_gp0_stream.txt : "<addr8> <time8> <data8>" lines (addr 4=GP1 else GP0)
-- Env: INJ_FRAME (default 1500), GP0_NOVRAM=1 to skip VRAM preload.
local VRAM="/tmp/mame_inj_vram.bin"
local STREAM="/tmp/mame_gp0_stream.txt"
local INJ=tonumber(os.getenv("INJ_FRAME") or "600")
local NOVRAM=(os.getenv("GP0_NOVRAM")=="1")
local f=0; local st=0

local function go()
  local M=manager.machine
  local sp=M.devices[":maincpu"].spaces["program"]
  -- park the CPU in an infinite self-loop so it stops driving the GPU/DMA
  sp:write_u32(0x001fff00, 0x1000ffff)  -- beq $zero,$zero,-1
  sp:write_u32(0x001fff04, 0x00000000)  -- nop (branch delay slot)
  M.devices[":maincpu"].state["pc"].value=0x801fff00
  -- stop the GPU DMA channel (ch2 CHCR) so it can't inject commands
  sp:write_u32(0x1f8010a8, 0x00000000)
  -- inject VRAM (textures + framebuffer)
  if not NOVRAM then
    local g=M.devices[":gpu"]; local vit=emu.item(g.items["0/p_vram"])
    local vh=io.open(VRAM,"rb")
    if vh then local v=vh:read("*a"); vh:close()
      for i=0,#v-2,2 do vit:write(i,(string.unpack("<I2",v,i+1)),2) end
      emu.print_info("GP0REP vram injected "..#v) end
  end
  -- GP1 reset, then replay the stream to the GPU ports
  sp:write_u32(0x1f801814, 0x00000000)
  local n=0
  for line in io.lines(STREAM) do
    local a,_,d = line:match("^%s*(%x+)%s+(%x+)%s+(%x+)")
    if a and d then
      local av=tonumber(a,16); local dv=tonumber(d,16)
      sp:write_u32((av==4) and 0x1f801814 or 0x1f801810, dv); n=n+1
    end
  end
  emu.print_info("GP0REP wrote "..n.." words")
end

emu.register_frame_done(function()
  f=f+1
  if st==0 and f>=INJ then
    st=1; local ok,e=pcall(go)
    emu.print_info("GP0REP ok="..tostring(ok)..(e and (" err="..tostring(e)) or ""))
  elseif st==1 and f>=INJ+8 then
    st=2; pcall(function() manager.machine.video:snapshot() end)
    emu.print_info("GP0REP snapshot frame "..f)
  end
end)
