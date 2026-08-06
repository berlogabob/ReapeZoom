-- @description Split rehearsal recording into song regions
-- @author berlogabob
-- @version 1.1
-- @link https://github.com/berlogabob/ReapeZoom
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
--   Read peaks from the item's project position instead of project time 0 —
--   regions were wrong for any item not starting at 0:00.
--   Derive channel count from the source instead of assuming stereo.
--   Re-running now replaces its own regions instead of duplicating them.
--   Report which render settings were changed.

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
  -- ponytail: O(n * window) = 2.3M ops for a 91-min take, instant. Monotonic
  -- deque only if a multi-hour recording ever feels slow.
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
  local spans, cursor = {}, 1
  for _, g in ipairs(gaps) do
    if g[1] > cursor then spans[#spans + 1] = { cursor, g[1] - 1 } end
    cursor = g[2] + 1
  end
  if cursor <= n then spans[#spans + 1] = { cursor, n } end

  local songs = {}
  for k, sp in ipairs(spans) do
    local a, b = sp[1], sp[2]
    if (b - a + 1) / rate >= opts.minSong then
      -- Pad into the surrounding quiet, but at most halfway to the neighbouring
      -- span, so regions can never overlap however large the padding.
      local prev_end = k > 1 and spans[k - 1][2] or 0
      local next_start = spans[k + 1] and spans[k + 1][1] or (n + 1)
      local s = a - math.min(opts.pad * rate, (a - prev_end - 1) / 2)
      local e = b + math.min(opts.pad * rate, (next_start - b - 1) / 2)
      songs[#songs + 1] = { s = (s - 1) / rate, e = e / rate }
    end
  end

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

  -- regions must stay inside the item and never overlap, however big the padding
  for _, pad in ipairs { 0, 1, 5, 60 } do
    local r = find_songs(env, rate, { thresh = -40, minGap = 8, minSong = 45, pad = pad })
    local len = #env / rate
    for i, x in ipairs(r) do
      assert(x.s >= 0 and x.e <= len, ("pad=%d region %d out of bounds"):format(pad, i))
      assert(x.e > x.s, ("pad=%d region %d is empty"):format(pad, i))
      if i > 1 then assert(x.s >= r[i - 1].e, ("pad=%d regions %d/%d overlap"):format(pad, i - 1, i)) end
    end
  end

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

local function read_envelope(take, item_pos, item_len)
  -- Reads the already-built .reapeaks cache, so a 2 GB file costs nothing.
  -- starttime is PROJECT time, not item-relative -- see saull_Peak envelope
  -- generator.lua and BirdBird's waveform_peaks.lua, which both pass D_POSITION.
  -- Buffer layout is maximums block, then minimums block, then an optional
  -- extra block; reserve all three, it costs nothing.
  local CHUNK = 4096
  local NCH = math.min(2, reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take)))
  if NCH < 1 then return {} end
  local buf = reaper.new_array(CHUNK * NCH * 3)
  local env, t = {}, 0

  while t < item_len do
    local want = math.min(CHUNK, math.ceil((item_len - t) * PEAKRATE))
    if want < 1 then break end
    buf.clear()
    local ret = reaper.GetMediaItemTake_Peaks(take, PEAKRATE, item_pos + t, NCH, want, 0, buf)
    local got = ret & 0xfffff
    if got < 1 then break end
    -- the minimums block is laid out after the *requested* count, not the returned one
    local minbase = want * NCH
    for i = 1, got do
      local o = (i - 1) * NCH
      local v = 0
      for c = 1, NCH do
        v = math.max(v, math.abs(buf[o + c]), math.abs(buf[minbase + o + c]))
      end
      env[#env + 1] = v
    end
    t = t + got / PEAKRATE
  end

  return env
end

-- Regions this script created, so re-running replaces them instead of
-- duplicating them and never touches regions the user made.
local function clear_own_regions()
  local _, csv = reaper.GetProjExtState(0, EXT, "regions")
  if csv == "" then return 0 end
  local owned = {}
  for id in csv:gmatch("%d+") do owned[tonumber(id)] = true end

  local removed = 0
  local i = 0
  while true do
    local ok, isrgn, _, _, _, idx = reaper.EnumProjectMarkers3(0, i)
    if ok == 0 then break end
    if isrgn and owned[idx] then
      reaper.DeleteProjectMarker(0, idx, true)
      removed = removed + 1
    else
      i = i + 1 -- only advance when nothing was deleted; indices shift otherwise
    end
  end
  reaper.SetProjExtState(0, EXT, "regions", "")
  return removed
end

local function apply_render_settings()
  local nums = {
    { "PROJECT_SRATE", 48000 },
    { "PROJECT_SRATE_USE", 1 },
    { "RENDER_BOUNDSFLAG", 3 },                     -- all project regions
    { "RENDER_SETTINGS", 512 },                     -- master mix + embed metadata
    -- 1=enable, &14==0 selects LUFS-I, 64=brickwall, 128=true peak, 512/1024=fades
    { "RENDER_NORMALIZE", 1 | 64 | 128 | 512 | 1024 },
    { "RENDER_NORMALIZE_TARGET", 10 ^ (-14 / 20) }, -- -14 LUFS-I
    { "RENDER_BRICKWALL", 10 ^ (-1 / 20) },         -- -1 dBTP
    { "RENDER_FADEIN", 0.010 },
    { "RENDER_FADEOUT", 0.050 },
  }
  local changed = {}
  for _, kv in ipairs(nums) do
    local old = reaper.GetSetProjectInfo(0, kv[1], 0, false)
    if math.abs(old - kv[2]) > 1e-9 then
      changed[#changed + 1] = ("%s: %g -> %g"):format(kv[1], old, kv[2])
      reaper.GetSetProjectInfo(0, kv[1], kv[2], true)
    end
  end
  local _, oldpat = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
  if oldpat ~= "$region" then
    changed[#changed + 1] = ("RENDER_PATTERN: %q -> \"$region\""):format(oldpat)
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$region", true)
  end
  return changed
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
      get_setting("minSong", "90"),
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

  local env = read_envelope(take, item_pos, item_len)
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

  local removed = clear_own_regions()
  local ids = {}
  for i, s in ipairs(songs) do
    -- s.s/s.e are already project time: read_envelope started at item_pos
    ids[#ids + 1] = reaper.AddProjectMarker2(0, true, s.s, s.e, ("%02d"):format(i), -1, 0)
  end
  reaper.SetProjExtState(0, EXT, "regions", table.concat(ids, ","))

  local changed = do_render and apply_render_settings() or {}
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split rehearsal into song regions", -1)

  local msg = { ("%d songs found."):format(#songs) }
  if removed > 0 then msg[#msg + 1] = ("Replaced %d regions from a previous run."):format(removed) end
  msg[#msg + 1] = "\nRename them in View > Region/Marker Manager, then render."
  if do_render then
    msg[#msg + 1] = #changed == 0 and "\nRender settings were already correct."
      or ("\nRender settings changed:\n  " .. table.concat(changed, "\n  "))
  end
  reaper.MB(table.concat(msg, "\n"), "Split rehearsal", 0)
end

main()
