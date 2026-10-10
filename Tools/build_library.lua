-- @noindex
-- The decision half of the offline library builder. Every choice here is made by
-- Scripts/lib -- this file only sequences them and writes the results out.
--
-- Called by Tools/build_library.py, which owns the audio. Reads:
--   <work>/hits.tsv   src \t time \t peak_db \t aligned_db \t <2049 magnitudes>
--   <work>/loops.tsv  src \t start \t end \t <onset times inside the span>
-- Writes:
--   <work>/manifest.tsv   src \t start \t stop-or-dash \t name \t kind
--   <out>/<kit>.sfz, .dspreset, .model  and <work>/report.lua
--
-- Run: lua Tools/build_library.lua <work-dir> <out-dir> <kit> <k>

local work, out, kit, K = ...
K = tonumber(K) or 4

local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".") .. "/../Scripts/lib/"
local function lib(name) return assert(loadfile(here .. name))() end
local C, E, L, P = lib("cluster.lua"), lib("envelope.lua"), lib("library.lua"), lib("preset.lua")

local FIRST_NOTE, OUTLIER_PCT, BINHZ = 36, 0.9, 48000 / 4096

-- k is a MUSICAL CONVENTION, not a statistical discovery. Silhouette scores fall
-- monotonically with k on both instruments recorded so far -- cajon 0.621/0.565/0.476
-- and boxstomp 0.571/0.549/0.484 for k=2/3/4 -- because struck-percussion timbre is a
-- continuum, not separated blobs. An "automatic" k would ship 2 articulations every
-- time. 4 suits a cajon (bass/tone/edge/slap); boxstomp's one-hit material is really
-- 2 sounds and -k 2 is what its own warnings ask for. Set it from the instrument.

----------------------------------------------------------------------
-- read what the audio half extracted
----------------------------------------------------------------------

local hits, loops = {}, {}
for line in io.lines(work .. "/hits.tsv") do
  local src, t, pk, apk, rest = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)$")
  local mags, i = {}, 0
  for v in rest:gmatch("%S+") do i = i + 1; mags[i] = tonumber(v) end
  local f = C.features(mags, BINHZ)
  hits[#hits + 1] = { src = src, t = tonumber(t), pk = tonumber(pk), apk = tonumber(apk),
                      point = C.feature_vector(f), centroid = f.centroid }
end
for line in io.lines(work .. "/loops.tsv") do
  local src, s, e, ons = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t?(.*)$")
  local t = {}
  for v in (ons or ""):gmatch("%S+") do t[#t + 1] = tonumber(v) end
  loops[#loops + 1] = { src = src, s = tonumber(s), e = tonumber(e), onsets = t }
end
assert(#hits >= K, "not enough hits to build " .. K .. " articulations")

local points = {}
for i, h in ipairs(hits) do points[i] = h.point end

----------------------------------------------------------------------
-- the cluster model: reuse a frozen one so a released note map never moves
----------------------------------------------------------------------

local model, frozen = nil, false
local fh = io.open(out .. "/" .. kit .. ".model", "r")
if fh then
  local text = fh:read("a"); fh:close()
  local decoded, err = C.model_decode(text)
  if decoded then
    model, frozen = decoded, true
    print(("model: reusing %s.model -- %d articulations, names and notes frozen"):format(kit, decoded.k))
  else
    -- A corrupt model must degrade to a rebuild, never take the run down with it.
    print(("model: %s.model unreadable (%s); rebuilding from scratch"):format(kit, tostring(err)))
  end
end

local labels, centroids, names
if frozen then
  labels = C.assign(C.normalize_with(points, model.stats), model.centroids)
  centroids, names = model.centroids, model.names
else
  local norm, stats = C.normalize(points)
  local inertia, seed
  labels, centroids, inertia, seed = C.kmeans_best(norm, K, 12)
  print(("kmeans_best: 12 restarts, seed %d, inertia %.1f"):format(seed, inertia))
  -- Re-index into rank order (darkest first) so cluster identity is stable across runs
  -- regardless of the order k-means happened to emit them in.
  local rank = C.order_clusters(centroids)
  local byrank = {}
  for c = 1, #centroids do byrank[rank[c]] = centroids[c] end
  for i = 1, #labels do labels[i] = rank[labels[i]] end
  centroids = byrank
  names = {}
  for r = 1, #centroids do names[r] = C.name_for(r, #centroids) end
  model = { seed = seed, k = #centroids, stats = stats, centroids = centroids,
            names = names, notes = {}, cut = 0 }
end

local _, distances = C.assign(C.normalize_with(points, model.stats), centroids)
if not frozen then model.cut = C.outlier_cut(distances, OUTLIER_PCT) end
local cut = model.cut

----------------------------------------------------------------------
-- loops, then ONE call to plan_notes -- the single source of note truth
----------------------------------------------------------------------

table.sort(loops, function(a, b) return (b.e - b.s) < (a.e - a.s) end)
local loopnames = {}
for i, lp in ipairs(loops) do
  lp.bpm = C.bpm(lp.onsets)
  lp.name = lp.bpm and ("Loop_%dbpm_%d"):format(math.floor(lp.bpm + 0.5), i)
    or ("Loop_%d"):format(i)
  loopnames[i] = lp.name
end

local plan, overflow = L.plan_notes(names, loopnames, FIRST_NOTE)
local note_of = {}
for _, p in ipairs(plan) do note_of[p.name] = p.note end
if frozen then
  -- Saved notes win for anything the model already knew about.
  for r, n in ipairs(model.notes) do note_of[names[r]] = n end
end
for r = 1, #names do model.notes[r] = note_of[names[r]] end
if #overflow > 0 then print("NOTE OVERFLOW (dropped): " .. table.concat(overflow, ", ")) end

----------------------------------------------------------------------
-- group the hits, parking outliers
----------------------------------------------------------------------

local groups, review = {}, {}
for r = 1, #names do groups[r] = { name = names[r], note = note_of[names[r]], hits = {} } end
for i, h in ipairs(hits) do
  h.rank, h.dist = labels[i], distances[i]
  if distances[i] > cut then
    review[#review + 1] = { name = names[h.rank], source = h.src, distance = distances[i] }
  else
    table.insert(groups[h.rank].hits, h)
  end
end

----------------------------------------------------------------------
-- velocity layers (count chosen per articulation), round robins, matrix
----------------------------------------------------------------------

local slugs = P.slugs(names)
local matrix, advice, manifest = {}, {}, {}
for r = 1, #names do
  local g = groups[r]
  table.sort(g.hits, function(x, y)
    if x.src ~= y.src then return x.src < y.src end
    return x.t < y.t
  end)
  -- Aligned peaks: each source's gain offset is already removed, so this axis is how
  -- hard the hit was struck rather than which take it came from.
  local dbs, vals = {}, {}
  for i, h in ipairs(g.hits) do dbs[i] = h.apk; vals[i] = 10 ^ (h.apk / 20) end
  local pick = L.choose_layers(dbs, E.assign_layers, {})
  local layer_of, layers = E.assign_layers(vals, pick.layers)
  local rr, samples, lyr = {}, {}, {}
  for i, h in ipairs(g.hits) do
    local l = layer_of[i]
    rr[l] = (rr[l] or 0) + 1
    local lo, hi = E.velocity_range(l, #layers)
    local base = ("%s_v%d_rr%d"):format(slugs[r], l, rr[l])
    samples[#samples + 1] = { file = "Samples/" .. base .. ".wav", lovel = lo, hivel = hi,
                              seq = rr[l], seqlen = 0, layer = l }
    manifest[#manifest + 1] = { src = h.src, t = h.t, name = base, kind = "hit" }
  end
  for _, s in ipairs(samples) do s.seqlen = rr[s.layer] end
  for li, ly in ipairs(layers) do lyr[li] = { lo = ly.lo, hi = ly.hi, count = rr[li] or 0 } end
  matrix[r] = { name = g.name, note = g.note, samples = samples, layers = lyr }
  advice[r] = { name = g.name, peaks_db = dbs }
  g.pick = pick
end

for _, lp in ipairs(loops) do
  matrix[#matrix + 1] = { name = lp.name, note = note_of[lp.name], layers = {},
    samples = { { file = "Samples/" .. lp.name .. ".wav",
                  lovel = 1, hivel = 127, seq = 1, seqlen = 1 } } }
  manifest[#manifest + 1] = { src = lp.src, t = lp.s, stop = lp.e, name = lp.name, kind = "loop" }
end

----------------------------------------------------------------------
-- write manifest, model, presets, and the report inputs
----------------------------------------------------------------------

local function put(path, s)
  local f = assert(io.open(path, "w")); f:write(s); f:close()
end

local mf = assert(io.open(work .. "/manifest.tsv", "w"))
for _, m in ipairs(manifest) do
  mf:write(("%s\t%.6f\t%s\t%s\t%s\n"):format(
    m.src, m.t, m.stop and ("%.6f"):format(m.stop) or "-", m.name, m.kind))
end
mf:close()

put(out .. "/" .. kit .. ".model", C.model_encode(model))
put(out .. "/" .. kit .. ".sfz", P.build_sfz(matrix, kit))
put(out .. "/" .. kit .. ".dspreset", P.build_dspreset(matrix, kit))

local warnings, gaps = L.layer_warnings(matrix, {}), L.gap_advice(advice, {})
local sources, seen = {}, {}
for _, h in ipairs(hits) do
  if not seen[h.src] then seen[h.src] = true; sources[#sources + 1] = h.src end
end

put(work .. "/report.lua", ("return %s"):format((function()
  local function ser(v)
    if type(v) == "number" then return ("%.10g"):format(v) end
    if type(v) == "string" then return ("%q"):format(v) end
    if type(v) == "boolean" then return tostring(v) end
    local o = { "{" }
    for k, x in pairs(v) do
      o[#o + 1] = (type(k) == "string" and ("[%q]="):format(k) or "") .. ser(x) .. ","
    end
    o[#o + 1] = "}"
    return table.concat(o)
  end
  return ser({ matrix = matrix, review = review, gaps = gaps, warnings = warnings,
               plan = plan, cut = cut, frozen = frozen, sources = sources })
end)()))

----------------------------------------------------------------------
-- what happened, on stdout, for the human watching
----------------------------------------------------------------------

print(("\nhits %d   loops %d   parked for review %d"):format(#hits, #loops, #review))
print("\nname     note  hits  layers  widest dB  min rr  layer choice")
local total = 0
for r = 1, #names do
  local m, pick = matrix[r], groups[r].pick
  local widest, minrr = 0, math.huge
  for _, ly in ipairs(m.layers) do
    widest = math.max(widest, ly.hi - ly.lo); minrr = math.min(minrr, ly.count)
  end
  total = total + #m.samples
  print(("%-8s %3d  %4d  %6d  %9.1f  %6d  %s"):format(m.name, m.note, #m.samples, #m.layers,
    widest, minrr == math.huge and 0 or minrr,
    pick.floor and ("rr floor %d"):format(pick.floor) or "best effort"))
end
if #loops > 0 then
  print("\nloops:")
  for _, lp in ipairs(loops) do
    print(("  %-18s note %3d  %6.2f s  %s"):format(lp.name, note_of[lp.name], lp.e - lp.s,
      lp.bpm and ("%.0f bpm"):format(lp.bpm) or "no confident tempo"))
  end
end
print("\nwarnings:")
if #warnings == 0 then print("  (none)") end
for _, w in ipairs(warnings) do print("  - " .. w) end
if #gaps > 0 then
  print("\nrecording gaps -- what to record next:")
  for _, g in ipairs(gaps) do print("  - " .. g) end
end
print(("\n%d hit samples + %d loops = %d to cut"):format(total, #loops, total + #loops))
