-- @description ReapeZoom
-- @author berlogabob
-- @version 2.8
-- @link https://github.com/berlogabob/ReapeZoom
-- @provides
--   [main] .
--   [main] berloga_Ride levels into automation items.lua
--   [main] berloga_Check stereo and phase.lua
--   [main] berloga_Split percussion recording into hits.lua
--   [main] berloga_Build sampler preset from tracks.lua
--   [main] berloga_Master songs.lua
--   [nomain] lib/envelope.lua
--   [nomain] lib/level.lua
--   [nomain] lib/master.lua
--   [nomain] lib/preset.lua
--   [nomain] lib/stereo.lua
--   [nomain] lib/tempo.lua
-- @about
--   # ReapeZoom
--
--   Turning long Zoom-recorder captures into finished material, two ways.
--
--   **Split rehearsal recording into song regions** — one long rehearsal becomes
--   named regions, one per song, ready to render at streaming loudness. It does
--   not split on silence: between songs a rehearsal is full of talking, tuning
--   and noodling. It finds quiet gaps of a minimum length, then discards spans
--   too short to be a song. Optionally, each song also gets a second take warped
--   onto a constant tempo grid.
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
--   **Master songs** — loudness preset, master-bus compressor and limiter, and a
--   check of the rendered files against the target.
--
--   **Build sampler preset from tracks** — measures every hit, sorts it into
--   velocity layers and round robins, lays the matrix out on the arrange grid
--   for review, and writes both `.sfz` and `.dspreset`.
--
--   Thresholds are relative to the material's own peak, so they work on quiet
--   32-bit-float captures without recalibration.
-- @changelog
--   New action Master songs: loudness presets (mp3 / streaming / apple / archive), item
--   trim to the level the chain expects, a stock ReaComp + ReaLimit master chain, and a
--   check mode that measures every rendered file (LUFS-I, true peak) against the preset.
--   MP3 presets limit 1 dB lower so the encode cannot push true peak over the target.
--   Split rehearsal: batch mode for unattended runs, threshold "auto" picked from the
--   sweep, regions named after the recording file, render folder set, MP3 320 render
--   format (ExtState format=wav for 24-bit WAV), and still-building peaks reported
--   instead of "no songs found".
--   Split rehearsal: optionally finds each song's tempo and adds a second, tempo-aligned
--   take to it, so T flips between the warped version and the original.
--   Split rehearsal: a re-run only replaces the regions inside the item it was run
--   on, so a project holding several recordings keeps the songs found in the others.
--   Split rehearsal: durations no longer round to "3:60".
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
local BEATRATE = 100  -- envelope buckets per second for beat detection
-- Below this, the winning tempo is barely more autocorrelated than any other in
-- range and the answer is a coin toss. Measured, not guessed: see lib/tempo.lua.
local MIN_CLARITY = 3.0
local EXT = "ReapeZoom"

-- Batch mode (ExtState ReapeZoom/batch = "1"): no dialogs. Settings come from the
-- stored ExtState values or the defaults, every preview is accepted, and every
-- message goes to the REAPER console and reapezoom-batch.log beside the project. Lets the action run unattended, e.g. from
-- Tools/run_headless.lua. Interactive use is unchanged.
local BATCH = reaper.GetExtState(EXT, "batch") == "1"
local function MB(msg, title, kind)
  if not BATCH then return reaper.MB(msg, title, kind) end
  local text = ("[%s]\n%s\n\n"):format(title, msg)
  reaper.ShowConsoleMsg(text)
  -- the console dies with REAPER, so also append to a log beside the project
  local _, proj = reaper.EnumProjects(-1)
  local log = io.open((proj:match("^(.*)[/\\]") or ".") .. "/reapezoom-batch.log", "a")
  if log then log:write(text); log:close() end
  -- 3 = preview: accept. 1 = "go back and change it?": no, stop. 0 = info.
  return ({ [0] = 1, [1] = 2, [3] = 6 })[kind] or 1
end
local function ask(title, n, captions, defaults)
  if not BATCH then return reaper.GetUserInputs(title, n, captions, defaults) end
  return true, defaults
end

-- Load a sibling library, with a readable message instead of a raw Lua error
-- when the install is incomplete -- by far the most common way this fails.
local function require_lib(name)
  local dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]")
  local path = dir .. "/lib/" .. name
  local fh = io.open(path, "r")
  if not fh then
    MB(("Missing library:\n%s\n\nReinstall ReapeZoom via ReaPack, or if you are running " ..
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
    MB(("Library failed to load:\n%s\n\n%s\n\nReinstall ReapeZoom via ReaPack.")
      :format(path, ok and "It did not return a module." or tostring(mod)), "ReapeZoom", 0)
    return nil
  end
  return mod
end

local E = require_lib("envelope.lua")
if not E then return end
local T = require_lib("tempo.lua")
if not T then return end

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

-- Regions this script created, so re-running replaces them instead of
-- duplicating them and never touches regions the user made.
-- Clears the regions a previous run made **for this item only**, and returns
-- the ones it kept so the caller can carry them forward.
--
-- Bounded to the item because a rehearsal night is several recordings: one item
-- per file, the action run once per item. Clearing every region it had ever made
-- meant the second item deleted the first item's songs, and the fourth left you
-- with only the fourth. The ownership record is still project-wide -- regions the
-- user made by hand are never touched either way.
local function clear_own_regions(from, to)
  local _, csv = reaper.GetProjExtState(0, EXT, "regions")
  if csv == "" then return 0, {} end
  local owned = {}
  for id in csv:gmatch("%d+") do owned[tonumber(id)] = true end

  local removed, kept = 0, {}
  local i = 0
  while true do
    local ok, isrgn, pos, rgnend, _, idx = reaper.EnumProjectMarkers3(0, i)
    if ok == 0 then break end
    if isrgn and owned[idx] and pos >= from - 1e-6 and rgnend <= to + 1e-6 then
      reaper.DeleteProjectMarker(0, idx, true)
      removed = removed + 1
    else
      if isrgn and owned[idx] then kept[#kept + 1] = idx end
      i = i + 1 -- only advance when nothing was deleted; indices shift otherwise
    end
  end
  return removed, kept
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
  -- Without this the files land wherever the render dialog was last pointed.
  local _, olddir = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  if olddir == "" then
    changed[#changed + 1] = "RENDER_FILE: -> render (beside the project)"
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "render", true)
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
  -- MP3 is the default: 320 kbps CBR, string copied from a REAPER-saved project.
  local WAV24 = get_setting("format", "mp3") == "wav" and "ZXZhdxgAAQ==" or
    "bDNwbUABAAAAAAAAAgAAAP////8EAAAAQAEAAAAAAAA="
  local _, oldfmt = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
  if oldfmt ~= WAV24 then
    changed[#changed + 1] = "RENDER_FORMAT: -> " .. (WAV24 == "ZXZhdxgAAQ==" and "WAV 24-bit" or "MP3 320")
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
  -- Round to a whole second FIRST, then split. Rounding only the seconds half
  -- turns 3:59.7 into "3:60", which the threshold sweep has been printing since
  -- it was written.
  local t = math.floor(sec + 0.5)
  return ("%d:%02d"):format(t // 60, t % 60)
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

-- `span` is how long the song is. A whole-number target is almost never the
-- tempo that was played, so the grid ends up a little longer or shorter than the
-- audio it replaces -- and the two takes share one item length, which cannot
-- grow without exposing extra audio on the original take. `over` is how far the
-- grid runs past the end of the item; beats out there have nowhere to go.
local function warp_stats(beats, bpm, span)
  local warp = T.warp(beats, bpm)
  local drift = 0
  for _, marker in ipairs(warp) do
    drift = math.max(drift, math.abs(marker.at - marker.from))
  end
  local over = #warp > 0 and math.max(0, warp[#warp].at - span) or 0
  return warp, drift, over
end

local function detect_tempos(take, songs)
  local tempos = {}
  for _, s in ipairs(songs) do
    local env = E.read_envelope(take, s.s, s.e - s.s, BEATRATE)
    local strength = T.onset_strength(env)
    local est = T.tempo(strength, BEATRATE)
    if not est then
      tempos[#tempos + 1] = { bpm = 0 }
    else
      local bpm = math.floor(est.bpm + 0.5)
      local beats = T.beats(strength, BEATRATE, est.period)
      local span = s.e - s.s
      local warp, drift, over = warp_stats(beats, bpm, span)
      -- the strength curve is kept because a typed-over BPM has to find its own
      -- beats again; only the autocorrelation above is expensive.
      tempos[#tempos + 1] = {
        bpm = bpm, clarity = est.clarity, beats = #beats, drift = drift, over = over,
        beat_times = beats, warp = warp, span = span, strength = strength,
      }
    end
  end
  return tempos
end

local function tempo_preview_text(songs, tempos)
  local lines = {}
  for i, s in ipairs(songs) do
    local tempo = tempos[i]
    if not tempo.clarity then
      lines[#lines + 1] = ("%02d  %5s  no tempo found -- left alone")
        :format(i, mmss(s.e - s.s))
    else
      local flags = {}
      if tempo.clarity < MIN_CLARITY then flags[#flags + 1] = "CHECK" end
      -- below a tenth of a second the grid is as long as the song; a flag
      -- reading "TAIL 0.0 s" only teaches people to ignore the column.
      if tempo.over > 0.05 then flags[#flags + 1] = ("TAIL %.1f s"):format(tempo.over) end
      local flag = #flags > 0 and ("   " .. table.concat(flags, "   ")) or ""
      lines[#lines + 1] = ("%02d  %5s  %3d BPM   clarity %.1f   drift %.2f s%s")
        :format(i, mmss(s.e - s.s), tempo.bpm, tempo.clarity, tempo.drift, flag)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "CHECK marks clarity below 3.0."
  lines[#lines + 1] = "TAIL is how far a whole-number grid runs past the end of the song. Both " ..
    "takes share one item length, so that last stretch plays unwarped instead of being cut. " ..
    "Another BPM usually shortens it."
  lines[#lines + 1] = "Clarity separates a click track from music, not a right answer from a wrong " ..
    "one, so trust your ears."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Use these tempos?"
  lines[#lines + 1] = "Yes = align    No = edit BPMs    Cancel = regions only"
  return table.concat(lines, "\n")
end

local function edit_tempos(songs, tempos)
  local current = {}
  for i, tempo in ipairs(tempos) do current[i] = tempo.bpm end

  while true do
    local ok, csv = ask("Split rehearsal -- edit tempos", 1,
      "BPM per song (comma-separated),extrawidth=200", table.concat(current, ","))
    if not ok then return false end

    local values = {}
    local bad
    for v in csv:gmatch("[^,%s]+") do
      local bpm = tonumber(v)
      if not bpm or bpm <= 0 or bpm % 1 ~= 0 then
        bad = "Every BPM must be a positive whole number."
      else
        values[#values + 1] = bpm
      end
    end
    if not bad and #values ~= #songs then
      bad = ("Enter exactly %d BPM values, one per song."):format(#songs)
    end

    if bad then
      if MB(bad .. "\n\nGo back and change it?", "Split rehearsal", 1) ~= 1 then
        return nil
      end
    else
      for i, bpm in ipairs(values) do
        local tempo = tempos[i]
        tempo.bpm = bpm
        current[i] = bpm
        if tempo.strength then
          -- Find the beats again at the tempo that was typed, rather than
          -- re-pointing the old grid at a new spacing. The correction people
          -- actually make is the octave, and half as many beats stretched onto
          -- a grid twice as fine is not a drift fix -- it is the song at double
          -- speed, with the second half of it hanging off the end of the item.
          tempo.beat_times = T.beats(tempo.strength, BEATRATE, 60 / bpm)
          tempo.beats = #tempo.beat_times
          tempo.warp, tempo.drift, tempo.over =
            warp_stats(tempo.beat_times, bpm, tempo.span)
        end
      end
      return true
    end
  end
end

local function find_song_item(track, song)
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if math.abs(pos - song.s) <= 0.001 and math.abs(item_end - song.e) <= 0.001 then
      return item
    end
  end

  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_end = pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos <= song.s + 0.001 and item_end >= song.e - 0.001 then
      local piece = reaper.SplitMediaItem(item, song.s) or item
      reaper.SplitMediaItem(piece, song.e)
      return piece
    end
  end
  return nil
end

local function align_songs(item, songs, tempos)
  local track = reaper.GetMediaItem_Track(item)
  local report = {}
  local aligned_count = 0

  for i, s in ipairs(songs) do
    local tempo = tempos[i]
    if not tempo.clarity then
      report[#report + 1] = ("%02d  skipped -- no tempo found"):format(i)
    elseif #(tempo.warp or {}) < 2 then
      report[#report + 1] = ("%02d  skipped -- fewer than two warp points"):format(i)
    else
      local song_item = find_song_item(track, s)
      if not song_item then
        report[#report + 1] = ("%02d  skipped -- no item found to split"):format(i)
      else
        local first_take = reaper.GetTake(song_item, 0)
        if not first_take then
          report[#report + 1] = ("%02d  skipped -- song item has no take"):format(i)
        else
          local tk
          for take_index = 0, reaper.CountTakes(song_item) - 1 do
            local candidate = reaper.GetTake(song_item, take_index)
            local _, name = reaper.GetSetMediaItemTakeInfo_String(candidate, "P_NAME", "", false)
            if name:find(" aligned ", 1, true) then
              tk = candidate
              break
            end
          end

          local failure
          if tk then
            reaper.DeleteTakeStretchMarkers(tk, 0, reaper.GetTakeNumStretchMarkers(tk))
          else
            local source = reaper.GetMediaItemTake_Source(first_take)
            local path = source and reaper.GetMediaSourceFileName(source) or ""
            local copy = path ~= "" and reaper.PCM_Source_CreateFromFile(path) or nil
            if not copy then
              failure = "source file could not be opened"
            else
              tk = reaper.AddTakeToMediaItem(song_item)
              if tk then
                reaper.SetMediaItemTake_Source(tk, copy)
              else
                failure = "aligned take could not be added"
              end
            end
          end

          if failure then
            report[#report + 1] = ("%02d  skipped -- %s"):format(i, failure)
          else
            local startoffs = reaper.GetMediaItemTakeInfo_Value(first_take, "D_STARTOFFS")
            local playrate = reaper.GetMediaItemTakeInfo_Value(first_take, "D_PLAYRATE")
            local pitch = reaper.GetMediaItemTakeInfo_Value(first_take, "D_PITCH")
            reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", startoffs)
            reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", playrate)
            reaper.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", 1)
            reaper.SetMediaItemTakeInfo_Value(tk, "D_PITCH", pitch)
            reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME",
              ("%02d aligned %d BPM"):format(i, tempo.bpm), true)

            local item_pos = reaper.GetMediaItemInfo_Value(song_item, "D_POSITION")
            local item_len = reaper.GetMediaItemInfo_Value(song_item, "D_LENGTH")
            local dropped = 0
            for _, marker in ipairs(tempo.warp) do
              -- `at` and `from` are seconds from the ANALYSED SPAN, which began at s.s.
              -- a marker position is ITEM time, so express the span start against item_pos.
              -- its source position is SOURCE FILE time: add startoffs and scale by playrate.
              local pos = marker.at + (s.s - item_pos)
              -- A marker past the end of the item has no audio to anchor. Leaving
              -- it out lets the last seconds play at their own speed, which is
              -- audible but whole; placing it would take those seconds off the end.
              if pos > item_len then
                dropped = dropped + 1
              else
                reaper.SetTakeStretchMarker(tk, -1, pos, startoffs + marker.from * playrate)
              end
            end
            reaper.SetActiveTake(tk)
            reaper.UpdateItemInProject(song_item)
            report[#report + 1] = ("%02d  %d BPM, %d beats%s")
              :format(i, tempo.bpm, tempo.beats,
                dropped > 0 and (", last %d past the item end left unwarped"):format(dropped) or "")
            aligned_count = aligned_count + 1
          end
        end
      end
    end
  end

  if aligned_count > 0 then
    report[#report + 1] = "Rendering the regions now writes the aligned versions."
  end
  return report
end

local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item and reaper.CountMediaItems(0) == 1 then item = reaper.GetMediaItem(0, 0) end
  if not item then
    MB("Select the rehearsal item first.", "Split rehearsal", 0)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    MB("Selected item has no audio take.", "Split rehearsal", 0)
    return
  end

  -- Region names carry the recording's file name, so a night of several
  -- recordings never renders two songs to the same "01".
  local src = reaper.GetMediaItemTake_Source(take)
  local prefix = (src and reaper.GetMediaSourceFileName(src) or ""):match("([^/\\]+)$") or ""
  prefix = prefix:gsub("%.[^.]*$", "")
  if prefix == "" then prefix = "song" end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  -- Read the peaks ONCE, before the dialog: the settings loop below re-runs
  -- detection on every pass and re-reading would make it crawl.
  local env = E.read_envelope(take, item_pos, item_len, PEAKRATE)
  -- Peaks still building read back as zeros, not as an error; without this the
  -- result is a confident "No songs found" over a good recording.
  if #env == 0 or E.max_peak(env) == 0 then
    MB("Could not read peaks for this item. Let REAPER finish building them and retry.",
      "Split rehearsal", 0)
    return
  end

  -- Settings, then a preview of what they would produce, until the user accepts.
  -- Prefilled from what was last TYPED rather than from the stored settings, so
  -- "change settings" comes back with the numbers you were just looking at.
  local vals = {
    get_setting("thresh", "auto"),
    get_setting("minGap", "8"),
    get_setting("minSong", "90"),
    get_setting("pad", "1.0"),
    get_setting("render", "y"),
    get_setting("align", "n"),
  }
  local opts, do_render, do_align
  while true do
    local ok, csv = ask("Split rehearsal into song regions", 6,
      "Threshold (dB below item peak, or auto),Min gap between songs (s),Min song length (s)," ..
      "Region padding (s),Set streaming render settings (y/n),Tempo-align songs (y/n)," ..
      "extrawidth=60",
      table.concat(vals, ","))
    if not ok then return end

    local f = {}
    for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
    for i = 1, 6 do vals[i] = f[i] or vals[i] end

    opts = {
      thresh = tonumber(f[1]), minGap = tonumber(f[2]),
      minSpan = tonumber(f[3]), pad = tonumber(f[4]),
    }
    -- "auto" picks the threshold from the sweep (see E.auto_threshold)
    if (f[1] or ""):lower():sub(1, 1) == "a" and opts.minGap and opts.minSpan and opts.pad then
      opts.thresh = E.auto_threshold(env, PEAKRATE, opts)
      if not opts.thresh then
        opts.thresh = -40
        MB("No threshold gave a stable song count; using -40 dB. Check the preview.",
          "Split rehearsal", 0)
      end
    end
    do_render = (f[5] or ""):lower():sub(1, 1) == "y"
    do_align = (f[6] or ""):lower():sub(1, 1) == "y"

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
      if MB(bad .. "\n\nGo back and change it?", "Split rehearsal", 1) ~= 1 then return end
    else
      local answer = MB(preview_text(env, opts), "Split rehearsal -- what these settings find", 3)
      if answer == 6 then break end   -- yes: use these
      if answer == 2 then return end  -- cancel: nothing written
      -- no: round again with the same values prefilled
    end
  end

  reaper.SetExtState(EXT, "thresh", tostring(vals[1]), true) -- as typed, so "auto" stays auto
  reaper.SetExtState(EXT, "minGap", tostring(opts.minGap), true)
  reaper.SetExtState(EXT, "minSong", tostring(opts.minSpan), true)
  reaper.SetExtState(EXT, "pad", tostring(opts.pad), true)
  reaper.SetExtState(EXT, "render", do_render and "y" or "n", true)
  reaper.SetExtState(EXT, "align", do_align and "y" or "n", true)

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
    MB("No songs found. Try a lower threshold or a shorter minimum song length.",
      "Split rehearsal", 0)
    return
  end

  local tempos
  if do_align then
    -- Tempo detection is the slow pass, so keep its beats and only rebuild the
    -- cheap warp when the user edits a BPM.
    tempos = detect_tempos(take, songs)
    while true do
      local answer = MB(tempo_preview_text(songs, tempos),
        "Split rehearsal -- tempo alignment", 3)
      if answer == 6 then break end   -- yes: align
      -- Cancel drops the alignment, not the regions: those were accepted at the
      -- previous dialog and are worth having on their own.
      if answer == 2 then do_align = false; break end
      local edited = edit_tempos(songs, tempos)
      if edited == nil then return end
      -- cancelling the editor returns to this preview; a valid edit redraws it
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local removed, ids = clear_own_regions(item_pos, item_end)
  for i, s in ipairs(songs) do
    ids[#ids + 1] = reaper.AddProjectMarker2(0, true, s.s, s.e, ("%s %02d"):format(prefix, i), -1, 0)
  end
  reaper.SetProjExtState(0, EXT, "regions", table.concat(ids, ","))

  local alignment = do_align and align_songs(item, songs, tempos) or {}

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
  if do_align then
    msg[#msg + 1] = "\nTempo alignment:\n  " .. table.concat(alignment, "\n  ")
    msg[#msg + 1] = "T switches between the aligned take and the original."
  end
  MB(table.concat(msg, "\n"), "Split rehearsal", 0)
end

main()
