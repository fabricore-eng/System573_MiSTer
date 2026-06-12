-- mame_snap_milestones.lua
-- Capture MAME snapshots at a series of frame milestones, then exit.
-- Used for objective reference-frame generation (System 573 oracle).
-- Snapshots are written to MAME's -snapshot_directory with -snapname.
-- Frame milestones are spread across the run so we catch multiple boot stages
-- even if the game stalls early.

local frame = 0
-- ~60 fps; milestones in FRAMES. Tuned for a long install/boot run.
-- (last milestone should be <= seconds_to_run*60)
local shots = {
  [30]   = true,  -- ~0.5s  (very early / BIOS)
  [180]  = true,  -- ~3s
  [600]  = true,  -- ~10s
  [1200] = true,  -- ~20s
  [2400] = true,  -- ~40s
  [3600] = true,  -- ~60s
  [5400] = true,  -- ~90s
  [7200] = true,  -- ~120s
  [9000] = true,  -- ~150s
  [10800]= true,  -- ~180s
  [14400]= true,  -- ~240s
  [18000]= true,  -- ~300s
}

emu.register_frame_done(function()
  frame = frame + 1
  if shots[frame] then
    -- snapshot() writes a PNG to the snapshot dir using -snapname
    manager.machine.video:snapshot()
    emu.print_info(string.format("[snap] frame %d captured", frame))
  end
end)
