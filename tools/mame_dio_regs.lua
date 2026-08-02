-- mame_dio_regs.lua -- MAME behavioural ORACLE for the k573dio MP3 registers.
--
-- Answers the question our own instrumentation structurally cannot: what does the
-- GAME write when playback should stop? On hardware every config adoption reads
-- fpga_ctrl[14:13] = 1 (16/16 samples), so an early stop (failed stage) is invisible
-- to us. MAME is authoritative for register-level intent, so log every write to the
-- k573dio page and read the truth off the sequence.
--
-- Register map -- taken from OUR rtl/k573dio.v :666-688 (write decode), which is
-- where the core's behaviour actually comes from. An earlier version of this file
-- mis-annotated 0xe0..0xe6 as crypto keys; they are LAMPS. Writes:
--   0xa0/a2  mp3_start hi/lo      0xa4/a6  mp3_end hi/lo
--   0xa8     crypto_key1          0xea     crypto_key2      0xec  crypto_key3
--   0xac     MAS3507D I2C bit-bang  <- scl=din[13], sda=din[12]
--   0xae     fpga_ctrl            <- bit15 FRAME_COUNTER_ENABLE,
--                                     bit14 STREAMING_ENABLE, bit13 MP3_ENABLE
--            Ground truth: MAME k573fpga.h enum (FPGA_MP3_ENABLE = 13,
--            FPGA_STREAMING_ENABLE = 14, FPGA_FRAME_COUNTER_ENABLE = 15), and our
--            rtl/k573_mp3stream.v:140 `stream_en = fpga_ctrl[13] & fpga_ctrl[14]`.
--            An earlier version of this file had 13 and 14 SWAPPED, which inverted
--            every MP3_EN/STREAM_EN label it ever printed -- and the stop event this
--            whole oracle exists to find is bit14 going low.
--   0xb0/b2  ram_adr hi/lo        0xb6/b8  ram_read_adr hi/lo   0xb4  ram data port
--   0xe0/e2/e4/e6, 0xfa/fc/fe     lamps    0xee  one-wire       0xf8  FPGA bitstream
--
-- WHY THE I2C DECODE MATTERS: our core LATCHES mas_scl/mas_sda and reads them back
-- (k573dio.v:672, :715) and nothing else -- the actual MP3 decode is host-side
-- (minimp3 in s573mp3.cpp), so there is no MAS3507D model at all. Every command the
-- game sends the decoder chip -- mute, volume, stop -- is dropped on the floor. That
-- is a candidate explanation for the open bug (music keeps playing when a stage is
-- failed) with the right shape: a stop signal we are structurally unable to see.
-- So decode the bus rather than logging 1181 lines of bit-bang per minute.
--
-- ============================ LIFETIME -- READ THIS ==========================
-- EVERY MAME Lua object here is GC-OWNED. install_write_tap returns a
-- memory_passthrough_handler and add_machine_*_notifier returns a subscription;
-- when that object is collected the tap/notifier is SILENTLY REMOVED. An
-- -autoboot_script chunk's LOCALS die the moment the chunk returns, so a tap
-- stored in a local is live only until the next GC cycle.
--
-- That is exactly what burned the first three runs (2026-07-31): the log always
-- died at t=3.209 MID-bitstream-upload -- 96 consecutive off=f8 writes then
-- nothing -- and 40 s / 400 s / 700 s runs produced byte-identical output. Read
-- naively that says "the game stops touching the DIO after boot"; it actually
-- says "the tap was collected". Zero fpga_ctrl writes was an artifact, not a
-- finding.
--
-- So: every handle lives in a GLOBAL (_G.DIO). Do not demote these to locals.
-- ============================================================================
--
-- LESSONS compliance: Lua print() is buffered and LOST on SIGTERM, so everything
-- goes through io.open + :flush() per line. A positive control is armed too -- if
-- the tap never fires at all the run is a dead instrument, not a null result.

DIO = {}                      -- GLOBAL: keeps taps/notifiers/file alive for the run

local OUT = "/tmp/dio_regs.log"
DIO.f = io.open(OUT, "w")
local function say(s)
  DIO.lines = (DIO.lines or 0) + 1
  if DIO.lines > 400000 then
    if not DIO.capped then
      DIO.capped = true
      DIO.f:write("# LINE CAP HIT -- further per-write lines suppressed; counters still run\n")
      DIO.f:flush()
    end
    return
  end
  DIO.f:write(s .. "\n"); DIO.f:flush()
end

say("# k573dio register-write oracle")

DIO.cpu   = manager.machine.devices[":maincpu"]
DIO.space = DIO.cpu.spaces["program"]

local function now()
  local ok, t = pcall(function() return manager.machine.time:as_double() end)
  if ok and t then return t end
  return -1
end

local function pc()
  local ok, v = pcall(function() return DIO.cpu.state["pc"].value end)
  if ok and v then return v end
  return 0
end

-- decode the bits we actually care about so the log is readable without a manual
-- Names from our rtl/k573dio.v write decode, plus the MAME-only registers our RTL
-- does NOT implement (marked) -- knowing those exist is half the point of an oracle.
local NAMES = {
  [0xa0] = "mp3_start hi", [0xa2] = "mp3_start lo",
  [0xa4] = "mp3_end hi",   [0xa6] = "mp3_end lo",
  [0xa8] = "crypto_key1",  [0xea] = "crypto_key2",  [0xec] = "crypto_key3",
  [0xaa] = "mpeg_ctrl",
  [0xb0] = "ram_adr hi",   [0xb2] = "ram_adr lo",   [0xb4] = "ram data port",
  [0xb6] = "ram_read_adr hi", [0xb8] = "ram_read_adr lo",
  [0xee] = "one-wire",     [0xf8] = "fpga bitstream",
  [0xe0] = "lamp1", [0xe2] = "lamp0", [0xe4] = "lamp3", [0xe6] = "lamp7",
  [0xfa] = "lamp4", [0xfc] = "lamp5 / output_5", [0xfe] = "lamp2",
  [0x90] = "network_id (NOT in our RTL)",
  [0xc0] = "network buffer (NOT in our RTL)",
}

local function annotate(off, data)
  if off == 0xae then
    return string.format("  fpga_ctrl  fce=%d STREAM_EN=%d MP3_EN=%d",
      (data >> 15) & 1, (data >> 14) & 1, (data >> 13) & 1)
  end
  local n = NAMES[off]
  if n then return "  " .. n end
  return ""
end

-- ---------------------------------------------------------------- I2C decoder
-- The CPU bit-bangs the MAS3507D control bus through 0xac, one pin-state write at
-- a time, so a raw log is unreadable and enormous. Reassemble it: START = SDA
-- falls while SCL high, STOP = SDA rises while SCL high, bits sample on SCL rising,
-- every 9th clock is the slave's ACK (a READ of 0xac, so we never see it driven --
-- we record whatever the bus floats to and don't count it as data).
DIO.i2c = { scl = 1, sda = 1, run = false, bits = 0, val = 0,
            ack = false, bytes = {}, t0 = 0, pc0 = 0, n = 0 }

-- Consecutive IDENTICAL transactions are collapsed. ddrsbm polls the MAS3507D frame
-- counter ("3a 69" then a 2-byte read) every video frame, which is ~120 transactions
-- a second and buries the handful that matter. Only a CHANGE is interesting.
local function i2c_emit_repeat()
  local q = DIO.i2c
  if q.rep and q.rep > 0 then
    say(string.format("%8.3f   [... previous I2C transaction repeated x%d, through t=%.3f]",
      q.rep_t0, q.rep, q.rep_t1))
    q.rep = 0
  end
end

local function i2c_flush(reason, t)
  local q = DIO.i2c
  if #q.bytes == 0 then return end
  local hex = {}
  for i = 1, #q.bytes do hex[i] = string.format("%02x", q.bytes[i]) end
  local sig = table.concat(hex, " ")
  q.n = q.n + 1

  if sig == q.last_sig then
    q.rep = (q.rep or 0) + 1
    if q.rep == 1 then q.rep_t0 = q.t0 end
    q.rep_t1 = q.t0
    q.bytes = {}
    return
  end
  i2c_emit_repeat()
  q.last_sig = sig

  local addr = q.bytes[1]
  local dir = (addr & 1) == 1 and "rd" or "wr"
  say(string.format("%8.3f pc=%08x I2C#%d %s addr=%02x %s [%d bytes: %s]",
    q.t0, q.pc0, q.n, reason, addr >> 1, dir, #q.bytes, sig))
  q.bytes = {}
end

local function i2c_step(new_scl, new_sda, t, pcv)
  local q = DIO.i2c
  local osc, osd = q.scl, q.sda
  if osc == 1 and new_scl == 1 and osd ~= new_sda then
    if new_sda == 0 then                    -- START (or repeated START)
      i2c_flush("Sr", t)
      q.run, q.bits, q.val, q.ack = true, 0, 0, false
      q.t0, q.pc0 = t, pcv
    else                                    -- STOP
      i2c_flush("P", t)
      q.run = false
    end
  elseif osc == 0 and new_scl == 1 and q.run then
    if q.ack then
      q.ack = false                         -- 9th clock: slave ACK, not data
    else
      q.val = ((q.val << 1) | new_sda) & 0xff
      q.bits = q.bits + 1
      if q.bits == 8 then
        q.bytes[#q.bytes + 1] = q.val
        q.val, q.bits, q.ack = 0, 0, true
        if #q.bytes >= 32 then i2c_flush("overlong", t) end
      end
    end
  end
  q.scl, q.sda = new_scl, new_sda
end

DIO.writes = 0
DIO.ctrl_writes = 0
DIO.lines = 0

-- BULK PORTS: 0xf8 (FPGA bitstream upload) and 0xb4 (DRAM data port) carry pure
-- payload, one 16-bit word per write, and both run for millions of writes -- the
-- boot DRAM check alone produced a 104 MB log in ~2 emulated seconds and was on
-- course to fill dell's 7.5 GB /tmp. Never log them per-write; count each burst and
-- emit one summary when it ends. Everything else is rare enough to log verbatim.
-- 0xc0 is the network buffer (MAME k573dio; our RTL does not implement it). ddrsbm
-- hammers it -- 201,476 hits in one run, the single most-written register, and pure
-- noise for an audio investigation. Leaving it uncollapsed drove a 1500 s run into
-- the line cap at t~501 and silently discarded the last 1000 emulated seconds.
local BULK = { [0xb4] = true, [0xf8] = true, [0xc0] = true }
DIO.bulk_n = {}
DIO.bulk_t0 = {}

DIO.capped = false

local function bulk_flush(off, t)
  local n = DIO.bulk_n[off]
  if n and n > 0 then
    say(string.format("%8.3f  [%s x%d words, through t=%.3f]",
      DIO.bulk_t0[off], NAMES[off] or string.format("off=%02x", off), n, t))
    DIO.bulk_n[off] = 0
  end
end

local function bulk_flush_all(t)
  for off in pairs(BULK) do bulk_flush(off, t) end
end

-- k573dio sits at 0x1f640000 in the sys573 program map.
local BASE = 0x1f640000
local ok, err = pcall(function()
  DIO.tap = DIO.space:install_write_tap(BASE, BASE + 0xff, "diotap",
    function(offset, data, mask)
      DIO.writes = DIO.writes + 1
      local base_off = offset - BASE
      if base_off < 0 or base_off > 0xff then base_off = offset & 0xff end

      -- ---------------------------------------------------------------------
      -- 32-BIT LANE SPLIT. The PSX bus is 32 bits wide, so MAME reports every
      -- tap hit at a DWORD-ALIGNED offset and tells you which 16-bit half is
      -- live via `mask`. The k573dio's registers are 16-bit, so the register at
      -- base+2 arrives in the UPPER half of `data`.
      --
      -- Getting this wrong is invisible and total: an earlier version did
      -- `data & 0xffff` and keyed off the aligned offset alone, so 0xa2, 0xa6,
      -- 0xaa and -- fatally -- 0xae (fpga_ctrl) were NEVER decoded. 0xae rides
      -- in the upper half of an access at 0xac, which was being swallowed whole
      -- by the I2C branch below. The log then said "fpga_ctrl_writes=0" for
      -- 1200 emulated seconds of a game that was demonstrably playing.
      --
      -- The tell: every offset ever logged was a multiple of 4. Not one was
      -- 2 mod 4. Real 16-bit register traffic cannot look like that.
      -- ---------------------------------------------------------------------
      local halves = {}
      if (mask & 0x0000ffff) ~= 0 then
        halves[#halves + 1] = { base_off,     data & 0xffff }
      end
      if (mask & 0xffff0000) ~= 0 then
        halves[#halves + 1] = { base_off + 2, (data >> 16) & 0xffff }
      end
      -- If mask is absent/zero on some build, fall back to the low half rather
      -- than silently dropping the write.
      if #halves == 0 then halves[1] = { base_off, data & 0xffff } end

      for i = 1, #halves do
        local off, val = halves[i][1], halves[i][2]

        if off == 0xac then
          -- MAS3507D control bus: decode, don't dump. See the header.
          i2c_step((val >> 13) & 1, (val >> 12) & 1, now(), pc())
        elseif BULK[off] then
          -- Bulk payload ports: count, never log per-write. See BULK above.
          local n = DIO.bulk_n[off] or 0
          if n == 0 then DIO.bulk_t0[off] = now() end
          DIO.bulk_n[off] = n + 1
        else
          bulk_flush_all(now())
          if off == 0xae then
            DIO.ctrl_writes = DIO.ctrl_writes + 1
            -- MP3_ENABLE (bit14) actually going high is the only honest "audio is
            -- happening" signal. Plain ctrl_writes > 0 is useless as a trigger: boot
            -- init writes 0xae fourteen times before the game is anywhere near a song.
            -- Playback is actually running only when BOTH enables are set
            -- (rtl/k573_mp3stream.v:140 stream_en = fpga_ctrl[13] & fpga_ctrl[14]).
            if ((val >> 13) & 3) == 3 then DIO.mp3_en_seen = true end
          end
          if (off % 4) == 2 then DIO.odd_half = (DIO.odd_half or 0) + 1 end
          say(string.format("%8.3f pc=%08x off=%02x data=%04x%s",
            now(), pc(), off, val, annotate(off, val)))
        end
      end
      return data
    end)
end)

if not ok then
  say("FATAL: install_write_tap failed: " .. tostring(err))
elseif DIO.tap == nil then
  say("FATAL: install_write_tap returned nil -- handler not retained, tap will be GC'd")
else
  say("# tap armed on " .. string.format("%08x..%08x", BASE, BASE + 0xff)
      .. " handle=" .. tostring(DIO.tap))
end

-- POSITIVE CONTROL: a periodic liveness line. If the run ends with liveness ticks
-- but zero writes, the tap is wrong (or the base address is) -- NOT "the game never
-- writes". Distinguishing those two is the whole point. It samples the PC too, so a
-- stalled game (same PC forever) is distinguishable from a quiet one.
--
-- The notifier SUBSCRIPTION is GC-owned like the tap -- hence DIO.frame_sub. The
-- earlier version threw the return value away inside a pcall and never fired once.
-- AUTO-PRESS: headless MAME delivers no input, and ddrsbm will sit forever on
-- "Please press test button" (both at the install prompt and again at INITIALIZE
-- COMPLETE). A run that never leaves that screen logs zero MP3 activity, which
-- reads exactly like "the game never enables MP3" -- that is what the first day of
-- oracle runs actually measured. So detect the park and press.
--
-- Park = the PC stayed inside a <0x400 window for a whole 5 s sample. Guarded two
-- ways so it can never fire during real play (where a test press would open the
-- operator menu): it stops permanently once any fpga_ctrl write is seen, and it is
-- capped at MAX_PRESSES.
local MAX_PRESSES = 4
DIO.presses = 0
DIO.press_until = -1
DIO.last_press = -100

DIO.svc, DIO.coin, DIO.start = nil, nil, nil
for pname, port in pairs(manager.machine.ioport.ports) do
  for fname, field in pairs(port.fields) do
    if fname == "Service Mode"    then DIO.svc   = field end
    if fname == "Coin 1"          then DIO.coin  = field end
    if fname == "1 Player Start"  then DIO.start = field end
  end
end
say(DIO.svc and "# test button found (:: Service Mode)" or "# WARNING: no test button")

-- PLAY MODE (opt-in): create /tmp/s573_play_song on dell before the run.
--
-- Goal: reach a song that stops EARLY -- a FAILED STAGE -- with nobody at the
-- cabinet, because that is the one case the enable-clear path has not been shown
-- to cover.
--
-- FIRST ATTEMPT, WRONG (2026-07-31): coin in, press Start a few times, then go
-- silent and let DDR's menu timers auto-start the highlighted song. They don't.
-- The run sat in song select, timed out all the way back to the title screen
-- ("press a button", 1 credit still in), and logged NO audio activity for 455
-- straight emulated seconds. Menu timeouts in this game go BACKWARDS, not forwards.
--
-- What actually works: press 1P Start continuously, forever. It walks mode select
-- and song select, starts the song, and is harmless during play (DDR arcade has no
-- pause). Crucially it is NOT a pad arrow -- the dance steps are the only input
-- that keeps the life bar up, so the stage still fails on its own. Coins are topped
-- up periodically so a failed credit does not end the loop.
--
-- Gated on a marker file rather than an env var because the hub runner builds the
-- MAME command line and does not forward environment.
DIO.play = (function()
  local h = io.open("/tmp/s573_play_song", "r")
  if h then h:close(); return true end
  return false
end)()
say(DIO.play and "# PLAY MODE armed (coin/start injection)" or "# observe mode (no input injection)")

-- When to start feeding input. Absolute time is a bad trigger -- boot length varies
-- with the flash/DRAM checks. Prefer "20 s after the game first touches the MP3 path"
-- (it is alive and in attract by then), with a hard fallback in case attract never
-- drives MP3 at all.
local INPUT_FALLBACK_AT = 420.0   -- used only if no MP3 activity by then
local COIN_EVERY        =  5.0    -- 2 COINS PER CREDIT on this cabinet, so coin often
local START_EVERY       =  3.0    -- walk the menus; never an arrow, so stages fail
DIO.input_t0 = nil
DIO.next_coin, DIO.next_start = 0, 0
DIO.hold = {}    -- field -> {t = release time, name = label}

local function tap_button(field, name, t, dur)
  if not field then return end
  pcall(function() field:set_value(1) end)
  DIO.hold[field] = { t = t + (dur or 0.25), name = name }
  say(string.format("%8.3f INPUT %s down", t, name))
end

DIO.frames = 0
DIO.pcmin, DIO.pcmax = 0xffffffff, 0
local ok_fn, fn_err = pcall(function()
  DIO.frame_sub = emu.add_machine_frame_notifier(function()
    DIO.frames = DIO.frames + 1
    local t = now()
    local p = pc()
    if p < DIO.pcmin then DIO.pcmin = p end
    if p > DIO.pcmax then DIO.pcmax = p end

    -- release a held press
    if DIO.press_until > 0 and t >= DIO.press_until then
      DIO.press_until = -1
      pcall(function() DIO.svc:set_value(0) end)
      say(string.format("%8.3f TEST BUTTON UP", t))
    end

    -- release any tapped buttons whose hold has expired
    for field, h in pairs(DIO.hold) do
      if t >= h.t then
        pcall(function() field:set_value(0) end)
        DIO.hold[field] = nil
        say(string.format("%8.3f INPUT %s up", t, h.name))
      end
    end

    -- PLAY MODE: coins + start, then deliberate silence so a stage fails.
    if DIO.play then
      if DIO.input_t0 == nil then
        if DIO.mp3_en_seen then
          DIO.input_t0 = t + 20.0
          say(string.format("%8.3f INPUT armed: MP3_ENABLE seen, coining from t=%.1f",
            t, DIO.input_t0))
        elseif t >= INPUT_FALLBACK_AT then
          DIO.input_t0 = t
          say(string.format("%8.3f INPUT armed by FALLBACK -- no MP3 activity in attract", t))
        end
        if DIO.input_t0 then
          DIO.next_coin  = DIO.input_t0
          DIO.next_start = DIO.input_t0 + 4.0
        end
      else
        -- Coin first (a credit must exist before Start does anything), then keep
        -- tapping Start forever. Only one button per tick so they never overlap.
        if t >= DIO.next_coin then
          DIO.next_coin = t + COIN_EVERY
          tap_button(DIO.coin, "Coin 1", t)
        elseif t >= DIO.next_start then
          DIO.next_start = t + START_EVERY
          tap_button(DIO.start, "1P Start", t)
        end
      end
    end

    if DIO.frames % 300 == 0 then
      bulk_flush_all(t)   -- so a long burst still reports progress
      i2c_emit_repeat()   -- and a long poll run reports too
      say(string.format(
        "# alive t=%.1f frames=%d pc=%08x range=%08x..%08x writes=%d fpga_ctrl_writes=%d i2c=%d",
        t, DIO.frames, p, DIO.pcmin, DIO.pcmax, DIO.writes, DIO.ctrl_writes, DIO.i2c.n))
      pcall(function() manager.machine.video:snapshot() end)

      if DIO.svc and not DIO.mp3_en_seen and DIO.presses < MAX_PRESSES
         and DIO.press_until < 0 and (t - DIO.last_press) > 15.0
         and (DIO.pcmax - DIO.pcmin) < 0x400 then
        DIO.presses = DIO.presses + 1
        DIO.last_press = t
        DIO.press_until = t + 2.0
        pcall(function() DIO.svc:set_value(1) end)
        say(string.format("%8.3f TEST BUTTON DOWN (#%d -- parked in %08x..%08x)",
          t, DIO.presses, DIO.pcmin, DIO.pcmax))
      end
      DIO.pcmin, DIO.pcmax = 0xffffffff, 0
    end
  end)
end)
if not ok_fn then
  say("# WARNING: frame notifier raised: " .. tostring(fn_err))
elseif DIO.frame_sub == nil then
  say("# WARNING: frame notifier returned nil subscription -- liveness will be GC'd")
else
  say("# liveness armed (frame notifier)")
end

pcall(function()
  DIO.stop_sub = emu.add_machine_stop_notifier(function()
    bulk_flush_all(now())
    i2c_flush("eof", now())
    i2c_emit_repeat()
    say(string.format(
      "# DONE t=%.1f frames=%d total_writes=%d fpga_ctrl_writes=%d i2c=%d presses=%d",
      now(), DIO.frames, DIO.writes, DIO.ctrl_writes, DIO.i2c.n, DIO.presses))
    -- SELF-CHECK for the 32-bit lane bug. The k573dio's registers are 16-bit and
    -- plenty of the interesting ones sit at 2 mod 4 (0xa2/0xa6/0xaa/0xae). If a run
    -- logged real traffic and NONE of it landed on an odd half, the lane split is
    -- broken again and every "register never written" conclusion is worthless.
    local odd = DIO.odd_half or 0
    if DIO.lines > 200 and odd == 0 then
      say("# INSTRUMENT WARNING: zero writes at offset 2 mod 4 across the whole run.")
      say("#   That is the signature of the 32-bit lane bug -- suspect `mask` handling")
      say("#   before believing any 'register never written' claim from this log.")
    else
      say(string.format("# self-check: %d writes decoded at offset 2 mod 4 (lane split OK)", odd))
    end
    DIO.f:flush()
  end)
end)
