# ADR-0011: Diff renderer

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6, §14, §19; ADR-0005, ADR-0006, ADR-0026

## Context
The diff body must scroll a 50,000-line diff at 60 FPS, paint a 2,000-line diff in under 50 ms, stay under
30 MB for 50k lines, align side-by-side rows exactly, and support line selection, copy and VoiceOver.
Candidates (design §4.8): (1) TextKit 2 (`NSTextView` + `NSTextLayoutManager`); (2) a custom virtualized
row renderer.

## Measurements (spike S1)
Release build, MacBook Pro Mac17,9 (M5 Pro), macOS 27.2, Git 2.54.0. Same documents for both (a file with
every 5th line changed, all context shown); offscreen 1000×800 window; first paint = build view + draw the
visible rect; scroll = 400 steps of three rows, each redrawing the whole visible rect (worse than real
scrolling, which draws only the exposed strip). `swift run -c release JitBench renderer-spike`.

| Renderer | Rows | First paint | Frame p50 / p99 / max | Frames > 16.7 ms | Footprint |
|---|---|---|---|---|---|
| CodeLinesView | 2,401 | 5.7 ms (28.2 ms cold, first run in process) | 0.83 / 1.38 / 1.75 ms | 0 / 400 | +18 MB |
| TextKit 2 | 2,401 | 52.7 ms | 2.41 / 29.2 / 54.7 ms | 18 / 400 | +43 MB |
| CodeLinesView | 60,001 | 8.0 ms | 0.83 / 1.05 / 1.53 ms | 0 / 400 | +12.6 MB |
| TextKit 2 | 60,001 | 910.7 ms | 12.9 / 721 / 1,409 ms | 19 / 400 | +102 MB |

(Footprint deltas include AppKit warm-up in the first run of each process; the diff document itself is
measured separately: 28 B/line beyond Git's output, ADR-0026.)

## Decision
The diff body (and blame, and the Phase 4 conflict resolver) uses **`CodeLinesView`**: an `NSView` in an
`NSScrollView` with a fixed row height, drawing only rows in the dirty rect, `CTLine`s cached for recently
drawn rows (bounded), gutters/backgrounds/change bars drawn directly, one or two columns (side by side
from the document's split table, so alignment is exact by construction). Line selection, copy (⌘C),
search highlights and accessibility (an `NSAccessibilityElement` per visible row) are explicit.
Standard AppKit/SwiftUI text stays for small read-only areas (headers, commit messages).
The TextKit 2 prototype was deleted after the measurement.

## Consequences
- Meets every numeric criterion with a wide margin; TextKit 2 failed the 2k first paint, the 50k scroll
  and the 50k memory target.
- Native text selection inside a line is not available (row-level selection only, which is what line
  staging needs; copy copies selected rows). Find is implemented in the viewer.
- Soft wrap needs variable row heights; not supported in V1 (horizontal scrolling instead).
