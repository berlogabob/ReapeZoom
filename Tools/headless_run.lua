-- @noindex
-- Unattended run of "Split rehearsal recording into song regions": batch-mode
-- settings, wait for peaks, run the action, save the project, quit REAPER.
--   reaper -nosplash <project>.RPP Tools/headless_run.lua
-- The recording item must be selected in the project. Edit SETTINGS per take.
local SETTINGS = { thresh = "auto", minGap = "8", minSong = "90", pad = "1.0", render = "y", align = "n" }
local EXT = "ReapeZoom"
local here = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]")
local ACTION = here .. "/../Scripts/berloga_Split rehearsal recording into song regions.lua"

local item = reaper.GetSelectedMediaItem(0, 0)
local take = item and reaper.GetActiveTake(item)
local pos = item and reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local buf = reaper.new_array(100 * 2 * 3)
local deadline = reaper.time_precise() + 900

-- Until REAPER has built peaks, GetMediaItemTake_Peaks returns zeros and the
-- action reports "no songs found" over a perfectly good recording.
local function peaks_at(t)
  buf.clear()
  reaper.GetMediaItemTake_Peaks(take, 20, t, 2, 100, 0, buf)
  for i = 1, 200 do if math.abs(buf[i]) > 0 then return true end end
  return false
end

local function run()
  reaper.SetExtState(EXT, "batch", "1", false)
  for k, v in pairs(SETTINGS) do reaper.SetExtState(EXT, k, v, false) end
  -- the action finds lib/ next to the script it believes it is
  local real = reaper.get_action_context
  reaper.get_action_context = function() return false, ACTION end
  local ok, err = pcall(dofile, ACTION)
  reaper.get_action_context = real
  if not ok then reaper.ShowConsoleMsg(tostring(err) .. "\n") end
  reaper.DeleteExtState(EXT, "batch", false)
  reaper.Main_SaveProject(0, false)
  reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
end

local function poll()
  if not take or (peaks_at(pos + 1) and peaks_at(pos + len - 10)) or reaper.time_precise() > deadline then
    run()
  else
    reaper.defer(poll)
  end
end
poll()
