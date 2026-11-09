# Phase 06 — Polish & performance: progress report

Status: complete with carry-overs
Branch / PR: `phase/06-polish-and-performance` (PR link added when opened)
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2,
Git 2.54.0 (Homebrew). Reference Mac = this machine (same as Phases 0–5; not separately confirmed by the owner).
Conditions: busy machine (load ≈ 4.5; GitKraken renderer and WindowServer ≈ 45 % CPU each).

## Implemented
- **P6.1 Signposts and plumbing** — `Signposts` registry (GitCore, Points of Interest, `com.example.jit`): app
  intervals and `core.*` spans; `-JitBenchmarkScenario` (inert unless passed). Evidence: `SignpostNamingTests`,
  `BenchmarkScenarioArgumentTests`; intervals extracted from a Release trace (`instruments/trace.sh`).
- **P6.2 Harness** — `gen-repos.sh` (6 deterministic repos), scenarios (launch warm/cold, idle 0/1/5, open-repo,
  graph-scroll, diff-switch, large-diff, many-files, multi-tab, open-close-loop, glass-cost), `footprint.sh`,
  `network-idle.sh`, `powermetrics.sh`, `run-all.sh`, `results.py`/`compare.sh`, `JitBench micro`,
  `-JitOpaqueChrome`, `instruments/{trace.sh,signposts.py,hotspots.py}`. Evidence: `BenchRepoDeterminismTests`,
  `scripts/benchmarks/tests` (6), two full runs.
- **P6.3 Baseline** — `baseline/phase6-start.json` + summary; ranked bottlenecks (leak, 1.2 GB long-line diff, diff
  switch, idle 5 tabs, tab switch) in `docs/performance.md`.
- **P6.4 Startup** — accounts service lazy; launch already within budget (warm 259 ms, cold 241 ms).
  `LaunchWorkTests` (no Git process and no accounts service before the window is in the foreground).
- **P6.5 Idle** — timer/animation audit (none found; source-scan test), suspension/occlusion verified and tested
  (`IdleAndCacheTests`: inactive tab releases watcher, occluded window pauses, suspended tab reconciles external
  edits); idle measured with powermetrics (≤ 0.1 ms/s CPU, 0 network) visible / minimized / hidden, 0/1/5 tabs.
- **P6.6 Memory** — closed-tab leak fixed (531 → 157 MB, 0 leaks; `ClosedTabDeallocatesTests`), long-line layout
  bounded (1,215 → 211 MB), `CacheLimits` table + memory-pressure trimming (`IdleAndCacheTests`).
- **P6.7 Visual / glass** — review log and Liquid Glass inventory (`visual-review.md`), glass only via helpers in
  chrome (`GlassPolicyTests`, lint), palette UI fixes found by review, Differentiate Without Color.
- **P6.8 Motion** — inventory; literal durations and missing Reduce Motion paths fixed (`MotionPolicyTests`).
- **P6.9 Palette and keyboard** — `CommandRegistry` builds the menus; ⌘K palette (commands, refs, files, repos,
  SHA; fuzzy ranker off main; disabled reasons); ⌥⌘←/→ pane focus; ⌘+/⌘-/⌘0 code text size.
  `CommandRegistryTests`, `FuzzyRankerTests`; driven with real keystrokes (⌘K → `@inspector-2006` → ↩ selects the
  branch tip; ⎋ / ⌘K close). Screenshots `screenshots/command-palette-empty-{light,dark}.png`.
- **P6.10 Accessibility** — diff headings/rotors/line actions, graph rotors, Differentiate Without Color, text
  size step. `AccessibilityTests` (stages a line via accessibility actions only).
- **P6.11 Visual regression** — offscreen harness, 21 references (new tab ×5, switcher ×4, palette ×4, unified
  diff ×3, split diff ×2, graph ×3) in light/dark/Increase Contrast/Reduce Transparency; 1-pt shift detected; green
  twice in a row. ADR-0040, `docs/testing.md`.
- **P6.12 Gate and report** — CI `performance` job (micro + loose compare, advisory), reference baseline
  `baseline/reference.json`, final report in `docs/performance.md`.

## Verified
- Tests: `scripts/build/test-core.sh` → 735 passed (GitCore 390, Services 200, Features 130, DesignSystem 15), 0
  failed. App tests (`scripts/build/test-app.sh`, `-quiet`) exit 0. Benchmark tooling 6/6. Lint clean.
  Not asserted in the full parallel run: the load-sensitive `lanesLayout100kUnder150ms` wall-clock check
  (`JIT_FULL_SUITE=1`; enforced in filtered runs and by `JitBench micro`, 50 ms vs 150 ms budget).
- Real workflow: release app on the bench repositories (all scenarios); debug app driven by real keystrokes for
  the palette; `leaks` on a held process after 50 open/close cycles (0 leaks).
- Screenshots: `screenshots/command-palette-empty-{light,dark}.png` (live, glass); snapshot references in
  `macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/`.

## Performance (release, reference Mac)
| Metric | Phase 6 start | Now | Method |
|---|---|---|---|
| Warm / cold launch | 264.6 / 236.0 ms | 259.3 / 241.0 ms | launch-warm / launch-cold |
| Idle CPU (0/1/5 tabs) | 0.0 % (2.4 % peak, not reproducible) | 0.00 %; ≤ 0.1 ms/s powermetrics | idle.sh |
| Idle network | 0 | 0 bytes, 0 sockets | network-idle.sh |
| Memory no repo / 1 repo / 5 tabs | 32 / 71 / 70 MB | 32 / 72 / 70 MB | footprint |
| Open/close ×50 (peak / settled) | 531 / 411 MB | 157 / 66 MB, 0 leaks | open-close-loop, leaks |
| Diff switch (small files) | 63.5 ms | 51.9 ms (43–53) | diff-switch |
| 5 MB-line diff footprint | 1,215 MB | 211 MB | large-diff |
| Graph scroll step (100k) | 1.68 / p95 2.04 ms | 1.63 / p95 1.92 ms, 0 > 16.7 ms | graph-scroll |
| Tab switch | 16.7 / p90 27.8 ms | 17.4 / p90 31.6 ms | multi-tab |
Full table, glass A/B and bottleneck analysis: `docs/performance.md` ("Phase 6 — final report").

## Decisions
- ADR-0040 Visual regression — custom offscreen harness; glass chrome via Reduce Transparency rendering; OS-pinned.
- ADR-0041 Measurement and regression policy — reference Mac authority, schema, thresholds, powermetrics for idle.
- ADR-0042 Tab suspension and occlusion — foreground-only work, teardown on close, lazy accounts.
- ADR-0043 Cache limits — `CacheLimits` table, trim notification, no graph page eviction (store is 18 MB/100k).
- ADR-0044 Command palette — single registry for menus and palette, ranking, responder-chain validation.
- ADR-0006 and ADR-0008 unchanged (audit found no rule to refine; file-watching policy unchanged).

## Deviations from plan
- `Signposts` lives in GitCore (not Services/Diagnostics) so core spans and app intervals share one registry; all
  intervals use the Points of Interest category (xctrace drops custom categories) with the category as name prefix.
- Palette appear animation is opacity only (the 4 pt rise was dropped once the top edge was anchored).
- No XCUITest target exists; keyboard-only flows were driven with System Events keystrokes, and VoiceOver line
  staging is tested through accessibility actions in `AccessibilityTests`, not XCUITest.
- `top`'s IDLEW is informational; idle wakeups/energy come from powermetrics (ADR-0041).
- Snapshot references live in `Tests/FeaturesTests/__Snapshots__/` (package test target), not `macos/Tests/Snapshots`.
- Graph page eviction not implemented (decided against with data, ADR-0043).
- Docs updated: yes (performance, design-system, architecture, testing (new), roadmap, CLAUDE.md, ADRs).

## Known issues / carry-overs
- **Tab switch** 17.4 ms median / 31.6 ms p90 vs the 16 ms Phase 1 target — toolbar tab-strip and workbench
  SwiftUI relayout; options in performance.md. Phase 7 / Phase 8 (medium).
- **Live VoiceOver walkthrough** of §24 scenarios B, C, D with speech not performed (verified through the
  accessibility API and tests only). Before release (Phase 7).
- **XCUITest UI tests** (palette navigation, keyboard-only commit and conflict resolution, accessibility audit)
  not written — no UI-test target. Phase 7.
- **Instruments by hand**: Animation Hitches during a trackpad fling / live-resize drag, Metal System Trace for the
  compositor cost of glass. Phase 7 release checklist.
- **Visual re-review by eye** of settings, repository browser, conflict resolver and clone sheet (unchanged since
  their Phase 4/5 captures) and Reduce Transparency / Increase Contrast live captures of those. Phase 7.
- Repository-browser memory and credential overhead in release (Phase 5 carry-over; no provider accounts here).
- Reference machine not explicitly confirmed by the owner; numbers taken on a busy machine.

## Self-review findings
- Benchmark path filter accepted `//host` segments of URLs — fixed (test caught it).
- `xctrace --launch` traced a stale Debug UI-test build — worked around (`/usr/bin/env`), and those stray
  processes were killed.
- My first snapshot-token parallelization read the fingerprint twice per token (doubling hash cost on large
  files) — fixed with one fingerprint per token, read before the hashed content.
- A doc comment was split by an insertion in `WorkbenchController` — fixed.
- Three tab-switch "optimizations" showed no measurable gain — reverted per the phase rule.
- Two flaky tests surfaced by the larger parallel suite (process-global secret wipe hook; fixed-sleep draft save)
  — made deterministic. `queuedOperationShowsWhatItWaitsFor` failed once under full load and passed in every
  later run — watch.
- Security: benchmark hooks open only explicit local paths, read-only; results contain metrics only; signpost
  details never include paths, refs or titles (`gitSubcommand` test); no network from scenarios.

## Next
- Phase 7 (packaging & release): signed, notarized DMG with bundled Git; re-run `scripts/benchmarks/run-all.sh`
  against the bundled Git and compare with `baseline/reference.json`; the carry-overs above in the release checklist.
