# Phase 6 — visual review, Liquid Glass audit, motion inventory

Reference Mac: MacBook Pro `Mac17,9` (M5 Pro), macOS 27.2. Captures: `screenshots/` (live window captures via
`scripts/testing/screenshot.sh`, glass composited by the window server) and the offscreen regression references
in `macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/` (ADR-0040).

## 1. Findings and fixes

| Screen | Finding | Fix | Evidence |
|---|---|---|---|
| Command palette | Placeholder ("Search commands, branches, files, repositories") truncated into the prefix hint text | Shorter placeholder; prefix scopes as five compact key chips with tooltips | `screenshots/command-palette-empty-{light,dark}.png` |
| Command palette | Empty query listed About Jit / Settings first | Empty state orders repository → branch → view → edit → file → window → help → app commands, recents first | same |
| Command palette | Panel slid down while the result list shrank (found by driving ⌘K → `@inspector-2006`) | Panel sizes from content with the top edge anchored | 428 → 100 pt at the same top (window bounds), commit `35d4244` |
| Diff (5 MB minified line) | 1.2 GB footprint, view millions of points wide | Lines laid out up to 10,000 characters + "+N characters not shown"; width capped | footprint 1,218 → 204 MB |
| Tab strip | Selection still morphed (linear) under Reduce Motion | No morph under Reduce Motion | `MotionPolicyTests` |
| Activity checkmark | Literal 0.16 / 0.2 s durations | `MotionToken.feedbackIn/Out` | `MotionPolicyTests.noLiteralAnimationDurations` |
| Workbench overlay, profile capsule | Animated with Reduce Motion on | Instant under Reduce Motion | `MotionPolicyTests` |
| Diff / tab status | Meaning carried by colour only | Differentiate Without Color: +/− gutter glyphs; square (operation) and diamond (danger) status dots | `AccessibilityTests`, code review |
| Composer, banner, resolver, blame, diff, graph bar | `.buttonStyle(.glass…)` used directly (bypassed helpers, `-JitOpaqueChrome` and the audit) | All through `primaryGlassButton()` / `secondaryGlassButton()`; lint forbids direct use | `GlassPolicyTests`, `lint.sh` |

Per-screen checklist (design §3.3) — spacing, alignment, typography, colour tokens, contrast, states, density, dark
tuning — was re-checked on the new-tab page, graph, diff (unified/split), profile switcher and palette in light and
dark (snapshots above). Token use is enforced by `StylingLintTests` (no literal colours/fonts outside
DesignSystem) and contrast by `ContrastTests` (all four variants: light, dark, light/dark high contrast; body
text ≥ 4.5:1, tertiary and lane lines ≥ 3:1, text on diff backgrounds ≥ 4.5:1). No new violations were found.
Not re-reviewed by eye this phase: settings panes, repository browser, conflict resolver, clone sheet (unchanged
since their Phase 4/5 screenshots; listed as carry-over).

## 2. Liquid Glass inventory (ADR-0006)

| Surface | Mechanism | Container | Notes |
|---|---|---|---|
| Window toolbar, sidebar | System (`NSToolbar` unified, `NSSplitViewItem` sidebar) | system | Not affected by `-JitOpaqueChrome` |
| Tab strip | `GlassTabStrip` + `glassTab` | one `GlassEffectContainer` | Morph only on user selection; none under Reduce Motion |
| Profile capsule, switcher actions | `jitGlass`, glass buttons | toolbar item / popover | Popover itself is system |
| Graph command bar | `GlassControlGroup` | one per bar | Floating over the graph, not in rows |
| Diff chrome bar, selection capsule | `GlassControlGroup`, `jitGlass(Capsule)` | one per bar | Floating |
| Blame bar, resolver toolbar/action bar | `GlassControlGroup`, glass buttons | one per bar | Floating / docked bottom bar |
| Composer action bar | `jitGlass(Rectangle)` + glass buttons | bar | Docked bottom bar |
| Operation banner | `tintedGlassBar` (status tint) | bar | Text uses label colours |
| New-tab actions | glass buttons | — | One prominent (accent-tinted) action |
| Command palette | `jitGlass(RoundedRectangle)` | one panel | System label colours; accent selection fill |

Content layer: no glass on graph rows, diff lines, file rows, navigator, inspector body or resolver panes —
`GlassPolicyTests` pins glass to the allowlisted chrome files, and lint forbids raw `glassEffect`,
`NSGlassEffectView`, `NSVisualEffectView`, `CIFilter`, `.blur(radius:)` and `buttonStyle(.glass…)` in
features. Reduce Transparency: every custom surface switches to `surface.chromeOpaque` + `border.strong`
(snapshot variants `*-rt`); Increase Contrast adds explicit edges (snapshot variants `*-ic`, palette border).
Legibility: palette over the dense graph checked in light and dark captures.

**Cost** (`scenarios/glass-cost.sh`, huge-100k, glass vs `-JitOpaqueChrome`, single runs): Jit idle energy
0.017 vs 0.015 (no idle glass cost, 0 GPU ms/s for Jit); graph scroll steps median 1.71 vs 1.80 ms, p95 2.02 vs
2.09 ms, 0 of 400 steps over 16.7 ms in both; Jit energy while scrolling 948 vs 843 (+12 %), during stepped
resizes 131 vs 105. Glass compositing happens in WindowServer, whose per-process GPU counter reads 0 on this
machine and whose energy is dominated by other apps, so the compositor-side cost could not be attributed
(Instruments Metal System Trace by hand is the follow-up). Tab switch median 17.2 ms glass vs 15.8 ms opaque.

## 3. Motion inventory

| Animation | Where | Duration / curve | Reduce Motion | Idle after |
|---|---|---|---|---|
| Tab selection glass morph | `TabStrip` | `motion.glassMorph` 220 ms smooth | none (instant) | one-shot |
| Tab drag reorder | `TabStrip` | `motion.select` 150 ms | none | one-shot |
| Graph bar reveal (search/overflow) | `GraphBar` | `motion.panel` 200 ms, `RevealTransition` | opacity / none | one-shot |
| Graph hover (cell highlight) | `GraphCells` | `motion.hover` 100 ms (CATransaction) | instant | one-shot |
| Graph scroll-to-selection | `GraphViewController` | `motion.panel` 200 ms | instant | one-shot |
| Row inserts on page append | `GraphViewController` | 0 (no animation on bulk updates) | — | — |
| Inspector open/close | `WorkbenchController` | system split-view animation | instant | one-shot |
| Focus diff | `WorkbenchController` | `motion.panel` 200 ms opacity | instant | one-shot |
| Workbench error overlay | `WorkbenchViews` | `motion.panel` | instant | one-shot |
| Working-directory section changes | `WorkingDirectoryView` | tokens | none | one-shot |
| Operation banner | `OperationBanner` | tokens, reveal | identity | one-shot |
| Activity checkmark | `ActivityViews` | feedback in 180 ms, hold 900 ms, out 120 ms | none | one-shot (no loop) |
| Profile capsule change | `ProfileViews` | `motion.select` | none | one-shot |
| Command palette | `CommandPaletteController` | appear 140 ms ease-out, dismiss 100 ms, opacity | opacity only | one-shot |
| Progress spinners | `ProgressView` (composer, graph bar, activity, settings, browser) | system | system | shown only while busy |

No repeating timers, display links, `TimelineView` or `repeatForever` exist in the sources
(`IdleAndCacheTests.noRepeatingTimersOrPerpetualAnimationsInSources`). Idle after interaction measured with
powermetrics: 0.007–0.1 ms/s CPU (visible / minimized / hidden, 5 tabs).

## 4. Accessibility walkthrough

Verified by tests against real repositories (`AccessibilityTests`): graph rows speak "Commit <sha>, <subject>, by
<author>, <date>, <refs>, merge of N parents"; rotors Branches and Tags / Merge Commits / HEAD; diff lines speak
"Added line 5: …"; hunk and file rows are headings; rotors Changes / Hunks; a line is selected, the selection
extended and staged **only through accessibility actions** and Git confirms exactly that hunk part is staged.
Palette: field labelled "Command palette search", rows announce title, kind, shortcut and disabled reason;
selection changes are announced. Keyboard-only: ⌘K → `@branch` → ↩ selects the branch tip (driven with real
keystrokes); ⎋ and ⌘K close; ⌥⌘←/→ cycle panes.

**Not done by ear:** a full live VoiceOver walkthrough of §24 scenarios B, C and D (with speech) was not
performed in this session; the behaviours above were verified through the accessibility API. Carry-over.
