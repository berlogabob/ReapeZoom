-- @description ReapeZoom
-- @author berlogabob
-- @version 2.0
-- @link https://github.com/berlogabob/ReapeZoom
-- @provides
--   [main] .
--   [main] berloga_Split percussion recording into hits.lua
--   [main] berloga_Build sampler preset from tracks.lua
--   [nomain] lib/envelope.lua
--   [nomain] lib/preset.lua
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
--   Ship as one package with three actions and a shared library.
--   Add percussion hit splitting and SFZ / Decent Sampler preset building.

local PEAKRATE = 20 -- envelope buckets per second
local EXT = "ReapeZoom"

local env_lib = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]") .. "/lib/envelope.lua"
local E = dofile(env_lib)

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
    minSpan = tonumber(f[3]), pad = tonumber(f[4]),
  }
  local do_render = (f[5] or ""):lower():sub(1, 1) == "y"
  if not (opts.thresh and opts.minGap and opts.minSpan and opts.pad) then
    reaper.MB("All four numeric fields are required.", "Split rehearsal", 0)
    return
  end
  reaper.SetExtState(EXT, "thresh", tostring(opts.thresh), true)
  reaper.SetExtState(EXT, "minGap", tostring(opts.minGap), true)
  reaper.SetExtState(EXT, "minSong", tostring(opts.minSpan), true)
  reaper.SetExtState(EXT, "pad", tostring(opts.pad), true)
  reaper.SetExtState(EXT, "render", do_render and "y" or "n", true)

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local env = E.read_envelope(take, item_pos, item_len, PEAKRATE)
  if #env == 0 then
    reaper.MB("Could not read peaks for this item. Let REAPER finish building them and retry.",
      "Split rehearsal", 0)
    return
  end

  local songs = E.find_spans(env, PEAKRATE, opts)
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
