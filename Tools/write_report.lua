-- @noindex
-- Writes <out>/<kit>.md once the samples exist on disk, so the report can state
-- whether every one of them was actually found rather than assuming it.
-- Run: lua Tools/write_report.lua <work-dir> <out-dir> <kit> <library-gain-db> <aligns>

local work, out, kit, gain, aligns = ...

local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".") .. "/../Scripts/lib/"
local function lib(name) return assert(loadfile(here .. name))() end
local L = lib("library.lua")

local info = assert(loadfile(work .. "/report.lua"))()

local settings = {
  { name = "Articulations (k)", value = #info.plan > 0 and info.kit or "-" },
  { name = "Library gain", value = ("%s dB, one value for the whole kit"):format(gain) },
  { name = "Per-source alignment", value = aligns ~= "" and aligns or "none" },
  { name = "Output format", value = "24-bit 48 kHz stereo WAV" },
}
local n = 0
for _ in pairs(info.matrix) do n = n + 1 end
settings[1].value = ("%d groups incl. loops"):format(n)

local missing = L.verify_samples(info.matrix, function(path)
  local f = io.open(out .. "/" .. path, "r")
  if f then f:close(); return true end
  return false
end)

local text = L.report{
  kit = kit,
  settings = settings,
  plan = info.plan,
  matrix = info.matrix,
  gaps = info.gaps,
  review = info.review,
  warnings = info.warnings,
  missing = missing,
  model = { frozen = info.frozen, cut = info.cut, sources = info.sources },
}
local fh = assert(io.open(out .. "/" .. kit .. ".md", "w"))
fh:write(text)
fh:close()
local nsamples = 0
for _, g in ipairs(info.matrix) do nsamples = nsamples + #g.samples end
print(("  %s.md written, %d samples verified, %d missing"):format(kit, nsamples, #missing))
