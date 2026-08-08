-- @noindex
-- Part of the ReapeZoom package. See the main script for metadata.
--
-- Turns tracks of one-shot hits into a sampler instrument.
--   track     -> articulation -> one MIDI note -> one preset group
--   loudness  -> velocity layer
--   k-th hit within a (track, layer) cell -> round robin
-- Lays that matrix out on the arrange grid so misfiled hits are visible,
-- names the takes so REAPER's $item wildcard renders correct filenames, and
-- writes both .sfz and .dspreset.

local ANALYSISRATE = 400 -- buckets/s when measuring a hit's peak
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
local P = require_lib("preset.lua")
if not (E and P) then return end

local function get_setting(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

-- "Kick [36]" pins the note; otherwise notes run upward from 36. There is no
-- sensible General MIDI mapping for a cajon, so nothing is guessed.
-- The parsing itself lives in preset.lua, where the self-check can reach it --
-- including the "[128] is not a MIDI note" case that used to reach the presets.
local function parse_track(tr, fallback_note)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return P.parse_name(name, fallback_note, ("Track %d"):format(fallback_note - 35))
end

local function collect_tracks()
  local out = {}
  local n = reaper.CountSelectedTracks(0)
  if n > 0 then
    for i = 0, n - 1 do out[#out + 1] = reaper.GetSelectedTrack(0, i) end
  else
    -- a source recording sits alone on its track; hit tracks hold many items
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if reaper.CountTrackMediaItems(tr) >= 2
        and reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 0 then
        out[#out + 1] = tr
      end
    end
  end
  return out
end

local function hit_peak(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  -- ponytail: peak, not RMS or LUFS. For one-shots it tracks perceived level
  -- closely enough and needs no extension. Revisit if soft hits with long
  -- decays keep landing in the wrong layer.
  return E.max_peak(E.read_envelope(take, pos, len, ANALYSISRATE))
end

local function apply_render_settings(samples_dir)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 32, true)  -- selected media items, dry
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true) -- selected media items
  -- Normalizing sample exports would destroy the dynamics the velocity layers
  -- encode. The rehearsal script turns this on project-wide, so turning it off
  -- here is mandatory, not cosmetic.
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, true) -- project rate
  -- Not set before, so a project left over from a mono bounce rendered every
  -- sample in mono and both presets then pointed at those files.
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 2, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$item", true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", samples_dir, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "ZXZhdxgAAQ==", true) -- evaw + 0x18: WAV 24-bit
end

local function main()
  local _, projfn = reaper.EnumProjects(-1)
  if projfn == "" then
    reaper.MB("Save the project first -- the preset files go next to it.", "Build preset", 0)
    return
  end
  local projdir = projfn:match("^(.*)[/\\]")
  local kit = projfn:match("([^/\\]+)%.[Rr][Pp][Pp]$") or "Kit"

  local tracks = collect_tracks()
  if #tracks == 0 then
    reaper.MB("No hit tracks found.\n\nSelect the tracks to build from, or leave nothing " ..
      "selected to use every unmuted track holding 2+ items.", "Build preset", 0)
    return
  end

  local ok, csv = reaper.GetUserInputs("Build sampler preset from tracks", 3,
    "Velocity layers,Grid slot per hit (s),Lay out matrix on grid (y/n),extrawidth=60",
    table.concat({
      get_setting("layers", "4"),
      get_setting("slot", "2.0"),
      get_setting("layout", "y"),
    }, ","))
  if not ok then return end

  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v end
  local nlayers = tonumber(f[1])
  local slot = tonumber(f[2])
  local do_layout = (f[3] or ""):lower():sub(1, 1) == "y"
  -- Whole layers only, and at most 127 of them: a fractional count produces a
  -- layer key that #layers cannot see, and past 127 the velocity ranges run off
  -- the end of MIDI and the presets will not load.
  if not nlayers or nlayers < 1 or nlayers > 127 or nlayers % 1 ~= 0
     or not slot or slot <= 0 then
    reaper.MB("Velocity layers must be a whole number from 1 to 127, and the slot must be " ..
      "positive.", "Build preset", 0)
    return
  end
  reaper.SetExtState(EXT, "layers", tostring(nlayers), true)
  reaper.SetExtState(EXT, "slot", tostring(slot), true)
  reaper.SetExtState(EXT, "layout", do_layout and "y" or "n", true)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- measure and classify --------------------------------------------
  -- Slugs are worked out for all tracks together, because they have to be
  -- unique across the whole kit: "Tap & Slap" and "Tap / Slap" reduce to the
  -- same filename on their own and one articulation would overwrite the other.
  local names, notes = {}, {}
  for t, tr in ipairs(tracks) do
    names[t], notes[t] = parse_track(tr, 35 + t)
  end
  local slugs = P.slugs(names)

  local matrix, warnings, maxrr = {}, {}, 1
  for t, tr in ipairs(tracks) do
    local name, note, slug = names[t], notes[t], slugs[t]
    local items, peaks = {}, {}
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local pk = hit_peak(it)
      if pk and pk > 0 then
        items[#items + 1] = it
        peaks[#peaks + 1] = pk
      end
    end
    if #items > 0 then
      local layer_of, layers = E.assign_layers(peaks, nlayers)
      local n = #layers
      if n < nlayers then
        warnings[#warnings + 1] = ("%s: only %d hits, using %d layers"):format(name, #items, n)
      end
      for l = 1, n do
        local spread = layers[l].hi - layers[l].lo
        if spread > 9 then
          -- round robins are meant to sound alike; a wide layer breaks that
          warnings[#warnings + 1] =
            ("%s layer %d spans %.0f dB -- add layers, those round robins won't match")
            :format(name, l, spread)
        end
      end

      local rr_in_layer = {}
      local group = { name = name, note = note, samples = {}, items = {} }
      for i, it in ipairs(items) do
        local l = layer_of[i]
        rr_in_layer[l] = (rr_in_layer[l] or 0) + 1
        local rr = rr_in_layer[l]
        if rr > maxrr then maxrr = rr end
        local lovel, hivel = E.velocity_range(l, n)
        local base = ("%s_v%d_rr%d"):format(slug, l, rr)
        group.samples[#group.samples + 1] =
          { file = "Samples/" .. base .. ".wav", lovel = lovel, hivel = hivel,
            seq = rr, seqlen = 0, layer = l }
        group.items[#group.items + 1] = { item = it, name = base, layer = l, rr = rr }
      end
      -- seqlen is the cycle length of the layer this sample belongs to
      for _, s in ipairs(group.samples) do s.seqlen = rr_in_layer[s.layer] end
      matrix[#matrix + 1] = group
    end
  end

  if #matrix == 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Build sampler preset", -1)
    reaper.MB("No audio hits found on those tracks.", "Build preset", 0)
    return
  end

  -- name takes, and optionally lay the matrix out on the grid ---------
  for _, g in ipairs(matrix) do
    for _, h in ipairs(g.items) do
      local take = reaper.GetActiveTake(h.item)
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", h.name, true)
      if do_layout then
        -- column = velocity layer, position within column = round robin,
        -- identical X mapping on every track so columns line up
        reaper.SetMediaItemInfo_Value(h.item, "D_POSITION",
          ((h.layer - 1) * maxrr + (h.rr - 1)) * slot)
        reaper.SetMediaItemInfo_Value(h.item, "D_LENGTH",
          math.min(reaper.GetMediaItemInfo_Value(h.item, "D_LENGTH"), slot))
      end
    end
  end

  if do_layout then
    -- Column markers, replacing the ones WE made. Matching on the name alone
    -- would delete a user's own marker called "v1"; the ids of ours are
    -- remembered in the project instead, the same way the rehearsal script
    -- tracks the regions it owns.
    local _, owned_csv = reaper.GetProjExtState(0, EXT, "layout_markers")
    local owned = {}
    for id in owned_csv:gmatch("%d+") do owned[tonumber(id)] = true end

    local i = 0
    while true do
      local ret, isrgn, _, _, _, idx = reaper.EnumProjectMarkers3(0, i)
      if ret == 0 then break end
      if not isrgn and owned[idx] then reaper.DeleteProjectMarker(0, idx, false)
      else i = i + 1 end
    end

    local ids = {}
    for l = 1, nlayers do
      ids[#ids + 1] = reaper.AddProjectMarker2(0, false, (l - 1) * maxrr * slot, 0,
        ("v%d"):format(l), -1, 0)
    end
    reaper.SetProjExtState(0, EXT, "layout_markers", table.concat(ids, ","))
  end

  -- render setup and preset files ------------------------------------
  local samples_dir = projdir .. "/Samples"
  reaper.RecursiveCreateDirectory(samples_dir, 0)
  apply_render_settings(samples_dir)

  local written, failed = {}, {}
  for _, spec in ipairs {
    { projdir .. "/" .. kit .. ".sfz", P.build_sfz(matrix, kit) },
    { projdir .. "/" .. kit .. ".dspreset", P.build_dspreset(matrix, kit) },
  } do
    local fh, err = io.open(spec[1], "w")
    if fh then
      fh:write(spec[2]); fh:close()
      written[#written + 1] = spec[1]:match("([^/\\]+)$")
    else
      failed[#failed + 1] = ("%s (%s)"):format(spec[1]:match("([^/\\]+)$"), err or "?")
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Build sampler preset from tracks", -1)

  local nsamples = 0
  local msg = {}
  for _, g in ipairs(matrix) do
    nsamples = nsamples + #g.samples
    msg[#msg + 1] = ("  %s  note %d  %d hits"):format(g.name, g.note, #g.samples)
  end
  table.insert(msg, 1, ("%d articulations, %d samples:"):format(#matrix, nsamples))
  if #warnings > 0 then
    msg[#msg + 1] = "\nWarnings:"
    for _, w in ipairs(warnings) do msg[#msg + 1] = "  " .. w end
  end
  if #failed > 0 then
    msg[#msg + 1] = "\nCould not write: " .. table.concat(failed, ", ")
  end
  msg[#msg + 1] = ("\nWrote %s next to the project."):format(table.concat(written, " and "))
  msg[#msg + 1] = "Now: Select All Items, then Render -- output goes to Samples/."
  reaper.MB(table.concat(msg, "\n"), "Build preset", 0)
end

main()
