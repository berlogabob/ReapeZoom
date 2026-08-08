-- @noindex
-- Stereo health checks for a single stereo capture: L/R balance, DC offset,
-- polarity, and mono compatibility.
-- Runs standalone under `lua stereo.lua`.
--
-- What this does NOT do is time-align the channels. On a coincident X/Y pair
-- (the H1essential's built-in capsules) both channels see the sound at the same
-- instant, so there is no offset to remove. Polarity, balance and DC are a
-- different matter -- those are real faults and they are all measurable.

local M = {}

local function db(x) return 20 * math.log(math.max(math.abs(x), 1e-9), 10) end

-- chans: { [ch] = { {mx=,mn=}, ... } } from envelope.read_channels
-- Returns { balance_db =, dc = {per channel}, level_db = {per channel} }
function M.analyze_peaks(chans)
  local level, dc = {}, {}
  for c = 1, #chans do
    local sum, off, n = 0, 0, 0
    for _, p in ipairs(chans[c]) do
      local amp = math.max(math.abs(p.mx), math.abs(p.mn))
      if amp > 1e-6 then           -- ignore digital silence
        sum = sum + amp
        off = off + (p.mx + p.mn) / 2 -- asymmetry between the rails IS the DC
        n = n + 1
      end
    end
    level[c] = n > 0 and (sum / n) or 0
    dc[c] = n > 0 and (off / n) or 0
  end
  local balance = (#chans >= 2 and level[1] > 0 and level[2] > 0)
    and (db(level[2]) - db(level[1])) or 0
  return { level = level, dc = dc, balance_db = balance }
end

-- Pearson correlation of two equal-length sample arrays.
-- +1 = identical, 0 = unrelated, -1 = polarity inverted.
function M.correlation(l, r)
  local n = math.min(#l, #r)
  if n < 2 then return 0 end
  local sl, sr = 0, 0
  for i = 1, n do sl = sl + l[i]; sr = sr + r[i] end
  local ml, mr = sl / n, sr / n
  local num, dl, dr = 0, 0, 0
  for i = 1, n do
    local a, b = l[i] - ml, r[i] - mr
    num = num + a * b; dl = dl + a * a; dr = dr + b * b
  end
  if dl <= 0 or dr <= 0 then return 0 end
  return num / math.sqrt(dl * dr)
end

-- Turns measurements into plain sentences plus a machine-readable verdict.
-- corr may be nil when correlation could not be measured.
function M.report(peaks, corr, sampled_s)
  local lines, flags = {}, {}

  if corr then
    lines[#lines + 1] = ("Correlation  %+.2f  (from %.0f s sampled across the file)")
      :format(corr, sampled_s or 0)
    if corr < -0.5 then
      lines[#lines + 1] = "  -> Channels are POLARITY INVERTED. This will nearly vanish in mono."
      flags.polarity = true
    elseif corr < 0.2 then
      lines[#lines + 1] = "  -> Very wide or uncorrelated. Check how it sounds summed to mono."
      flags.wide = true
    else
      lines[#lines + 1] = "  -> Good mono compatibility."
    end
  else
    lines[#lines + 1] = "Correlation  not measured."
  end

  lines[#lines + 1] = ("Balance      %+.1f dB  (positive = right louder)"):format(peaks.balance_db)
  if math.abs(peaks.balance_db) > 3 then
    lines[#lines + 1] = "  -> Noticeably off-centre. Worth a listen -- but a band really can be"
    lines[#lines + 1] = "     louder on one side, so this is not corrected automatically."
    flags.balance = true
  else
    lines[#lines + 1] = "  -> Centred."
  end

  local worst = 0
  for c = 1, #peaks.dc do worst = math.max(worst, math.abs(peaks.dc[c])) end
  lines[#lines + 1] = ("DC offset    %.5f  (%.1f dBFS)"):format(worst, db(worst))
  if worst > 0.002 then
    lines[#lines + 1] = "  -> Enough to waste headroom and thump on edits. A 20 Hz high-pass fixes it."
    flags.dc = true
  else
    lines[#lines + 1] = "  -> Negligible."
  end

  return table.concat(lines, "\n"), flags
end

----------------------------------------------------------------------
-- self-check
----------------------------------------------------------------------

function M.selftest()
  -- correlation ------------------------------------------------------
  local a, b, inv, noise = {}, {}, {}, {}
  for i = 1, 2000 do
    local v = math.sin(i * 0.05)
    a[i] = v
    b[i] = v * 0.9 + math.sin(i * 0.37) * 0.05 -- same signal, slightly different
    inv[i] = -v                                -- polarity inverted
    noise[i] = math.sin(i * 1.7) * math.sin(i * 0.013) -- unrelated
  end
  assert(M.correlation(a, a) > 0.99, "identical must correlate ~1")
  assert(M.correlation(a, b) > 0.9, "similar must correlate high")
  assert(M.correlation(a, inv) < -0.99,
    ("inverted must correlate ~-1, got %.3f"):format(M.correlation(a, inv)))
  assert(math.abs(M.correlation(a, noise)) < 0.5, "unrelated must correlate low")
  assert(M.correlation({}, {}) == 0, "empty is safe")
  assert(M.correlation({ 1, 1, 1 }, { 2, 2, 2 }) == 0, "zero variance is safe")
  -- each guard separately: the both-constant case above exits on the left one,
  -- so the right-hand guard was never reached. Without it this is 0/0 = NaN,
  -- and NaN reads as "good mono compatibility" downstream.
  assert(M.correlation({ -1, 1, -1, 1 }, { 0, 0, 0, 0 }) == 0, "flat right channel is safe")
  assert(M.correlation({ 0, 0, 0, 0 }, { -1, 1, -1, 1 }) == 0, "flat left channel is safe")

  -- peaks ------------------------------------------------------------
  local chans = { {}, {} }
  for i = 1, 500 do
    chans[1][i] = { mx = 0.5, mn = -0.5 }   -- centred, no DC
    chans[2][i] = { mx = 0.25, mn = -0.25 } -- 6 dB quieter
  end
  local p = M.analyze_peaks(chans)
  assert(math.abs(p.balance_db + 6) < 0.2,
    ("balance %.2f, expected about -6 (right quieter)"):format(p.balance_db))
  assert(math.abs(p.dc[1]) < 1e-9 and math.abs(p.dc[2]) < 1e-9, "no DC expected")

  -- a rail offset shows up as DC
  local off = { {} }
  for i = 1, 500 do off[1][i] = { mx = 0.6, mn = -0.4 } end -- +0.1 offset
  local q = M.analyze_peaks(off)
  assert(math.abs(q.dc[1] - 0.1) < 1e-6, ("DC %.4f, expected 0.1"):format(q.dc[1]))

  -- reporting --------------------------------------------------------
  local _, flags = M.report(p, -0.9, 10)
  assert(flags.polarity, "negative correlation must raise the polarity flag")
  assert(flags.balance, "6 dB imbalance must be flagged")
  local _, clean = M.report(M.analyze_peaks(chans), 0.8, 10)
  assert(not clean.polarity, "healthy correlation must not flag polarity")
  local _, dcflag = M.report(q, 0.9, 10)
  assert(dcflag.dc, "0.1 DC offset must be flagged")

  -- a checker that never fires is not a checker: prove the clean path too
  local even = { {}, {} }
  for i = 1, 100 do even[1][i] = { mx = 0.5, mn = -0.5 }; even[2][i] = { mx = 0.5, mn = -0.5 } end
  local _, none = M.report(M.analyze_peaks(even), 0.95, 10)
  assert(not none.polarity and not none.balance and not none.dc,
    "a clean file must raise no flags")

  -- uncorrelated is its own verdict, between "inverted" and "fine". Untested,
  -- this branch could vanish and a genuinely wide recording would be called
  -- healthy.
  local wtxt, wide = M.report(M.analyze_peaks(even), 0, 10)
  assert(wide.wide, "correlation 0 must raise the wide flag")
  assert(not wide.polarity, "correlation 0 is not a polarity fault")
  assert(wtxt:find("mono", 1, true), "the wide warning must mention mono")

  -- and the boundary between the two verdicts behaves
  local _, stillwide = M.report(M.analyze_peaks(even), 0.19, 10)
  assert(stillwide.wide, "0.19 must still count as wide")
  local _, ok21 = M.report(M.analyze_peaks(even), 0.21, 10)
  assert(not ok21.wide, "0.21 must not be flagged wide")

  -- correlation is optional: an unreadable or silent take reports nil, and the
  -- report must say so rather than crash or quietly omit the line
  local ntxt, nflags = M.report(M.analyze_peaks(even), nil, 0)
  assert(ntxt:find("not measured", 1, true), "nil correlation must say 'not measured'")
  assert(not nflags.polarity and not nflags.wide, "nil correlation raises no correlation flag")

  -- digital silence must read as zero everywhere, not as an imbalance
  local sil = { {}, {} }
  for i = 1, 100 do sil[1][i] = { mx = 0, mn = 0 }; sil[2][i] = { mx = 0, mn = 0 } end
  local sp = M.analyze_peaks(sil)
  assert(sp.level[1] == 0 and sp.level[2] == 0, "silence has no level")
  assert(sp.dc[1] == 0 and sp.dc[2] == 0, "silence has no DC")
  assert(sp.balance_db == 0, ("silence reported balance %.2f"):format(sp.balance_db))
  local _, sflags = M.report(sp, nil, 0)
  assert(not sflags.balance and not sflags.dc, "silence must raise no flags")

  -- no channels at all is not a stereo file
  local none_ch = M.analyze_peaks({})
  assert(none_ch.balance_db == 0 and #none_ch.level == 0, "zero channels must be inert")

  return true
end

if not reaper then
  assert(M.selftest())
  print("ok")
end

return M
