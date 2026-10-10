-- @noindex
-- Pure timbre clustering and timing helpers for the ReapeZoom sampler workflow.
-- Runs standalone under `lua cluster.lua` to exercise the deterministic logic.

local M = {}

----------------------------------------------------------------------
-- spectral features -- level never enters the feature vector
----------------------------------------------------------------------

function M.features(mags, binhz)
  local total, weighted = 0, 0
  local bands = { lo = 0, mid = 0, hi = 0, air = 0 }
  for i, mag in ipairs(mags) do
    local hz = (i - 1) * binhz
    total = total + mag
    weighted = weighted + mag * hz
    if hz < 300 then
      bands.lo = bands.lo + mag
    elseif hz < 1500 then
      bands.mid = bands.mid + mag
    elseif hz <= 5000 then
      bands.hi = bands.hi + mag
    else
      bands.air = bands.air + mag
    end
  end
  if total == 0 then return { centroid = 0, lo = 0, mid = 0, hi = 0, air = 0 } end
  return {
    centroid = weighted / total,
    lo = bands.lo / total,
    mid = bands.mid / total,
    hi = bands.hi / total,
    air = bands.air / total,
  }
end

function M.feature_vector(f)
  return { math.log(f.centroid + 1, 10), f.lo, f.mid, f.hi, f.air }
end

function M.normalize(points)
  if #points == 0 then return {}, { means = {}, sds = {} } end
  local dims, means, sds = #points[1], {}, {}
  for d = 1, dims do
    local sum = 0
    for i = 1, #points do sum = sum + points[i][d] end
    means[d] = sum / #points
  end
  for d = 1, dims do
    local sum = 0
    for i = 1, #points do
      local delta = points[i][d] - means[d]
      sum = sum + delta * delta
    end
    sds[d] = math.sqrt(sum / #points)
  end

  local out = {}
  for i, point in ipairs(points) do
    out[i] = {}
    for d = 1, dims do
      out[i][d] = sds[d] == 0 and 0 or (point[d] - means[d]) / sds[d]
    end
  end
  return out, { means = means, sds = sds }
end

function M.normalize_with(points, stats)
  local out = {}
  for i, point in ipairs(points) do
    out[i] = {}
    for d = 1, #point do
      out[i][d] = stats.sds[d] == 0 and 0 or (point[d] - stats.means[d]) / stats.sds[d]
    end
  end
  return out
end

----------------------------------------------------------------------
-- clustering -- deterministic so repeated exports keep their layout
----------------------------------------------------------------------

local function copy_vector(v)
  local out = {}
  for i = 1, #v do out[i] = v[i] end
  return out
end

local function distance2(a, b)
  local sum = 0
  for i = 1, #a do
    local delta = a[i] - b[i]
    sum = sum + delta * delta
  end
  return sum
end

local function nearest(point, centroids)
  local best, best_distance = 1, distance2(point, centroids[1])
  for c = 2, #centroids do
    local d = distance2(point, centroids[c])
    if d < best_distance then best, best_distance = c, d end
  end
  return best, best_distance
end

function M.assign(points, centroids)
  local labels, distances = {}, {}
  for i, point in ipairs(points) do
    local label, squared = nearest(point, centroids)
    labels[i], distances[i] = label, math.sqrt(squared)
  end
  return labels, distances
end

local function lcg(seed)
  local modulus = 2147483647
  local state = math.floor(seed or 1) % modulus
  if state == 0 then state = 1 end
  return function()
    state = state * 48271 % modulus
    return state / modulus
  end
end

function M.kmeans(points, k, seed)
  local n = #points
  if n == 0 then return {}, {}, 0 end
  k = math.min(math.max(1, math.floor(k)), n)
  local random = lcg(seed)
  local centroids = { copy_vector(points[math.floor(random() * n) + 1]) }

  -- k-means++ keeps the small batch implementation stable without retries.
  for _ = 2, k do
    local weights, total = {}, 0
    for i, point in ipairs(points) do
      local nearest = distance2(point, centroids[1])
      for c = 2, #centroids do nearest = math.min(nearest, distance2(point, centroids[c])) end
      weights[i] = nearest
      total = total + nearest
    end
    local chosen
    if total == 0 then
      chosen = math.floor(random() * n) + 1
    else
      local target, cumulative = random() * total, 0
      for i = 1, n do
        cumulative = cumulative + weights[i]
        if cumulative >= target then chosen = i; break end
      end
      chosen = chosen or n
    end
    centroids[#centroids + 1] = copy_vector(points[chosen])
  end

  local labels = {}
  -- ponytail: O(80*n*k) batch k-means; use a spatial index only if hit sets
  -- grow beyond ordinary recording sessions.
  for _ = 1, 80 do
    local changed = false
    for i, point in ipairs(points) do
      local best, best_distance = 1, distance2(point, centroids[1])
      for c = 2, k do
        local d = distance2(point, centroids[c])
        if d < best_distance then best, best_distance = c, d end
      end
      if labels[i] ~= best then labels[i], changed = best, true end
    end
    if not changed then break end

    local sums, counts = {}, {}
    for c = 1, k do
      sums[c], counts[c] = {}, 0
      for d = 1, #points[1] do sums[c][d] = 0 end
    end
    for i, point in ipairs(points) do
      local c = labels[i]
      counts[c] = counts[c] + 1
      for d = 1, #point do sums[c][d] = sums[c][d] + point[d] end
    end
    for c = 1, k do
      if counts[c] > 0 then
        for d = 1, #sums[c] do sums[c][d] = sums[c][d] / counts[c] end
        centroids[c] = sums[c]
      end -- empty clusters keep the previous centroid
    end
  end

  local inertia = 0
  for i, point in ipairs(points) do inertia = inertia + distance2(point, centroids[labels[i]]) end
  return labels, centroids, inertia
end

function M.kmeans_best(points, k, seeds)
  local best_labels, best_centroids, best_inertia, best_seed
  for seed = 1, seeds or 12 do
    local labels, centroids, inertia = M.kmeans(points, k, seed)
    if not best_inertia or inertia < best_inertia then
      best_labels, best_centroids, best_inertia, best_seed = labels, centroids, inertia, seed
    end
  end
  return best_labels, best_centroids, best_inertia, best_seed
end

function M.suggest_k(points, kmin, kmax, seed)
  local rows = {}
  for k = kmin, kmax do
    local labels, centroids, inertia = M.kmeans(points, k, seed)
    local sizes = {}
    for c = 1, #centroids do sizes[c] = 0 end
    for _, c in ipairs(labels) do sizes[c] = sizes[c] + 1 end
    rows[#rows + 1] = { k = k, inertia = inertia, sizes = sizes }
  end
  return rows
end

function M.order_clusters(centroids)
  local order, rank_of = {}, {}
  for i = 1, #centroids do order[i] = i end
  table.sort(order, function(a, b)
    if centroids[a][1] == centroids[b][1] then return a < b end
    return centroids[a][1] < centroids[b][1]
  end)
  for rank, cluster in ipairs(order) do rank_of[cluster] = rank end
  return rank_of
end

function M.name_for(rank, n)
  local names = { "Bass", "Tone", "Edge", "Slap", "Tip" }
  return names[rank] or ("Sound %d"):format(rank)
end

----------------------------------------------------------------------
-- frozen cluster models
----------------------------------------------------------------------

local function number_text(value)
  return ("%.17g"):format(value)
end

local function encoded_text(value)
  return (value:gsub("[%c%%]", function(char) return ("%%%02X"):format(char:byte()) end))
end

local function vector_line(name, values)
  local fields = { name, tostring(#values) }
  for _, value in ipairs(values) do fields[#fields + 1] = number_text(value) end
  return table.concat(fields, "\t")
end

function M.model_encode(model)
  local lines = {
    "ReapeZoom cluster model\t1",
    "seed\t" .. number_text(model.seed),
    "k\t" .. number_text(model.k),
    vector_line("means", model.stats.means),
    vector_line("sds", model.stats.sds),
    "centroids\t" .. #model.centroids,
  }
  for _, centroid in ipairs(model.centroids) do
    lines[#lines + 1] = vector_line("centroid", centroid)
  end
  lines[#lines + 1] = "names\t" .. #model.names
  for _, name in ipairs(model.names) do lines[#lines + 1] = "name\t" .. encoded_text(name) end
  lines[#lines + 1] = "notes\t" .. #model.notes
  for _, note in ipairs(model.notes) do lines[#lines + 1] = "note\t" .. number_text(note) end
  lines[#lines + 1] = "cut\t" .. number_text(model.cut)
  lines[#lines + 1] = "end"
  return table.concat(lines, "\n") .. "\n"
end

local function parse_model(text)
  if type(text) ~= "string" then error("model text must be a string", 0) end
  text = text:gsub("\r\n", "\n")
  if text:find("\r", 1, true) then error("invalid line ending", 0) end
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end

  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if lines[1] ~= "ReapeZoom cluster model\t1" then error("invalid model header", 0) end

  local index = 2
  local function take(name)
    local line = lines[index]
    if not line then error("truncated model: expected " .. name, 0) end
    index = index + 1
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    if fields[1] ~= name then error("malformed model: expected " .. name, 0) end
    return fields
  end
  local function finite(value, name)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
      error("invalid number in " .. name, 0)
    end
    return number
  end
  local function count(fields, name)
    if #fields ~= 2 then error("malformed " .. name .. " line", 0) end
    local value = finite(fields[2], name)
    if value < 0 or value % 1 ~= 0 then error("invalid count in " .. name, 0) end
    return value
  end
  local function scalar(name)
    local fields = take(name)
    if #fields ~= 2 then error("malformed " .. name .. " line", 0) end
    return finite(fields[2], name)
  end
  local function vector(name, expected)
    local fields = take(name)
    local size = finite(fields[2], name)
    if size < 0 or size % 1 ~= 0 or #fields ~= size + 2 or expected and size ~= expected then
      error("invalid vector in " .. name, 0)
    end
    local values = {}
    for i = 1, size do values[i] = finite(fields[i + 2], name) end
    return values
  end
  local function decoded(value)
    if value:find("%c") then error("unescaped control character in name", 0) end
    local position = 1
    while true do
      local percent = value:find("%", position, true)
      if not percent then break end
      if not value:sub(percent + 1, percent + 2):match("^%x%x$") then error("invalid name escape", 0) end
      position = percent + 3
    end
    return (value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
  end

  local seed, k = scalar("seed"), scalar("k")
  if k < 1 or k % 1 ~= 0 then error("invalid k", 0) end
  local means = vector("means")
  local sds = vector("sds", #means)
  for _, sd in ipairs(sds) do if sd < 0 then error("invalid sd", 0) end end

  local centroid_count = count(take("centroids"), "centroids")
  if centroid_count ~= k then error("centroid count does not match k", 0) end
  local centroids = {}
  for i = 1, centroid_count do centroids[i] = vector("centroid", #means) end

  local name_count = count(take("names"), "names")
  if name_count ~= k then error("name count does not match k", 0) end
  local names = {}
  for i = 1, name_count do
    local fields = take("name")
    if #fields ~= 2 then error("malformed name line", 0) end
    names[i] = decoded(fields[2])
  end

  local note_count = count(take("notes"), "notes")
  if note_count ~= k then error("note count does not match k", 0) end
  local notes = {}
  for i = 1, note_count do notes[i] = scalar("note") end
  local cut = scalar("cut")
  if cut < 0 then error("invalid cut", 0) end
  if #take("end") ~= 1 or index <= #lines then error("trailing model data", 0) end

  return {
    seed = seed, k = k, stats = { means = means, sds = sds }, centroids = centroids,
    names = names, notes = notes, cut = cut,
  }
end

function M.model_decode(text)
  local ok, model = pcall(parse_model, text)
  if ok then return model end
  return nil, tostring(model)
end

----------------------------------------------------------------------
-- timing -- optional pass and tempo evidence, never timbre evidence
----------------------------------------------------------------------

function M.time_blocks(times, gap)
  if #times == 0 then return {} end
  local out, first = {}, 1
  for i = 2, #times do
    if times[i] - times[i - 1] > gap then
      out[#out + 1] = {
        s = times[first], e = times[i - 1], n = i - first, first = first, last = i - 1,
      }
      first = i
    end
  end
  out[#out + 1] = {
    s = times[first], e = times[#times], n = #times - first + 1, first = first, last = #times,
  }
  return out
end

function M.hand_split(times, opts)
  opts = opts or {}
  -- Measured on 260812-154609.WAV: 3 s matched raw-hit spacing, but
  -- alternating sounds put same-cluster hits 3-8 s apart; 8-12 s found passes.
  local blocks = M.time_blocks(times, opts.gap or 10.0)
  local keep = {}
  for _, block in ipairs(blocks) do
    if block.n >= (opts.minHits or 5) then keep[#keep + 1] = block end
  end
  if #keep ~= 2 or keep[1].n + keep[2].n < (opts.frac or 0.7) * #times then return nil end

  -- ponytail: gap-only pass detection; add sequence modelling only if real
  -- sessions regularly interleave hands inside one pass.
  local a, b = {}, {}
  for i = keep[1].first, keep[1].last do a[#a + 1] = i end
  for i = keep[2].first, keep[2].last do b[#b + 1] = i end
  return a, b
end

-- Preview gap choices before committing; hand_split remains the decision path
-- so the preview cannot disagree with the split that will actually be applied.
function M.hand_sweep(times, gaps, opts)
  opts = opts or {}
  local rows = {}
  for _, gap in ipairs(gaps) do
    local blocks = M.time_blocks(times, gap)
    local big, covered = 0, 0
    for _, block in ipairs(blocks) do
      if block.n >= (opts.minHits or 5) then
        big, covered = big + 1, covered + block.n
      end
    end
    local split = M.hand_split(times, { gap = gap, minHits = opts.minHits, frac = opts.frac })
    rows[#rows + 1] = {
      gap = gap, blocks = #blocks, big = big,
      cover = #times == 0 and 0 or covered / #times,
      split = split ~= nil,
    }
  end
  return rows
end

local function percentile(sorted, fraction)
  local position = 1 + (#sorted - 1) * fraction
  local lower = math.floor(position)
  local upper = math.ceil(position)
  if lower == upper then return sorted[lower] end
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower)
end

function M.outlier_cut(distances, fraction)
  if #distances == 0 then return nil end
  local sorted = copy_vector(distances)
  table.sort(sorted)
  return percentile(sorted, fraction)
end

function M.bpm(onsets)
  if #onsets < 4 then return nil end
  local intervals = {}
  for i = 2, #onsets do intervals[#intervals + 1] = onsets[i] - onsets[i - 1] end
  table.sort(intervals)
  local median = percentile(intervals, 0.5)
  if median <= 0 then return nil end
  local confidence = math.max(0, math.min(1,
    1 - (percentile(intervals, 0.75) - percentile(intervals, 0.25)) / median))
  if confidence < 0.5 then return nil end

  local bpm = 60 / median
  while bpm < 60 do bpm = bpm * 2 end
  while bpm > 200 do bpm = bpm / 2 end
  return bpm, confidence
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  -- 1. Three planted timbres must remain three articulations.
  local planted = {
    { -10, -10 }, { -10, -9 }, { -9, -10 },
    { 0, 0 }, { 0, 1 }, { 1, 0 },
    { 10, 10 }, { 10, 11 }, { 11, 10 },
  }
  local labels, planted_centroids = M.kmeans(planted, 3, 123)
  assert(labels[1] == labels[2] and labels[2] == labels[3]
      and labels[4] == labels[5] and labels[5] == labels[6]
      and labels[7] == labels[8] and labels[8] == labels[9]
      and labels[1] ~= labels[4] and labels[1] ~= labels[7] and labels[4] ~= labels[7],
    "kmeans must recover planted groups: merged timbres would collapse sampler articulations")
  -- If this line ever needs updating, every already-exported library re-clusters;
  -- changing it is a deliberate decision, not a test fix.
  local frozen_labels = { 1, 1, 1, 3, 3, 3, 2, 2, 2 }
  for i = 1, #labels do
    assert(labels[i] == frozen_labels[i],
      "kmeans labels must match the frozen seed layout: renumbering would reshuffle every already-exported library")
  end
  local assigned = M.assign(planted, planted_centroids)
  for i = 1, #labels do
    assert(assigned[i] == labels[i],
      "assign must match kmeans labels: added hits would otherwise join the wrong released articulation")
  end
  local fixed_centroids = { { 0, 0 }, { 10, 10 } }
  local _, known_distances = M.assign({ { 3, 4 } }, fixed_centroids)
  assert(known_distances[1] == 5,
    "assign distances must be Euclidean: squared distances would corrupt the frozen outlier threshold")
  assert(fixed_centroids[1][1] == 0 and fixed_centroids[1][2] == 0,
    "assign must not move centroids: fitting new hits would silently remap a released instrument")
  local _, empty_centroids, empty_inertia = M.kmeans({ { 1 }, { 1 }, { 1 } }, 3, 123)
  for _, centroid in ipairs(empty_centroids) do
    for _, v in ipairs(centroid) do
      assert(v == v,
        "empty clusters must stay finite: NaN would poison inertia and the k = 2..6 preview table the user reads to choose k")
    end
  end
  assert(empty_inertia == empty_inertia,
    "empty clusters must stay finite: NaN would poison inertia and the k = 2..6 preview table the user reads to choose k")
  local refined = M.kmeans({ { 0 }, { 1 }, { 2 }, { 10 }, { 13 }, { 20 } }, 2, 123)
  assert(refined[1] == refined[2] and refined[2] == refined[3]
      and refined[4] == refined[5] and refined[5] == refined[6]
      and refined[1] ~= refined[4],
    "kmeans must refine centroids after the first assignment: stopping early would put borderline hits in the wrong articulation")

  -- 2. A seed must freeze the matrix layout across exports.
  local again_a = M.kmeans(planted, 3, 456)
  local again_b = M.kmeans(planted, 3, 456)
  for i = 1, #again_a do
    assert(again_a[i] == again_b[i],
      "kmeans must repeat labels for one seed: reshuffling would change an existing library")
  end

  local local_minimum = {}
  for _, center in ipairs { 0, 5, 20, 40 } do
    for i = 1, 10 do local_minimum[#local_minimum + 1] = { center + (i % 3 - 1) * 0.2 } end
  end
  local_minimum[#local_minimum + 1] = { 50 }
  local worst_inertia, bad_seed, bad_min = -math.huge
  for seed = 1, 12 do
    local seed_labels, _, seed_inertia = M.kmeans(local_minimum, 4, seed)
    local sizes = { 0, 0, 0, 0 }
    for _, label in ipairs(seed_labels) do sizes[label] = sizes[label] + 1 end
    if seed_inertia > worst_inertia then
      worst_inertia, bad_seed, bad_min = seed_inertia, seed, math.min(table.unpack(sizes))
    end
  end
  local best_labels, _, best_inertia, best_seed = M.kmeans_best(local_minimum, 4)
  local best_sizes = { 0, 0, 0, 0 }
  for _, label in ipairs(best_labels) do best_sizes[label] = best_sizes[label] + 1 end
  assert(bad_seed and bad_min == 1 and best_inertia < worst_inertia,
    "kmeans_best must beat a verified bad local minimum: one outlier would otherwise erase a real articulation")
  assert(math.min(table.unpack(best_sizes)) >= 2,
    "kmeans_best must avoid a singleton cluster when a lower-inertia partition exists")
  local repeated_labels, _, _, repeated_seed = M.kmeans_best(local_minimum, 4)
  local replayed_labels = M.kmeans(local_minimum, 4, best_seed)
  for i = 1, #best_labels do
    assert(repeated_seed == best_seed and repeated_labels[i] == best_labels[i],
      "kmeans_best must return identical labels and seed for identical input")
    assert(replayed_labels[i] == best_labels[i],
      "kmeans_best's returned seed must reproduce its labels for a meaningful saved model")
  end

  -- 3. Scaling the whole spectrum must never leak velocity into articulation.
  local spectrum = { 1, 2, 4, 8, 4, 2, 1, 0.5 }
  local vectors = {}
  for _, scale in ipairs { 1, 0.1, 10 } do
    local scaled = {}
    for i, mag in ipairs(spectrum) do scaled[i] = mag * scale end
    vectors[#vectors + 1] = M.feature_vector(M.features(scaled, 1000))
  end
  for d = 1, #vectors[1] do
    assert(math.abs(vectors[1][d] - vectors[2][d]) <= 1e-9
        and math.abs(vectors[1][d] - vectors[3][d]) <= 1e-9,
      "features must be level-invariant: loudness leaking in would split one articulation by velocity")
  end
  local normalize_points = { { 1, 0 }, { 2, 0 }, { 3, 0 } }
  local normalized, stats = M.normalize(normalize_points)
  assert(normalized[1][1] == -math.sqrt(1.5) and normalized[2][1] == 0
      and normalized[3][1] == math.sqrt(1.5),
    "normalize must preserve its original values: changing them would re-cluster every existing library")
  local normalized_again = M.normalize_with(normalize_points, stats)
  for _, point in ipairs(normalized) do
    for _, v in ipairs(point) do
      assert(v == v,
        "normalized features must stay finite: one constant band would make every cluster distance meaningless")
    end
    assert(point[2] == 0,
      "constant normalized features must be zero: a dark kit's empty air band would distort every articulation")
  end
  for i, point in ipairs(normalized) do
    for d, value in ipairs(point) do
      assert(normalized_again[i][d] == value,
        "normalize_with must reproduce normalize exactly: added material would otherwise re-scale an existing library")
    end
  end
  local constant = M.normalize_with({ { 99 } }, { means = { 1 }, sds = { 0 } })
  assert(constant[1][1] == 0 and constant[1][1] == constant[1][1],
    "normalize_with constant dimensions must be zero: NaN would make frozen-model assignment meaningless")

  -- 4. Band ratios must be complete, and silence must stay finite.
  local f = M.features(spectrum, 1000)
  assert(math.abs(f.lo + f.mid + f.hi + f.air - 1) <= 1e-12,
    "feature bands must sum to one: missing spectral energy would bias cluster distances")
  local silent = M.features({ 0, 0, 0 }, 1000)
  for _, v in pairs(silent) do
    assert(v == v,
      "silent features must not be NaN: one empty spectrum would poison every centroid")
  end

  -- 5. Naming follows darkness, not k-means' arbitrary emission order.
  local ranks = M.order_clusters { { 3 }, { 2 }, { 1 } }
  assert(ranks[3] == 1 and ranks[2] == 2 and ranks[1] == 3,
    "cluster order must put darkest first: unstable names would mislabel sampler notes")

  local model = {
    seed = 123, k = 2,
    stats = { means = { 1.25, -2 }, sds = { 0.5, 3.25 } },
    centroids = { { -1, 0.25 }, { 2.5, 4 } },
    names = { "Bass", "Tone%\tGhost" }, notes = { 36, 37 }, cut = 1.06,
  }
  local encoded = M.model_encode(model)
  assert(encoded == M.model_encode(model),
    "model encoding must be stable: identical library exports would otherwise produce spurious diffs")
  local decoded, decode_error = M.model_decode(encoded)
  assert(decoded and not decode_error and decoded.seed == model.seed and decoded.k == model.k
      and decoded.cut == model.cut,
    "model scalars must round-trip: a changed seed, k, or cut would remap a released instrument")
  for d = 1, #model.stats.means do
    assert(decoded.stats.means[d] == model.stats.means[d]
        and decoded.stats.sds[d] == model.stats.sds[d],
      "model normalization stats must round-trip: changed scaling would remap every added hit")
  end
  for c = 1, #model.centroids do
    for d = 1, #model.centroids[c] do
      assert(decoded.centroids[c][d] == model.centroids[c][d],
        "model centroids must round-trip: moved centroids would change released articulation assignments")
    end
    assert(decoded.names[c] == model.names[c] and decoded.notes[c] == model.notes[c],
      "model names and notes must round-trip: released sampler mappings would otherwise change")
  end

  local garbage, garbage_error = M.model_decode("garbage")
  assert(garbage == nil and type(garbage_error) == "string",
    "model garbage must fail safely: a corrupt model must trigger a rebuild instead of crashing mid-edit")
  local truncated, truncated_error = M.model_decode((encoded:gsub("end\n$", "")))
  assert(truncated == nil and type(truncated_error) == "string",
    "truncated models must fail safely: a half-loaded model would silently remap a released instrument")
  local invalid, invalid_error = M.model_decode((encoded:gsub("cut\t[^\n]+", "cut\t1e9999", 1)))
  assert(invalid == nil and type(invalid_error) == "string",
    "invalid model numbers must fail safely: infinity would poison every frozen-model distance")

  -- 6. Only gaps larger than the threshold make pass boundaries.
  local block_times = { 1, 2, 3, 40, 41, 42 }
  assert(#M.time_blocks(block_times, 3) == 2,
    "time blocks must split long rests: separate passes would be mixed together")
  assert(#M.time_blocks(block_times, 50) == 1,
    "time blocks must respect the gap: one pass would be fragmented into false hands")

  -- 7. Hand splitting needs two dominant blocks, not merely any ten hits.
  local hand_times = { 1, 2, 3, 4, 5, 40, 41, 42, 43, 44 }
  local hand_a, hand_b = M.hand_split(hand_times, {})
  assert(hand_a and hand_b and #hand_a == 5 and #hand_b == 5
      and hand_a[1] == 1 and hand_b[1] == 6,
    "hand split must return two real passes: same-articulation hands would remain mixed")
  local stray_times = { 1, 2, 3, 4, 5, 40, 41, 42, 43, 44, 100 }
  local stray_a, stray_b = M.hand_split(stray_times, {})
  local stray_kept = false
  for _, pass in ipairs { stray_a or {}, stray_b or {} } do
    for _, index in ipairs(pass) do stray_kept = stray_kept or index == 11 end
  end
  assert(stray_a and stray_b and #stray_a == 5 and #stray_b == 5 and not stray_kept,
    "hand split must ignore isolated hits: a stray hit must not veto hand detection")
  local spread = { 0, 4, 8, 12, 16, 20, 24, 28, 32, 36 }
  assert(M.hand_split(spread, {}) == nil,
    "hand split must reject evenly spread hits: an always-on splitter would invent hands")
  local three_blocks = { 1, 2, 3, 4, 5, 40, 41, 42, 43, 44, 80, 81, 82, 83, 84 }
  assert(M.hand_split(three_blocks, {}) == nil
      and M.hand_split(three_blocks, { frac = 0.65 }) == nil,
    "hand split must reject three passes: taking the first two would invent a hand split")
  local sparse_blocks = { 0, 10, 11, 12, 13, 14, 20, 24, 30, 31, 32, 33, 34, 40, 44 }
  assert(M.hand_split(sparse_blocks, {}) == nil,
    "hand split must reject minority blocks: scattered majority hits would be assigned false hands")

  local alternating_times = { 0, 1, 2, 3, 4, 9, 10, 11, 12, 13 }
  assert(M.hand_split(alternating_times, {}) == nil,
    "hand split default gap must be 10 s: alternating sounds put same-cluster hits about 5 s apart")
  assert(M.hand_split(alternating_times, { gap = 4 }),
    "hand split must honor an explicit 4 s gap: two passes 5 s apart should split")

  local sweep_times = { 0, 6, 7, 8, 9, 10, 20, 30, 31, 32, 33, 34, 40, 46, 52 }
  local sweep_expected = {
    { gap = 10, blocks = 1, big = 1, cover = 1 },
    { gap = 4, blocks = 7, big = 2, cover = 10 / 15 },
    { gap = 6, blocks = 3, big = 2, cover = 14 / 15 },
  }
  local sweep = M.hand_sweep(sweep_times, { 10, 4, 6 }, {})
  for i, expected in ipairs(sweep_expected) do
    local row = sweep[i]
    assert(row and row.gap == expected.gap and row.blocks == expected.blocks
        and row.big == expected.big and math.abs(row.cover - expected.cover) <= 1e-12,
      ("hand sweep stats are wrong at gap %g"):format(expected.gap))
    local direct = M.hand_split(sweep_times, { gap = row.gap }) ~= nil
    assert(row.split == direct,
      ("hand sweep says split=%s at gap %g, hand_split says %s")
        :format(tostring(row.split), row.gap, tostring(direct)))
  end

  -- 8. Tempo is emitted only when the onset evidence is tight.
  local tempo = M.bpm { 0, 0.5, 1, 1.5, 2, 2.5, 3 }
  assert(tempo and math.abs(tempo - 120) < 1,
    "bpm must recover a clean 120 train: reliable tempo metadata would be lost")
  local folded_down = M.bpm { 0, 0.125, 0.25, 0.375, 0.5 }
  local folded_up = M.bpm { 0, 1.5, 3, 4.5, 6 }
  assert(folded_down >= 60 and folded_down <= 200 and math.abs(folded_down - 120) < 1
      and folded_up >= 60 and folded_up <= 200 and math.abs(folded_up - 80) < 1,
    "bpm must fold into 60..200: an unfolded tempo would be written into a loop filename as Loop_480bpm and be wrong for anyone who reads it")
  local jitter, t = { 0 }, 0
  for _, interval in ipairs { 0.1, 1.2, 0.15, 1.0, 0.12, 0.9 } do
    t = t + interval
    jitter[#jitter + 1] = t
  end
  assert(M.bpm(jitter) == nil,
    "bpm must reject heavy jitter: a confident wrong tempo would be baked into filenames")
  assert(math.abs(M.outlier_cut({ 10, 0 }, 0.9) - 9) <= 1e-12,
    "outlier_cut must use the shared interpolated percentile: a shifted cut would misjudge later material")

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
