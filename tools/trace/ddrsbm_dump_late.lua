-- ddrsbm_dump_late.lua -- NO TAPS AT ALL (taps crash MAME 0.285 during the ddrsbm
-- PACKET/DMA phase at f141 -- v1/v6/v7 all died there). Just: wait to frame 4800
-- (game fully booted; MAME boots ddrsbm fine), then dump the game-main RAM windows.
local f = io.open("/tmp/ddrsbm_dump_late.log", "w")
f:setvbuf("line")
local cpu = manager.machine.devices[":maincpu"]
local space = nil
local frame = 0
local dumped = false
local function dump_bin(fn, base, len)
  local wf = io.open(fn, "wb")
  local chunk = {}
  for a = base, base + len - 4, 4 do
    local v = space:read_u32(a)
    chunk[#chunk + 1] = string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)
    if #chunk >= 1024 then wf:write(table.concat(chunk)); chunk = {} end
  end
  wf:write(table.concat(chunk))
  wf:close()
  f:write(string.format("# BIN %s base=%08x len=0x%x (f=%d)\n", fn, base, len, frame))
end
emu.register_frame_done(function()
  frame = frame + 1
  if frame % 300 == 0 then f:write(string.format("# alive f=%d\n", frame)) end
  if not dumped and frame >= 4800 then
    dumped = true
    space = cpu.spaces["program"]
    local ok, err = pcall(function()
      local pcv = (cpu.state ~= nil) and cpu.state["pc"].value or 0
      f:write(string.format("# dump point: pc=%08x\n", pcv))
      dump_bin("/tmp/ddrsbm_gwait.bin", 0x800a8000, 0x8000)
      dump_bin("/tmp/ddrsbm_gmain.bin", 0x800b0000, 0x4000)
    end)
    if not ok then f:write("# dump error: " .. tostring(err) .. "\n") end
  end
end)
if emu.add_machine_stop_notifier then
  emu.add_machine_stop_notifier(function() f:write(string.format("# end f=%d\n", frame)); f:close() end)
end
