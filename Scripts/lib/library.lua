-- @noindex
-- Pure planning, checking, audition, and report helpers for sample libraries.
-- Runs standalone under `lua library.lua` to exercise the deterministic logic.

local M = {}

----------------------------------------------------------------------
-- MIDI plan -- hits stay compact; loops start on an octave boundary
----------------------------------------------------------------------

function M.plan_notes(articulations, loops, first_note)
  local plan, overflow = {}, {}
  local function add(names, start_note, kind)
    for i, name in ipairs(names) do
      local note = start_note + i - 1
      if note >= 0 and note <= 127 and note % 1 == 0 then
        plan[#plan + 1] = { name = name, note = note, kind = kind }
      else
        overflow[#overflow + 1] = name
      end
    end
  end

  add(articulations, first_note, "hit")
  local first_loop = math.ceil((first_note + #articulations) / 12) * 12
  add(loops, first_loop, "loop")
  return plan, overflow
end

----------------------------------------------------------------------
-- quality gates -- warnings describe decisions before anything is shared
----------------------------------------------------------------------

local function layer_stats(peaks_db, n, assign_layers)
  local values = {}
  -- choose_layers receives dB, but envelope.assign_layers expects linear amplitudes.
  for i, db in ipairs(peaks_db) do values[i] = 10 ^ (db / 20) end
  local _, layers = assign_layers(values, n)
  local widest, min_rr = 0, math.huge
  for _, layer in ipairs(layers) do
    widest = math.max(widest, layer.hi - layer.lo)
    min_rr = math.min(min_rr, layer.count)
  end
  return widest, min_rr == math.huge and 0 or min_rr
end

function M.choose_layers(peaks_db, assign_layers, opts)
  opts = opts or {}
  local max_layers = math.min(math.floor(opts.maxLayers or 12), #peaks_db)
  local wide_db, floors = opts.wideDb or 9, opts.floors or { 5, 4, 3, 2 }
  for _, floor in ipairs(floors) do
    for n = max_layers, 2, -1 do
      local widest, min_rr = layer_stats(peaks_db, n, assign_layers)
      if widest <= wide_db and min_rr >= floor then
        return { layers = n, widest = widest, minRr = min_rr, floor = floor }
      end
    end
  end
  local widest, min_rr = layer_stats(peaks_db, 2, assign_layers)
  return { layers = 2, widest = widest, minRr = min_rr, floor = nil }
end

function M.layer_warnings(matrix, opts)
  opts = opts or {}
  local wide_db, min_rr = opts.wideDb or 9, opts.minRr or 2
  local warnings = {}
  for _, group in ipairs(matrix) do
    local layers = group.layers or {}
    for i, layer in ipairs(layers) do
      local spread = layer.hi - layer.lo
      if spread > wide_db then
        warnings[#warnings + 1] =
          ("%s layer %d spans %.1f dB; round robins should sound alike while velocity layers should differ, so this layer's round robins do not match -- add more layers")
          :format(group.name, i, spread)
      end
      if layer.count < min_rr then
        warnings[#warnings + 1] =
          ("%s layer %d has %d round robins; need at least %d to avoid machine-gun repeats")
          :format(group.name, i, layer.count, min_rr)
      end
    end
    if #(group.samples or {}) < #layers then
      warnings[#warnings + 1] =
        ("%s has %d hits for %d layers; every layer needs at least one hit")
        :format(group.name, #(group.samples or {}), #layers)
    end
  end
  return warnings
end

function M.dynamic_gaps(peaks_db, count)
  local sorted, gaps, out = {}, {}, {}
  for i, peak in ipairs(peaks_db) do sorted[i] = peak end
  table.sort(sorted)
  for i = 2, #sorted do
    gaps[#gaps + 1] = {
      gap = sorted[i] - sorted[i - 1], from = sorted[i - 1], to = sorted[i],
    }
  end
  table.sort(gaps, function(a, b)
    return a.gap == b.gap and a.from < b.from or a.gap > b.gap
  end)
  for i = 1, math.min(count, #gaps) do out[i] = gaps[i] end
  return out
end

function M.gap_advice(groups, opts)
  opts = opts or {}
  local min_gap = opts.minGap
  if min_gap == nil then min_gap = 6 end
  local advice = {}
  for _, group in ipairs(groups) do
    local gap = M.dynamic_gaps(group.peaks_db, 1)[1]
    if gap and gap.gap > min_gap then
      advice[#advice + 1] =
        ("%s has a %.1f dB dynamic gap between %.1f dB and %.1f dB; more layers will not close it -- hits recorded at that force will.")
        :format(group.name, gap.gap, gap.from, gap.to)
    end
  end
  return advice
end

function M.verify_samples(matrix, exists)
  local missing, seen = {}, {}
  for _, group in ipairs(matrix) do
    for _, sample in ipairs(group.samples) do
      local file = sample.file
      if not seen[file] then
        seen[file] = true
        if not exists(file) then missing[#missing + 1] = file end
      end
    end
  end
  return missing
end

----------------------------------------------------------------------
-- audition -- one event per existing matrix sample, in matrix order
----------------------------------------------------------------------

function M.audition_notes(matrix, step)
  local out, pos = {}, 0
  for _, group in ipairs(matrix) do
    for _, sample in ipairs(group.samples) do
      out[#out + 1] = {
        note = group.note,
        vel = math.floor((sample.lovel + sample.hivel) / 2),
        pos = pos,
      }
      pos = pos + step
    end
  end
  return out
end

----------------------------------------------------------------------
-- report -- the shareable library's decision and verification record
----------------------------------------------------------------------

local function display(value)
  return value == nil and "-" or tostring(value)
end

function M.report(info)
  -- ponytail: assemble plain Markdown directly; add a renderer only if a second
  -- report format is ever required.
  local out = { ("# %s Library Report"):format(info.kit) }
  local source = info.source

  out[#out + 1] = ""
  out[#out + 1] = "## Source"
  if source then
    out[#out + 1] = ""
    out[#out + 1] = "| Field | Value |"
    out[#out + 1] = "|---|---|"
    local fields = {
      { "Name", source.name }, { "Duration (s)", source.dur },
      { "Sample rate (Hz)", source.srate }, { "Bit depth", source.bits },
      { "Peak (dBFS)", source.peak_db }, { "DC", source.dc },
      { "Balance (dB)", source.balance_db }, { "Correlation", source.corr },
    }
    for _, field in ipairs(fields) do
      out[#out + 1] = ("| %s | %s |"):format(field[1], display(field[2]))
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "Source metadata was not available."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Settings"
  if info.settings and #info.settings > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "| Setting | Value |"
    out[#out + 1] = "|---|---|"
    for _, setting in ipairs(info.settings) do
      out[#out + 1] = ("| %s | %s |"):format(display(setting.name), display(setting.value))
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No settings were recorded."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Clusters"
  if info.clusters and #info.clusters > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "| Name | Hits | Centroid | Peak low | Peak high | Blocks |"
    out[#out + 1] = "|---|---:|---:|---:|---:|---:|"
    for _, cluster in ipairs(info.clusters) do
      out[#out + 1] = ("| %s | %s | %s | %s | %s | %s |")
        :format(display(cluster.name), display(cluster.n), display(cluster.centroid),
          display(cluster.peak_lo), display(cluster.peak_hi), display(cluster.blocks))
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No clusters were recorded."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## MIDI Plan"
  if info.plan and #info.plan > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "| Name | Note | Kind |"
    out[#out + 1] = "|---|---:|---|"
    for _, row in ipairs(info.plan) do
      out[#out + 1] = ("| %s | %s | %s |")
        :format(display(row.name), display(row.note), display(row.kind))
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No MIDI notes were planned."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Sample Matrix"
  if info.matrix and #info.matrix > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "| Group | Note | Sample | Velocity | Round robin |"
    out[#out + 1] = "|---|---:|---|---:|---:|"
    for _, group in ipairs(info.matrix) do
      for _, sample in ipairs(group.samples) do
        out[#out + 1] = ("| %s | %s | %s | %s-%s | %s/%s |")
          :format(display(group.name), display(group.note), display(sample.file),
            display(sample.lovel), display(sample.hivel), display(sample.seq), display(sample.seqlen))
      end
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No sample matrix was produced."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Loops"
  if info.loops and #info.loops > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "| Name | Duration (s) | BPM |"
    out[#out + 1] = "|---|---:|---:|"
    for _, loop in ipairs(info.loops) do
      out[#out + 1] = ("| %s | %s | %s |")
        :format(display(loop.name), display(loop.dur), display(loop.bpm))
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No loops were recorded."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Warnings"
  if info.warnings and #info.warnings > 0 then
    out[#out + 1] = ""
    for _, warning in ipairs(info.warnings) do out[#out + 1] = "- " .. warning end
  else
    out[#out + 1] = ""
    out[#out + 1] = "No warnings."
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Dynamic Gaps"
  if info.gaps and #info.gaps > 0 then
    out[#out + 1] = ""
    for _, gap in ipairs(info.gaps) do out[#out + 1] = "- " .. gap end
  else
    out[#out + 1] = ""
    out[#out + 1] = "The dynamic range is evenly covered."
  end

  if info.review and #info.review > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "## Review"
    out[#out + 1] = ""
    out[#out + 1] = "These hits were assigned to their nearest articulation but set aside on the Review track for a listen; they were not silently mixed in."
    out[#out + 1] = ""
    out[#out + 1] = "| Name | Source | Distance |"
    out[#out + 1] = "|---|---|---:|"
    for _, hit in ipairs(info.review) do
      out[#out + 1] = ("| %s | %s | %s |")
        :format(display(hit.name), display(hit.source), display(hit.distance))
    end
  end

  if info.model then
    out[#out + 1] = ""
    out[#out + 1] = "## Articulation Model"
    if info.model.frozen then
      out[#out + 1] = ""
      out[#out + 1] = "Articulation names and MIDI notes came from a previously saved model and did not move."
    end
    if info.model.cut ~= nil then
      out[#out + 1] = ""
      out[#out + 1] = ("Model outlier cut: %s."):format(display(info.model.cut))
    end
    if info.model.sources and #info.model.sources > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "The library was built from these source recordings:"
      out[#out + 1] = ""
      for _, source_name in ipairs(info.model.sources) do
        out[#out + 1] = "- " .. source_name
      end
    end
  end

  out[#out + 1] = ""
  out[#out + 1] = "## Sample Verification"
  if info.missing and #info.missing > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "**MISSING sample files — this library is not shareable:**"
    out[#out + 1] = ""
    for _, file in ipairs(info.missing) do out[#out + 1] = "- " .. file end
  else
    out[#out + 1] = ""
    out[#out + 1] = "Every sample was found."
  end

  return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

local function contains(list, needle)
  for _, value in ipairs(list) do
    if value:find(needle, 1, true) then return true end
  end
  return false
end

function M.selftest()
  local articulations = { "Kick", "Tap" }
  local loops = { "Groove A", "Groove B" }
  local plan = M.plan_notes(articulations, loops, 36)
  assert(#plan == 4 and plan[1].note == 36 and plan[2].note == 37
      and plan[3].kind == "loop" and plan[4].note == plan[3].note + 1,
    "plan must keep hits consecutive and loops ordered: a wrong map would trigger the wrong sound")
  assert(plan[3].note % 12 == 0,
    "the first loop must start on an octave boundary: mixing loops into hit notes would make the keyboard layout unstable")

  local expanded = M.plan_notes({ "Kick", "Tap", "Slap" }, loops, 36)
  assert(expanded[4].note == plan[3].note and expanded[5].note == plan[4].note,
    "one added hit below the boundary must not renumber loops: existing songs would play different loops")

  local many = {}
  for i = 1, 10 do many[i] = "Hit " .. i end
  local limited, overflow = M.plan_notes(many, { "Overflow Loop" }, 120)
  local all_midi = true
  for _, row in ipairs(limited) do all_midi = all_midi and row.note >= 0 and row.note <= 127 end
  assert(all_midi and #limited == 8 and #overflow == 3
      and overflow[1] == "Hit 9" and overflow[2] == "Hit 10" and overflow[3] == "Overflow Loop",
    "out-of-range names must overflow instead of emitting notes above 127: invalid notes make sampler presets unloadable")

  local matrix = {
    { name = "Kick", note = 36, layers = {
      { lo = -12, hi = -6, count = 2 }, { lo = -5, hi = 0, count = 2 },
    }, samples = {
      { file = "Samples/Kick_v1_rr1.wav", lovel = 1, hivel = 31, seq = 1, seqlen = 2 },
      { file = "Samples/Kick_v1_rr2.wav", lovel = 1, hivel = 31, seq = 2, seqlen = 2 },
      { file = "Samples/Kick_v2_rr1.wav", lovel = 32, hivel = 127, seq = 1, seqlen = 2 },
      { file = "Samples/Kick_v2_rr2.wav", lovel = 32, hivel = 127, seq = 2, seqlen = 2 },
    } },
    { name = "Tap", note = 37, layers = {
      { lo = -4, hi = -1, count = 2 },
    }, samples = {
      { file = "Samples/Tap_v1_rr1.wav", lovel = 1, hivel = 127, seq = 1, seqlen = 2 },
      { file = "Samples/Tap_v1_rr2.wav", lovel = 1, hivel = 127, seq = 2, seqlen = 2 },
    } },
  }

  assert(#M.layer_warnings(matrix) == 0,
    "a healthy kit must produce no warnings: false alarms would train users to ignore the real gate")
  local wide = M.layer_warnings({ { name = "Wide", samples = { {}, {} },
    layers = { { lo = -12, hi = -2, count = 2 } } } })
  assert(contains(wide, "round robins should sound alike") and contains(wide, "add more layers"),
    "a wide layer must explain round-robin mismatch and its fix: otherwise unlike hits would ship as one cycle")
  local thin = M.layer_warnings({ { name = "Thin", samples = { {} },
    layers = { { lo = -2, hi = -1, count = 1 } } } })
  assert(contains(thin, "has 1 round robins"),
    "a layer below the round-robin minimum must warn: one sample cannot suppress machine-gun repeats")
  local sparse = M.layer_warnings({ { name = "Sparse", samples = { {} }, layers = {
    { lo = -4, hi = -3, count = 2 }, { lo = -2, hi = -1, count = 2 },
  } } })
  assert(contains(sparse, "has 1 hits for 2 layers"),
    "fewer hits than layers must warn: an empty velocity layer makes the promised matrix impossible")

  local function even_peaks(count, lo, hi)
    local out = {}
    for i = 1, count do out[i] = lo + (i - 1) * (hi - lo) / (count - 1) end
    return out
  end
  local function assign_layers(values, n)
    if #values == 0 or n < 1 then return {}, {} end
    n = math.min(n, #values)
    local order, layer_of, layers = {}, {}, {}
    for i = 1, #values do order[i] = i end
    table.sort(order, function(a, b) return values[a] < values[b] end)
    for rank, idx in ipairs(order) do
      local l = math.min(n, math.floor((rank - 1) * n / #values) + 1)
      local db, L = 20 * math.log(math.max(values[idx], 1e-9), 10), layers[l]
      layer_of[idx] = l
      layers[l] = L and { lo = math.min(L.lo, db), hi = math.max(L.hi, db), count = L.count + 1 }
        or { lo = db, hi = db, count = 1 }
    end
    return layer_of, layers
  end
  local slap = M.choose_layers(even_peaks(75, -66, 0), assign_layers)
  assert(slap.layers == 12 and slap.floor == 5 and slap.minRr == 6
      and slap.widest > 5 and slap.widest < 6,
    "75 Slap hits must choose 12 roughly 6 dB layers while preserving six round robins")
  local tone_peaks_for_layers = even_peaks(48, -125, 0)
  local tone_layers = M.choose_layers(tone_peaks_for_layers, assign_layers)
  assert(tone_layers.layers == 12 and tone_layers.floor == 4,
    "48 Tone hits must fall through floor 5 and choose 12 roughly 8 dB layers at floor 4")
  local amplitudes = {}
  for i, db in ipairs(tone_peaks_for_layers) do amplitudes[i] = 10 ^ (db / 20) end
  local _, split = assign_layers(amplitudes, tone_layers.layers)
  local widest, min_rr = 0, math.huge
  for _, layer in ipairs(split) do
    widest = math.max(widest, layer.hi - layer.lo)
    min_rr = math.min(min_rr, layer.count)
  end
  assert(tone_layers.widest > 7.9 and tone_layers.widest < 8.1 and tone_layers.minRr == 4
      and math.abs(tone_layers.widest - widest) <= 1e-12 and tone_layers.minRr == min_rr,
    "choose_layers must report the widest layer and minimum round robins from its returned split")
  local best_effort = M.choose_layers({ -100, -66, -33, 0 }, assign_layers)
  assert(best_effort and best_effort.layers == 2 and best_effort.floor == nil
      and best_effort.widest > 9 and best_effort.minRr == 2,
    "choose_layers must return a usable two-layer best effort when no floor satisfies the width limit")

  local tone_peaks = {
    18, -17, -17, -15, -14, -14, -14, -14, -11, -8.5,
    0, 0, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    8, 8, 9, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, -17,
  }
  local gaps = M.dynamic_gaps(tone_peaks, 3)
  assert(#tone_peaks == 41 and gaps[1].gap == 8.5 and gaps[1].from == -8.5 and gaps[1].to == 0
      and gaps[2].gap == 3,
    "Tone's 8.5 dB hole must rank first: missing it would prescribe more layers instead of more mid-force hits")
  local tied_gaps = M.dynamic_gaps({ 10, 8, 2, 0 }, 3)
  assert(tied_gaps[2].from == 0 and tied_gaps[3].from == 8,
    "equal gaps must sort by their lower edge: unstable advice would send repeated runs to different force ranges")
  assert(#M.dynamic_gaps({ 0 }, 3) == 0 and #M.dynamic_gaps({}, 3) == 0,
    "fewer than two peaks must have no gaps: inventing a gap would demand recordings without evidence")

  local advice = M.gap_advice({ { name = "Tone", peaks_db = tone_peaks } })
  assert(#advice == 1,
    "Tone's hole must trigger advice: a checker that never fires would let an unrecorded force range ship")
  assert(#M.gap_advice({ { name = "Even", peaks_db = { -12, -8, -4, 0 } } }) == 0,
    "evenly spread hits must stay silent: false alarms would waste another recording session")
  assert(advice[1]:find("8.5 dB", 1, true)
      and advice[1]:find("-8.5 dB", 1, true) and advice[1]:find("0.0 dB", 1, true),
    "gap advice must name its size and both edges: vague advice cannot tell the player what force to record")

  local audition = M.audition_notes(matrix, 0.5)
  assert(#audition == 6,
    "audition must emit one note per sample: skipped or extra notes make the quality pass incomplete")
  local velocities_ok = true
  local sample_index = 0
  for gi, group in ipairs(matrix) do
    for _, sample in ipairs(group.samples) do
      sample_index = sample_index + 1
      local event = audition[sample_index]
      velocities_ok = velocities_ok and event.note == group.note
        and event.vel >= sample.lovel and event.vel <= sample.hivel
    end
  end
  assert(velocities_ok and audition[1].vel == 16 and audition[3].vel == 79,
    "every audition velocity must be its sample's midpoint: crossing a range would audition the wrong layer")
  assert(audition[1].pos == 0 and audition[2].pos == 0.5 and audition[6].pos == 2.5
      and audition[4].note == 36 and audition[5].note == 37,
    "audition must preserve matrix order and step positions: a shuffled preview would misidentify bad samples")

  local verify_matrix = { { samples = {
    { file = "a.wav" }, { file = "b.wav" }, { file = "b.wav" }, { file = "c.wav" },
  } } }
  local missing = M.verify_samples(verify_matrix, function(path) return path == "a.wav" end)
  assert(#missing == 2 and missing[1] == "b.wav" and missing[2] == "c.wav",
    "verification must return unique missing files in matrix order: duplicates or reordering obscure the repair list")
  assert(#M.verify_samples(verify_matrix, function() return true end) == 0,
    "verification must return an empty array when all files exist: a false failure would block a shareable kit")

  local warnings = { "Wide layer warning", "Round robin warning" }
  local report = M.report {
    kit = "Cajon", source = { name = "session.wav", dur = 180, srate = 48000,
      bits = 32, peak_db = -1, dc = 0.001, balance_db = 0.2, corr = 0.9 },
    settings = { { name = "Layers", value = 2 } },
    clusters = { { name = "Kick", n = 4, centroid = 120, peak_lo = -12,
      peak_hi = 0, blocks = 1 } },
    plan = plan, matrix = matrix, loops = { { name = "Groove A", dur = 4, bpm = 120 } },
    warnings = warnings, gaps = advice,
    review = { { name = "Tone", source = "second-session.wav", distance = 3.2 } },
    model = { frozen = true, cut = 2.5, sources = { "first-session.wav", "second-session.wav" } },
    missing = { "Samples/missing.wav" },
  }
  assert(report:find("# Cajon Library Report", 1, true)
      and report:find("| Field | Value |", 1, true)
      and report:find("session.wav", 1, true) and report:find("Layers", 1, true)
      and report:find("| Kick | 4 | 120 |", 1, true)
      and report:find("Samples/Kick_v1_rr1.wav", 1, true)
      and report:find("| Groove A | 4 | 120 |", 1, true),
    "report must contain readable stage headings and tables: missing decisions make the shipped record unauditable")
  local names_present = true
  for _, row in ipairs(plan) do names_present = names_present and report:find(row.name, 1, true) ~= nil end
  assert(names_present,
    "every planned articulation must appear in the report: an omitted mapping leaves players guessing which note to use")
  local warnings_present = true
  for _, warning in ipairs(warnings) do
    warnings_present = warnings_present and report:find(warning, 1, true) ~= nil
  end
  assert(warnings_present,
    "every warning must appear verbatim in the report: softened or dropped warnings can bless a bad library")
  assert(report:find("MISSING", 1, true) and report:find("Samples/missing.wav", 1, true),
    "missing samples must be unmistakable and listed: a silent failure would let a broken library be shared")
  assert(report:find(advice[1], 1, true),
    "the report must include gap advice verbatim: dropping it would hide what force the next session must capture")
  assert(report:find("| Tone | second-session.wav | 3.2 |", 1, true)
      and report:find("not silently mixed in", 1, true),
    "the report must list reviewed hits, distances, and isolation: otherwise outliers could look silently approved")
  assert(report:find("previously saved model", 1, true) and report:find("did not move", 1, true)
      and report:find("first-session.wav", 1, true) and report:find("second-session.wav", 1, true),
    "a frozen-model report must preserve the note-map statement and sources: updated packs could appear remapped")

  local complete = M.report { kit = "Complete", missing = {} }
  assert(complete:find("Every sample was found.", 1, true),
    "a complete verification must say every sample was found: silence leaves shareability ambiguous")
  assert(complete:find("The dynamic range is evenly covered.", 1, true),
    "a report without gap advice must say coverage is even: silence would leave the recording gate unresolved")
  local ok, partial = pcall(M.report, { kit = "Partial" })
  assert(ok and partial:find("Source metadata was not available.", 1, true)
      and partial:find("No loops were recorded.", 1, true),
    "nil source and loops must still produce a partial report: an interrupted run must keep its decisions")

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
