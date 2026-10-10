-- @noindex
-- Part of the ReapeZoom package. See the main script for metadata.
--
-- The whole job in one go, each step being the action you would run by hand:
-- stereo check, split into songs, level riding, master chain, render, then a
-- check of what was rendered. Every step keeps its own dialog, so nothing is
-- decided for you; this only removes the walking between them.
-- Select the recording item first.

local EXT = "ReapeZoom"
local dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]")

local STEPS = {
  { "Check stereo and phase", "berloga_Check stereo and phase.lua" },
  { "Split rehearsal recording into song regions", "berloga_Split rehearsal recording into song regions.lua" },
  { "Ride levels into automation items", "berloga_Ride levels into automation items.lua" },
  { "Master songs (apply)", "berloga_Master songs.lua", "apply" },
  { "RENDER" },
  { "Master songs (check)", "berloga_Master songs.lua", "check" },
}

local function run(steps, i)
  local step = steps[i]
  if not step then return end
  if reaper.MB(("Step %d of %d: %s"):format(i, #steps, step[1]), "Rehearsal to masters", 1) ~= 1 then return end
  if step[1] == "RENDER" then
    reaper.Main_OnCommand(41824, 0) -- File: Render project, using the most recent render settings
  else
    if step[3] then reaper.SetExtState(EXT, "mMode", step[3], false) end
    local ok, err = pcall(dofile, dir .. "/" .. step[2])
    if not ok then
      reaper.MB(("%s failed:\n%s\n\nStopping here."):format(step[1], tostring(err)), "Rehearsal to masters", 0)
      return
    end
  end
  run(steps, i + 1)
end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then
  reaper.MB("Select the rehearsal item first.", "Rehearsal to masters", 0)
  return
end

-- Peaks must exist before the steps run: they are synchronous, and the split
-- would otherwise have to wait mid-chain.
local take = reaper.GetActiveTake(item)
local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local buf = reaper.new_array(600)
local function at(t)
  buf.clear()
  reaper.GetMediaItemTake_Peaks(take, 20, t, 2, 100, 0, buf)
  for k = 1, 200 do if math.abs(buf[k]) > 0 then return true end end
  return false
end
local deadline = reaper.time_precise() + 900
local function start()
  if not take or (at(pos + math.min(1, len / 2)) and at(math.max(pos, pos + len - 10)))
     or reaper.time_precise() > deadline then
    run(STEPS, 1)
  else
    reaper.defer(start)
  end
end
start()
