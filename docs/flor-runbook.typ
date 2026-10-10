// Runbook for splitting the 20 Aug 2026 "Flor" rehearsal recordings.
//
// Every dialog reproduced here is the literal text the action prints, captured
// by driving Scripts/berloga_Split rehearsal recording into song regions.lua
// headless over the four recordings in 2026-0820-Flor.RPP.
//
//   typst compile --font-path docs/fonts --ignore-system-fonts \
//     docs/flor-runbook.typ docs/flor-runbook.pdf

#import "lib.typ": *

#show: report.with((
  title: "Flor Rehearsal Runbook",
  author: ("berlogabob",),
  footer: "ReapeZoom 2.6 · 2026-0820-Flor.RPP",
))

// Tightened locally, not in lib.typ: a runbook is read standing at a machine,
// and every centimetre saved is one less page to scroll past mid-task.
#set par(spacing: 0.95em)
#show heading: set block(above: 1.15em, below: 0.55em)

// REAPER's modal text, reproduced literally. A raw block is monospaced already;
// hand-kerning it would be both fragile and a licence to paraphrase.
#let dialog(title, body) = block(
  width: 100%,
  breakable: false,
  above: 0.9em,
  below: 0.9em,
)[
  #block(
    width: 100%,
    fill: brand,
    inset: (x: 9pt, y: 4pt),
    radius: (top: radius-sm),
  )[#text(size: 7.5pt, weight: 600, fill: white, font: mono-font)[#title]]
  #block(
    width: 100%,
    fill: surface,
    stroke: 0.6pt + hairline,
    inset: (x: 9pt, y: 7pt),
    radius: (bottom: radius-sm),
  )[#set par(leading: 0.45em)
    #text(size: 7.6pt, fill: ink)[#raw(body, block: true)]]
]

// The number is the sequence, and the sequence is real: these are carried out
// in this order at the machine.
#let step(n, title, body) = block(breakable: true, above: 0.85em, below: 0em)[
  #grid(
    columns: (0.85cm, 1fr),
    gutter: 6pt,
    text(size: 9pt, weight: 700, fill: accent, font: mono-font)[#n],
    [
      #block(sticky: true, above: 0pt, below: 0.3em)[#text(size: 10pt, weight: 700)[#title]]
      #body
    ],
  )
]

#title-block(
  "Flor Rehearsal Runbook",
  subtitle: "Four recordings to fifteen tempo-aligned songs",
  meta-line: "20 August 2026 · ~/Documents/GitHub/ReapeZoom/2026-0820-Flor.RPP",
  standfirst: [Every dialog below is the script's literal output, captured from these four files.],
)

#kpi-row((
  ("4", "recordings", "one item each"),
  ("15", "songs", "1 + 1 + 7 + 6"),
  ("2", "takes per song", "aligned, original"),
  ("11", "steps", "setup to render"),
))

#callout(tone: "warn", title: "Before you start")[
  One selected item per run — four recordings, four runs. \
  Alignment splits the recording into one item per song. \
  ⌘Z undoes one whole run. \
  ReaPack has v2.5, which cannot align. Step 01 replaces it. \
  Splitting, the second take and the stretch markers have never run in REAPER. This is the first
  real run. The tempo numbers in step 07 come from these four files and should match.
]

= Setup

#step("01", "Load the new action")[
  The repo is already linked at `ReapeZoom-dev`. Point REAPER at the file.

  + *Actions → Show action list… → New action… → Load ReaScript…*
  + `~/Library/Application Support/REAPER/Scripts/ReapeZoom-dev/`
  + `berloga_Split rehearsal recording into song regions.lua`

  The new entry is highlighted. Assign it a shortcut now — the ReaPack entry has the same name.
  *Check:* the settings dialog has six rows, not five.
]

#step("02", "Save a copy")[
  *File → Save Project As…* → `2026-0820-Flor-split.RPP`. Undo goes back one run at a time.

  The project is 44.1 kHz, the recordings 48 kHz. The script corrects the project on the first run
  while `Set streaming render settings` is `y`.
]

= What is in the project

#data-table(
  ("Recording", "Starts", "Length", "Threshold", "Songs"),
  (
    (raw("260820-201537"), "0:16", "4:00", "−40", "1"),
    (raw("260820-202042"), "7:12", "2:53", "−40", "1"),
    (raw("260820-205840"), "12:48", "29:00", "−40", "7"),
    (raw("260820-212823"), "51:12", "36:26", "−25", "6"),
  ),
  widths: (1fr, auto, auto, auto, auto),
  right-from: 1,
)

The first two are single songs: one region each, no split. The last needs its threshold raised —
step 06. `260820-205410` is not in the project.

= The loop, four times

#step("03", "Select one recording")[
  Click the item. Run the action. Start with `260820-205840`.
]

#step("04", "Type the settings")[
  #dialog(
    "Split rehearsal into song regions",
    "Threshold (dB below item peak)        -40\nMin gap between songs (s)             8\nMin song length (s)                   90\nRegion padding (s)                    1.0\nSet streaming render settings (y/n)   y\nTempo-align songs (y/n)               y",
  )
  Defaults, except the last row starts at `n`. Type `y`. REAPER remembers it afterwards.

  Threshold is measured below the recording's own peak, not in absolute dBFS.
]

#step("05", "Read the threshold preview")[
  Nothing is created yet. This is what your setting and four neighbours would find.

  #dialog(
    "Split rehearsal -- what these settings find",
    "Threshold      Songs    Shortest - longest\n\n-50 dB        2       1:54 - 26:56\n-45 dB        4       1:34 - 19:55\n-40 dB        7       1:34 - 8:20   << your setting\n-35 dB        5       2:21 - 5:16\n-30 dB        5       2:11 - 3:46\n\nCreate regions with your current settings?\nYes = go ahead    No = change settings    Cancel = do nothing",
  )
  Seven songs, none over 8:20. Press *Yes*. *No* returns to the settings; *Cancel* writes nothing.

  One giant song means the threshold is too low. Many short ones mean it is too high and cutting
  inside songs. Take the row where the count settles and the longest is a plausible song.
]

#step("06", "Raise the threshold on the 36-minute recording")[
  `260820-212823` has a noisier room, so the gaps never get quiet enough:

  #dialog(
    "Split rehearsal -- what these settings find",
    "-50 dB        1       36:26 - 36:26\n-45 dB        1       36:26 - 36:26\n-40 dB        1       36:26 - 36:26   << your setting\n-35 dB        2       1:38 - 34:42\n-30 dB        4       1:38 - 19:43",
  )
  Press *No*, set `-30`, look again. The window slides with you:

  #dialog(
    "Split rehearsal -- what these settings find",
    "-40 dB        1       36:26 - 36:26\n-35 dB        2       1:38 - 34:42\n-30 dB        4       1:38 - 19:43   << your setting\n-25 dB        6       1:34 - 3:48\n-20 dB        4       1:58 - 3:27",
  )
  −25 gives six songs of 1:34 to 3:48; −20 loses them again. Press *No*, type `-25`, then *Yes*.
]

#step("07", "Read the tempo table")[
  #dialog(
    "Split rehearsal -- tempo alignment",
    "01   3:34   92 BPM   clarity 3.1   drift 0.72 s\n02   8:20  140 BPM   clarity 4.3   drift 0.82 s\n03   5:08  140 BPM   clarity 3.4   drift 0.64 s\n04   3:25  118 BPM   clarity 3.3   drift 1.00 s   TAIL 0.6 s\n05   1:59  171 BPM   clarity 3.7   drift 0.48 s\n06   1:34   66 BPM   clarity 4.4   drift 1.14 s\n07   1:43   86 BPM   clarity 2.4   drift 1.05 s   CHECK\n\nUse these tempos?\nYes = align    No = edit BPMs    Cancel = regions only",
  )
  To correct a tempo, press *No* and type all seven in order, comma-separated:
  `92, 140, 140, 118, 171, 66, 86`. The beats are found again at what you typed. Then *Yes*.

  #callout(tone: "warn", title: "Expect octave errors")[
    140 read as 70, or 92 read as 184. Both fit the audio; only a guess separates them. A song that
    plays half-speed on the aligned take is this. Undo, run again, type the tempo.
  ]
]

#step("08", "Check the result")[
  The 29-minute recording is now 13 items: 7 songs and 6 offcuts. Each song has two takes, aligned
  on top and playing.

  Press *T* to flip takes. On the same bar, the aligned take holds the grid and the original drifts.
  Pitch must not change.

  Return to step 03 for the next recording.
]

= After all four

#step("09", "Rename every region")[
  *View → Region/Marker Manager.* Numbering restarts at `01` per recording, so four regions are
  called `01`. Rendering uses the region name as the filename: four regions called `01` render to
  one file, three of them overwritten. Rename before rendering.
]

#step("10", "Optional passes")[
  *Check stereo and phase* — correlation, L/R balance, DC offset; offers a polarity fix. \
  *Ride levels into automation items* — evens chorus against verse with an editable gain curve.
]

#step("11", "Render")[
  *⌘⌥R.* Set from step 04: all project regions, `$region` filename, 24-bit WAV at 48 kHz,
  −14 LUFS-I, −1 dBTP brickwall.

  The aligned take renders, because alignment left it active. Press *T* first for the original.
]

= Reference

#data-table(
  ("Term", "Meaning"),
  (
    ([Threshold], [Silence, measured below the recording's own peak. Lower tolerates quieter passages.]),
    ([Min gap], [Quiet long enough to end a song. Raise it when one song splits in half.]),
    ([Min song length], [Anything shorter is discarded. Raise it when chatter becomes a song.]),
    ([Region padding], [Room at each end, so a region clips neither the first hit nor the last ring.]),
    ([clarity], [How far the winning tempo stands above the rest. Noise 2.7, song 2.4–4.4, click 21. Separates music from noise, not right from wrong.]),
    ([drift], [How far the band strayed from a steady grid. This is what alignment corrects.]),
    ([CHECK], [Clarity under 3.0. Listen before trusting the number.]),
    ([TAIL], [The grid overruns the song by this much; that stretch plays unwarped. Another BPM shrinks it.]),
  ),
  widths: (auto, 1fr),
  right-from: none,
)

#data-table(
  ("Symptom", "Fix"),
  (
    ([One region over the whole recording], [Threshold too low. *No*, raise 10 dB, look again.]),
    ([A song cut in half], [Raise *Min gap*.]),
    ([Tuning became a song], [Raise *Min song length*.]),
    ([Aligned take at half or double speed], [Octave error. Undo, run again, type the tempo.]),
    ([The end of a song plays loose], [That is `TAIL`. Try a BPM one either side.]),
    ([Both takes sound identical], [Same take. Press *T* and watch the take name.]),
    ([Five rows in the settings dialog], [ReaPack v2.5. Back to step 01.]),
  ),
  widths: (auto, 1fr),
  right-from: none,
)
