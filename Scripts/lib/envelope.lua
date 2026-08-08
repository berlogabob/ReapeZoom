-- @noindex
-- Shared envelope reading and span/onset detection for the ReapeZoom scripts.
-- Runs standalone under `lua envelope.lua` to exercise the pure logic.

local M = {}

----------------------------------------------------------------------
-- pure logic (no reaper.* in here, so it is testable standalone)
----------------------------------------------------------------------

-- env: array of linear amplitudes, one per bucket, at `rate` buckets/second.
-- opts: thresh (dB below peak), minGap, minSpan, pad (all seconds).
--
-- Returns {s=, e=} in seconds **from the start of env**, NOT project time.
-- read_envelope's item_pos does not leak into these numbers -- callers that
-- want project time must add it back themselves. Getting this wrong is
-- invisible whenever the item happens to sit at 0:00, so it is asserted below.
function M.find_spans(env, rate, opts)
  local n = #env
  if n == 0 then return {} end

  -- sliding-window max: a rest or a note decay inside a span is not a gap
  -- ponytail: O(n * window) = 2.3M ops for a 91-min take, instant. Monotonic
  -- deque only if a multi-hour recording ever feels slow.
  local half = math.max(1, math.floor(rate * 0.5))
  local smooth = {}
  for i = 1, n do
    local m = 0
    for j = math.max(1, i - half), math.min(n, i + half) do
      if env[j] > m then m = env[j] end
    end
    smooth[i] = m
  end

  local peak = 0
  for i = 1, n do if env[i] > peak then peak = env[i] end end
  if peak <= 0 then return {} end
  local limit = peak * 10 ^ (opts.thresh / 20)

  -- collect gaps: runs below the limit lasting at least minGap
  -- ceil, not floor: an accepted gap must never be SHORTER than the one asked
  -- for, or the split happens where the user said it should not.
  local minGapBuckets = math.max(1, math.ceil(opts.minGap * rate))
  local gaps, run = {}, nil
  for i = 1, n do
    if smooth[i] < limit then
      run = run or i
    elseif run then
      if i - run >= minGapBuckets then gaps[#gaps + 1] = { run, i - 1 } end
      run = nil
    end
  end
  if run and n + 1 - run >= minGapBuckets then gaps[#gaps + 1] = { run, n } end

  -- spans between the gaps are the candidates
  local spans, cursor = {}, 1
  for _, g in ipairs(gaps) do
    if g[1] > cursor then spans[#spans + 1] = { cursor, g[1] - 1 } end
    cursor = g[2] + 1
  end
  if cursor <= n then spans[#spans + 1] = { cursor, n } end

  local out = {}
  for k, sp in ipairs(spans) do
    local a, b = sp[1], sp[2]
    if (b - a + 1) / rate >= opts.minSpan then
      -- Pad into the surrounding quiet, but at most halfway to the neighbouring
      -- span, so results can never overlap however large the padding.
      -- The first and last span have no neighbour on the outer side, so there
      -- they take the whole remaining distance -- halving against a boundary
      -- that is not a span silently threw away half the requested padding.
      local head = (k > 1) and (a - spans[k - 1][2] - 1) / 2 or (a - 1)
      local tail = spans[k + 1] and (spans[k + 1][1] - b - 1) / 2 or (n - b)
      local s = a - math.min(opts.pad * rate, head)
      local e = b + math.min(opts.pad * rate, tail)
      out[#out + 1] = { s = (s - 1) / rate, e = e / rate }
    end
  end

  return out
end

-- Percussion onsets: a RISING EDGE crossing the threshold, not merely being
-- above it. A swell that never crosses from below produces no onset, and a
-- bounce inside minInterval of the previous hit is suppressed.
-- opts: thresh (dB below peak), minInterval (seconds).
-- returns array of onset times in seconds.
function M.find_onsets(env, rate, opts)
  local n = #env
  if n == 0 then return {} end

  local peak = 0
  for i = 1, n do if env[i] > peak then peak = env[i] end end
  if peak <= 0 then return {} end
  local limit = peak * 10 ^ (opts.thresh / 20)
  -- ceil for the same reason as find_spans: two onsets must never end up closer
  -- together than minInterval.
  local minGapBuckets = math.max(1, math.ceil(opts.minInterval * rate))

  local onsets, armed, last = {}, true, nil
  for i = 1, n do
    if env[i] >= limit then
      if armed and (not last or i - last >= minGapBuckets) then
        onsets[#onsets + 1] = (i - 1) / rate
        last = i
      end
      armed = false -- must fall below the limit again before the next onset
    else
      armed = true
    end
  end

  return onsets
end

-- Equal-count split of `values` into `n` layers, quietest first.
-- Returns layer index per input position, plus per-layer {lo=,hi=,count=} in dB.
function M.assign_layers(values, n)
  local count = #values
  if count == 0 or n < 1 then return {}, {} end
  n = math.min(n, count) -- never produce an empty layer

  local order = {}
  for i = 1, count do order[i] = i end
  table.sort(order, function(a, b) return values[a] < values[b] end)

  local layer_of, layers = {}, {}
  for rank, idx in ipairs(order) do
    -- rank 1..count spread across n buckets, remainder to the lowest layers
    local l = math.min(n, math.floor((rank - 1) * n / count) + 1)
    layer_of[idx] = l
    local db = 20 * math.log(math.max(values[idx], 1e-9), 10)
    local L = layers[l]
    if not L then
      layers[l] = { lo = db, hi = db, count = 1 }
    else
      L.lo = math.min(L.lo, db); L.hi = math.max(L.hi, db); L.count = L.count + 1
    end
  end

  return layer_of, layers
end

-- What the detector would find at nearby thresholds, so the choice can be made
-- before committing rather than by running and undoing.
-- `deltas` are dB offsets applied to opts.thresh. Thresholds above 0 are
-- skipped: the number is dB BELOW the item peak, so a positive one is
-- meaningless. Rows come back sorted by threshold, and exactly one is marked
-- `current` -- the one the caller actually asked for.
-- Cheap enough to do inline: ~15 ms per find_spans on a 68-minute envelope.
function M.sweep_thresholds(env, rate, opts, deltas)
  local rows = {}
  for _, d in ipairs(deltas) do
    local t = opts.thresh + d
    if t <= 0 then
      local spans = M.find_spans(env, rate, {
        thresh = t, minGap = opts.minGap, minSpan = opts.minSpan, pad = opts.pad,
      })
      local shortest, longest
      for _, s in ipairs(spans) do
        local len = s.e - s.s
        if not shortest or len < shortest then shortest = len end
        if not longest or len > longest then longest = len end
      end
      rows[#rows + 1] = {
        thresh = t, count = #spans, shortest = shortest, longest = longest,
        current = d == 0,
      }
    end
  end
  table.sort(rows, function(a, b) return a.thresh < b.thresh end)
  return rows
end

-- Loudest bucket in an envelope, linear. 0 for an empty one.
function M.max_peak(env)
  local m = 0
  for i = 1, #env do if env[i] > m then m = env[i] end end
  return m
end

-- The parts of an item covered by regions, in timeline order, clipped to the
-- item. No overlapping region means the whole item is one span.
-- `regions` is a plain array of {s=,e=} in PROJECT time -- the caller does the
-- EnumProjectMarkers3 walk, so this stays pure and testable.
-- Returns {s=,e=} in PROJECT time.
function M.spans_in(regions, item_pos, item_len)
  local item_end = item_pos + item_len
  local out = {}
  for _, r in ipairs(regions) do
    if r.e > item_pos and r.s < item_end then
      out[#out + 1] = { s = math.max(r.s, item_pos), e = math.min(r.e, item_end) }
    end
  end
  table.sort(out, function(a, b) return a.s < b.s end)
  if #out == 0 then out[1] = { s = item_pos, e = item_end } end
  return out
end

-- Map layer index (1..n) to a MIDI velocity range. Layer 1 is the quietest.
function M.velocity_range(layer, n)
  local lo = math.floor((layer - 1) * 127 / n) + 1
  local hi = math.floor(layer * 127 / n)
  if layer == n then hi = 127 end
  return lo, hi
end

----------------------------------------------------------------------
-- REAPER side
----------------------------------------------------------------------

-- Reads the already-built .reapeaks cache, so a 2 GB file costs nothing.
-- starttime is PROJECT time, not item-relative -- see saull_Peak envelope
-- generator.lua and BirdBird's waveform_peaks.lua, which both pass D_POSITION.
-- Buffer layout is maximums block, then minimums block, then an optional
-- extra block; reserve all three, it costs nothing.
function M.read_envelope(take, item_pos, item_len, peakrate)
  local CHUNK = 4096
  local NCH = math.min(2, reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take)))
  if NCH < 1 then return {} end
  local buf = reaper.new_array(CHUNK * NCH * 3)
  local env, t = {}, 0

  while t < item_len do
    local want = math.min(CHUNK, math.ceil((item_len - t) * peakrate))
    if want < 1 then break end
    buf.clear()
    local ret = reaper.GetMediaItemTake_Peaks(take, peakrate, item_pos + t, NCH, want, 0, buf)
    local got = ret & 0xfffff
    if got < 1 then break end
    -- the minimums block is laid out after the *requested* count, not the returned one
    local minbase = want * NCH
    for i = 1, got do
      local o = (i - 1) * NCH
      local v = 0
      for c = 1, NCH do
        v = math.max(v, math.abs(buf[o + c]), math.abs(buf[minbase + o + c]))
      end
      env[#env + 1] = v
    end
    t = t + got / peakrate
  end

  return env
end

-- Same read, but keeping the channels apart and preserving the sign of the
-- minimums. Returns { [ch] = { {mx=, mn=}, ... } }, nch.
-- The min/max asymmetry is what makes a free DC offset estimate possible.
function M.read_channels(take, item_pos, item_len, peakrate)
  local CHUNK = 4096
  local NCH = math.min(2, reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take)))
  if NCH < 1 then return {}, 0 end
  local buf = reaper.new_array(CHUNK * NCH * 3)
  local out, t = {}, 0
  for c = 1, NCH do out[c] = {} end

  while t < item_len do
    local want = math.min(CHUNK, math.ceil((item_len - t) * peakrate))
    if want < 1 then break end
    buf.clear()
    local ret = reaper.GetMediaItemTake_Peaks(take, peakrate, item_pos + t, NCH, want, 0, buf)
    local got = ret & 0xfffff
    if got < 1 then break end
    local minbase = want * NCH
    for i = 1, got do
      local o = (i - 1) * NCH
      for c = 1, NCH do
        out[c][#out[c] + 1] = { mx = buf[o + c], mn = buf[minbase + o + c] }
      end
    end
    t = t + got / peakrate
  end

  return out, NCH
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  local rate = 20
  local env = {}
  local function fill(seconds, amp)
    for _ = 1, math.floor(seconds * rate) do env[#env + 1] = amp end
  end
  fill(60, 0.8)   -- span 1
  fill(12, 0.001) -- real gap
  fill(45, 0.8)   -- span 2, first half
  fill(3, 0.001)  -- short dip mid-span: must NOT split
  fill(45, 0.8)   -- span 2, second half
  fill(20, 0.001) -- real gap
  fill(10, 0.8)   -- too short, must be dropped

  local o = { thresh = -40, minGap = 8, minSpan = 45, pad = 1 }
  local s = M.find_spans(env, rate, o)
  assert(#s == 2, ("expected 2 spans, got %d"):format(#s))
  assert(math.abs(s[1].e - s[1].s - 62) < 2, "span 1 length")
  assert(math.abs(s[2].e - s[2].s - 95) < 2, "span 2 length")
  assert(s[2].s > 70, "span 2 must start after the first gap")

  -- regions must stay inside the item and never overlap, however big the padding
  for _, pad in ipairs { 0, 1, 5, 60 } do
    local r = M.find_spans(env, rate, { thresh = -40, minGap = 8, minSpan = 45, pad = pad })
    local len = #env / rate
    for i, x in ipairs(r) do
      assert(x.s >= 0 and x.e <= len, ("pad=%d span %d out of bounds"):format(pad, i))
      assert(x.e > x.s, ("pad=%d span %d is empty"):format(pad, i))
      if i > 1 then assert(x.s >= r[i - 1].e, ("pad=%d spans %d/%d overlap"):format(pad, i - 1, i)) end
    end
  end

  -- the coordinate frame is the start of env, never project time
  local lead = {}
  for _ = 1, 5 * rate do lead[#lead + 1] = 0.001 end   -- 5 s of quiet first
  for _ = 1, 100 * rate do lead[#lead + 1] = 0.8 end
  local ls = M.find_spans(lead, rate, { thresh = -40, minGap = 2, minSpan = 45, pad = 0 })
  assert(#ls == 1, "expected one span after the lead-in")
  -- the ±0.5 s smoothing window legitimately pulls the boundary earlier; the
  -- point here is that the number is ~5 and not ~0 or an item position
  assert(math.abs(ls[1].s - 5) <= 0.6,
    ("span starts at %.2f s into env, expected ~5 -- offsets are env-relative"):format(ls[1].s))

  -- padding at the outer edges takes the whole remaining distance; halving
  -- against a non-existent neighbour silently dropped half of it
  local island = {}
  for _ = 1, 2 * rate do island[#island + 1] = 0.0001 end
  for _ = 1, 60 * rate do island[#island + 1] = 0.8 end
  for _ = 1, 4 * rate do island[#island + 1] = 0.0001 end
  local is = M.find_spans(island, rate, { thresh = -40, minGap = 1, minSpan = 45, pad = 30 })
  assert(#is == 1, ("expected 1 span, got %d"):format(#is))
  assert(is[1].s < 0.01, ("head padding stopped at %.2f s, should reach 0"):format(is[1].s))
  assert(is[1].e > #island / rate - 0.01,
    ("tail padding stopped at %.2f s, should reach %.2f"):format(is[1].e, #island / rate))

  -- a take that ends in silence must not have that silence inside the last span
  local trail = {}
  for _ = 1, 60 * rate do trail[#trail + 1] = 0.8 end
  for _ = 1, 12 * rate do trail[#trail + 1] = 0.001 end
  local ts = M.find_spans(trail, rate, { thresh = -40, minGap = 8, minSpan = 45, pad = 0 })
  assert(#ts == 1, ("expected 1 span, got %d"):format(#ts))
  assert(ts[1].e < 61, ("span runs to %.2f s, must end near 60 not 72"):format(ts[1].e))

  assert(#M.find_spans({}, rate, o) == 0)
  local silent = {}
  for _ = 1, 100 * rate do silent[#silent + 1] = 0 end
  assert(#M.find_spans(silent, rate, o) == 0)

  -- onsets ------------------------------------------------------------
  local orate = 400
  local hits = {}
  local function quiet(sec) for _ = 1, math.floor(sec * orate) do hits[#hits + 1] = 0.0005 end end
  local function strike(amp)
    hits[#hits + 1] = amp
    for k = 1, 40 do hits[#hits + 1] = amp * (0.9 ^ k) end -- 100 ms decay
  end
  quiet(0.2)
  for i = 1, 10 do strike(0.9); quiet(0.4) end
  local oo = { thresh = -30, minInterval = 0.08 }
  local on = M.find_onsets(hits, orate, oo)
  assert(#on == 10, ("expected 10 onsets, got %d"):format(#on))
  assert(math.abs(on[2] - on[1] - 0.5) < 0.02, "onset spacing")

  -- a bounce 20 ms after a hit is one hit, not two
  local bounce = {}
  for _ = 1, math.floor(0.2 * orate) do bounce[#bounce + 1] = 0.0005 end
  bounce[#bounce + 1] = 0.9
  for _ = 1, math.floor(0.005 * orate) do bounce[#bounce + 1] = 0.0005 end
  bounce[#bounce + 1] = 0.7 -- rising edge again, but inside minInterval
  for _ = 1, math.floor(0.5 * orate) do bounce[#bounce + 1] = 0.0005 end
  assert(#M.find_onsets(bounce, orate, oo) == 1,
    ("bounce produced %d onsets"):format(#M.find_onsets(bounce, orate, oo)))

  -- a slow swell never crosses from below, so it is one onset, not many
  local swell = {}
  for i = 1, 400 do swell[#swell + 1] = i / 400 end
  assert(#M.find_onsets(swell, orate, oo) == 1, "swell must not retrigger")

  -- onsets are never closer together than minInterval: rounding the bucket
  -- count down used to accept a gap shorter than the one asked for
  local tight = M.find_onsets({ 0, 1, 0, 1 }, 10, { thresh = -20, minInterval = 0.29 })
  for i = 2, #tight do
    assert(tight[i] - tight[i - 1] >= 0.29 - 1e-9,
      ("onsets %.2f s apart, minInterval was 0.29"):format(tight[i] - tight[i - 1]))
  end

  -- nothing to detect must produce nothing, not a phantom hit at position 0
  assert(#M.find_onsets({}, orate, oo) == 0, "empty env must give no onsets")
  local zeros = {}
  for _ = 1, 100 do zeros[#zeros + 1] = 0 end
  assert(#M.find_onsets(zeros, orate, oo) == 0, "silence must give no onsets")

  -- sweep_thresholds ---------------------------------------------------
  local DELTAS = { -10, -5, 0, 5, 10 }
  local sw = M.sweep_thresholds(env, rate, o, DELTAS)
  assert(#sw > 0, "sweep produced no rows")

  -- THE invariant: the previewed count for the chosen threshold must equal
  -- what the commit will actually produce. If these can disagree the preview
  -- is worse than useless, because it is believed.
  local cur
  for _, r in ipairs(sw) do if r.current then cur = r end end
  assert(cur, "no row marked current")
  assert(cur.thresh == o.thresh, ("current row is %g dB, asked for %g"):format(cur.thresh, o.thresh))
  assert(cur.count == #M.find_spans(env, rate, o),
    ("preview says %d songs, find_spans says %d"):format(cur.count, #M.find_spans(env, rate, o)))

  -- the current row's lengths must be the real min and max, not merely
  -- consistent with each other: assert against spans computed directly
  local direct = M.find_spans(env, rate, o)
  local dmin, dmax
  for _, s in ipairs(direct) do
    local len = s.e - s.s
    if not dmin or len < dmin then dmin = len end
    if not dmax or len > dmax then dmax = len end
  end
  assert(math.abs(cur.shortest - dmin) < 1e-9,
    ("shortest is %.2f, the actual shortest span is %.2f"):format(cur.shortest, dmin))
  assert(math.abs(cur.longest - dmax) < 1e-9,
    ("longest is %.2f, the actual longest span is %.2f"):format(cur.longest, dmax))
  assert(dmin < dmax, "fixture must have spans of differing length or this proves nothing")

  -- sorting is the sweep's job, not the caller's: feed the deltas scrambled
  local scrambled = M.sweep_thresholds(env, rate, o, { 5, -10, 0, 10, -5 })
  for i = 2, #scrambled do
    assert(scrambled[i].thresh > scrambled[i - 1].thresh, "sweep rows must be sorted by threshold")
  end
  for i = 2, #sw do
    assert(sw[i].thresh > sw[i - 1].thresh, "sweep rows must be sorted by threshold")
  end
  for _, r in ipairs(sw) do
    assert(r.thresh <= 0, ("threshold %g is above 0 -- it is dB BELOW the peak"):format(r.thresh))
    if r.count > 0 then
      assert(r.shortest and r.longest, "a non-empty row must report both lengths")
      assert(r.shortest <= r.longest, "shortest must not exceed longest")
    else
      assert(not r.shortest and not r.longest, "an empty row must report no lengths")
    end
  end

  -- a threshold that would land above 0 is dropped, not clamped or passed on
  local near = M.sweep_thresholds(env, rate,
    { thresh = -2, minGap = o.minGap, minSpan = o.minSpan, pad = o.pad }, DELTAS)
  for _, r in ipairs(near) do assert(r.thresh <= 0, "positive threshold leaked into the sweep") end
  assert(#near < #DELTAS, "rows above 0 dB should have been dropped")

  -- silence must give zero-count rows, not an error
  local ssw = M.sweep_thresholds(silent, rate, o, DELTAS)
  for _, r in ipairs(ssw) do assert(r.count == 0, "silence produced spans") end

  -- max_peak ----------------------------------------------------------
  assert(M.max_peak({}) == 0, "empty envelope has no peak")
  assert(M.max_peak({ 0.2, 0.9, 0.4 }) == 0.9, "peak must be the maximum")
  assert(M.max_peak({ 0.9, 0.2 }) == 0.9, "peak must not depend on order")

  -- spans_in ----------------------------------------------------------
  -- item 10..20, regions given out of order, clipped at both edges
  local sp = M.spans_in({ { s = 18, e = 25 }, { s = 5, e = 12 }, { s = 30, e = 40 } }, 10, 10)
  assert(#sp == 2, ("expected 2 spans inside the item, got %d"):format(#sp))
  assert(sp[1].s == 10 and sp[1].e == 12, ("left clip wrong: %.1f..%.1f"):format(sp[1].s, sp[1].e))
  assert(sp[2].s == 18 and sp[2].e == 20, ("right clip wrong: %.1f..%.1f"):format(sp[2].s, sp[2].e))
  -- a region that only touches the edge does not count as overlapping
  assert(#M.spans_in({ { s = 0, e = 10 } }, 10, 10) == 1, "touching region must fall back")
  assert(M.spans_in({ { s = 0, e = 10 } }, 10, 10)[1].e == 20, "fallback must span the item")
  -- no regions at all: the whole item is one span
  local none = M.spans_in({}, 10, 10)
  assert(#none == 1 and none[1].s == 10 and none[1].e == 20, "no-region fallback wrong")

  -- layers ------------------------------------------------------------
  local vals = {}
  for i = 1, 20 do vals[i] = 10 ^ ((-30 + (i - 1) * 30 / 19) / 20) end
  local layer_of, layers = M.assign_layers(vals, 4)
  assert(#layers == 4, "expected 4 layers")
  for l = 1, 4 do assert(layers[l].count == 5, ("layer %d has %d"):format(l, layers[l].count)) end
  for l = 2, 4 do assert(layers[l].lo >= layers[l - 1].hi - 1e-9, "layers must be monotonic") end
  assert(layer_of[1] == 1 and layer_of[20] == 4, "quietest in layer 1, loudest in layer 4")

  -- never produce an empty layer when there are fewer hits than layers
  local _, few = M.assign_layers({ 0.1, 0.5 }, 4)
  assert(#few == 2, ("expected 2 layers for 2 hits, got %d"):format(#few))

  -- both halves of the guard: nothing to sort, and a nonsense layer count
  local lo0, la0 = M.assign_layers({}, 4)
  assert(#lo0 == 0 and #la0 == 0, "empty values must give empty results")
  local lo1, la1 = M.assign_layers({ 0.5 }, 0)
  assert(#lo1 == 0 and #la1 == 0, "n < 1 must give empty results")

  -- the remainder goes to the LOWEST layers: 5 values over 2 layers is 3 then 2
  local lo5, la5 = M.assign_layers({ 0.1, 0.2, 0.3, 0.4, 0.5 }, 2)
  assert(#la5 == 2, ("expected 2 layers, got %d"):format(#la5))
  assert(la5[1].count == 3 and la5[2].count == 2,
    ("remainder split is %d/%d, documented as 3/2"):format(la5[1].count, la5[2].count))
  assert(lo5[3] == 1, "the third-quietest of five must sit in layer 1")

  -- velocity ranges tile 1..127 with no gaps and no overlap
  local prev = 0
  for l = 1, 4 do
    local lo, hi = M.velocity_range(l, 4)
    assert(lo == prev + 1, ("layer %d starts at %d, expected %d"):format(l, lo, prev + 1))
    assert(hi >= lo, "velocity range inverted")
    prev = hi
  end
  assert(prev == 127, ("velocity ranges end at %d, expected 127"):format(prev))

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
