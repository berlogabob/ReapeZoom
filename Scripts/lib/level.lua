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

-- Median, not mean: a live recording has long quiet stretches that drag a mean
-- down and would make the whole song get boosted.
local function median(t)
  if #t == 0 then return 0 end
  local s = {}
  for i = 1, #t do s[i] = t[i] end
  table.sort(s)
  local m = #s // 2
  if #s % 2 == 1 then return s[m + 1] end
  return (s[m] + s[m + 1]) / 2
end

-- env:  linear amplitudes, one per bucket, at `rate` buckets/second
-- opts: maxBoost, maxCut (dB, positive numbers)
--       response  (s)     smoothing window, the "how fast does it react" knob
--       slew      (dB/s)  hard limit on how fast the gain may move
--       floor     (dB)    below target-floor, hold instead of boosting
--       thin      (dB)    emit a point only after the gain moves this much
-- returns array of {t = seconds from start of env, db = gain correction}
function M.ride(env, rate, opts)
  local n = #env
  if n == 0 then return {} end

  -- 1. smooth to a short-term-loudness proxy
  -- ponytail: peak, not RMS or true LUFS-S. Tracks well enough for slow riding
  -- and needs no extra decode. Revisit if dense material rides visibly wrong.
  local half = math.max(1, math.floor(opts.response * rate / 2))
  local smooth = {}
  for i = 1, n do
    local m = 0
    local a, b = math.max(1, i - half), math.min(n, i + half)
    for j = a, b do if env[j] > m then m = env[j] end end
    smooth[i] = db(m)
  end

  -- 2. target level, from the loud half of the material only
  local loud = {}
  for i = 1, n do if smooth[i] > -60 then loud[#loud + 1] = smooth[i] end end
  if #loud == 0 then return {} end
  local target = median(loud)
  local gate = target - opts.floor

  -- 3. desired correction, gated so quiet passages are never boosted
  local want = {}
  local held = 0
  for i = 1, n do
    if smooth[i] < gate then
      want[i] = held -- hold: boosting here would just raise the room noise
    else
      local c = target - smooth[i]
      if c > opts.maxBoost then c = opts.maxBoost end
      if c < -opts.maxCut then c = -opts.maxCut end
      want[i] = c
      held = c
    end
  end

  -- 4. slew limit so it cannot pump on transients
  local step = opts.slew / rate
  local cur = want[1]
  local ride = {}
  for i = 1, n do
    local d = want[i] - cur
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

  -- clamps hold against an extreme swing
  local wild = {}
  fill(wild, 60, 0.9)
  fill(wild, 60, 0.02) -- ~-33 dB, far past maxBoost
  p = M.ride(wild, rate, o)
  for _, q in ipairs(p) do
    assert(q.db <= o.maxBoost + 1e-6 and q.db >= -o.maxCut - 1e-6,
      ("gain %.2f outside clamp"):format(q.db))
  end

  -- points are ordered and the end is anchored
  for i = 2, #p do assert(p[i].t > p[i - 1].t, "points out of order") end
  assert(math.abs(p[#p].t - #wild / rate) < 1e-6, "end not anchored")

  assert(#M.ride({}, rate, o) == 0)

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
