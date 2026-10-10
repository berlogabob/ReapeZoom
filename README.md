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

Five actions over five shared libraries. Everything else is a native REAPER feature that just
needs the right settings — the scripts apply them for you.

| Job | How |
|---|---|
| Find the songs in a 90-minute rehearsal | `Split rehearsal recording into song regions` |
| Warp a song onto a steady grid at its own tempo | same action, `Tempo-align songs` on |
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
Threshold (dB below item peak)   auto   or a number; auto = first threshold whose song count holds 5 dB up
Min gap between songs (s)         8     shorter than your between-song chatter
Min song length (s)              90     longer than your longest bit of noodling
Region padding (s)                1.0   breathing room at each end
Set streaming render settings     y
Tempo-align songs                 n     off by default; see step 4
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

It creates regions named after the recording file — `261006-194759 01`, `261006-194759 02`, …. With tempo-align off it does not split, glue, or
otherwise touch the audio.

**Names carry the recording's file name**, so a night of several recordings never produces two
regions called `01`. Re-running only replaces the regions inside the item it was run on.

**4. Optional: tempo-align.** With `Tempo-align songs` set to `y`, it goes on to estimate each
song's tempo and warp that song onto a steady grid at that tempo, so the drift a band picks up
over four minutes is gone. Nothing is destroyed: the warp goes on a **second take** of the song,
and `T` (next take) flips between aligned and original.

It shows you what it found before writing anything:

```
01  3:34   92 BPM   clarity 3.1   drift 0.72 s
02  8:19  140 BPM   clarity 4.3   drift 0.82 s
03  5:07  140 BPM   clarity 3.4   drift 0.64 s
07  1:42   86 BPM   clarity 2.4   drift 1.05 s   CHECK
```

**Yes** writes the aligned takes, **No** lets you type the tempos yourself, **Cancel** leaves the
regions and stops. *Drift* is how far the played beat strays from a steady grid — what the warp
is there to remove. *Clarity* is how far the winning tempo stands above every other tempo in
range. On the material this was built for, deterministic noise scores 2.7, a real song 2.4 to
4.4, and a click track 21 — so clarity tells a click track from music, and does **not** tell a
right answer from a wrong one. Read it as "look at this one", not as a probability, and trust
your ears over the number.

The failure mode to expect is the octave: a 140 BPM song reported as 70, or a 90 as 180. Half or
double is what a tempo estimator gets wrong, and it is why the tempos are editable rather than
merely displayed. Type the right one and the warp is rebuilt from the beats already found.

Two consequences worth knowing before you turn it on:

- **It splits the item.** One item per song, plus whatever was between them, left alone. The
  long rehearsal item does not survive that, so to redo the whole take — different threshold,
  different settings — **undo first**. Run it again without undoing and it works on whatever is
  selected, which is now a single song, and replaces all the regions with that one song's. On a
  single song that is exactly right: it reuses that song's item and rewrites its aligned take
  rather than splitting again or stacking a third take.
- **The aligned take becomes the active one**, so `Cmd+Alt+R` now renders the aligned versions.
  Flip the takes back first if you want the originals.

One tempo is fitted per song. A song that speeds up deliberately in its last chorus is warped to
its average and will fight you; leave those on the original take.

**5. Rename.** `View → Region/Marker Manager`, type the real titles. Do this before rendering. Those names become the
filenames.

**6. Check the stereo** — `Check stereo and phase`. Reports correlation, L/R balance, DC offset
and mono compatibility, and offers to flip the polarity if the channels are inverted. See below
for why this matters even on a single-mic recording.

**7. Ride the levels** — `Ride levels into automation items`. One automation item per song region
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

**8. Render.** `Cmd+Alt+R`. With the render option left on, this is already set:

| Setting | Value |
|---|---|
| Bounds | All project regions |
| File name | `$region` |
| Format | MP3 320 kbps CBR, 48 kHz (ExtState `ReapeZoom/format` = `wav` for 24-bit WAV) |
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

## One-command library build

With `ffmpeg`, `ffprobe`, Lua, and NumPy installed, a complete library is one command:

```sh
python3 Tools/build_library.py Media/*.WAV --out Cajon --kit Cajon
```

It detects one-shots and long loop spans, freezes or reuses the articulation model, chooses
velocity layers per articulation, applies one kit-wide gain, and writes `Cajon.model`,
`Cajon.sfz`, `Cajon.dspreset`, `Cajon.md`, and the verified 24-bit stereo files under
`Cajon/Samples/`. The command fails if either preset names a missing sample, a sample is not
referenced, or an output clips.

Three parts are recording conventions, not facts discovered from the signal:

- **Four articulations (`k=4`)** means cajon bass/tone/edge/slap. The measured silhouette scores
  actually decline from k=2 through k=4, so choosing k automatically would produce the wrong
  musical instrument.
- **Velocity layers are chosen per articulation:** take the largest equal-count split up to 12
  layers that stays within 9 dB while preserving a round-robin floor, trying 5, 4, 3, then 2.
- **Left and right hand cannot be inferred** from the coincident X/Y capsule; the measured channel
  spread is only 0.54 dB. Same-timbre passes are therefore neutral `_A`/`_B`, never claimed as
  left or right.

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

# Recordings → library, in one command

The REAPER actions above want you to record one pass per sound type. When a session isn't
organised that way — sounds alternating, hits 1.5 s apart, grooves mixed in with one-hits —
this builds the whole library outside REAPER instead:

```sh
python3 Tools/build_library.py Media/*.WAV --out Cajon --kit Cajon
```

Needs `ffmpeg`, `ffprobe` and `numpy`. It detects hits and loops, clusters the hits by timbre,
picks velocity layers, cuts every sample, writes `<Kit>.sfz`, `<Kit>.dspreset`, `<Kit>.model`
and a `<Kit>.md` report, then verifies the result and **exits non-zero if the library is not
shareable** — a missing sample, a velocity hole, or anything clipping.

`Tools/build_library.py` owns the audio. Every *decision* is made by `Scripts/lib` through
`Tools/build_library.lua`, so the clustering, layering and preset logic stays where the
self-checks are.

### Adding to a library later

The cluster model is frozen into `<Kit>.model` on the first build and reused afterwards, so
articulation names and MIDI notes **do not move** when you add a recording. Point the same
command at the old and new files together. A corrupt model rebuilds from scratch rather than
failing.

### Three things that are conventions, not measurements

- **`-k`, the number of articulations.** Silhouette scores decline monotonically with k on every
  instrument tested — cajon 0.621 / 0.565 / 0.476 and boxstomp 0.571 / 0.549 / 0.484 for
  k = 2/3/4 — because struck-percussion timbre is a continuum, not separated blobs. An
  "automatic" k ships two articulations every time. 4 suits a cajon; boxstomp's one-hit material
  is genuinely two sounds. Pick it from the instrument and read the warnings.
- **The velocity layer count**, chosen per articulation: the most layers that keep every layer
  under 9 dB with at least 5 round robins, relaxing the round-robin floor only when nothing
  qualifies. The report says which floor it settled for.
- **`_A`/`_B` when a same-timbre pass is split in two.** Which one is your *left* hand is not in
  the audio — see below.

### Two gain stages, and why both exist

Sources are 32-bit float and routinely peak above 0 dBFS, so writing 24-bit PCM without gain
staging clips every loud hit. First each **source is aligned** on its own loudest contribution,
because a recorder gain change between takes otherwise masquerades as velocity — boxstomp's two
files sat 41.4 dB apart while each held an identical 29.9 dB of real dynamics, and cajon's sat
8.9 dB apart with ranges of 30.0 and 29.6 dB. Then **one gain for the whole kit** puts the
loudest sample at −1 dBFS. Never per sample: that would erase the level relationships the
velocity layers exist to encode.

### Loops are found by onset density, not level

A loop is a run of onsets that keep arriving; a one-hit is isolated. Timing survives a change of
recording level and amplitude thresholds do not. An absolute −40 dBFS floor found nine loops in
a file containing none, because on a +26 dBFS take the decay tails never drop below it so
"silence" never happens. A relative floor fails from both ends too: the value that isolates hits
fragments continuous playing, and one low enough to keep playing intact swallows a quiet file
whole. Measured median inter-onset interval is **0.12 s inside loops and 1.31 s between
one-hits** — an order of magnitude apart in the same session, with no knife edge in between.

---

## What this deliberately does not do

- **Phase correction.** The H1essential's X/Y capsules are coincident: L and R hit the same
  point in space at the same time. There is no phase error to correct on a single-recorder
  stereo capture.
- **Time-align the stereo pair.** Coincident capsules see the sound at the same instant; there
  is no offset to remove. Polarity, balance and DC *are* checked — see above.
- Both become real the day you add a second source — a phone video, a board feed, a second
  recorder. That's a separate script, not yet written.
- **Tell your left hand from your right.** Coincident capsules put both hands in the same place:
  measured L/R balance across 140 cajon hits is 1.39 dB mean with 0.54 dB spread, unimodal, and
  what variation there is tracks the *zone* struck rather than the hand. Same-timbre passes can
  be split into `_A`/`_B` by their gap in time; naming them is yours to do.
- **Decide how many articulations an instrument has.** See `-k` above. The tool clusters; the
  count is a musical judgement and the code says so.
- **Follow a tempo that changes on purpose.** One tempo is fitted per song. A deliberate push
  into the last chorus is drift as far as the estimator is concerned, and warping it away is not
  a fix. Nor does it decide the octave for you: 140 and 70 fit the same audio, so it shows the
  number it picked and lets you type over it.

## Status

Honest state of testing, because "it's on GitHub and CI is green" is not the same as "it works":

| | |
|---|---|
| Gap, onset and layer detection | **verified** — self-checks, plus the rehearsal detector run against a real 91-minute recording (14 songs, 2:17–5:59 each) |
| Tempo and beat detection (`lib/tempo.lua`) | **verified outside REAPER** — self-checks, every assertion mutation-tested (13 mutations, 13 caught), plus the detector run offline over 69 minutes of real rehearsal audio: 9 songs, 66–171 BPM, 0.5–1.1 s of drift each |
| Tempo alignment inside REAPER — the split, the second take, the stretch markers | **exercised against a stub, never run in REAPER.** The whole action was driven headless over a real 29-minute capture: 7 regions, 7 song items each with 2 takes, 3199 stretch markers, all of them item-relative and inside their take's slice of the source, identical whether the item sits at 0:00 or 5:00, and a second run reusing the item and take instead of splitting again. A stub cannot catch a `reaper.*` call REAPER rejects, and its own peak reader had to be corrected once before these numbers matched the audio |
| `Tools/build_library.py` end to end | **verified by execution** on two real sessions — a 481 s cajon session (211 hits, 7 loops, 197 samples) and a 279 s boxstomp session (132 hits, 3 loops, 121 samples). Both pass the built-in gate: no missing or unreferenced samples, no velocity holes, every round-robin cycle complete, loudest sample exactly −1.0 dBFS, nothing clipped |
| `cluster.lua` and `library.lua` | **verified** — every assertion mutation-tested: the guarded line was deleted, the self-check confirmed to fail, the line restored |
| Generated `.dspreset` | **verified** — parses under a real XML parser, velocity 1–127 covered with no gaps or overlaps, on both libraries |
| Generated `.sfz` | structurally asserted, **not yet loaded in a sampler** |
| Whether either library *sounds* right | **not verified.** Nothing here has been listened to. The structural checks cannot hear a hit filed under the wrong articulation — and 21 cajon hits and 14 boxstomp hits sat far enough from every centroid to be parked for review, which is exactly the material worth hearing |
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
- Take **stretch markers** put three frames on one line: the beat times come back from
  `lib/tempo.lua` measured from the start of the analysed span, a marker's position is measured
  from the start of the *item*, and its source position is measured into the *source file* and
  scaled by the take's playrate. All three coincide for an unsplit take at 0:00 played at 1×.

Note the pattern — every one of these is a case where the API documentation is silent and the two
frames coincide at zero. When you touch anything that converts between times, assume this is
happening until you have checked at a non-zero position.

Get either wrong and everything still looks perfect for an item starting at 0:00, because the
two frames coincide there. Both bugs shipped. Two projects in the repo exist only to make this
check one double-click — the item is already at 5:00 in both:

| | Item | For |
|---|---|---|
| `verify-offset.RPP` | `Media/260805-192929.WAV`, 91 min | regions and level riding |
| `verify-tempo.RPP` | `Media/flor/260820-205840.WAV`, 29 min | tempo alignment: 7 songs, 66–171 BPM |

Neither is committed with the audio — the `Media/` files are gitignored, so these open with an
offline item unless you have the recordings. `*.RPP` is gitignored too, so a verification project
only lands in the repo via `git add -f`; that is how `verify-offset.RPP` got there and how a third
one would. The check itself:

1. Open one of them, or put a long recording on a track and **drag it to 5:00**.
2. Run *Split rehearsal recording into song regions*.
3. Every region must start after 5:00. If the first one lands at 1:20 instead of 6:20, a
   coordinate frame is being mixed up.
4. Move the item back to 0:00, re-run, and confirm the times shift by exactly 5:00.
5. Undo back to one item, then run again with `Tempo-align songs = y`. On `verify-tempo.RPP` at
   the default −40 dB threshold that is a known quantity, which is the point of shipping the
   project:

   ```
   01   3:34   92 BPM   clarity 3.1   drift 0.72 s
   02   8:20  140 BPM   clarity 4.3   drift 0.82 s
   03   5:08  140 BPM   clarity 3.4   drift 0.64 s
   04   3:25  118 BPM   clarity 3.3   drift 1.00 s   TAIL 0.6 s
   05   1:59  171 BPM   clarity 3.7   drift 0.48 s
   06   1:34   66 BPM   clarity 4.4   drift 1.14 s
   07   1:43   86 BPM   clarity 2.4   drift 1.05 s   CHECK
   ```

   Then in the arrange: 13 items on the track — 7 songs with two takes each and 6 untouched
   pieces between them — every song item on its region's bounds, take 2 showing stretch markers,
   and `T` flipping between a take that is in time and one that is not. If the tempos match this
   table but the audio comes out wrong, the bug is on the `reaper.*` side, which is the half no
   self-check reaches.
6. Select one aligned song and run it again. It must reuse that item and rewrite its aligned take
   — no third take, no further split. The long item is gone by then, so this is what "re-run"
   means once alignment has happened.

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

## Working in the REAPER GUI

- **Preview** lists every song with start, end and length, not just counts.
- **Render format** (mp3/wav) is a field in the dialog.
- **Name the songs** asks for titles in order after you accept the preview; blank keeps the
  numbered names. Titles become `01 Title`, which is also the file name.
- **Peaks** still building: the action waits and carries on instead of asking you to retry.
- **Several selected items** are processed in turn; cancelling one dialog stops the rest.
- **`Rehearsal to masters`** walks stereo check, split, level ride, master, render and the final
  check, with an OK/Cancel prompt before each step. Each step keeps its own dialog.

## Mastering: `Master songs`

One action, two modes. **apply** picks a preset, trims the selected item so the master chain sees
-18 LUFS (a hot float capture otherwise slams the limiter), adds `ReapeZoom ReaComp` (2:1, -20 dB,
30/250 ms) and `ReapeZoom ReaLimit` to the master bus, and sets the render. Re-running updates the
same plug-ins instead of stacking them. Item volume is set absolutely, so it also does not trim
twice. **check** measures every `.wav`/`.mp3` in the render folder and writes
`ReapeZoom-masters.txt` with a verdict per file.

| Preset | Target | Ceiling | Format |
|---|---|---|---|
| `mp3` | -14 LUFS-I | -2.0 dBTP | MP3 320 |
| `streaming` | -14 LUFS-I | -1.0 dBTP | WAV 24 |
| `apple` | -16 LUFS-I | -1.0 dBTP | WAV 24 |
| `archive` | -18 LUFS-I | -1.0 dBTP | WAV 24 |

The MP3 ceiling is 1 dB lower on purpose: the encoder overshoots the limiter by up to ~0.6 dB, and
the check holds files to -1.0 dBTP. On the reference take this took true peak from -0.5…-0.8 to
-1.6…-1.8 dBTP. No EQ stage: ReaEQ exposes no band-enable parameter to a script. Measurements use
`CalculateNormalization` and agree with ffmpeg `ebur128` to 0.1.

## Unattended run

`Tools/headless_run.lua` runs the split action with no dialogs (batch mode: ExtState
`ReapeZoom/batch=1`), waits for peaks, saves and quits REAPER. Select the recording item, then:

```sh
reaper -nosplash Project.RPP Tools/headless_run.lua
reaper -nosplash -renderproject Project.RPP
```

Steps run in order (`REAPEZOOM_STEPS=split,master` by default; `check` measures the render).
Messages go to `reapezoom-batch.log` beside the project. Settings are at the top of the runner.
