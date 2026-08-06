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

Then Browse packages → install **ReapeZoom**. It registers three actions.

## What's in here

Three actions and a shared library. Everything else is a native REAPER feature that just needs
the right settings — the scripts apply them for you.

| Job | How |
|---|---|
| Find the songs in a 90-minute rehearsal | `Split rehearsal recording into song regions` |
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

It creates regions named `01`, `02`, … It does not split, glue, or otherwise touch the audio.

**4. Rename.** `View → Region/Marker Manager`, type the real titles. Those names become the
filenames.

**5. Render.** `Cmd+Alt+R`. With the render option left on, this is already set:

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

**1. Record one pass per sound type.** 20 kicks, pause, 20 taps, pause, 20 slaps. Vary how hard
you hit — that variation *is* the velocity layers. The pause is what separates the sound types;
a second or two is plenty.

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
(`Kick [36]`); otherwise notes run upward from 36 in track order.

**4. `Build sampler preset from tracks`.** Measures every hit, sorts it into velocity layers and
round robins, and lays the matrix out on the grid: **column = velocity layer**, position within
a column = round robin, with `v1`…`vN` markers. Every track uses the same X mapping, so a cell
with only two hits is obvious at a glance. Drag a misfiled hit into another column, delete a bad
one, run it again.

It warns when a layer spans more than ~9 dB. That matters: round robins are meant to sound
*alike* — they exist to kill the machine-gun effect — while velocity layers are *expected* to
differ. A wide layer produces round robins that don't match, and the fix is more layers.

**5. Select All Items → Render.** Settings are already applied: selected media items, `$item`
filenames, 24-bit WAV into `Samples/`, and **normalization off** — normalizing would erase the
dynamics the whole matrix encodes.

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
- **Delay compensation.** One track, one item, no plugins. REAPER's plugin delay compensation
  is automatic and already correct.
- Both become real the day you add a second source — a phone video, a board feed, a second
  recorder. That's a separate script; drop it in `Scripts/` and CI will pick it up.
- **Classify hit types automatically.** Telling a kick from a slap is an audio-ML problem. The
  one-pass-per-sound-type convention makes it unnecessary.

## Development

The action scripts are REAPER glue and can't run headless. All the testable logic lives in
`Scripts/lib/`, each file with a self-check:

```sh
lua Scripts/lib/envelope.lua   # gap + onset detection, velocity layering -> "ok"
lua Scripts/lib/preset.lua     # SFZ and dspreset writers -> "ok"
```

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

### Known limits

- Take playrate is assumed to be 1.0. A time-stretched take will produce misplaced regions.
- Sources with more than two channels are read as their first two.
- Velocity layering uses peak, not RMS or LUFS. Soft hits with long decays may land a layer low.
- Push events don't trigger CI on this repo for reasons I never pinned down; run it with
  `gh workflow run Check`.
