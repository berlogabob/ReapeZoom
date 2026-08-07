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
  return dofile(path)
end

local E = require_lib("envelope.lua")
local L = require_lib("level.lua")
if not (E and L) then return end

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

-- Regions overlapping the item, in timeline order. No regions -> the whole item.
local function spans_for(item_pos, item_len)
  local out, i = {}, 0
  while true do
    local ret, isrgn, pos, rgnend = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    if isrgn and rgnend > item_pos and pos < item_pos + item_len then
      out[#out + 1] = { s = math.max(pos, item_pos), e = math.min(rgnend, item_pos + item_len) }
    end
    i = i + 1
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  if #out == 0 then out[1] = { s = item_pos, e = item_pos + item_len } end
  return out
end

local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item and reaper.CountMediaItems(0) == 1 then item = reaper.GetMediaItem(0, 0) end
  if not item then
    reaper.MB("Select the item to ride first.", "Ride levels", 0)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.MB("Selected item has no audio take.", "Ride levels", 0)
    return
  end
  local track = reaper.GetMediaItem_Track(item)

  local ok, csv = reaper.GetUserInputs("Ride levels into automation items", 5,
    "Max boost (dB),Max cut (dB),Response (s),Max change (dB/s),Noise floor (dB below target),extrawidth=60",
    table.concat({
      get_setting("rBoost", "6"),
      get_setting("rCut", "6"),
      get_setting("rResp", "15"),
      get_setting("rSlew", "0.5"),
      get_setting("rFloor", "20"),
    }, ","))
  if not ok then return end

  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
  local opts = {
    maxBoost = tonumber(f[1]), maxCut = tonumber(f[2]),
    response = tonumber(f[3]), slew = tonumber(f[4]), floor = tonumber(f[5]),
    thin = 0.5,
  }
  if not (opts.maxBoost and opts.maxCut and opts.response and opts.slew and opts.floor) then
    reaper.MB("All five fields must be numbers.", "Ride levels", 0)
    return
  end
  if opts.response <= 0 or opts.slew <= 0 then
    reaper.MB("Response and max change must be greater than zero.", "Ride levels", 0)
    return
  end
  for k, v in pairs { rBoost = opts.maxBoost, rCut = opts.maxCut, rResp = opts.response,
                      rSlew = opts.slew, rFloor = opts.floor } do
    reaper.SetExtState(EXT, k, tostring(v), true)
  end

  local env = reaper.GetTrackEnvelopeByName(track, "Volume")
  if not env then
    -- 40406 = Track: Toggle track volume envelope visible
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(40406, 0)
    env = reaper.GetTrackEnvelopeByName(track, "Volume")
  end
  if not env then
    reaper.MB("Could not find or create the track volume envelope.", "Ride levels", 0)
    return
  end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local spans = spans_for(item_pos, item_len)

  -- Automation items cannot be deleted through the API, so never create a
  -- second set on top of an existing one -- reuse when the shape matches,
  -- otherwise stop and say what to do.
  local existing = reaper.CountAutomationItems(env)
  if existing > 0 and existing ~= #spans then
    reaper.MB(("This envelope already has %d automation item(s) but there are %d region(s).\n\n" ..
      "Delete them first: select them, then Envelope: Delete automation items.")
      :format(existing, #spans), "Ride levels", 0)
    return
  end
  local reusing = existing == #spans and existing > 0

  local scaling = reaper.GetEnvelopeScalingMode(env)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local total, done = 0, 0
  for i, sp in ipairs(spans) do
    local len = sp.e - sp.s
    local buckets = E.read_envelope(take, sp.s, len, PEAKRATE)
    local pts = L.ride(buckets, PEAKRATE, opts)
    if #pts > 0 then
      local idx
      if reusing then
        idx = i - 1
        reaper.GetSetAutomationItemInfo(env, idx, "D_POSITION", sp.s, true)
        reaper.GetSetAutomationItemInfo(env, idx, "D_LENGTH", len, true)
        reaper.DeleteEnvelopePointRangeEx(env, idx, -1, len + 1)
      else
        idx = reaper.InsertAutomationItem(env, -1, sp.s, len) -- -1 = new pool
      end
      for _, p in ipairs(pts) do
        -- point time is relative to the automation item; value is linear gain
        -- put through the envelope's scaling mode -- volume envelopes may be
        -- fader-scaled, and writing raw gain then is silently wrong
        local v = reaper.ScaleToEnvelopeMode(scaling, 10 ^ (p.db / 20))
        reaper.InsertEnvelopePointEx(env, idx, p.t, v, 0, 0, false, true)
      end
      reaper.Envelope_SortPointsEx(env, idx)
      total = total + #pts
      done = done + 1
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Ride levels into automation items", -1)

  reaper.MB(("%s %d automation item(s), %d points total.\n\n" ..
    "They are on the track volume envelope -- look at them, drag anything that " ..
    "sounds wrong. Toggle one off to A/B it.\n\nRiding is separate from render " ..
    "normalization: this evens out level inside a song, normalization sets the " ..
    "level of the whole file.")
    :format(reusing and "Rewrote" or "Created", done, total), "Ride levels", 0)
end

main()
