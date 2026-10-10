-- @noindex
-- Mastering layer for the ReapeZoom actions: loudness presets, a gentle
-- master-bus chain, and a check that measures what was actually rendered.
-- Runs standalone under `lua master.lua` to exercise the pure logic.

local M = {}

----------------------------------------------------------------------
-- pure logic
----------------------------------------------------------------------

-- fmt "mp3" is 320 kbps CBR, "wav" is 24-bit. Lossy encoding overshoots the
-- limiter by up to ~0.6 dB (measured on 8 renders: -1.5 dBTP in, -0.9 worst out), so a lossy preset
-- limits lower than it promises.
M.PRESETS = {
  mp3       = { lufs = -14, tp = -1, fmt = "mp3", what = "shareable demo, MP3 320" },
  streaming = { lufs = -14, tp = -1, fmt = "wav", what = "Spotify / YouTube / Amazon master" },
  apple     = { lufs = -16, tp = -1, fmt = "wav", what = "Apple Music master" },
  archive   = { lufs = -18, tp = -1, fmt = "wav", what = "quiet, dynamic archive copy" },
}
M.ORDER = { "mp3", "streaming", "apple", "archive" }
M.TRIM_LUFS = -18  -- level the chain sees; hot float captures peak far above 0 dBFS
M.LOSSY_MARGIN = 1.0

function M.ceiling(p)
  return p.tp - (p.fmt == "mp3" and M.LOSSY_MARGIN or 0)
end

-- Gain in dB that brings a measured loudness to the chain's working level.
function M.trim_db(measured_lufs)
  return M.TRIM_LUFS - measured_lufs
end

-- true when a rendered file meets the preset, else false and why.
-- Normalization is applied before the limiter, so loudness lands a little under
-- target on peaky material; 1 LU is the tolerance, true peak gets none.
function M.verdict(p, lufs, tp)
  if tp > p.tp + 0.05 then
    return false, ("true peak %.1f dBTP is over %.1f"):format(tp, p.tp)
  end
  if math.abs(lufs - p.lufs) > 1.0 then
    return false, ("%.1f LUFS is more than 1 LU from %.0f"):format(lufs, p.lufs)
  end
  return true
end

----------------------------------------------------------------------
-- REAPER side
----------------------------------------------------------------------

local function lin_to_db(x) return 20 * math.log(x, 10) end

-- Sets an FX parameter by what it DISPLAYS ("-18" dB, "2.00" ratio), not by its
-- normalised value, which for these plug-ins is a curve nobody should hard-code.
-- Bisection works because every parameter used here is monotonic.
function M.set_display(track, fx, param, target)
  local function shown(v)
    local _, text = reaper.TrackFX_FormatParamValueNormalized(track, fx, param, v, "")
    if text:find("inf") then return -math.huge end
    return tonumber(text:match("[-+]?%d*%.?%d+"))
  end
  local lo, hi = 0, 1
  local rising = (shown(1) or 0) > (shown(0) or 0)
  for _ = 1, 40 do
    local mid = (lo + hi) / 2
    local s = shown(mid)
    if not s then return false end
    if (s < target) == rising then lo = mid else hi = mid end
  end
  reaper.TrackFX_SetParamNormalized(track, fx, param, (lo + hi) / 2)
  return true
end

-- Master-bus chain: glue compressor, then a limiter at the preset's ceiling.
-- Stock plug-ins only. Tagged by name so a re-run updates instead of stacking.
-- (A high-pass is deliberately absent: ReaEQ exposes no band-enable parameter.)
function M.apply_chain(p)
  local master = reaper.GetMasterTrack(0)
  local function find(tag)
    for i = 0, reaper.TrackFX_GetCount(master) - 1 do
      local _, name = reaper.TrackFX_GetFXName(master, i, "")
      if name:find(tag, 1, true) then return i end
    end
  end
  local function ensure(plugin)
    local tag = "ReapeZoom " .. plugin
    local fx = find(tag)
    if not fx then
      fx = reaper.TrackFX_AddByName(master, plugin, false, -1)
      if fx < 0 then return nil end
      reaper.TrackFX_SetNamedConfigParm(master, fx, "renamed_name", tag)
    end
    return fx
  end
  local comp, lim = ensure("ReaComp"), ensure("ReaLimit")
  if not (comp and lim) then return false, "ReaComp or ReaLimit not found" end
  -- parameter indices from a dump of the stock plug-ins
  M.set_display(master, comp, 0, -20)  -- threshold dB
  M.set_display(master, comp, 1, 2)    -- ratio
  M.set_display(master, comp, 2, 30)   -- attack ms
  M.set_display(master, comp, 3, 250)  -- release ms
  M.set_display(master, lim, 0, M.ceiling(p) - 6)  -- limiter threshold
  M.set_display(master, lim, 1, M.ceiling(p))      -- ceiling
  return true
end

-- WAV24 and MP3 320 CBR sink strings, copied from REAPER-saved projects.
local FORMAT = { wav = "ZXZhdxgAAQ==", mp3 = "bDNwbUABAAAAAAAAAgAAAP////8EAAAAQAEAAAAAAAA=" }

function M.apply_render(p)
  local changed = {}
  local function num(key, v)
    local old = reaper.GetSetProjectInfo(0, key, 0, false)
    if math.abs(old - v) > 1e-9 then
      changed[#changed + 1] = ("%s: %g -> %g"):format(key, old, v)
      reaper.GetSetProjectInfo(0, key, v, true)
    end
  end
  num("RENDER_NORMALIZE", 1 | 64 | 128 | 512 | 1024) -- LUFS-I, brickwall, true peak, fades
  num("RENDER_NORMALIZE_TARGET", 10 ^ (p.lufs / 20))
  num("RENDER_BRICKWALL", 10 ^ (M.ceiling(p) / 20))
  local _, old = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
  if old ~= FORMAT[p.fmt] then
    changed[#changed + 1] = "RENDER_FORMAT: -> " .. p.fmt
    reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", FORMAT[p.fmt], true)
  end
  return changed
end

-- Loudness (LUFS-I) and true peak (dBTP) of any file REAPER can open.
-- CalculateNormalization returns the gain that reaches the target, and the target
-- is in dB (not linear, unlike RENDER_NORMALIZE_TARGET), so against 0 the
-- measurement is minus that gain in dB. Checked against ffmpeg ebur128 on a
-- rendered MP3: -14.2 LUFS and -1.0 dBTP both agree.
function M.measure(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local len = reaper.GetMediaSourceLength(src)
  local function gain(kind) return reaper.CalculateNormalization(src, kind, 0, 0, 0) end
  local lufs = -lin_to_db(gain(0))   -- 0 = LUFS-I
  local tp = -lin_to_db(gain(3))     -- 3 = true peak
  reaper.PCM_Source_Destroy(src)
  return lufs, tp, len
end

-- Loudness of the whole item, used to place the chain's input level.
function M.measure_take(take)
  local src = reaper.GetMediaItemTake_Source(take)
  return -lin_to_db(reaper.CalculateNormalization(src, 0, 0, 0, 0))
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  for _, name in ipairs(M.ORDER) do
    local p = M.PRESETS[name]
    assert(p and p.lufs < 0 and p.tp <= 0 and (p.fmt == "mp3" or p.fmt == "wav"), name)
  end
  assert(#M.ORDER == 4, "every preset must be listed once")
  -- lossy presets limit lower than they promise, lossless ones do not
  assert(M.ceiling(M.PRESETS.mp3) == -2 and M.ceiling(M.PRESETS.streaming) == -1)
  -- a hot capture (-5 LUFS) is trimmed down, a quiet one (-30) is brought up
  assert(M.trim_db(-5) == -13 and M.trim_db(-30) == 12)
  -- verdict: loudness tolerance both ways, true peak has none
  local p = M.PRESETS.mp3
  assert(M.verdict(p, -14.4, -1.2))
  assert(not M.verdict(p, -14.4, -0.5), "true peak over the ceiling must fail")
  assert(not M.verdict(p, -16.5, -1.5), "2.5 LU under target must fail")
  assert(not M.verdict(p, -12.5, -1.5), "1.5 LU over target must fail")
  local ok, why = M.verdict(p, -14, -0.2)
  assert(not ok and why:find("true peak"), "failure must say why")
  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
