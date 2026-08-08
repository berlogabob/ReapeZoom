-- @noindex
-- Part of the ReapeZoom package. See the main script for metadata.
--
-- One long percussion recording -> one track per sound type, one item per hit.
-- Assumes each sound type was recorded as its own contiguous pass:
--   20 kicks, pause, 20 taps, pause, 20 slaps, ...
-- Passes are found by the gap detector; hits inside a pass by onset detection.

local PASSRATE = 20  -- buckets/s for finding the passes
local HITRATE = 400  -- buckets/s for finding transients inside a pass
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

local function db(x) return 20 * math.log(math.max(x, 1e-9), 10) end

local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item and reaper.CountMediaItems(0) == 1 then item = reaper.GetMediaItem(0, 0) end
  if not item then
    reaper.MB("Select the percussion recording item first.", "Split percussion", 0)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.MB("Selected item has no audio take.", "Split percussion", 0)
    return
  end

  local ok, csv = reaper.GetUserInputs("Split percussion recording into hits", 6,
    "Hit threshold (dB below pass peak),Min time between hits (ms),Pre-roll (ms),Tail (ms),Gap between sound types (s),Min pass length (s),extrawidth=60",
    table.concat({
      get_setting("hitThresh", "-30"),
      get_setting("minInt", "80"),
      get_setting("preroll", "5"),
      get_setting("tail", "1500"),
      get_setting("passGap", "1.5"),
      get_setting("passMin", "2.0"),
    }, ","))
  if not ok then return end

  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
  local thresh   = tonumber(f[1])
  local minInt   = tonumber(f[2])
  local preroll  = tonumber(f[3])
  local tail     = tonumber(f[4])
  local passGap  = tonumber(f[5])
  local passMin  = tonumber(f[6])
  if not (thresh and minInt and preroll and tail and passGap and passMin) then
    reaper.MB("All six fields must be numbers.", "Split percussion", 0)
    return
  end
  -- A negative tail makes every hit's stop land before its start, so the
  -- "stop > start" test below silently rejects all of them and the action
  -- reports finding onsets while creating nothing.
  if minInt < 0 or preroll < 0 or tail < 0 or passGap < 0 or passMin < 0 then
    reaper.MB("Times and gaps are durations, so none of them can be negative.",
      "Split percussion", 0)
    return
  end
  if thresh > 0 then
    reaper.MB("Hit threshold is dB BELOW the pass peak, so it must be zero or negative.",
      "Split percussion", 0)
    return
  end
  for k, v in pairs { hitThresh = thresh, minInt = minInt, preroll = preroll,
                      tail = tail, passGap = passGap, passMin = passMin } do
    reaper.SetExtState(EXT, k, tostring(v), true)
  end
  minInt, preroll, tail = minInt / 1000, preroll / 1000, tail / 1000

  local src = reaper.GetMediaItemTake_Source(take)
  local path = reaper.GetMediaSourceFileName(src, "")
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local src_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  -- Project seconds and source seconds are only the same thing at 1x. At 2x,
  -- one second of item covers two seconds of source, so every hit offset has to
  -- be scaled and the new takes have to inherit the rate, or they point at the
  -- wrong audio and play it at the wrong speed.
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if playrate <= 0 then playrate = 1 end
  local preserve_pitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")
  local pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
  local src_track = reaper.GetMediaItem_Track(item)
  local track_idx = reaper.GetMediaTrackInfo_Value(src_track, "IP_TRACKNUMBER") -- 1-based

  -- pass detection ---------------------------------------------------
  local coarse = E.read_envelope(take, item_pos, item_len, PASSRATE)
  if #coarse == 0 then
    reaper.MB("Could not read peaks. Let REAPER finish building them and retry.",
      "Split percussion", 0)
    return
  end
  local passes = E.find_spans(coarse, PASSRATE,
    { thresh = thresh, minGap = passGap, minSpan = passMin, pad = 0 })
  if #passes == 0 then
    reaper.MB("No passes found. Lower the threshold, or shorten the gap / min pass length.",
      "Split percussion", 0)
    return
  end
  -- find_spans measures from the start of the envelope, which began at
  -- item_pos. Convert to project time once, here, so everything below --
  -- the per-pass envelope reads, the hit positions -- is in one frame.
  for _, p in ipairs(passes) do p.s = item_pos + p.s; p.e = item_pos + p.e end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local total, empty, created = 0, {}, 0
  for p, pass in ipairs(passes) do
    -- onset detection inside this pass, at transient resolution
    local fine = E.read_envelope(take, pass.s, pass.e - pass.s, HITRATE)
    local onsets = E.find_onsets(fine, HITRATE, { thresh = thresh, minInterval = minInt })

    if #onsets == 0 then
      empty[#empty + 1] = p
    else
      -- Count tracks actually created, not passes examined: a pass with no
      -- onsets would otherwise leave a hole in the numbering and the following
      -- generated tracks would land after whatever tracks already sat there.
      reaper.InsertTrackAtIndex(track_idx + created, true)
      local tr = reaper.GetTrack(0, track_idx + created)
      created = created + 1
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", ("Sound %d"):format(p), true)

      for h, onset in ipairs(onsets) do
        local hit_pos = pass.s + onset
        local next_pos = onsets[h + 1] and (pass.s + onsets[h + 1]) or (pass.e + tail)
        local start = math.max(item_pos, hit_pos - preroll)
        local stop = math.min(hit_pos + tail, next_pos, item_pos + item_len)
        if stop > start then
          -- peak of this hit, from the envelope we already have
          local a = math.max(1, math.floor(onset * HITRATE))
          local b = math.min(#fine, math.floor((stop - pass.s) * HITRATE))
          local pk = 0
          for i = a, b do if fine[i] > pk then pk = fine[i] end end

          local it = reaper.AddMediaItemToTrack(tr)
          reaper.SetMediaItemInfo_Value(it, "D_POSITION", start)
          reaper.SetMediaItemInfo_Value(it, "D_LENGTH", stop - start)
          reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 0.005)
          reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", 0.020)
          local tk = reaper.AddTakeToMediaItem(it)
          reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(path))
          -- D_STARTOFFS is SOURCE time: the source offset of the item plus how
          -- far into the item this hit starts, converted at the playback rate.
          reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS",
            src_offs + (start - item_pos) * playrate)
          reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", playrate)
          reaper.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", preserve_pitch)
          reaper.SetMediaItemTakeInfo_Value(tk, "D_PITCH", pitch)
          reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME",
            ("%d.%d  %.1f dB"):format(p, h, db(pk)), true)
          total = total + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Split percussion recording into hits", -1)

  local msg = { ("%d passes, %d hits."):format(#passes - #empty, total) }
  if #empty > 0 then
    msg[#msg + 1] = ("%d pass(es) had no detectable hits and were skipped."):format(#empty)
  end
  msg[#msg + 1] = "\nRename the new tracks to the sound types (Kick, Tap, Slap...),"
  msg[#msg + 1] = "then run \"Build sampler preset from tracks\"."
  reaper.MB(table.concat(msg, "\n"), "Split percussion", 0)
end

main()
