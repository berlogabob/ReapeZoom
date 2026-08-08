-- @noindex
-- Part of the ReapeZoom package. See the main script for metadata.
--
-- Checks a stereo capture for the faults that actually matter on release:
-- polarity inversion, L/R imbalance, DC offset, and mono compatibility.
-- Spotify plays in mono on plenty of devices, so mono collapse is a real
-- concern rather than a purist's footnote.
--
-- It does not time-align the channels. Coincident capsules see the sound at
-- the same instant; there is no offset to remove.

local PEAKRATE = 20
local WINDOWS = 20    -- correlation windows spread through the file
local WINDOW_S = 0.5  -- seconds each
local EXT = "ReapeZoom"

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
local S = require_lib("stereo.lua")
if not (E and S) then return end

-- Correlation needs real samples, and a 91-minute file is 263M frames. Sample
-- windows spread through it instead -- fast, and honest about being an estimate.
local function sample_correlation(take, item_pos, item_len)
  local acc = reaper.CreateTakeAudioAccessor(take)
  if not acc then return nil, 0 end
  local sr = 48000
  -- An item shorter than the window would otherwise be read from before its
  -- start and past its end, counting the same fraction of a second repeatedly
  -- and reporting far more material as "sampled" than actually exists.
  local win = math.min(WINDOW_S, item_len)
  if win <= 0 then reaper.DestroyAudioAccessor(acc); return nil, 0 end
  local n = math.floor(win * sr)
  if n < 2 then reaper.DestroyAudioAccessor(acc); return nil, 0 end
  local buf = reaper.new_array(n * 2)
  local sums, count = 0, 0

  for w = 0, WINDOWS - 1 do
    local t = item_pos + (item_len - win) * (w / math.max(1, WINDOWS - 1))
    buf.clear()
    if reaper.GetAudioAccessorSamples(acc, sr, 2, t, n, buf) == 1 then
      local l, r, peak = {}, {}, 0
      for i = 1, n do
        local a, b = buf[(i - 1) * 2 + 1], buf[(i - 1) * 2 + 2]
        l[i] = a; r[i] = b
        peak = math.max(peak, math.abs(a), math.abs(b))
      end
      -- skip near-silent windows: correlation of noise is meaningless and
      -- would drag the average toward zero for no reason
      if peak > 0.001 then
        sums = sums + S.correlation(l, r)
        count = count + 1
      end
    end
  end
  reaper.DestroyAudioAccessor(acc)
  if count == 0 then return nil, 0 end
  return sums / count, count * win
end

local function main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item and reaper.CountMediaItems(0) == 1 then item = reaper.GetMediaItem(0, 0) end
  if not item then
    reaper.MB("Select the item to check first.", "Stereo check", 0)
    return
  end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    reaper.MB("Selected item has no audio take.", "Stereo check", 0)
    return
  end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local chans, nch = E.read_channels(take, item_pos, item_len, PEAKRATE)
  if nch < 1 then
    reaper.MB("Could not read any channels from this item.\n\nIts source reports no channels " ..
      "-- it may be offline, still building peaks, or not audio at all.", "Stereo check", 0)
    return
  end
  if nch < 2 then
    reaper.MB("This item is mono -- nothing stereo to check.", "Stereo check", 0)
    return
  end

  local peaks = S.analyze_peaks(chans)
  local corr, sampled = sample_correlation(take, item_pos, item_len)
  local text, flags = S.report(peaks, corr, sampled)

  -- Only polarity gets an automatic fix, because it is the only one that can be
  -- applied completely. Half-configuring a plugin and calling it done is worse
  -- than saying what to do.
  local advice = {}
  if flags.dc then
    advice[#advice + 1] = "DC offset: add ReaEQ and set band 1 to High Pass at 20 Hz."
  end
  if flags.balance then
    advice[#advice + 1] = "Balance: judgement call -- a band really can be louder on one side."
    advice[#advice + 1] = "  To correct it anyway, use utility/chanmix2 and trim the louder side."
  end
  local tail = #advice > 0 and ("\n\n" .. table.concat(advice, "\n")) or ""

  if not flags.polarity then
    reaper.MB(text .. (tail ~= "" and tail or "\n\nNothing needs fixing."), "Stereo check", 0)
    return
  end

  local answer = reaper.MB(text .. tail ..
    "\n\nFlip the right channel's polarity now?\n" ..
    "(Adds utility/chanmix2 to THIS TAKE with Right Phase = Invert.)",
    "Stereo check", 4) -- 4 = Yes/No
  if answer ~= 6 then return end

  reaper.Undo_BeginBlock()
  -- On the take, not the track. The diagnosis came from this one item, and a
  -- track FX would invert every other item on the same track as well -- the
  -- healthy ones included.
  -- chanmix2 is "Stereo Channel Volume/Pan/Polarity Control":
  -- slider1..6 -> params 0..5, so param 5 is Right Phase (0 = Normal, 1 = Invert)
  local fx = reaper.TakeFX_AddByName(take, "utility/chanmix2", 1)
  local msg
  if fx >= 0 then
    reaper.TakeFX_SetParam(take, fx, 5, 1)
    -- Deliberately NOT "re-run and correlation will be positive": this check
    -- reads through CreateTakeAudioAccessor, which returns audio from before
    -- the take FX chain. Re-running would report the same negative number and
    -- look like the fix had failed.
    msg = "Added utility/chanmix2 to this take with Right Phase = Invert.\n\n" ..
      "Listen to it -- the item should now sum to mono properly.\n\n" ..
      "Re-running this check will still report the original correlation: it " ..
      "measures the take's source audio, which is upstream of the take FX."
  else
    msg = "Could not add utility/chanmix2. Add it to the take by hand and set " ..
      "Right Phase to Invert."
  end
  reaper.Undo_EndBlock("Flip right channel polarity", -1)

  reaper.MB(msg, "Stereo check", 0)
end

main()
