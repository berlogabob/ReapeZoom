# ReapeZoom

Long Zoom-recorder captures → finished material, in REAPER. Two pipelines:

- **A band rehearsal** → per-song files at streaming loudness.
- **A percussion sampling session** → a playable instrument with velocity layers and round
  robins, as `.sfz` and `.dspreset`.

Built for a Zoom H1essential capture (32-bit float stereo WAV), but nothing is specific to that
recorder.

## Install

ReaPack → **Import repositories** →

```
https://github.com/berlogabob/ReapeZoom/raw/main/index.xml
```

Then Browse packages → install **ReapeZoom**. It registers five actions.

## What's in here

Five actions over four shared libraries. Everything else is a native REAPER feature that just
needs the right settings — the scripts apply them for you.

| Job | How |
|---|---|
| Find the songs in a 90-minute rehearsal | `Split rehearsal recording into song regions` |
| Even out level *inside* a song | `Ride levels into automation items` |
| Polarity, balance, DC, mono compatibility | `Check stereo and phase` |
| Split a sampling session into individual hits | `Split percussion recording into hits` |
| Velocity layers, round robins, SFZ + Decent Sampler | `Build sampler preset from tracks` |
| Loudness for Spotify etc. | native render normalization (LUFS-I + true-peak brickwall) |
| One file per song / per sample, named | native: render bounds + `$region` / `$item` wildcards |
| Metadata / tags | native: render dialog → Metadata tab |

---

# Rehearsal → songs

## Workflow

**1. Sample rate.** Set the project to match the recorder — the H1essential records 48 kHz,
and a fresh REAPER project defaults to 44.1. The script sets this for you if you leave the
render option on.

**2. 32-bit float.** If the waveform looks clipped, it isn't. The reference recording here
peaks at **+20.9 dBFS** — a 32-bit float file can hold samples well above full scale and the
H1essential uses that headroom instead of clipping. Pull item volume down and the peaks
reconstruct intact. Do not reach for a clip-repair plugin. The render normalization below
applies a large negative gain anyway, so the exported files are correct even though the master
meter goes red while you monitor.

**3. Select the item and run the script.**

```
Threshold (dB below item peak)   -40    lower = more tolerant of quiet passages
Min gap between songs (s)         8     shorter than your between-song chatter
Min song length (s)              90     longer than your longest bit of noodling
Region padding (s)                1.0   breathing room at each end
Set streaming render settings     y
```

The threshold is **relative to the item's own peak**, not absolute dBFS, so it works the same
on a quiet capture and a hot one. Only these two knobs matter in practice: raise *min gap* if
one song gets split in half, raise *min song length* if tuning and talking show up as regions.

Leave the threshold at −40 unless the room is very noisy. Raising it to −35 or −30 does not
find fewer false positives — it eats into the quiet intros and outros and makes regions start
late. Use *min song length* to reject noodling instead; that's what it's for.

**It shows you the answer before committing.** After the settings dialog you get what nearby
thresholds would actually find:

```
Threshold      Songs    Shortest - longest

-50 dB         1       34:25 - 34:25
-45 dB         1       34:25 - 34:25
-40 dB         1       34:25 - 34:25   << your setting
-35 dB         7        2:23 - 5:58
-30 dB         7        2:23 - 5:58
```

**Yes** creates the regions, **No** takes you back to the settings with your numbers still in
them, **Cancel** does nothing. That example is the case worth having it for: at −40 you would
get one 34-minute region and reasonably conclude the detector was broken, when −35 finds the
seven songs. A noisy room raises the floor, and this is how you see that in one step instead of
by running and undoing.

The sweep re-runs detection five times on peaks that are already in memory — about 90 ms on a
91-minute take, so it is not worth avoiding.

It creates regions named `01`, `02`, … It does not split, glue, or otherwise touch the audio.

**4. Rename.** `View → Region/Marker Manager`, type the real titles. Those names become the
filenames.

**5. Check the stereo** — `Check stereo and phase`. Reports correlation, L/R balance, DC offset
and mono compatibility, and offers to flip the polarity if the channels are inverted. See below
for why this matters even on a single-mic recording.

**6. Ride the levels** — `Ride levels into automation items`. One automation item per song region
on the track volume envelope. Select several items and it measures them all, then rides each one.

It **measures first**: before the dialog you get peak, loud, quiet and the dynamic range between
them, per item. Pick the target from those numbers instead of guessing.

```
Max boost (dB)                    6
Max cut (dB)                      6
Response (s)                     15   how far back it looks; longer = gentler
Max change (dB/s)               0.5   a full 6 dB move takes 12 s, so it cannot pump
Noise floor (dB below target)    20   below this it holds instead of boosting
Target range (dB; 0 = flat)     ...   prefilled from what it just measured
```

Then **look at the envelope**. That's the whole point of using automation items rather than a
compressor — the curve is visible and draggable, and you can toggle one song's item off to A/B
it. On the reference recording these defaults produce ~80 points per song.

It only ever rewrites automation items it created itself. If the envelope holds anything else —
an item you made, or points you drew by hand inside a region — it stops and says so rather than
overwriting your work.

**7. Render.** `Cmd+Alt+R`. With the render option left on, this is already set:

| Setting | Value |
|---|---|
| Bounds | All project regions |
| File name | `$region` |
| Format | WAV, 24-bit PCM, 48 kHz |
| Normalize | **−14 LUFS-I** |
| Brickwall limit | **−1 dBTP** (true peak) |
| Fades | 10 ms in, 50 ms out |

Normalization is applied per rendered file, so every song lands at −14 LUFS-I on its own.

### Why −14 LUFS / −1 dBTP

Spotify, YouTube and Amazon normalize playback to −14 LUFS-I; Apple Music to −16. They turn
loud masters **down** and never turn quiet ones up, so one master at −14 LUFS-I with −1 dBTP
of true-peak headroom plays back correctly everywhere and survives lossy transcoding without
inter-sample clipping.

Deliver 24-bit WAV to your distributor. Not MP3 — they make the MP3.

### Riding is not normalization

They solve different problems and you want both:

| | Fixes | Scope |
|---|---|---|
| **Render normalization** | how loud the song is | one static gain for the whole file |
| **Level riding** | how loud the *chorus* is against the *verse* | a curve, moment to moment |

Normalization cannot help a quiet verse against a loud chorus — it moves the whole file by one
number. A compressor could, but it reacts blind, can't look ahead, and colours the sound. An
offline curve sees the whole song, adds no distortion, and is visible and editable afterwards.
That's what automation items are for.

It measures first. Before the dialog appears you get the numbers for every selected item — peak,
how loud the loud parts are, how quiet the quiet parts are, and the **dynamic range** between
them. Pick the target from those numbers rather than guessing.

The three knobs that matter:

- **target range** — how much of that gap to leave behind, in dB. `0` flattens everything to one
  level. Setting it to the range you were just shown does nothing at all. Anything larger is
  clamped: this tames dynamics, it never expands them.
- **response** — how far back it looks. Longer is gentler.
- **max change** — how fast the gain may move.

The defaults are deliberately slow. If you can *hear* the riding, lengthen the response or lower
the max change. Note that **max boost** and **max cut** still cap the correction, so asking for a
very small target range on very dynamic material will stop at the cap rather than reach the target.

The **noise floor** setting is the one that stops it ruining a live recording: below that level
the gain *holds* instead of boosting. Without it, every gap between songs gets the room noise
ridden up to full volume.

Select several items and it measures them all, then rides each one.

### Why check stereo on a single-mic recording

The H1essential's X/Y capsules are coincident, so there is no timing offset between L and R and
nothing to align. But four things can still be wrong, and all are measurable:

- **Polarity inversion** — a cable or hardware fault. The stereo image nearly vanishes when
  summed to mono. Fixed on request via `utility/chanmix2`, added **to the take**, not the track —
  the diagnosis came from one item, and a track FX would invert every other item sharing that
  track as well.
- **L/R imbalance** — the band stood off-centre. Reported, never auto-corrected: a band really
  can be louder on one side, and "fixing" that would be wrong.
- **DC offset** — wastes headroom and thumps at edits. Reported with the fix (20 Hz high-pass).
- **Mono compatibility** — Spotify plays in mono on plenty of devices, so this is a release
  concern, not a purist's footnote.

Correlation is estimated from 20 half-second windows sampled across the file rather than decoding
every frame; the report says how much was measured. On an item shorter than the window it reads
the item once rather than repeatedly overrunning both ends.

Re-running the check **after** the polarity fix still reports the original negative correlation.
That is not a failed fix: the measurement reads the take's source audio through an audio
accessor, which is upstream of take FX. Judge it by ear, or by the fact that the item now sums to
mono properly.

---

# Percussion → sampler instrument

The organising idea is a **3-axis matrix**:

| Axis | Comes from | Becomes |
|---|---|---|
| Articulation | one **track** per sound type | one MIDI note, one preset group |
| Velocity layer | measured **loudness** of each hit | `lovel`/`hivel` (SFZ), `loVel`/`hiVel` (DS) |
| Round robin | k-th hit **within** a (track, layer) cell | `seq_position` / `seqPosition` |

Filenames encode all three — `Kick_v2_rr3.wav`. Both preset files are two renderings of the
same matrix.

## Workflow

**1. Record one pass per sound type.**

| | |
|---|---|
| Sound types | one contiguous pass each — cajon **kick** (centre, full hand), **tap** (edge, fingertips), **slap** (top corner), **clap** |
| Hits per type | ~20: five each at soft / medium / hard / very hard |
| Order within a pass | **mixed, not a rising ramp** — a misdetected layer should stand out, not hide in the sequence |
| Between hits | ~0.5 s (the detector merges anything closer than 80 ms) |
| Between passes | ~3 s of silence (the default gap setting is 1.5 s) |
| Room | quiet — the threshold is relative to each pass's own peak, so noise raises the floor and eats soft hits |
| Mic | 30–50 cm back, 32-bit float on, ignore apparent clipping |
| Total | ~3–4 minutes |

The force variation *is* the velocity layers — 20 hits supports the default 4 layers × 5 round
robins. Serious commercial libraries target roughly 6 × 5; record more hits and raise the layer
count if you want that.

**2. Select the item → `Split percussion recording into hits`.** Passes become tracks
(`Sound 1`, `Sound 2`…), hits become items named with their peak in dB.

```
Hit threshold (dB below pass peak)  -30   lower = picks up softer hits
Min time between hits (ms)           80   suppresses a bounce being counted twice
Pre-roll (ms)                         5   keeps the attack intact
Tail (ms)                          1500   truncated early if the next hit arrives
Gap between sound types (s)         1.5   your pause between passes
Min pass length (s)                 2.0
```

**3. Rename the tracks** to `Kick`, `Tap`, `Slap`, `Clap`. Add `[36]` to pin a MIDI note
(`Kick [36]`); otherwise notes run upward from 36 in track order. A pin outside 0–127 is not a
MIDI note and is ignored rather than written into a preset no sampler will load.

Track names become filenames, and two names that reduce to the same slug — `Tap & Slap` and
`Tap / Slap` both give `Tap_Slap` — are disambiguated so one articulation cannot overwrite the
other's samples.

**4. `Build sampler preset from tracks`.** Measures every hit, sorts it into velocity layers and
round robins, and lays the matrix out on the grid: **column = velocity layer**, position within
a column = round robin, with `v1`…`vN` markers. Every track uses the same X mapping, so a cell
with only two hits is obvious at a glance. Drag a misfiled hit into another column, delete a bad
one, run it again.

It warns when a layer spans more than ~9 dB. That matters: round robins are meant to sound
*alike* — they exist to kill the machine-gun effect — while velocity layers are *expected* to
differ. A wide layer produces round robins that don't match, and the fix is more layers.

**5. Select All Items → Render.** Settings are already applied: selected media items, `$item`
filenames, 24-bit stereo WAV into `Samples/`, and **normalization off** — normalizing would erase
the dynamics the whole matrix encodes. Sample rate, channel count and format are all set
explicitly, so a project last used for a mono bounce cannot quietly render the kit in mono.

**6. Play it.** `<Project>.sfz` and `<Project>.dspreset` sit next to the project.

### Why both formats

SFZ is the open one — plain text, royalty-free spec, read by sfizz, LinuxSampler, liquidsfz,
OpenMPT, Bitwig and HISE. Decent Sampler's player is closed source, which makes it the
convenient option but the weaker archive. Keep the `.sfz`, play the `.dspreset`.

Serious libraries aim for roughly 6 velocity layers × 5 round robins. Four layers is a sane
default for a hand percussion instrument; record more hits and raise it.

---

## What this deliberately does not do

- **Phase correction.** The H1essential's X/Y capsules are coincident: L and R hit the same
  point in space at the same time. There is no phase error to correct on a single-recorder
  stereo capture.
- **Time-align the stereo pair.** Coincident capsules see the sound at the same instant; there
  is no offset to remove. Polarity, balance and DC *are* checked — see above.
- Both become real the day you add a second source — a phone video, a board feed, a second
  recorder. That's a separate script, not yet written.
- **Classify hit types automatically.** Telling a kick from a slap is an audio-ML problem. The
  one-pass-per-sound-type convention makes it unnecessary.

## Status

Honest state of testing, because "it's on GitHub and CI is green" is not the same as "it works":

| | |
|---|---|
| Gap, onset and layer detection | **verified** — self-checks, plus the rehearsal detector run against a real 91-minute recording (14 songs, 2:17–5:59 each) |
| Generated `.dspreset` | **verified** — parses under a real XML parser, velocity 1–127 covered with no gaps or overlaps |
| Generated `.sfz` | structurally asserted, **not yet loaded in a sampler** |
| Input validation in every action | **verified by execution** against a REAPER stub: a negative duration or amount is refused before any undo block opens |
| Library-load failure handling | **verified by execution** — a library that returns a non-table, or fails to parse, is reported instead of crashing mid-edit |
| Everything else that calls `reaper.*` | **not yet run in REAPER.** Control flow is exercised against a stub; REAPER's own behaviour is not |

The stub proves the scripts take the right path and clean up after themselves. It does **not**
prove REAPER does what the API docs say. Item and track creation, automation-item pooling, region
handling, the grid layout, the take-FX insert and render setup remain unexecuted against the real
application. Treat v2.x as untested there until that changes.

One question is genuinely open: whether envelope point times inside an automation item are
relative to the item or in project time. The ReaScript docs for `InsertEnvelopePointEx`,
`GetEnvelopePointEx`, `SetEnvelopePointEx` and `DeleteEnvelopePointRangeEx` are all silent on it.
The code assumes item-relative, which is consistent with its own `-1 .. len+1` delete range. Until
someone runs a probe in REAPER, that assumption is exactly that.

### What the self-checks are worth

Every non-trivial assertion in `Scripts/lib/` has been **mutation-tested**: the fix it guards was
deleted, the self-check was confirmed to fail, and the fix restored. That matters because this
project already shipped a test that could not fail — the old clamp fixture produced a curve of
exactly 0.00 dB, so both the boost and cut clamps could be removed with CI still green.

A self-check that passes whether or not the code is correct is worse than no self-check, because
it is believed. If you add one, delete the line it protects and make sure it goes red.

## Verifying a change

**Always test with the item at a non-zero position.** This codebase has produced the same class
of bug twice, and both times it was invisible at 0:00:

- `GetMediaItemTake_Peaks`' `starttime` is *project* time, not item-relative (the API docs don't
  say so).
- `find_spans` returns offsets *from the start of the envelope*, not project time.
- Undecided, same family: envelope point times inside an **automation item**. Assumed
  item-relative; undocumented either way. See *Status*.

Note the pattern — every one of these is a case where the API documentation is silent and the two
frames coincide at zero. When you touch anything that converts between times, assume this is
happening until you have checked at a non-zero position.

Get either wrong and everything still looks perfect for an item starting at 0:00, because the
two frames coincide there. Both bugs shipped. The check that catches them:

1. Put a long recording on a track and **drag it to 5:00**.
2. Run *Split rehearsal recording into song regions*.
3. Every region must start after 5:00. If the first one lands at 1:20 instead of 6:20, a
   coordinate frame is being mixed up.
4. Move the item back to 0:00, re-run, and confirm the times shift by exactly 5:00.

The library self-check pins the pure half of this — a lead-in of silence must produce a span
starting at ~5 s — but only running it in REAPER covers the `reaper.*` side.

## Development

The action scripts are REAPER glue and can't run headless. All the testable logic lives in
`Scripts/lib/`, each file with a self-check:

```sh
for f in Scripts/lib/*.lua; do lua "$f"; done   # each prints "ok"
```

**Keep pure logic out of the action scripts.** CI runs the libraries and only syntax-checks the
actions, so anything that lives in an action is effectively untested. When an action grows a
function with no `reaper.*` call in it, move it to `Scripts/lib/` and assert it — that is how
`spans_for`, `max_peak`, the filename slugs and the track-name parser got covered.

`index.xml` is generated locally from the `@` headers — never edit it by hand. Bump `@version`
and add a `@changelog` entry, commit, then:

```sh
gem install reapack-index && brew install pandoc   # once; pandoc renders @about to RTF
reapack-index --commit --amend --name ReapeZoom \
  --url-template 'https://github.com/berlogabob/ReapeZoom/raw/$commit/$path'
git push
```

CI does not generate the index — it only checks. On every push it runs the self-check and
`reapack-index --check` to validate the headers, so there is one source of truth for
`index.xml` and no chance of local and remote diverging.

### Adding a script

This is **one** ReaPack package with several actions, not one package per script — ReaPack has no
dependency mechanism, so two packages cannot both `@provides` the same library file. Two
consequences, both of which have already caused bugs here:

- A new file is invisible until it is listed in `@provides` in
  `berloga_Split rehearsal recording into song regions.lua` (the package's primary file). Dropping
  a `.lua` into `Scripts/` is **not** enough — it will not be indexed, and a library left out
  makes the installed package crash on load. Use `[main]` for actions, `[nomain]` for libraries.
- `reapack-index` only re-reads a file when `@version` changes. Fixing a library without bumping
  the version leaves the index pointing at the old commit, so users keep getting the bug.

### Running from the repo

To test edits without a version bump and reinstall, symlink the whole `Scripts` folder:

```sh
ln -s "$PWD/Scripts" ~/Library/Application\ Support/REAPER/Scripts/ReapeZoom-dev
```

Then Actions → Show action list → New action → Load ReaScript, and pick the five
`berloga_*.lua`. Nothing in `lib/` is an action — don't load those.

It must be a **directory** symlink, not one per file: the scripts locate `lib/` relative to
themselves. And the name must not be `ReapeZoom` — that's where ReaPack installs the package,
and it would write into the repo.

### Known limits

- Sources with more than two channels are read as their first two.
- Velocity layering uses peak, not RMS or LUFS. Soft hits with long decays may land a layer low.
- Riding never *expands* dynamics. A target range larger than the measured one is clamped to
  "leave it alone".
- **Max boost** and **max cut** still cap the correction, so a very small target range on very
  dynamic material stops at the cap instead of reaching the target.
- The stereo check reads pre-FX audio, so it cannot see its own polarity fix (see above).
- Across several selected items the ride target is the **mean** of their measured ranges. Fine for
  one item, or for items from the same session; less so for a pile of unrelated material.

`Split percussion recording into hits` used to assume a take playrate of 1.0 and produced hits
pointing at the wrong source position on a time-stretched take. It now maps offsets through the
playrate and copies the rate and pitch settings onto each new take.
