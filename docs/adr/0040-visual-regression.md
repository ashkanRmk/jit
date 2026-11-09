# ADR-0040: Visual regression with an in-process offscreen snapshot harness

- Status: accepted
- Date: 2026-11-09
- Phase: P6
- Requirements: §18.4; design §4.6, §7 (spikes "glass offscreen", "library vs custom")

## Context
§18.4 asks for visual regression of the main screens in light and dark. Options: a third-party snapshot
library, XCUITest window screenshots, or a small custom harness. Jit's screens are AppKit (graph, diff) and
SwiftUI (new tab, switcher, palette). Spike results on the reference Mac (macOS 27.2):
- `cacheDisplay(in:to:)` of an offscreen window renders AppKit content and SwiftUI exactly and
  deterministically (two renders: 0 differing pixels) — but **not Liquid Glass**: glass is composited by the
  window server, so glass chrome hosted inside a view renders as an approximation (in one case a dark label on
  dark glass that the live window does not show).
- Text over a transparent background is not stable to compare (alpha anti-aliasing): ≈ 0.2–5.7 % of pixels
  flipped between runs. An opaque backdrop removed it.
- SwiftUI must get the appearance before its first render; setting it on the hosting view and pinning
  `colorScheme` removed an appearance race.
- No library handled AppKit + SwiftUI + appearance forcing better than ~150 lines of our own code, and none is
  needed elsewhere (no dependency added).

## Decision
- `Tests/FeaturesTests/SnapshotHarness.swift`: offscreen borderless window, fixed point size, fixed 2× bitmap,
  forced `NSAppearance` (aqua, darkAqua, accessibility high-contrast variants), opaque backdrop for hosted
  SwiftUI, two layout passes. Data comes from GitTestKit repositories (fixed dates and identities → fixed SHAs).
- Compare: a pixel differs if any RGBA channel differs by more than 6/255; a snapshot fails above 0.1 % differing
  pixels. A self-test proves a 1-pt shift fails. Failures write actual and diff PNGs to `$TMPDIR/jit-snapshots/`.
- Glass: content snapshots hide the glass chrome they host. Chrome is snapshotted in its **Reduce Transparency**
  rendering (opaque surfaces, forced with the `jitOpaqueChrome` environment value), which is exact offscreen.
  Live glass is reviewed with real window captures (`scripts/testing/screenshot.sh`) in `visual-review.md`.
- References live in `Tests/FeaturesTests/__Snapshots__/` with `os-version.txt`; on another macOS version the
  suite is disabled with that reason. Re-baseline deliberately: `UPDATE_SNAPSHOTS=1 swift test --filter
  SnapshotTests`, then review the PNG diff by eye.

## Consequences
- Fast (≈ 16 s), no app launch, no Screen Recording permission, no dependency.
- Live glass is not under automated regression; a glass regression is caught by the manual live-capture review.
- A macOS upgrade requires a deliberate re-baseline. Fonts and system colours are part of the reference.
