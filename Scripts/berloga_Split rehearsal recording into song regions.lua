-- @description ReapeZoom
-- @author berlogabob
-- @version 2.5
-- @link https://github.com/berlogabob/ReapeZoom
-- @provides
--   [main] .
--   [main] berloga_Ride levels into automation items.lua
--   [main] berloga_Check stereo and phase.lua
--   [main] berloga_Split percussion recording into hits.lua
--   [main] berloga_Build sampler preset from tracks.lua
--   [nomain] lib/envelope.lua
--   [nomain] lib/level.lua
--   [nomain] lib/preset.lua
--   [nomain] lib/stereo.lua
-- @about
--   # ReapeZoom
--
--   Turning long Zoom-recorder captures into finished material, two ways.
--
--   **Split rehearsal recording into song regions** — one long rehearsal becomes
--   named regions, one per song, ready to render at streaming loudness. It does
--   not split on silence: between songs a rehearsal is full of talking, tuning
--   and noodling. It finds quiet gaps of a minimum length, then discards spans
--   too short to be a song.
--
--   **Ride levels into automation items** — evens out level variation *inside*
--   each song with a slow, visible, editable gain curve. Not the same as
--   loudness normalization, which sets one static gain for a whole file.
--
--   **Check stereo and phase** — polarity, L/R balance, DC offset and mono
--   compatibility, with the polarity fix applied on request.
--
--   **Split percussion recording into hits** — a pass-per-sound-type recording
--   becomes one track per sound type, one item per hit.
--
--   **Build sampler preset from tracks** — measures every hit, sorts it into
--   velocity layers and round robins, lays the matrix out on the arrange grid
--   for review, and writes both `.sfz` and `.dspreset`.
--
--   Thresholds are relative to the material's own peak, so they work on quiet
--   32-bit-float captures without recalibration.
-- @changelog
--   Split rehearsal: shows what nearby thresholds would find -- song count and
--   shortest/longest -- before creating anything, and lets you go back and
--   change the settings without committing first.
--   Ride levels: measures the selection first and reports peak, loud, quiet and
--   the dynamic range between them, then takes a target range to ride toward --
--   0 flattens as before, the measured range leaves the material alone.
--   Ride levels: accepts several selected items instead of one.
--   Ride levels: only reuses automation items it created itself, refuses to run
--   over hand-drawn envelope points, and restores your track selection.
--   Ride levels: the gain curve now ramps from neutral at both item edges
--   instead of stepping straight to its full correction.
--   Stereo check: the polarity fix goes on the take, not the track, so other
--   items on the same track are no longer inverted too.
--   Split rehearsal: sets render sample rate, channel count and WAV format,
--   which were previously left at whatever the project last used.
--   Split percussion: hits from a time-stretched take now map to the right
--   source position and inherit the playback rate.
--   Build preset: sample filenames are unique, so two similarly named tracks no
--   longer overwrite each other; layout markers only delete their own.
--   All scripts: reject negative durations and amounts up front, and report a
--   broken library install instead of failing later mid-edit.
--   Padding at the first and last song now uses the full available space, and
--   minimum gaps round up so a gap is never shorter than the one requested.

local PEAKRATE = 20 -- envelope buckets per second
local EXT = "ReapeZoom"

-- Load a sibling library, with a readable message instead of a raw Lua error
-- when the install is incomplete -- by far the most common way this fails.
local function require_lib(name)
  local dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]")
  local path = dir .. "/lib/" .. name
  local fh = io.open(path, "r")
  if not fh then
    reaper.MB(("Missing library:\n%s\n\nReinstall ReapeZoom via ReaPack, or if you are running " ..
      "from a symlink, make sure it points at the whole Scripts folder rather than a single file.")
      :format(path), "ReapeZoom", 0)
    return nil
  end
  fh:close()
  -- A mismatched or half-written library can load and return something that is
  -- not a module. Truthiness alone lets that through, and the failure then
  -- surfaces much later as "attempt to index a boolean" -- inside an undo
  -- block, in the worst case, leaving it unclosed.
  local ok, mod = pcall(dofile, path)
  if not ok or type(mod) ~= "table" then
    reaper.MB(("Library failed to load:\n%s\n\n%s\n\nReinstall ReapeZoom via ReaPack.")
      :format(path, ok and "It did not return a module." or tostring(mod)), "ReapeZoom", 0)
    return nil
  end
  return mod
end

local E = require_lib("envelope.lua")
if not E then return end

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
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
    -- Rate, channel count and sink were NOT being set, so a project last used
    -- for a mono MP3 bounce rendered the songs as mono MP3 while every other
    -- setting here said "streaming master". 0 = follow the project rate.
    { "RENDER_SRATE", 0 },
    { "RENDER_CHANNELS", 2 },
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
  -- Same sink config the sampler script uses: "evaw" (WAV) + 0x18 = 24-bit.
  -- The README promises 24-bit WAV, so pin it rather than inheriting whatever
  -- the render dialog was last left on -- which is how a mono MP3 bounce could
  -- silently become the format for a whole release.
  local WAV24 = "ZXZhdxgAAQ=="
  local _, oldfmt = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
  if oldfmt ~= WAV24 then
    changed[#changed + 1] = "RENDER_FORMAT: -> WAV 24-bit"
    reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", WAV24, true)
  end
  return changed
end

-- What nearby thresholds would find, so the choice is made before committing
-- instead of by running and undoing. The sweep costs ~60 ms on a 90-minute take.
-- Column alignment is not relied on: this lands in a system alert with a
-- proportional font, so each row reads as a sentence rather than a table.
local DELTAS = { -10, -5, 0, 5, 10 }

local function mmss(sec)
  return ("%d:%02d"):format(math.floor(sec / 60), math.floor(sec % 60 + 0.5))
end

local function preview_text(env, opts)
  local lines = { "Threshold      Songs    Shortest - longest", "" }
  for _, r in ipairs(E.sweep_thresholds(env, PEAKRATE, opts, DELTAS)) do
    local mark = r.current and "   << your setting" or ""
    if r.count == 0 then
      lines[#lines + 1] = ("%+.0f dB       no songs found%s"):format(r.thresh, mark)
    else
      lines[#lines + 1] = ("%+.0f dB       %2d       %s - %s%s")
        :format(r.thresh, r.count, mmss(r.shortest), mmss(r.longest), mark)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Min song length is %g s -- anything shorter was already discarded.")
    :format(opts.minSpan)
  lines[#lines + 1] = "Raise it to reject noodling; raise min gap if one song splits in half."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Create regions with your current settings?"
  lines[#lines + 1] = "Yes = go ahead    No = change settings    Cancel = do nothing"
  return table.concat(lines, "\n")
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

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  -- Read the peaks ONCE, before the dialog: the settings loop below re-runs
  -- detection on every pass and re-reading would make it crawl.
  local env = E.read_envelope(take, item_pos, item_len, PEAKRATE)
  if #env == 0 then
    reaper.MB("Could not read peaks for this item. Let REAPER finish building them and retry.",
      "Split rehearsal", 0)
    return
  end

  -- Settings, then a preview of what they would produce, until the user accepts.
  -- Prefilled from what was last TYPED rather than from the stored settings, so
  -- "change settings" comes back with the numbers you were just looking at.
  local vals = {
    get_setting("thresh", "-40"),
    get_setting("minGap", "8"),
    get_setting("minSong", "90"),
    get_setting("pad", "1.0"),
    get_setting("render", "y"),
  }
  local opts, do_render
  while true do
    local ok, csv = reaper.GetUserInputs("Split rehearsal into song regions", 5,
      "Threshold (dB below item peak),Min gap between songs (s),Min song length (s),Region padding (s),Set streaming render settings (y/n),extrawidth=60",
      table.concat(vals, ","))
    if not ok then return end

    local f = {}
    for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
    for i = 1, 5 do vals[i] = f[i] or vals[i] end

    opts = {
      thresh = tonumber(f[1]), minGap = tonumber(f[2]),
      minSpan = tonumber(f[3]), pad = tonumber(f[4]),
    }
    do_render = (f[5] or ""):lower():sub(1, 1) == "y"

    -- Validation sends you back to the dialog rather than out of the script:
    -- losing four correct fields because the fifth had a typo is its own bug.
    local bad
    if not (opts.thresh and opts.minGap and opts.minSpan and opts.pad) then
      bad = "All four numeric fields are required."
    elseif opts.minGap < 0 or opts.minSpan < 0 or opts.pad < 0 then
      -- A negative pad walks the two ends of a span past each other, and
      -- AddProjectMarker2 then gets a region whose end precedes its start.
      bad = "Min gap, min song length and padding cannot be negative."
    elseif opts.thresh > 0 then
      bad = "Threshold is dB BELOW the item peak, so it must be zero or negative."
    end
    if bad then
      if reaper.MB(bad .. "\n\nGo back and change it?", "Split rehearsal", 1) ~= 1 then return end
    else
      local answer = reaper.MB(preview_text(env, opts), "Split rehearsal -- what these settings find", 3)
      if answer == 6 then break end   -- yes: use these
      if answer == 2 then return end  -- cancel: nothing written
      -- no: round again with the same values prefilled
    end
  end

  reaper.SetExtState(EXT, "thresh", tostring(opts.thresh), true)
  reaper.SetExtState(EXT, "minGap", tostring(opts.minGap), true)
  reaper.SetExtState(EXT, "minSong", tostring(opts.minSpan), true)
  reaper.SetExtState(EXT, "pad", tostring(opts.pad), true)
  reaper.SetExtState(EXT, "render", do_render and "y" or "n", true)

  local songs = E.find_spans(env, PEAKRATE, opts)
  -- find_spans measures from the start of the envelope, which began at
  -- item_pos. Convert to project time once, here.
  -- The clamp matters because the peak reader rounds its bucket count up, so
  -- the envelope can run a fraction of a bucket past the item; without it a
  -- region ends slightly beyond the audio it describes.
  local item_end = item_pos + item_len
  for _, s in ipairs(songs) do
    s.s = math.max(item_pos, math.min(item_end, item_pos + s.s))
    s.e = math.max(item_pos, math.min(item_end, item_pos + s.e))
  end
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
