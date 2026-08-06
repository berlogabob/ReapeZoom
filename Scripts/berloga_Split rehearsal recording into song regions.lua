-- @description Split rehearsal recording into song regions
-- @author berloga
-- @version 1.0
-- @provides [main] .
-- @about
--   # Split rehearsal recording into song regions
--
--   Turns one long live/rehearsal recording into named regions, one per song,
--   ready to render straight to streaming-loudness files.
--
--   Unlike REAPER's native Dynamic Split it does not split on silence: between
--   songs a rehearsal is full of talking, tuning and noodling. Instead it finds
--   quiet gaps of a minimum length, then discards the resulting spans that are
--   too short to be a song. The threshold is relative to the item's own peak, so
--   it works on quiet 32-bit-float captures without recalibration.
--
--   Select the item, run, rename the regions in the Region/Marker Manager,
--   then render with bounds "All project regions" and filename `$region`.
-- @changelog
--   Initial release

local PEAKRATE = 20 -- envelope buckets per second

----------------------------------------------------------------------
-- pure logic (no reaper.* in here, so it is testable standalone)
----------------------------------------------------------------------

-- env: array of linear amplitudes, one per bucket, at `rate` buckets/second.
-- opts: thresh (dB below peak), minGap, minSong, pad (all seconds).
-- returns array of {s=, e=} in seconds relative to the start of env.
local function find_songs(env, rate, opts)
  local n = #env
  if n == 0 then return {} end

  -- sliding-window max: a rest or a note decay inside a song is not a gap
  local half = math.max(1, math.floor(rate * 0.5))
  local smooth = {}
  for i = 1, n do
    local m = 0
    for j = math.max(1, i - half), math.min(n, i + half) do
      if env[j] > m then m = env[j] end
    end
    smooth[i] = m
  end

  local peak = 0
  for i = 1, n do if env[i] > peak then peak = env[i] end end
  if peak <= 0 then return {} end
  local limit = peak * 10 ^ (opts.thresh / 20)

  -- collect gaps: runs below the limit lasting at least minGap
  local minGapBuckets = math.max(1, math.floor(opts.minGap * rate))
  local gaps, run = {}, nil
  for i = 1, n do
    if smooth[i] < limit then
      run = run or i
    elseif run then
      if i - run >= minGapBuckets then gaps[#gaps + 1] = { run, i - 1 } end
      run = nil
    end
  end
  if run and n + 1 - run >= minGapBuckets then gaps[#gaps + 1] = { run, n } end

  -- spans between the gaps are candidate songs
  local songs, cursor = {}, 1
  local function add(a, b)
    local len = (b - a + 1) / rate
    if len >= opts.minSong then
      -- pad, but never past the surrounding gaps or the item bounds
      local s = math.max(1, a - opts.pad * rate)
      local e = math.min(n, b + opts.pad * rate)
      songs[#songs + 1] = { s = (s - 1) / rate, e = e / rate }
    end
  end
  for _, g in ipairs(gaps) do
    if g[1] > cursor then add(cursor, g[1] - 1) end
    cursor = g[2] + 1
  end
  if cursor <= n then add(cursor, n) end

  return songs
end

----------------------------------------------------------------------
-- standalone self-check: `lua "<this file>"`
----------------------------------------------------------------------

if not reaper then
  local rate = 20
  local env = {}
  local function fill(seconds, amp)
    for _ = 1, seconds * rate do env[#env + 1] = amp end
  end
  fill(60, 0.8)   -- song 1
  fill(12, 0.001) -- real gap
  fill(45, 0.8)   -- song 2, first half
  fill(3, 0.001)  -- short dip mid-song: must NOT split
  fill(45, 0.8)   -- song 2, second half
  fill(20, 0.001) -- real gap
  fill(10, 0.8)   -- chatter/noodling: too short, must be dropped

  local songs = find_songs(env, rate, { thresh = -40, minGap = 8, minSong = 45, pad = 1 })
  assert(#songs == 2, ("expected 2 songs, got %d"):format(#songs))
  assert(math.abs(songs[1].e - songs[1].s - 62) < 2,
    ("song 1 length %.1f, expected ~62 (60 + padding)"):format(songs[1].e - songs[1].s))
  assert(math.abs(songs[2].e - songs[2].s - 95) < 2,
    ("song 2 length %.1f, expected ~95 (45+3+45 + padding)"):format(songs[2].e - songs[2].s))
  assert(songs[2].s > 70, "song 2 must start after the first gap")

  -- degenerate inputs
  assert(#find_songs({}, rate, { thresh = -40, minGap = 8, minSong = 45, pad = 1 }) == 0)
  local silent = {}
  for _ = 1, 100 * rate do silent[#silent + 1] = 0 end
  assert(#find_songs(silent, rate, { thresh = -40, minGap = 8, minSong = 45, pad = 1 }) == 0)

  print("ok")
  return
end

----------------------------------------------------------------------
-- REAPER side
----------------------------------------------------------------------

local EXT = "ReapeZoom"

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

local function read_envelope(take, item_len)
  -- Reads the already-built .reapeaks cache, so a 2 GB file costs nothing.
  -- Buffer layout is maximums block, then minimums block, each numsamples*nch.
  local CHUNK, NCH = 4096, 2
  local buf = reaper.new_array(CHUNK * NCH * 2)
  local env, t = {}, 0

  while t < item_len do
    local want = math.min(CHUNK, math.ceil((item_len - t) * PEAKRATE))
    if want < 1 then break end
    buf.clear()
    local ret = reaper.GetMediaItemTake_Peaks(take, PEAKRATE, t, NCH, want, 0, buf)
    local got = ret & 0xfffff
    if got < 1 then break end
    for i = 1, got do
      local mx = math.max(math.abs(buf[(i - 1) * NCH + 1]), math.abs(buf[(i - 1) * NCH + 2]))
      local mn = math.max(math.abs(buf[got * NCH + (i - 1) * NCH + 1]),
                          math.abs(buf[got * NCH + (i - 1) * NCH + 2]))
      env[#env + 1] = math.max(mx, mn)
    end
    t = t + got / PEAKRATE
  end

  return env
end

local function apply_render_settings()
  reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 48000, true)
  reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 1, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 3, true)  -- all project regions
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 512, true)  -- master mix + embed metadata
  -- 1=enable, &14==0 selects LUFS-I, 64=brickwall, 128=true peak, 512/1024=fades
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", 1 | 64 | 128 | 512 | 1024, true)
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE_TARGET", 10 ^ (-14 / 20), true) -- -14 LUFS-I
  reaper.GetSetProjectInfo(0, "RENDER_BRICKWALL", 10 ^ (-1 / 20), true)         -- -1 dBTP
  reaper.GetSetProjectInfo(0, "RENDER_FADEIN", 0.010, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEOUT", 0.050, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$region", true)
end

local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item and reaper.CountMediaItems(0) == 1 then item = reaper.GetMediaItem(0, 0) end
  if not item then
    reaper.MB("Select the rehearsal item first.", "Split rehearsal", 0)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.MB("Selected item has no audio take.", "Split rehearsal", 0)
    return
  end

  local ok, csv = reaper.GetUserInputs("Split rehearsal into song regions", 5,
    "Threshold (dB below item peak),Min gap between songs (s),Min song length (s),Region padding (s),Set streaming render settings (y/n),extrawidth=60",
    table.concat({
      get_setting("thresh", "-40"),
      get_setting("minGap", "8"),
      get_setting("minSong", "45"),
      get_setting("pad", "1.0"),
      get_setting("render", "y"),
    }, ","))
  if not ok then return end

  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
  local opts = {
    thresh = tonumber(f[1]), minGap = tonumber(f[2]),
    minSong = tonumber(f[3]), pad = tonumber(f[4]),
  }
  local do_render = (f[5] or ""):lower():sub(1, 1) == "y"
  if not (opts.thresh and opts.minGap and opts.minSong and opts.pad) then
    reaper.MB("All four numeric fields are required.", "Split rehearsal", 0)
    return
  end
  reaper.SetExtState(EXT, "thresh", tostring(opts.thresh), true)
  reaper.SetExtState(EXT, "minGap", tostring(opts.minGap), true)
  reaper.SetExtState(EXT, "minSong", tostring(opts.minSong), true)
  reaper.SetExtState(EXT, "pad", tostring(opts.pad), true)
  reaper.SetExtState(EXT, "render", do_render and "y" or "n", true)

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local env = read_envelope(take, item_len)
  if #env == 0 then
    reaper.MB("Could not read peaks for this item. Let REAPER finish building them and retry.",
      "Split rehearsal", 0)
    return
  end

  local songs = find_songs(env, PEAKRATE, opts)
  if #songs == 0 then
    reaper.MB("No songs found. Try a lower threshold or a shorter minimum song length.",
      "Split rehearsal", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for i, s in ipairs(songs) do
    reaper.AddProjectMarker2(0, true, item_pos + s.s, item_pos + s.e, ("%02d"):format(i), -1, 0)
  end
  if do_render then apply_render_settings() end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split rehearsal into song regions", -1)

  reaper.MB(("%d songs found.\n\nRename the regions in View > Region/Marker Manager, then render%s.")
    :format(#songs, do_render and " (settings are already applied)" or ""),
    "Split rehearsal", 0)
end

main()
