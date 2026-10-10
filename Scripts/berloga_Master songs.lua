-- @noindex
-- Mastering layer. "apply" sets the loudness preset, trims the selected item(s) to
-- the level the master chain expects, and adds the master-bus compressor and
-- limiter. "check" measures every rendered file against the preset.
-- Unattended: ExtState ReapeZoom/batch=1 with mPreset, mChain, mTrim, mMode.

local EXT = "ReapeZoom"
local BATCH = reaper.GetExtState(EXT, "batch") == "1"

local function MB(msg, title, kind)
  if not BATCH then return reaper.MB(msg, title, kind) end
  local _, proj = reaper.EnumProjects(-1)
  local log = io.open((proj:match("^(.*)[/\\]") or ".") .. "/reapezoom-batch.log", "a")
  if log then log:write(("[%s]\n%s\n\n"):format(title, msg)); log:close() end
  return 1
end

local function get(key, default)
  local v = reaper.GetExtState(EXT, key)
  return v ~= "" and v or default
end

local dir = ({ reaper.get_action_context() })[2]:match("^(.*)[/\\]")
local ok, M = pcall(dofile, dir .. "/lib/master.lua")
if not ok or type(M) ~= "table" then
  MB("Library failed to load:\n" .. dir .. "/lib/master.lua\n\nReinstall ReapeZoom via ReaPack.",
    "ReapeZoom", 0)
  return
end

local function yes(s) return (s or ""):lower():sub(1, 1) == "y" end

local function apply(p, chain, trim)
  local items = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do items[#items + 1] = reaper.GetSelectedMediaItem(0, i) end
  if #items == 0 and reaper.CountMediaItems(0) == 1 then items[1] = reaper.GetMediaItem(0, 0) end
  if trim and #items == 0 then
    MB("Select the recording item(s) to trim, or turn trimming off.", "Master songs", 0)
    return
  end

  local lines = {}
  reaper.Undo_BeginBlock()
  if trim then
    for _, item in ipairs(items) do
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        -- Absolute, not cumulative: the measurement ignores item volume, so a
        -- second run lands on the same value instead of trimming twice.
        local db = M.trim_db(M.measure_take(take))
        reaper.SetMediaItemInfo_Value(item, "D_VOL", 10 ^ (db / 20))
        lines[#lines + 1] = ("Item trimmed %+.1f dB so the chain sees %d LUFS"):format(db, M.TRIM_LUFS)
      end
    end
  end
  if chain then
    local ok_chain, why = M.apply_chain(p)
    lines[#lines + 1] = ok_chain and "Master chain: ReaComp 2:1 then ReaLimit" or ("Master chain failed: " .. why)
  end
  local changed = M.apply_render(p)
  lines[#lines + 1] = #changed == 0 and "Render settings already correct."
    or ("Render settings changed:\n  " .. table.concat(changed, "\n  "))
  reaper.Undo_EndBlock("Master songs", -1)

  MB(("%s -> %.0f LUFS-I, %.1f dBTP ceiling, %s\n\n%s\n\nRender the regions, then run this again in check mode.")
    :format(p.what, p.lufs, M.ceiling(p), p.fmt:upper(), table.concat(lines, "\n")), "Master songs", 0)
end

local function check(p)
  local _, rdir = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  local _, proj = reaper.EnumProjects(-1)
  local base = proj:match("^(.*)[/\\]") or "."
  if rdir == "" then rdir = "render" end
  if not rdir:match("^/") then rdir = base .. "/" .. rdir end

  local rows, bad = {}, 0
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(rdir, i)
    if not f then break end
    i = i + 1
    if f:lower():match("%.wav$") or f:lower():match("%.mp3$") then
      local lufs, tp = M.measure(rdir .. "/" .. f)
      if lufs then
        local good, why = M.verdict(p, lufs, tp)
        if not good then bad = bad + 1 end
        rows[#rows + 1] = ("%-40s %6.1f LUFS  %5.1f dBTP  %s"):format(f, lufs, tp, good and "ok" or ("FAIL: " .. why))
      end
    end
  end
  table.sort(rows)
  if #rows == 0 then
    MB("No rendered .wav or .mp3 files in\n" .. rdir, "Master songs", 0)
    return
  end
  local text = table.concat(rows, "\n")
  local fh = io.open(rdir .. "/ReapeZoom-masters.txt", "w")
  if fh then fh:write(text, "\n"); fh:close() end
  MB(("%d files against %s (%.0f LUFS-I, %.1f dBTP): %d failing\n\n%s")
    :format(#rows, p.what, p.lufs, p.tp, bad, text), "Master songs -- check", 0)
end

local function main()
  local vals = { get("mPreset", "mp3"), get("mChain", "y"), get("mTrim", "y"), get("mMode", "apply") }
  local csv
  if BATCH then
    csv = table.concat(vals, ",")
  else
    local got
    got, csv = reaper.GetUserInputs("Master songs", 4,
      "Preset (mp3/streaming/apple/archive),Add master chain (y/n),Trim item to chain level (y/n)," ..
      "Mode (apply/check),extrawidth=60", table.concat(vals, ","))
    if not got then return end
  end
  local f = {}
  for v in csv:gmatch("[^,]*") do f[#f + 1] = v:match("^%s*(.-)%s*$") end
  local p = M.PRESETS[(f[1] or ""):lower()]
  if not p then
    MB("Preset must be one of: " .. table.concat(M.ORDER, ", "), "Master songs", 0)
    return
  end
  for i, k in ipairs { "mPreset", "mChain", "mTrim", "mMode" } do reaper.SetExtState(EXT, k, f[i] or "", true) end
  if (f[4] or ""):lower():sub(1, 1) == "c" then check(p) else apply(p, yes(f[2]), yes(f[3])) end
end

main()
