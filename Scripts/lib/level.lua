-- @noindex
-- Automatic level riding: turns a loudness envelope into a gain-correction
-- curve suitable for a volume automation item.
-- Runs standalone under `lua level.lua`.
--
-- This is NOT loudness normalization. Normalization applies one static gain to
-- a whole file. This corrects level variation *inside* a song -- a quiet verse
-- against a loud chorus, someone stepping toward the mic.

local M = {}

local function db(x) return 20 * math.log(math.max(x, 1e-9), 10) end

-- Linear-interpolated percentile. p is 0..1.
-- At p = 0.5 this is exactly the median it replaced, odd and even lengths alike.
local function percentile(t, p)
  local n = #t
  if n == 0 then return 0 end
  local s = {}
  for i = 1, n do s[i] = t[i] end
  table.sort(s)
  if n == 1 then return s[1] end
  local x = (n - 1) * p + 1
  local lo = math.floor(x)
  local hi = math.min(n, lo + 1)
  return s[lo] + (s[hi] - s[lo]) * (x - lo)
end

-- Median, not mean: a live recording has long quiet stretches that drag a mean
-- down and would make the whole song get boosted.
local function median(t) return percentile(t, 0.5) end

-- Short-term loudness proxy: sliding-window peak, in dB.
-- ponytail: peak, not RMS or true LUFS-S. Tracks well enough for slow riding
-- and needs no extra decode. Revisit if dense material rides visibly wrong.
local function smooth_db(env, rate, response)
  local n = #env
  local half = math.max(1, math.floor(response * rate / 2))
  local out = {}
  for i = 1, n do
    local m = 0
    local a, b = math.max(1, i - half), math.min(n, i + half)
    for j = a, b do if env[j] > m then m = env[j] end end
    out[i] = db(m)
  end
  return out
end

-- Where the material actually sits, given a smoothed curve.
-- `floor` is dB below the target; below that is room noise, not programme, and
-- it must not drag the measured range down (a rehearsal is mostly not music).
-- P10/P90 rather than min/max: one stray transient must not define the range.
-- Returns nil on an envelope with nothing above -60 dB -- callers must handle it.
local function stats(smooth, floor)
  local loud = {}
  for i = 1, #smooth do if smooth[i] > -60 then loud[#loud + 1] = smooth[i] end end
  if #loud == 0 then return nil end

  local target = median(loud)
  local gate = target - floor

  -- non-empty by construction: at least half of `loud` is >= target > gate
  local prog = {}
  for i = 1, #smooth do if smooth[i] >= gate then prog[#prog + 1] = smooth[i] end end

  local quiet, hi = percentile(prog, 0.10), percentile(prog, 0.90)
  return {
    target = target,
    gate = gate,
    quiet = quiet,
    loud = hi,
    range = hi - quiet,
    gated_frac = #prog / #smooth,
  }
end

-- What the material looks like before anything is done to it. Measured with the
-- same smoothing and the same gate M.ride uses, so the numbers reported here
-- describe exactly the material the ride will act on.
--
-- `response` and `floor` are the same knobs M.ride takes.
-- Returns {peak, loud, quiet, median, range, gated_frac} in dB, or nil when
-- there is nothing above -60 dB to measure.
function M.analyze(env, rate, response, floor)
  local n = #env
  if n == 0 then return nil end

  local peak = 0
  for i = 1, n do if env[i] > peak then peak = env[i] end end

  local st = stats(smooth_db(env, rate, response), floor)
  if not st then return nil end

  return {
    peak = db(peak),
    loud = st.loud,
    quiet = st.quiet,
    median = st.target,
    range = st.range,
    gated_frac = st.gated_frac,
  }
end

-- env:  linear amplitudes, one per bucket, at `rate` buckets/second
-- opts: maxBoost, maxCut (dB, positive numbers)
--       response  (s)     smoothing window, the "how fast does it react" knob
--       slew      (dB/s)  hard limit on how fast the gain may move
--       floor     (dB)    below target-floor, hold instead of boosting
--       thin      (dB)    emit a point only after the gain moves this much
--       range     (dB)    OPTIONAL target dynamic range to leave behind.
--                         nil or 0 = flatten everything to one level.
-- returns array of {t = seconds from start of env, db = gain correction}
function M.ride(env, rate, opts)
  local n = #env
  if n == 0 then return {} end

  -- 1. smooth to a short-term-loudness proxy
  local smooth = smooth_db(env, rate, opts.response)

  -- 2. target level, from the loud half of the material only
  local st = stats(smooth, opts.floor)
  if not st then return {} end
  local target, gate = st.target, st.gate

  -- How much of the existing spread to KEEP. 0 = flatten (the original
  -- behaviour), 1 = leave the material alone. Clamped at 1: this compresses
  -- macro-dynamics, it never expands them.
  local keep = 0
  if opts.range and opts.range > 0 and st.range > 0 then
    keep = math.min(1, opts.range / st.range)
  end

  -- 3. desired correction, gated so quiet passages are never boosted
  local want = {}
  local held = 0
  for i = 1, n do
    if smooth[i] < gate then
      want[i] = held -- hold: boosting here would just raise the room noise
    else
      local c = (target - smooth[i]) * (1 - keep)
      if c > opts.maxBoost then c = opts.maxBoost end
      if c < -opts.maxCut then c = -opts.maxCut end
      want[i] = c
      held = c
    end
  end

  -- 4. slew limit so it cannot pump on transients.
  -- Both ends are anchored at neutral gain and ramped into: outside the
  -- automation item the gain is 0 dB, so starting the curve at its full
  -- correction would step instantly at the boundary and can click. Forward from
  -- the start, then backward from the end -- the middle is untouched by the
  -- second pass because the first already left it within one step per bucket.
  local step = opts.slew / rate
  local ride = {}
  local cur = 0
  for i = 1, n do
    local d = want[i] - cur
    if d > step then d = step elseif d < -step then d = -step end
    cur = cur + d
    ride[i] = cur
  end
  cur = 0
  for i = n, 1, -1 do
    local d = ride[i] - cur
    if d > step then d = step elseif d < -step then d = -step end
    cur = cur + d
    ride[i] = cur
  end

  -- 5. thin: a point only when the gain has actually moved
  local pts = { { t = 0, db = ride[1] } }
  local last = ride[1]
  for i = 2, n do
    if math.abs(ride[i] - last) >= opts.thin then
      pts[#pts + 1] = { t = (i - 1) / rate, db = ride[i] }
      last = ride[i]
    end
  end
  -- always anchor the end so the envelope does not extrapolate
  local endt = n / rate
  if pts[#pts].t < endt - 1e-9 then pts[#pts + 1] = { t = endt, db = ride[n] } end

  return pts
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  local rate = 10
  local o = { maxBoost = 6, maxCut = 6, response = 3, slew = 3, floor = 20, thin = 0.2 }

  local function fill(t, seconds, amp)
    for _ = 1, math.floor(seconds * rate) do t[#t + 1] = amp end
  end

  -- constant level -> essentially no correction, and almost no points
  local flat = {}
  fill(flat, 60, 0.5)
  local p = M.ride(flat, rate, o)
  assert(#p <= 2, ("constant input produced %d points, expected <= 2"):format(#p))
  assert(math.abs(p[1].db) < 0.5, ("constant input wants %.2f dB"):format(p[1].db))

  -- a section 6 dB hotter must be pulled DOWN toward the rest
  local step = {}
  fill(step, 120, 0.25)
  fill(step, 120, 0.5) -- +6 dB
  fill(step, 120, 0.25)
  p = M.ride(step, rate, o)
  local function at(pts, t)
    local v = pts[1].db
    for _, q in ipairs(pts) do if q.t <= t then v = q.db else break end end
    return v
  end
  local quiet_g, loud_g = at(p, 60), at(p, 180)
  assert(loud_g < quiet_g - 3,
    ("loud section gain %.2f should be well below quiet %.2f"):format(loud_g, quiet_g))
  assert(loud_g >= -o.maxCut - 1e-6, "cut exceeded maxCut")

  -- a silent gap must NOT be boosted: the gate holds the previous gain
  local gap = {}
  fill(gap, 60, 0.5)
  fill(gap, 30, 0.00001) -- ~-100 dB
  fill(gap, 60, 0.5)
  p = M.ride(gap, rate, o)
  local before, during = at(p, 55), at(p, 75)
  assert(math.abs(during - before) < 0.5,
    ("gap gain moved from %.2f to %.2f -- the noise floor is being ridden up"):format(before, during))
  assert(during <= o.maxBoost, "gap was boosted past maxBoost")

  -- slew limit respected between consecutive points
  p = M.ride(step, rate, o)
  for i = 2, #p do
    local dt, dd = p[i].t - p[i - 1].t, math.abs(p[i].db - p[i - 1].db)
    assert(dd <= o.slew * dt + 0.35,
      ("slew violated: %.2f dB in %.2f s (limit %.2f)"):format(dd, dt, o.slew * dt))
  end

  -- Clamps. Both of them must actually BE REACHED, not merely not-exceeded:
  -- the old fixture here (0.9 then 0.02) produced a curve of exactly 0.00 dB
  -- throughout -- its quiet half fell below the gate and held -- so deleting
  -- either clamp still passed. Three levels with the middle one dominating puts
  -- the median in the middle, 10 dB either side, and 10 dB is inside the 20 dB
  -- gate, so both sections are programme and both corrections clamp at 6.
  local wild = {}
  fill(wild, 60, 0.316)  -- +10 dB vs middle -> wants -10, must clamp to -maxCut
  fill(wild, 240, 0.1)   -- the median
  fill(wild, 60, 0.0316) -- -10 dB vs middle -> wants +10, must clamp to +maxBoost
  p = M.ride(wild, rate, o)
  local lo, hi = math.huge, -math.huge
  for _, q in ipairs(p) do lo = math.min(lo, q.db); hi = math.max(hi, q.db) end
  assert(hi <= o.maxBoost + 1e-6 and lo >= -o.maxCut - 1e-6,
    ("gain %.2f..%.2f outside clamp"):format(lo, hi))
  assert(hi > o.maxBoost - 0.1,
    ("boost clamp never reached: peak gain %.2f, expected ~%.1f"):format(hi, o.maxBoost))
  assert(lo < -o.maxCut + 0.1,
    ("cut clamp never reached: lowest gain %.2f, expected ~%.1f"):format(lo, -o.maxCut))

  -- points are ordered and the end is anchored
  for i = 2, #p do assert(p[i].t > p[i - 1].t, "points out of order") end
  assert(math.abs(p[#p].t - #wild / rate) < 1e-6, "end not anchored")

  -- both edges start from neutral: outside the automation item the gain is 0 dB
  local edge = {}
  fill(edge, 60, 0.0316) -- wants a big boost immediately at t=0
  fill(edge, 240, 0.1)
  fill(edge, 60, 0.0316) -- and again right up to the end
  p = M.ride(edge, rate, o)
  assert(math.abs(p[1].db) <= o.slew / rate + 1e-6,
    ("curve starts at %.2f dB, must ramp from neutral"):format(p[1].db))
  assert(math.abs(p[#p].db) <= o.slew / rate + 1e-6,
    ("curve ends at %.2f dB, must ramp back to neutral"):format(p[#p].db))

  assert(#M.ride({}, rate, o) == 0)

  ----------------------------------------------------------------
  -- M.analyze
  ----------------------------------------------------------------

  -- `step` is a known +6 dB fixture, so the measured range has a hand-checkable
  -- answer. If this drifts, the percentile or the gate changed.
  local a = M.analyze(step, rate, o.response, o.floor)
  assert(a, "analyze returned nil on the step fixture")
  assert(math.abs(a.range - 6) < 0.5,
    ("step fixture measured %.2f dB range, expected ~6"):format(a.range))
  assert(a.loud > a.quiet, "loud must be above quiet")
  assert(math.abs(a.peak - db(0.5)) < 0.01, ("peak %.2f wrong"):format(a.peak))
  assert(a.gated_frac > 0 and a.gated_frac <= 1)

  assert(M.analyze({}, rate, o.response, o.floor) == nil, "empty env must give nil")
  local silent = {}
  fill(silent, 60, 0) -- digital silence: db() floors at -180, nothing above -60
  assert(M.analyze(silent, rate, o.response, o.floor) == nil, "silence must give nil")
  -- and the ride must decline to write anything on silence, not just the analysis
  assert(#M.ride(silent, rate, o) == 0, "silence must produce no ride points")

  -- a single bucket is a legal envelope for a very short item
  local one = M.analyze({ 0.5 }, rate, o.response, o.floor)
  assert(one and math.abs(one.range) < 1e-9, "single bucket must give a zero range")
  assert(#M.ride({ 0.5 }, rate, o) > 0, "single bucket must still ride")

  ----------------------------------------------------------------
  -- opts.range
  ----------------------------------------------------------------

  local function same(p1, p2)
    if #p1 ~= #p2 then return false end
    for i = 1, #p1 do
      if math.abs(p1[i].t - p2[i].t) > 1e-9 or math.abs(p1[i].db - p2[i].db) > 1e-9 then
        return false
      end
    end
    return true
  end

  local function with(extra)
    local t = {}
    for k, v in pairs(o) do t[k] = v end
    for k, v in pairs(extra) do t[k] = v end
    return t
  end

  -- range = 0 must be bit-identical to omitting it, or every existing project
  -- changes behaviour on upgrade.
  for _, fixture in ipairs { step, gap, wild, flat } do
    assert(same(M.ride(fixture, rate, o), M.ride(fixture, rate, with { range = 0 })),
      "range=0 differs from no range")
  end

  local ar = M.analyze(step, rate, o.response, o.floor).range

  -- asking for the range the material already has = do nothing
  p = M.ride(step, rate, with { range = ar })
  for _, q in ipairs(p) do
    assert(math.abs(q.db) < 0.5, ("range=current still moved %.2f dB"):format(q.db))
  end

  -- half the range = roughly half the correction
  local full = M.ride(step, rate, o)
  local half_p = M.ride(step, rate, with { range = ar / 2 })
  local function spread(pts)
    return math.abs(at(pts, 60) - at(pts, 180))
  end
  local sf, sh = spread(full), spread(half_p)
  assert(sh < sf, "half range should correct less than full flattening")
  assert(math.abs(sh - sf / 2) < 1.0,
    ("half-range spread %.2f, expected ~%.2f"):format(sh, sf / 2))

  -- asking for more range than exists must not expand it
  p = M.ride(step, rate, with { range = ar * 10 })
  for _, q in ipairs(p) do
    assert(math.abs(q.db) < 0.5, ("range far above current expanded by %.2f dB"):format(q.db))
  end

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
