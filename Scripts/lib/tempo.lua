-- @noindex
-- Beat/tempo estimation and ideal-grid mapping for the ReapeZoom scripts.
-- Part of the ReapeZoom package. See the main script for metadata.

local M = {}

----------------------------------------------------------------------
-- pure logic (no reaper.* in here, so it is testable standalone)
----------------------------------------------------------------------

-- env: array of linear amplitudes, one per bucket.
-- returns the positive first difference in dB, preserving the input length.
function M.onset_strength(env)
  if #env == 0 then return {} end

  local strength = { 0 }
  local previous = 20 * math.log(math.max(env[1], 1e-6), 10)
  for i = 2, #env do
    local current = 20 * math.log(math.max(env[i], 1e-6), 10)
    strength[i] = math.max(0, current - previous)
    previous = current
  end
  return strength
end

-- rate: buckets per second.
-- opts: minBpm, maxBpm, center.
--
-- Returns bpm, period in seconds, and `clarity`: how far the winning lag stands
-- above the average of the whole tempo range. 1 means the answer is no better
-- than any other tempo in the range. Measured on the material this was written
-- for -- a Zoom capture of a band in a room -- deterministic noise scores 2.7, a
-- real song scores between 2.4 and 4.4, and a click track scores 21. So clarity
-- tells a click track from music; it does NOT reliably tell a right answer from
-- a wrong one, which is why the caller shows the number and lets it be typed
-- over rather than deciding on the user's behalf.
function M.tempo(strength, rate, opts)
  opts = opts or {}
  local min_bpm = opts.minBpm or 60
  local max_bpm = opts.maxBpm or 200
  local center = opts.center or 120
  local n = #strength

  local mean = 0
  for i = 1, n do mean = mean + strength[i] end
  mean = mean / n

  local x = {}
  for i = 1, n do x[i] = strength[i] - mean end

  local lo_lag = math.max(1, math.ceil(rate * 60 / max_bpm))
  local hi_lag = math.floor(rate * 60 / min_bpm)
  if hi_lag <= lo_lag or n < 2 * hi_lag then return nil end

  local best_lag, best_acf, best_score, spread = nil, nil, nil, 0
  for lag = lo_lag, hi_lag do
    local sum = 0
    for i = 1, n - lag do sum = sum + x[i] * x[i + lag] end
    local acf = sum / (n - lag)
    spread = spread + math.abs(acf)
    local bpm = 60 * rate / lag
    local weight = math.exp(-0.5 * (math.log(bpm / center, 2) / 0.9) ^ 2)
    local score = acf * weight
    if not best_score or score > best_score then
      best_lag, best_acf, best_score = lag, acf, score
    end
  end
  -- Nothing varying means nothing to hear a tempo in: a flat envelope has zero
  -- autocorrelation at every lag, and dividing the winner by it would report a
  -- tempo for digital silence.
  spread = spread / (hi_lag - lo_lag + 1)
  if spread <= 0 then return nil end

  -- the lag range already confines the answer -- an octave fold loop can never fire.
  local period = best_lag / rate
  return {
    bpm = 60 / period,
    period = period,
    clarity = math.max(0, best_acf / spread),
  }
end

-- Walks the beat from `start`, each step landing one lag past the PREVIOUS
-- SNAPPED beat rather than one lag along a rigid grid laid down at the top of
-- the song. That is the whole point: a band that drifts 1% is 2.4 s adrift by
-- the end of a four-minute song, tens of times further than the search radius,
-- so a fixed grid stops finding beats after the first minute and the warp gets
-- built from noise.
-- Returns the snapped indices and the total onset strength sitting on them.
local function track(strength, lag, radius, start)
  local n = #strength
  local indices, score = {}, 0
  local ideal = start
  while ideal <= n do
    local snapped = ideal
    for i = math.max(1, ideal - radius), math.min(n, ideal + radius) do
      if strength[i] > strength[snapped] then snapped = i end
    end
    indices[#indices + 1] = snapped
    score = score + strength[snapped]
    ideal = snapped + lag
  end
  return indices, score
end

-- ponytail: snap-to-nearest-onset, not a DP beat tracker. Upgrade to Ellis-style
-- dynamic programming if songs with rubato or dropped beats come out wrong.
function M.beats(strength, rate, period)
  local n = #strength
  local lag = math.max(1, math.floor(period * rate + 0.5))
  if n < 2 * lag then return {} end

  -- radius stays well under half a beat, which is what keeps two snapped beats
  -- from crossing: a stretch marker pair whose source times run backwards makes
  -- REAPER reorder the markers and the warp comes back scrambled.
  local radius = math.floor(lag / 8)

  -- Phase by running the tracker from every start inside one beat and keeping
  -- the run that lands on the most onset energy. Scoring a rigid stride instead
  -- is cheaper and wrong: `lag` is the song's AVERAGE period, so on a drifting
  -- take a rigid stride is out of step with the opening bars by a bucket a beat
  -- and every offset scores like every other.
  local best_indices, best_score
  for start = 1, lag do
    local indices, score = track(strength, lag, radius, start)
    if not best_score or score > best_score then best_indices, best_score = indices, score end
  end

  local out = {}
  for i, index in ipairs(best_indices) do out[i] = (index - 1) / rate end
  return out
end

-- both coordinates are seconds from the start of the analysed span; converting
-- to item and source time is the caller's job.
function M.warp(beats, bpm)
  if #beats < 2 or bpm <= 0 then return {} end

  local out = {}
  local spacing = 60 / bpm
  for k = 1, #beats do
    local marker = { at = beats[1] + (k - 1) * spacing, from = beats[k] }
    local previous = out[#out]
    if not previous or (marker.at > previous.at and marker.from > previous.from) then
      out[#out + 1] = marker
    end
  end
  return out
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  local rate, nbeats = 100, 64
  -- an impulse per beat over a low deterministic ripple, so the array is not
  -- degenerate; `drift` stretches the last beat's period by that fraction.
  -- Returns the strength array and the times the beats really are at.
  -- The lead-in is not decoration: with beat one at bucket one, a phase search
  -- that never ran would still be right, and this file would be asserting
  -- nothing about it. A padded song region really does open with quiet.
  local LEAD = 0.37
  local function impulse_train(bpm, drift, train_rate)
    drift = drift or 0
    train_rate = train_rate or rate
    local spacing = 60 / bpm
    local n = math.floor((LEAD + nbeats * spacing * (1 + drift)) * train_rate + 0.5)
    local strength, truth = {}, {}
    for i = 1, n do strength[i] = 0.001 * ((i * 17) % 23) / 23 end
    for k = 0, nbeats - 1 do
      local time = LEAD + k * spacing * (1 + drift * k / nbeats)
      truth[#truth + 1] = time
      local i = math.floor(time * train_rate + 0.5) + 1
      strength[i] = strength[i] + 1
    end
    return strength, truth
  end

  local steady = (impulse_train(120))
  local estimate = M.tempo(steady, rate)
  assert(estimate, "120 BPM train produced no tempo")
  assert(math.abs(estimate.bpm - 120) < 1,
    ("120 BPM train recovered %.3f BPM"):format(estimate.bpm))
  assert(estimate.clarity > 10,
    ("120 BPM train clarity was %.2f, expected well above 10"):format(estimate.clarity))

  local drifted, truth = impulse_train(120, 0.02)
  local drift_estimate = M.tempo(drifted, rate)
  assert(drift_estimate, "drifting 120 BPM train produced no tempo")
  assert(math.abs(drift_estimate.bpm - 120) < 3,
    ("drifting 120 BPM train recovered %.3f BPM"):format(drift_estimate.bpm))
  local drift_beats = M.beats(drifted, rate, drift_estimate.period)
  assert(#drift_beats >= nbeats * 0.9,
    ("drifting train found %d beats, expected at least %.0f"):format(#drift_beats, nbeats * 0.9))
  for i = 2, #drift_beats do
    assert(drift_beats[i] > drift_beats[i - 1],
      ("beat %d landed at or before beat %d: %.3f s <= %.3f s")
        :format(i, i - 1, drift_beats[i], drift_beats[i - 1]))
  end

  -- The tracked beats must be the beats that are actually there, not a tidy grid
  -- near them. One bucket of tolerance; a rigid grid is a third of a beat out by
  -- the end of this fixture and fails here by a factor of thirty.
  for i = 1, math.min(#drift_beats, #truth) do
    assert(math.abs(drift_beats[i] - truth[i]) <= 2 / rate,
      ("beat %d tracked to %.3f s, really at %.3f s"):format(i, drift_beats[i], truth[i]))
  end

  -- The drift has to survive into the warp, or there is nothing for the stretch
  -- markers to correct. A constant grid crosses a linear ramp in the middle, so
  -- the residual is a parabola peaking around beat 32 at ~0.16 s here. The floor
  -- is what makes this a real check: with the snapping taken out, no residual can
  -- exceed the search radius, which is 0.06 s at this lag.
  local markers = M.warp(drift_beats, drift_estimate.bpm)
  local worst = 0
  for _, marker in ipairs(markers) do
    worst = math.max(worst, math.abs(marker.at - marker.from))
  end
  assert(worst > 0.12,
    ("largest drift residual was %.3f s, expected the fixture's drift to show"):format(worst))

  -- a beat list that goes backwards must lose the offending entry, not pass it on:
  -- REAPER reorders stretch markers whose srcpos is out of order, and the warp
  -- that comes back is nothing like the one that was asked for.
  local backwards = M.warp({ 0, 0.5, 0.4, 1 }, 120)
  assert(#backwards == 3, ("backwards beat survived the warp: %d markers"):format(#backwards))
  for i = 2, #backwards do
    assert(backwards[i].at > backwards[i - 1].at,
      ("at went backwards at marker %d: %.3f <= %.3f")
        :format(i, backwards[i].at, backwards[i - 1].at))
    assert(backwards[i].from > backwards[i - 1].from,
      ("from went backwards at marker %d: %.3f <= %.3f")
        :format(i, backwards[i].from, backwards[i - 1].from))
  end

  -- Clarity has to describe the audio. Something with no beat in it must not come
  -- back looking like a click track, or the number in the dialog is decoration.
  -- The gap is only this wide because the two ends are this far apart; real music
  -- lands between them, which the doc comment on M.tempo says out loud.
  local noise, seed = {}, 1
  for i = 1, 4000 do
    seed = (seed * 1103515245 + 12345) % 2147483648
    noise[i] = seed / 2147483648
  end
  local noisy = M.tempo(noise, rate)
  assert(not noisy or noisy.clarity < 5,
    ("noise came back at clarity %.2f"):format(noisy and noisy.clarity or 0))

  local flat = {}
  for i = 1, 400 do flat[i] = 0.5 end
  assert(M.tempo(flat, rate) == nil, "flat strength must not produce a tempo")
  local short = {}
  for i = 1, 199 do short[i] = i % 2 end
  assert(M.tempo(short, rate) == nil,
    ("%d buckets are shorter than two slowest lags but produced a tempo"):format(#short))

  local onset = M.onset_strength({ 0.1, 0.05, 0.2, 0, 0.3 })
  assert(onset[1] == 0, ("first onset strength was %.3f, expected 0"):format(onset[1]))
  for i, value in ipairs(onset) do
    assert(value >= 0, ("onset strength %d was negative: %.3f"):format(i, value))
  end

  -- octaves. A 60 BPM train has nothing at all on the half-beat, so 120 has no
  -- autocorrelation to stand on and 60 wins on the evidence, prior or no prior.
  local octave_rate = 90 -- integer bucket periods make the octave the only variable
  local slow = M.tempo((impulse_train(60, 0, octave_rate)), octave_rate)
  assert(slow and math.abs(slow.bpm - 60) < 1,
    ("60 BPM train recovered %s BPM, expected 60")
      :format(slow and ("%.3f"):format(slow.bpm) or "no"))

  -- A 180 BPM train, though, IS a 90 BPM train with a beat in between: the two
  -- readings fit the audio equally well and only the prior separates them, so
  -- the answer is the octave nearest 120 and it is 90, not 180. This is the
  -- documented limit of the estimator, not a bug -- it is why the caller shows
  -- the number and lets it be typed over. Asserted so nobody "fixes" the prior
  -- into silently preferring the other octave without noticing.
  local fast = M.tempo((impulse_train(180, 0, octave_rate)), octave_rate)
  assert(fast and math.abs(fast.bpm - 90) < 1,
    ("180 BPM train recovered %s BPM, expected the 90 BPM octave")
      :format(fast and ("%.3f"):format(fast.bpm) or "no"))
  local told = M.tempo((impulse_train(180, 0, octave_rate)), octave_rate, { minBpm = 130 })
  assert(told and math.abs(told.bpm - 180) < 1,
    ("with the 90 BPM octave out of range, 180 BPM train recovered %s BPM")
      :format(told and ("%.3f"):format(told.bpm) or "no"))

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
