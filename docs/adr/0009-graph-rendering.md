# ADR-0009: Graph rendering

- Status: accepted
- Date: 2026-11-09
- Phase: P2 (spikes S2, S3)
- Requirements: §5, §14, §15; ADR-0006

## Context
The graph must scroll at 60 FPS over 100k+ commits, append pages without moving rows on screen, and
stay opaque content under glass chrome. Options: SwiftUI `List`/`LazyVStack` (a view per row identity,
diffing on append), `NSCollectionView`, a single custom scrolling canvas, or a view-based `NSTableView`
with custom-drawn cells.

## Decision
- **View-based `NSTableView`** (`Features/GitGraph/GraphViewController.swift`), fixed row height, plain
  style, no header, zero intercell spacing, rows reused through `makeView(withIdentifier:)`.
  `numberOfRows` = loaded rows (+ WIP row, + end-of-history footer). Pages append with
  `insertRows(at:withAnimation: [])` inside a zero-duration animation group; no `reloadData` on append.
- **Cells draw themselves with Core Graphics**: `GraphCellView` (lanes and node from the row's
  `EdgeSegment`s — a row draws in isolation), `SubjectCellView` (all ref pills + subject in one
  `draw(_:)`, no subview per pill), `AuthorCellView` (initials avatar + name), `TextCellView`. Colours
  are resolved once per appearance into a `CGColor` table (`GraphColorTable`); vertical edges snap to the
  device pixel grid (`GraphMetrics.snap`).
- **Row materialization is synchronous on the main actor** (S3): `GraphRowCache` builds strings for
  visible rows in windows of 64, at most 16 windows.
- The table is opaque (`surface.canvas`); the scope menu, search and transient chips float above it
  in one `GlassEffectContainer` (`GlassControlGroup`), and rows scroll underneath.
- The graph column width follows the lanes of the rows on screen (grows at once, shrinks when a scroll
  ends), capped at 40 % of the table; lanes beyond 12 are drawn at 6 pt spacing and 50 % opacity.

## Measured (release, `JIT_BENCHMARK_GRAPH=1`, MacBook Pro Mac17,9, macOS 27.2, Git 2.54.0)
| Repository | scroll step (one screen, layout + display) | row draw | page append |
|---|---|---|---|
| 100k fixture | median 1.56 ms, p95 1.87 ms, max 10.9 ms, 0 of 400 > 16.7 ms | p95 0.012 ms | median 0.27 ms |
| git/git (86k) | median 1.57 ms, p95 1.76 ms, max 10.6 ms, 0 of 400 > 16.7 ms | p95 0.110 ms | median 0.30 ms |
| 10k fixture | median 1.56 ms, p95 1.94 ms, max 6.5 ms, 0 of 400 > 16.7 ms | p95 0.012 ms | median 0.29 ms |

S3: materializing rows (subject, author, dates, labels) happens inside those steps; a whole scroll step
including materialization stays under 2 ms at p95, so off-main materialization was not needed.

## Consequences
- The scroll numbers are main-thread cost per programmatic scroll step, not an Instruments Animation
  Hitches trace of a trackpad fling (that needs an interactive Instruments session; Phase 6 audit).
- No SwiftUI view or CALayer per historical commit; only visible rows have views.
- Rejected: SwiftUI `List` (identity per row, diffing on append), `NSCollectionView` (no advantage for a
  single column of fixed rows), a hand-rolled canvas (would re-implement selection, accessibility,
  type-select and keyboard navigation the table gives for free).
