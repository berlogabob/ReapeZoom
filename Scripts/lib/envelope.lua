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
  local minGapBuckets = math.max(1, math.floor(opts.minGap * rate))
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
      local prev_end = k > 1 and spans[k - 1][2] or 0
      local next_start = spans[k + 1] and spans[k + 1][1] or (n + 1)
      local s = a - math.min(opts.pad * rate, (a - prev_end - 1) / 2)
      local e = b + math.min(opts.pad * rate, (next_start - b - 1) / 2)
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
  local minGapBuckets = math.max(1, math.floor(opts.minInterval * rate))

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
