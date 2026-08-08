-- @noindex
-- Part of the ReapeZoom package. See the main script for metadata.
--
-- Evens out level variation *inside* each song by writing a slow gain curve
-- into one automation item per region on the track volume envelope.
--
-- This is not loudness normalization. Normalization sets one static gain for a
-- whole rendered file; it does nothing about a quiet verse against a loud
-- chorus. A compressor would, but it reacts blind and colours the sound. An
-- offline curve sees the whole song, stays clean, and -- the point -- is
-- visible and draggable afterwards.

local PEAKRATE = 10 -- envelope buckets per second; riding is slow by design
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
local L = require_lib("level.lua")
if not (E and L) then return end

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

-- Regions overlapping the item, in timeline order. No regions -> the whole item.
-- The walk stays here because it needs REAPER; the clipping, sorting and
-- fallback live in envelope.lua where the self-check can actually reach them.
local function spans_for(item_pos, item_len)
  local regions, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    if isrgn then regions[#regions + 1] = { s = pos, e = rgnend } end
    i = i + 1
  end
  return E.spans_in(regions, item_pos, item_len)
end

-- Every selected audio item, or the only item in the project when nothing is
-- selected. Items without an audio take are counted, not silently dropped.
local function collect_items()
  local raw, skipped = {}, 0
  local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then
    if reaper.CountMediaItems(0) == 1 then raw[1] = reaper.GetMediaItem(0, 0) end
  else
    for i = 0, n - 1 do raw[#raw + 1] = reaper.GetSelectedMediaItem(0, i) end
  end

  local out = {}
  for _, item in ipairs(raw) do
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      out[#out + 1] = {
        item = item, take = take, track = reaper.GetMediaItem_Track(item),
        pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
        len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
      }
    else
      skipped = skipped + 1
    end
  end
  return out, skipped
end

-- Measure before touching anything, so the target below is chosen from the
-- material's real numbers instead of a guess.
local function analyze(work, response, floor)
  local lines, ranges = {}, {}
  for i, w in ipairs(work) do
    local env = E.read_envelope(w.take, w.pos, w.len, PEAKRATE)
    local a = #env > 0 and L.analyze(env, PEAKRATE, response, floor) or nil
    if a then
      ranges[#ranges + 1] = a.range
      lines[#lines + 1] = ("Item %d  peak %+.1f  loud %+.1f  quiet %+.1f  range %.1f dB  (%.0f%% programme)")
        :format(i, a.peak, a.loud, a.quiet, a.range, a.gated_frac * 100)
    else
      lines[#lines + 1] = ("Item %d  no measurable level -- peaks not built yet, or silent."):format(i)
    end
  end
  if #ranges == 0 then return nil, table.concat(lines, "\n") end
  -- ponytail: mean across items. Exact for the usual single-item case; median
  -- only if someone rides a pile of wildly different items at once.
  local sum = 0
  for _, r in ipairs(ranges) do sum = sum + r end
  return sum / #ranges, table.concat(lines, "\n")
end

-- 40406 = Track: Toggle track volume envelope visible.
-- That action works on the selected track, so the user's track selection has to
-- be put back afterwards -- silently reselecting their tracks is not our call.
local function volume_envelope(track)
  local env = reaper.GetTrackEnvelopeByName(track, "Volume")
  if env then return env end

  local sel = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(0, i) end
  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommand(40406, 0)
  env = reaper.GetTrackEnvelopeByName(track, "Volume")

  reaper.SetOnlyTrackSelected(track, false)
  for i, tr in ipairs(sel) do reaper.SetTrackSelected(tr, true) end
  if #sel == 0 then reaper.SetTrackSelected(track, false) end
  return env
end

-- Automation items this script owns. REAPER gives no way to delete an
-- automation item from the API, so the reuse path rewrites them in place -- and
-- rewriting one the user made would destroy their work. Matching the COUNT is
-- not ownership; a tag is.
local POOL_TAG = "P_POOL_EXT:ReapeZoom"

local function owns(env, idx)
  local ok, v = reaper.GetSetAutomationItemInfo_String(env, idx, POOL_TAG, "", false)
  return ok and v == "1"
end

local function claim(env, idx)
  reaper.GetSetAutomationItemInfo_String(env, idx, POOL_TAG, "1", true)
end

-- Points drawn on the underlying envelope inside a span would be swallowed by
-- InsertAutomationItem and then deleted on the next run. Refuse instead.
local function underlying_points_in(env, s, e)
  local n = reaper.CountEnvelopePointsEx(env, -1)
  for i = 0, n - 1 do
    local ok, t = reaper.GetEnvelopePointEx(env, -1, i)
    if ok and t >= s and t <= e then return true end
  end
  return false
end

local function main()
  local work, skipped = collect_items()
  if #work == 0 then
    reaper.MB(skipped > 0 and "The selected item(s) have no audio take."
      or "Select the item(s) to ride first.", "Ride levels", 0)
    return
  end

  -- Step 1: analyse. Uses the stored settings -- the last values the user chose
  -- -- because the dialog that would change them has not been shown yet.
  local resp0 = tonumber(get_setting("rResp", "15")) or 15
  local floor0 = tonumber(get_setting("rFloor", "20")) or 20
  local measured, report = analyze(work, resp0, floor0)
  if not measured then
    reaper.MB("Nothing measurable in the selection.\n\n" .. report, "Ride levels", 0)
    return
  end
  if skipped > 0 then
    report = report .. ("\n\n%d selected item(s) skipped -- no audio take."):format(skipped)
  end
  reaper.MB(("%s\n\nDynamic range is the gap between the quiet and loud parts. Ask for less " ..
    "than %.1f dB to tighten it, 0 to flatten it completely, %.1f to leave it alone.")
    :format(report, measured, measured), "Ride levels -- what we are working with", 0)

  local ok, csv = reaper.GetUserInputs("Ride levels into automation items", 6,
    "Max boost (dB),Max cut (dB),Response (s),Max change (dB/s),Noise floor (dB below target),Target range (dB; 0 = flat),extrawidth=60",
    table.concat({
      get_setting("rBoost", "6"),
      get_setting("rCut", "6"),
      get_setting("rResp", "15"),
      get_setting("rSlew", "0.5"),
      get_setting("rFloor", "20"),
      get_setting("rRange", ("%.1f"):format(measured / 2)),
    }, ","))
  if not ok then return end

  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
  local opts = {
    maxBoost = tonumber(f[1]), maxCut = tonumber(f[2]),
    response = tonumber(f[3]), slew = tonumber(f[4]), floor = tonumber(f[5]),
    range = tonumber(f[6]),
    thin = 0.5,
  }
  if not (opts.maxBoost and opts.maxCut and opts.response and opts.slew and opts.floor
          and opts.range) then
    reaper.MB("All six fields must be numbers.", "Ride levels", 0)
    return
  end
  if opts.response <= 0 or opts.slew <= 0 then
    reaper.MB("Response and max change must be greater than zero.", "Ride levels", 0)
    return
  end
  if opts.range < 0 then
    reaper.MB("Target range cannot be negative. Use 0 to flatten completely.", "Ride levels", 0)
    return
  end
  -- A negative max boost becomes a clamp in the wrong direction: even perfectly
  -- flat material would then get that much cut written across the whole item.
  if opts.maxBoost < 0 or opts.maxCut < 0 or opts.floor < 0 then
    reaper.MB("Max boost, max cut and noise floor are amounts, so they cannot be negative.",
      "Ride levels", 0)
    return
  end
  for k, v in pairs { rBoost = opts.maxBoost, rCut = opts.maxCut, rResp = opts.response,
                      rSlew = opts.slew, rFloor = opts.floor, rRange = opts.range } do
    reaper.SetExtState(EXT, k, tostring(v), true)
  end

  -- Group the work by envelope. Several selected items can sit on one track and
  -- share one volume envelope, so the automation-item guard below has to count
  -- once per envelope -- counting per item would false-trigger.
  local groups, order = {}, {}
  for _, w in ipairs(work) do
    local env = volume_envelope(w.track)
    if not env then
      reaper.MB("Could not find or create the track volume envelope.", "Ride levels", 0)
      return
    end
    local g = groups[env]
    if not g then
      g = { env = env, spans = {} }
      groups[env] = g
      order[#order + 1] = g
    end
    for _, sp in ipairs(spans_for(w.pos, w.len)) do
      g.spans[#g.spans + 1] = { s = sp.s, e = sp.e, take = w.take }
    end
  end

  -- Automation items cannot be deleted through the API, so never create a
  -- second set on top of an existing one -- reuse OUR OWN when the shape
  -- matches, otherwise stop and say what to do. Checked for every envelope
  -- BEFORE the undo block opens, so aborting here cannot leave one half-open.
  for _, g in ipairs(order) do
    table.sort(g.spans, function(a, b) return a.s < b.s end)

    local existing = reaper.CountAutomationItems(g.env)
    local mine = 0
    for i = 0, existing - 1 do if owns(g.env, i) then mine = mine + 1 end end

    if existing > mine then
      reaper.MB(("A track envelope has %d automation item(s) that ReapeZoom did not create.\n\n" ..
        "They are left alone. Move or delete them first -- select them, then " ..
        "Envelope: Delete automation items -- and run this again.")
        :format(existing - mine), "Ride levels", 0)
      return
    end
    if mine > 0 and mine ~= #g.spans then
      reaper.MB(("This envelope has %d automation item(s) from a previous run but there are " ..
        "now %d region(s).\n\nDelete them first: select them, then Envelope: Delete " ..
        "automation items."):format(mine, #g.spans), "Ride levels", 0)
      return
    end
    g.reusing = mine == #g.spans and mine > 0

    -- A new automation item absorbs whatever the underlying envelope already
    -- has in its range, and the next run would then delete those points.
    if not g.reusing then
      for _, sp in ipairs(g.spans) do
        if underlying_points_in(g.env, sp.s, sp.e) then
          reaper.MB(("The track volume envelope already has points between %.1f s and %.1f s.\n\n" ..
            "A new automation item would swallow them and a later run would delete them. " ..
            "Clear those points, or move them outside the region, then run this again.")
            :format(sp.s, sp.e), "Ride levels", 0)
          return
        end
      end
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local total, done, reused = 0, 0, false
  for _, g in ipairs(order) do
    local scaling = reaper.GetEnvelopeScalingMode(g.env)
    if g.reusing then reused = true end
    for i, sp in ipairs(g.spans) do
      local len = sp.e - sp.s
      local buckets = E.read_envelope(sp.take, sp.s, len, PEAKRATE)
      local pts = L.ride(buckets, PEAKRATE, opts)
      if #pts > 0 then
        local idx
        if g.reusing then
          idx = i - 1
          reaper.GetSetAutomationItemInfo(g.env, idx, "D_POSITION", sp.s, true)
          reaper.GetSetAutomationItemInfo(g.env, idx, "D_LENGTH", len, true)
          reaper.DeleteEnvelopePointRangeEx(g.env, idx, -1, len + 1)
        else
          idx = reaper.InsertAutomationItem(g.env, -1, sp.s, len) -- -1 = new pool
          claim(g.env, idx) -- tag it so a later run knows this one is ours
        end
        for _, p in ipairs(pts) do
          -- point time is relative to the automation item; value is linear gain
          -- put through the envelope's scaling mode -- volume envelopes may be
          -- fader-scaled, and writing raw gain then is silently wrong
          local v = reaper.ScaleToEnvelopeMode(scaling, 10 ^ (p.db / 20))
          reaper.InsertEnvelopePointEx(g.env, idx, p.t, v, 0, 0, false, true)
        end
        reaper.Envelope_SortPointsEx(g.env, idx)
        total = total + #pts
        done = done + 1
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Ride levels into automation items", -1)

  reaper.MB(("%s %d automation item(s) on %d envelope(s), %d points total.\n\n" ..
    "Target range %.1f dB, measured %.1f dB before.\n\n" ..
    "They are on the track volume envelope -- look at them, drag anything that " ..
    "sounds wrong. Toggle one off to A/B it.\n\nRiding is separate from render " ..
    "normalization: this evens out level inside a song, normalization sets the " ..
    "level of the whole file.")
    :format(reused and "Rewrote" or "Created", done, #order, total, opts.range, measured),
    "Ride levels", 0)
end

main()
