# Phase 6 — Polish & performance: implementation plan

Design: [`design.md`](design.md). Budget: roadmap §7. Requirements: §3.4, §3.5, §15, §17, §18.4, §18.5.

Order matters: **measure (P6.1–P6.3) → optimize (P6.4–P6.6) → polish (P6.7–P6.10) → lock in
(P6.11–P6.12)**. Do not start an optimization milestone without a recorded baseline for its metrics.

## 1. Preconditions

- [ ] Phase 5 `progress.md` shows exit gate passed (or carry-overs accepted by the user).
- [ ] `main` builds in Release; `swift test` (GitCore/Services) and Xcode test suites green.
- [ ] Full Xcode with Instruments installed; `xcrun xctrace version` works.
- [ ] A reference Mac identified and its spec written into `docs/performance.md`.
- [ ] Disk space for synthetic repos (≈ 5–10 GB) outside the repository (`$JIT_BENCH_DIR`).

## 2. Milestones

### P6.1 — Signposts and measurement plumbing
Goal: every budget metric is observable in Instruments and from scripts.
- [ ] Spec `specs/P6.1-instrumentation.md` (interval list from design §4.1, naming, zero-cost rule).
- [ ] `OSSignposter` helpers in `Services/Diagnostics/Signposts.swift`; intervals `launch.firstWindow`,
      `repo.open`, `graph.firstPage`, `graph.page`, `diff.switch`, `tab.switch`, `ops.*`.
- [ ] `GitCore` spans (category `core`) for history page, lane layout, status, diff parse, patch build
      and Git subprocess lifetimes (subcommand name only).
- [ ] `-JitBenchmarkScenario <name>` launch argument handling (inert unless set) in `App/`.
- Tests: `SignpostNamingTests` (all intervals registered, begin/end paired via a test signposter),
  `BenchmarkScenarioArgumentTests` (unknown scenario → no-op + log).
- Verification: record a launch + open-repo trace; intervals visible in Points of Interest.
- Done when: all intervals appear in a trace from a Release build.

### P6.2 — Benchmark harness and synthetic repos
Goal: repeatable, machine-readable benchmarks (§15.6, §18.5).
- [ ] `scripts/benchmarks/gen-repos.sh` (fast-import based, seeded): `linear-1k`, `branchy-10k`,
      `huge-100k`, `many-files`, `large-diff`, `wide-tree`. Idempotent; checks existing output hash.
- [ ] Scenario scripts: `launch-cold`, `launch-warm`, `idle`, `open-repo`, `graph-scroll`,
      `diff-switch`, `large-diff`, `many-files`, `multi-tab` (5 tabs), `open-close-loop`.
- [ ] `idle.sh`, `footprint.sh`, network-idle check (`nettop`).
- [ ] xctrace record/export automation where reliable; documented manual recipe otherwise.
- [ ] `run-all.sh` → `benchmarks/results/<date>-<sha>.json` + `summary.md` (results dir git-ignored
      except the committed baseline).
- [ ] `compare` tool with per-metric thresholds; non-zero exit on regression.
- [ ] `JitBench` micro-benchmarks (Swift executable target, Release): lane layout (10k/100k), status
      parse (500 files), diff parse (50k lines), patch build; median/p90 + allocation counts.
- [ ] `-JitOpaqueChrome` debug flag (inert unless set) for glass-cost A/B measurements.
- Tests: `gen-repos` determinism check (two runs → identical `git rev-parse` of all refs);
  `compare` unit tests on fixture JSON (pass, regression, missing metric).
- Verification: `scripts/benchmarks/run-all.sh` completes on the reference Mac.
- Done when: a full run produces a valid results file and summary.

### P6.3 — Baseline report
Goal: know where we stand before changing anything.
- [ ] Run all scenarios on the reference Mac (Release, conditions from design §4.1).
- [ ] Instruments passes: App Launch, Time Profiler (open repo, scroll, diff switch), Allocations +
      Leaks (open/close loop), Hangs, System Trace (5 min idle), Energy/Power (idle + active), GPU /
      Power Profiler during graph scroll and live-resize with glass chrome vs `-JitOpaqueChrome`.
- [ ] Write `docs/performance.md` "Baseline (Phase 6 start)" table vs §15.1 + top bottlenecks with trace
      evidence; commit `scripts/benchmarks/baseline/reference.json`.
- Done when: every §15.1 metric has a measured value and a ranked bottleneck list exists.

### P6.4 — Startup optimization
Goal: warm < 500 ms, cold < 1 s to first window (or documented best + bottleneck).
- [ ] Act only on bottlenecks from P6.3: defer non-window work, lazy providers/Keychain/OAuth/proxy/CA,
      defer `GitLocator` probe, async session restore, reduce static initializers.
- [ ] Verify tab chrome restores from session file before any Git call.
- Tests: `LaunchDoesNotTouchGitTests` (launch with restored tabs, assert no Git process spawned before
  first frame — via an injectable process-runner spy in a test build), `LazyProviderInitTests`.
- Verification: `launch-warm` / `launch-cold` scenarios before/after; App Launch trace.
- Done when: numbers recorded; improvement or justified no-change for each change made.

### P6.5 — Idle CPU, wakeups, network
Goal: 0.0–0.2 % CPU, minimal wakeups, zero network after settling (§15.3).
- [ ] Timer/animation audit (static grep + System Trace); remove or gate each finding.
- [ ] Tab suspension (ADR-0042): release FSEvents, view caches, in-flight reads for inactive tabs;
      reconcile on activation.
- [ ] Window occlusion handling; app-inactive FSEvents latency policy.
- [ ] Relative-date refresh strategy per spike.
- Tests: `InactiveTabReleasesWatcherTests`, `OccludedWindowPausesRefreshTests`,
  `SuspendedTabReconcilesExternalEditsTests` (modify/stage files externally while suspended → correct
  status on reactivation), `NoRepeatingTimersTests` (debug-build timer registry is empty after settle,
  if a registry is introduced).
- Verification: `idle.sh` with 0, 1 and 5 tabs, window visible / minimized / covered; System Trace.
- Done when: idle metrics meet target or the residual cause is identified and documented.

### P6.6 — Memory and large repositories
Goal: < 120 MB idle no repo, < 200 MB typical repo; bounded with 100k+ commits; no leaks.
- [ ] `CacheLimits` (in `GitCore`, read by Services) with documented values (ADR-0043); LRU eviction everywhere.
- [ ] Graph page eviction; struct-of-arrays commit store; diff buffer release; highlight span bounds.
- [ ] Swift-specific audit per design §4.5: ARC hotspots in parsers/lane layout/row drawing, no
      per-row `String`/`NSString` outside the visible window, retain-cycle sweep, autorelease pools in
      batch drawing, copy-on-write around page appends.
- [ ] Memory-pressure source trimming caches.
- [ ] Large-repo hardening: `huge-100k`, `wide-tree`, `many-files`, `large-diff`, 5 tabs.
- Tests: `CacheLimitTests` (`GitCore` + Services: insert beyond limit → size ≤ limit),
  `ClosedTabDeallocatesTests` (weak reference nil after close), `GraphPageEvictionTests`,
  `GitCoreTests.historyMemoryBounded` (page through 100k commits; tracked allocation bound via
  `malloc` statistics), `SessionRetainCycleTests` (tab, palette, sheets deallocate).
- Verification: `open-close-loop`, `footprint.sh`, Allocations/Leaks; graph scrolling hitch ratio on
  `huge-100k`; diff-switch on `large-diff`.
- Done when: footprint and leak criteria from design §4.5 met or documented.

### P6.7 — Visual refinement pass
Goal: every screen matches the design system in both themes (§3.2, §3.3, §3.5).
- [ ] Lint/test: no literal colors/fonts/spacing in feature views (`DesignTokenUsageTests` scanning
      sources, or a SwiftLint custom rule if SwiftLint is already used).
- [ ] Per-screen review using the design §3.3 checklist; findings + fixes logged in `visual-review.md`
      with before/after screenshots in `screenshots/`.
- [ ] Token refinements recorded in `docs/design-system.md` (changelog section).
- [ ] Compact/comfortable density check on graph, sidebar, working directory, diff.
- [ ] Liquid Glass audit per design §3.5: inventory every glass surface, confirm system component or
      official API in a container, no glass in content/scrolling rows, legibility over worst-case
      content, tint policy; screenshots light/dark/Reduce Transparency/Increase Contrast.
- Tests: `NoCustomBlurTests` (source scan: no `NSVisualEffectView` stacking, `CIFilter` blur or
  custom blur shaders outside approved wrappers), `GlassOnlyInChromeTests` (glass modifiers/views
  appear only in chrome modules — allowlist).
- Done when: all findings fixed or explicitly deferred with reason.

### P6.8 — Micro-interactions and Reduce Motion
- [ ] Inventory every animation (table in `visual-review.md`): location, duration, curve token,
      Reduce Motion behavior, idle-after-completion proof.
- [ ] Fix out-of-range durations; remove perpetual/decorative animations; disable animation during
      bulk graph updates; progress indicators removed when done; glass morph transitions only on user
      action, within panel durations, none under Reduce Motion.
- Tests: `ReduceMotionTests` (with the setting forced, transitions use opacity/none),
  `ProgressIndicatorStopsTests`.
- Verification: Animation Hitches trace during graph scroll and panel transitions; Time Profiler shows
  no work after transitions end.
- Done when: inventory complete, all rows pass.

### P6.9 — Command palette and keyboard workflows
- [ ] Spec `specs/P6.9-command-palette.md`.
- [ ] Command registry shared by menus, context menus, toolbar and palette (ADR-0044); enabled state +
      disabled reason per command.
- [ ] Palette panel UI per design §3.1 (native floating glass panel, single glass container); sources: commands, refs, files (lazy `ls-files` index, bounded),
      repos/tabs, SHA prefix; fuzzy ranker off the main actor.
- [ ] Menu completeness audit (§17 menus); shortcuts per design §3.2; pane focus cycling.
- Tests: `FuzzyRankerTests` (word-start, consecutive, prefix, recency, ties), `ShortcutConflictTests`,
  `MenuPaletteParityTests` (every enabled menu command is in the palette and vice versa),
  UI tests `PaletteNavigateToBranchUITest`, `KeyboardOnlyCommitFlowUITest`,
  `KeyboardOnlyConflictResolveUITest`.
- Verification: keyboard-only scripts from design §3.2 performed manually and via UI tests.
- Done when: all keyboard paths pass without mouse.

### P6.10 — Accessibility
- [ ] Graph row accessibility elements + rotors; diff line elements + rotors + line-selection actions;
      outline semantics for sidebar and working directory; labels for every icon-only control.
- [ ] Increase Contrast token variants; Reduce Transparency (every glass surface opaque, verified by
      screenshot); Differentiate Without Color glyphs.
- [ ] Text-size step for code/diff; relative type styles in SwiftUI views where practical.
- [ ] Contrast audit (both themes, normal + Increase Contrast) → table in `visual-review.md`.
- Tests: `GraphAccessibilityTests` (row label content), `DiffAccessibilityTests`,
  UI test `VoiceOverStageLineUITest` (via accessibility actions), audit with
  `XCUIApplication.performAccessibilityAudit()` where available on the target Xcode.
- Verification: full VoiceOver walkthrough of Scenario B, C, D (§24) documented.
- Done when: walkthrough succeeds and audit has no unresolved errors.

### P6.11 — Visual regression suite
- [ ] ADR-0040; snapshot harness (offscreen window, fixed size/scale/appearance, frozen clock,
      deterministic fixtures from `GitTestKit`); XCUITest window-screenshot path for glass chrome if
      offscreen capture can't render glass faithfully (spike in design §7).
- [ ] References for §18.4: empty state, repository graph, working directory, side-by-side diff, unified
      diff, conflict resolver, profile switcher, repository browser (fixture data from a local stub —
      no network), settings; plus command palette. Light + dark; Reduce Transparency light + dark for
      every screen with glass chrome; Increase Contrast for 3 key screens.
- [ ] Re-baseline procedure documented (`docs/design-system.md` or `docs/testing.md`).
- Tests: `SnapshotTests/*` (20+ images).
- Done when: suite runs green twice in a row with no flakes; a deliberate 1-pt change is detected.

### P6.12 — Performance regression gate and final report
- [ ] CI job (macOS arm64 runner): Release build, `JitBench` micro-benchmarks, non-UI scenarios, results
      artifact, loose thresholds (ADR-0041).
- [ ] Final reference-Mac run; update `baseline/reference.json`.
- [ ] `docs/performance.md` final report: §15.1 table (target / baseline / final / method / status),
      environment block, bottleneck analysis for any miss, list of optimizations with measured effect.
- Done when: report complete and honest; regression check passes against new baseline.

## 3. Test plan summary

| Layer | New tests |
|---|---|
| `GitCore` unit (`swift test`) / `JitBench` | cache limits, history memory bound, micro-benchmarks (lane layout, status, diff, patch) |
| Swift unit (app/Services) | signposts, scenario args, lazy init, suspension/occlusion, cache limits, deallocation/retain cycles, ranker, shortcut conflicts, menu/palette parity, accessibility labels, token usage, no-custom-blur, glass-only-in-chrome |
| UI (XCUITest) | palette navigation, keyboard-only commit, keyboard-only conflict resolution, VoiceOver stage line, accessibility audit |
| Snapshot | §18.4 screens × light/dark, Reduce Transparency variants for glass chrome, Increase Contrast subset |
| Scripts | gen-repos determinism, compare tool |

No test may be skipped without a recorded reason in `progress.md`.

## 4. Performance checks

Every optimization commit message references the metric and before/after numbers from the reference
Mac. Final table must cover all §15.1 rows plus: repo open time per bench repo, branch switch time,
graph pagination latency, large-file diff time, multi-tab footprint, idle wakeups/s, energy impact,
and glass-chrome GPU cost (idle, scroll, live-resize) vs `-JitOpaqueChrome`.

## 5. Docs to update

- `docs/performance.md` — methodology, reference machine, baseline, final results, bottlenecks.
- `docs/design-system.md` — token refinements, Increase Contrast variants, motion inventory, Liquid
  Glass usage inventory and any refined rules.
- `docs/architecture.md` — suspension/occlusion, cache limits, command registry.
- `docs/testing.md` (create if absent) — snapshot and benchmark procedures, re-baselining.
- `CLAUDE.md` — benchmark and snapshot commands in the Commands section.
- ADRs 0040–0044; ADR-0008 amendment if changed; ADR-0006 amendment only if the glass audit refines a rule.

## 6. Exit checklist

- [ ] All milestones done or carried over with reason and new home.
- [ ] Final performance report in `docs/performance.md` with every §15.1 metric measured; misses
      explained with bottleneck and options — no unmeasured claims.
- [ ] Idle: 5-min sample at ≈0 % CPU, zero network, flat memory with 0/1/5 tabs (or documented residual).
- [ ] Open/close loop shows no leaks and bounded footprint.
- [ ] Graph scrolling on `huge-100k` meets hitch target or is documented.
- [ ] Visual review log complete (incl. Liquid Glass audit); snapshot suite green in light, dark and
      Reduce Transparency.
- [ ] Glass chrome: no idle GPU activity; no hitches attributable to chrome during scroll/resize.
- [ ] Command palette and keyboard-only flows work; menus complete; no shortcut conflicts.
- [ ] VoiceOver walkthrough of scenarios B/C/D documented.
- [ ] CI perf job running; reference baseline committed.
- [ ] Roadmap §9 exit gate items 1–8 satisfied.
