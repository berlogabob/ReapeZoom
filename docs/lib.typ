// Reusable report library for Typst 0.15.x.
//
// Verified against typst 0.15.1: table.header/table.footer, stroke/fill/align
// as (x, y) => ... callbacks, number-width: "tabular", context counter(page).
//
// HOW TO USE: copy this file next to your document, edit ONLY the TOKENS block
// below to match your brand, then `#import "lib.typ": *`.
//
// House rule inherited from the UNIDCOM report pipeline and worth keeping:
// **format every number before it reaches Typst.** Typst has no locale-aware
// number formatting, so thousands separators and decimal commas belong in
// whatever produced the data. Typst lays out strings; it does not do arithmetic.

// ---------------------------------------------------------------- TOKENS
// Swap these for your brand. Everything below is derived from them, so a
// rebrand is an edit to this block and nothing else.

#let brand = rgb("#14232A") // headings, table header fill, primary marks
#let accent = rgb("#0B6A6C") // ONE accent — rules, active marks, positive state
#let ink = rgb("#14232A") // body text
#let muted = rgb("#54666F") // secondary text, captions, footer
#let hairline = rgb("#D5DFE2") // rules, borders
#let surface = rgb("#F2F6F6") // callout / tile fill
#let zebra = rgb("#F8FBFB") // alternating table row

// Semantic status colours. Keep these distinguishable in greyscale by pairing
// them with a text label — never rely on hue alone (see reference/report-design.md).
#let ok = rgb("#15803D")
#let warn = rgb("#B45309")
#let bad = rgb("#B91C1C")
#let info = rgb("#1D4ED8")

// Vendored in docs/fonts, same as TypstSeq. Compile with --font-path so the
// build cannot silently pick up a different local copy.
#let body-font = ("Inter", "Noto Sans Symbols 2")
#let mono-font = "JetBrains Mono"
#let body-size = 9.5pt
#let radius-md = 6pt
#let radius-sm = 4pt

// ---------------------------------------------------------------- DOCUMENT
// Whole-document show rule. Use as: #show: report.with(meta)
// meta: (title, subtitle, footer, lang: "en", region: none)
#let report(meta, doc) = {
  set document(
    title: meta.title,
    author: meta.at("author", default: ()),
  )
  set page(
    paper: "a4",
    margin: (top: 2.1cm, bottom: 2.1cm, x: 2.2cm),
    // Footer only — never also set page(numbering:), the two conflict.
    footer: context {
      set text(size: 8pt, fill: muted)
      grid(
        columns: (1fr, auto),
        align(left, meta.at("footer", default: "")),
        align(right, counter(page).display("1 / 1", both: true)),
      )
    },
  )
  set text(
    font: body-font,
    size: body-size,
    fill: ink,
    lang: meta.at("lang", default: "en"),
    region: meta.at("region", default: none),
  )
  // Ragged right: justification without hyphenation opens rivers of whitespace.
  set par(justify: false, leading: 0.68em, spacing: 1.15em)
  set list(marker: text(accent)[•], indent: 0.3em, spacing: 0.85em)
  set enum(indent: 0.3em, spacing: 0.85em)

  // Three levels of hierarchy, distinguished by size AND weight, never colour alone.
  show heading: set block(above: 1.5em, below: 0.75em)
  show heading.where(level: 1): set text(size: 15pt, weight: 700, fill: brand)
  show heading.where(level: 2): set text(size: 11.5pt, weight: 700, fill: ink)
  show heading.where(level: 3): set text(size: 10pt, weight: 600, fill: muted)

  show link: set text(fill: info)
  show raw: set text(font: mono-font, size: 0.92em)
  // Tabular figures everywhere numbers get compared vertically.
  show table.cell: set text(number-width: "tabular")

  doc
}

// Title block: 22pt title, muted subtitle, accent rule, optional standfirst.
#let title-block(title, subtitle: none, standfirst: none, meta-line: none) = {
  block(above: 0pt, below: 1.1em)[
    #text(size: 22pt, weight: 700, fill: brand)[#title]
    #if subtitle != none [
      #linebreak()
      #text(size: 12.5pt, weight: 400, fill: muted)[#subtitle]
    ]
    #v(0.55em)
    #line(length: 100%, stroke: 2pt + accent)
    #if meta-line != none [
      #v(0.2em)
      #text(size: 8.5pt, fill: muted)[#meta-line]
    ]
    #if standfirst != none [
      #v(0.55em)
      #text(size: 10.5pt, fill: ink)[#standfirst]
    ]
  ]
}

// ---------------------------------------------------------------- MARKS
// Status pill. `tone` is one of: ok | warn | bad | info | neutral.
#let pill(label, tone: "neutral") = {
  let c = (ok: ok, warn: warn, bad: bad, info: info).at(tone, default: muted)
  box(
    fill: c.lighten(88%),
    radius: radius-sm,
    inset: (x: 5pt, y: 2.5pt),
    outset: (y: 2pt),
    text(size: 7.5pt, weight: 600, fill: c.darken(8%))[#label],
  )
}

// Callout / admonition. Left accent bar, tinted fill, no shadow.
#let callout(body, title: none, tone: "info") = {
  let c = (ok: ok, warn: warn, bad: bad, info: info).at(tone, default: brand)
  block(
    width: 100%,
    fill: c.lighten(94%),
    stroke: (left: 3pt + c),
    inset: (left: 11pt, rest: 9pt),
    radius: (right: radius-sm),
    breakable: false,
    above: 1.1em,
    below: 1.1em,
  )[
    #if title != none [
      #text(weight: 700, size: 9.5pt, fill: c.darken(12%))[#title]
      #linebreak()
    ]
    #body
  ]
}

// ---------------------------------------------------------------- TILES
// Row of KPI tiles. tiles: array of (value, label) or (value, label, note).
// Values are strings — format them upstream.
#let kpi-row(tiles, columns: auto) = {
  let n = if columns == auto { tiles.len() } else { columns }
  let gutter = 8pt
  let pad-x = 10pt
  let pad-y = 9pt
  let inner(t) = [
    #text(size: 7.5pt, weight: 600, fill: muted)[#upper(t.at(1))]
    #v(0.35em, weak: true)
    #text(size: 18pt, weight: 700, fill: brand)[#t.at(0)]
    #if t.len() > 2 [
      #v(0.2em, weak: true)
      #text(size: 7.5pt, fill: muted)[#t.at(2)]
    ]
  ]
  // Measure every tile at the width it will actually get, then set them all to
  // the tallest. Two things that do NOT work: grid rows equalise the CELL
  // height but a block inside still shrinks to its content, so one note
  // wrapping to a second line leaves the other tiles with ragged bottoms; and
  // `height: 100%` resolves the percentage against the page, which stretches
  // every tile to fill it.
  layout(size => {
    let w = (size.width - gutter * (n - 1)) / n
    let h = calc.max(..tiles.map(t => measure(block(width: w - 2 * pad-x, inner(t))).height))
    grid(
      columns: (1fr,) * n,
      gutter: gutter,
      ..tiles.map(t => block(
        width: 100%,
        height: h + 2 * pad-y,
        fill: surface,
        stroke: 0.6pt + hairline,
        radius: radius-md,
        inset: (x: pad-x, y: pad-y),
        inner(t),
      )),
    )
  })
}

// ---------------------------------------------------------------- TABLES
// Editorial data table: no vertical rules, hairline horizontals, zebra rows,
// first column left / rest right, repeating header, optional footer row.
// headers: array of strings. rows: array of arrays of content/strings.
// `right-from`: index of the first right-aligned column. Default 1 gives
// "label left, numbers right". Pass `none` for an all-text table — right-aligned
// prose is the single most common way these tables end up looking wrong.
#let data-table(headers, rows, widths: auto, total: none, right-from: 1) = {
  let cols = if widths == auto { (1fr,) + (auto,) * (headers.len() - 1) } else { widths }
  block(breakable: true)[
    #table(
      columns: cols,
      inset: (x: 7pt, y: 6pt),
      align: (x, y) => if right-from != none and x >= right-from { right } else { left },
      stroke: (x, y) => (
        top: if y == 1 { 0.7pt + brand } else { none },
        bottom: if y == 0 { 0.7pt + brand } else { 0.4pt + hairline },
      ),
      fill: (x, y) => if y > 0 and calc.odd(y) { zebra },
      table.header(..headers.map(h => text(weight: 700, size: 8.5pt)[#h])),
      ..rows.flatten(),
      ..if total != none {
        (table.footer(..total.map(c => text(weight: 700)[#c])),)
      } else { () },
    )
  ]
}

// Scorecard: one row per item with a status pill. Deliberately NOT a
// traffic-light grid — the label carries the meaning, the colour only echoes it.
// items: array of (label, status, tone, note)
#let scorecard(items) = {
  block(breakable: true)[
    #table(
      columns: (auto, 1fr, auto),
      inset: (x: 7pt, y: 7pt),
      align: (x, y) => if x == 2 { right } else { left } + horizon,
      stroke: (x, y) => (bottom: 0.4pt + hairline),
      fill: none,
      ..items
        .map(it => (
          text(size: 9pt, weight: 600)[#it.at(0)],
          text(size: 8.5pt, fill: muted)[#it.at(3)],
          pill(it.at(1), tone: it.at(2)),
        ))
        .flatten(),
    )
  ]
}

// Horizontal bar row — a chart without a charting package. `frac` is 0.0–1.0.
#let bar-row(label, value, frac, tone: "info") = {
  let c = (ok: ok, warn: warn, bad: bad, info: info).at(tone, default: accent)
  grid(
    columns: (5.5cm, 1fr, 1.6cm),
    gutter: 7pt,
    align: horizon,
    text(size: 8.5pt)[#label],
    box(width: 100%, height: 7pt, fill: hairline, radius: 3.5pt)[
      #place(left, box(width: frac * 100%, height: 7pt, fill: c, radius: 3.5pt))
    ],
    align(right, text(size: 8.5pt, weight: 600, number-width: "tabular")[#value]),
  )
}

// Definition row for key/value facts that aren't a full table.
#let fact(key, value) = grid(
  columns: (4.2cm, 1fr),
  gutter: 8pt,
  text(size: 8.5pt, fill: muted)[#key],
  text(size: 9pt)[#value],
)
