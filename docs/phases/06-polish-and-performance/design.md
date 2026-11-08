# Phase 6 — Polish & performance: design

> Requirements: §3.4, §3.5, §15 (all), §17, §18.4, §18.5, §22 Phase 6, §23. Budget table: roadmap §7.
> Rule of the phase: **profile before optimizing.** Every optimization is preceded by a measurement
> that names the bottleneck and followed by a measurement that shows the effect.

## 1. Goal & demo

Turn the feature-complete V1 (Phases 0–5) into a product that measurably meets — or honestly reports
against — the §15.1 targets, feels finished in both themes, and is fully operable by keyboard and
VoiceOver.

**Demo at the end of the phase**

1. Run `scripts/benchmarks/run-all.sh` on the reference Mac: it generates the synthetic repos, drives a
   release build through the scenarios, and writes `benchmarks/results/<date>-<sha>.json` plus a
   Markdown summary. The regression check passes against the committed baseline.
2. Show the final performance report (`docs/performance.md`) — every §15.1 metric with measured value,
   method and, for misses, the bottleneck analysis.
3. Launch the app, open three repos, leave it idle 5 minutes: Activity Monitor / `top` show ≈0 % CPU,
   no wakeup storm, flat memory; Instruments Energy shows "Low"/idle.
4. Press ⌘K, jump to a branch, a file and another repo without touching the mouse.
5. Turn on VoiceOver: navigate graph rows, read a commit, move through diff lines, stage a line.
6. Run the visual regression suite: all §18.4 screens pass in light and dark.

## 2. Scope / out of scope

**In scope**
- Measurement infrastructure: signposts, benchmark harness, idle samplers, Instruments recipes.
- Startup, idle, memory and rendering optimizations driven by measurements.
- Large-repository and multi-tab hardening.
- Visual refinement pass across every screen; micro-interaction audit; Reduce Motion.
- Command palette (⌘K), keyboard workflow completion, menu completeness (§17).
- Accessibility pass (§17): VoiceOver, focus order, contrast, Increase Contrast, text size where practical.
- Visual regression suite (§18.4) and performance regression suite (§18.5).
- Final measured performance report.

**Out of scope**
- New Git features → Phase 8 epics (interactive rebase, stash, worktrees, reflog…).
- Universal/Intel builds, bundled Git, signing, notarization, DMG → Phase 7.
  (Phase 6 measures the arm64 release build with the development Git; Phase 7 re-runs the key
  benchmarks against the bundled Git and universal binary.)
- Redesigning the design system. Phase 6 *refines* tokens and fixes inconsistencies; it does not
  restart the visual identity. Token changes go through `docs/design-system.md`.
- Auto-update, telemetry, crash reporting — never by default (§19); update policy is ADR-0020 (Phase 7).

## 3. User experience

### 3.1 Command palette (⌘K)

**Interaction**
- ⌘K opens a floating panel centered in the upper third of the active window (a child `NSPanel`,
  not a sheet; does not steal the app's key-window semantics for other windows).
- One search field, results below. Typing filters live; ↑/↓ move, ↩ executes, ⌘↩ executes the
  secondary action (e.g. "checkout" vs "reveal" for a branch), ⎋ closes, ⌘K again closes.
- Empty query shows: recent commands (max 5), then contextual commands for the current tab.
- Prefix scopes (shown as hint chips, optional): `>` commands, `@` branches/tags, `/` files,
  `#` repositories/tabs, `:` commit SHA. Without a prefix all sources are mixed and ranked.

**Sources (all local, no network)**
- Commands: every menu command with its title, shortcut and enabled state (built from the same
  command registry as the menus, so palette and menus can never disagree).
- Branches, remote branches, tags of the active repo (from the cached ref model).
- Files: working-directory changed files first, then tracked paths (`git ls-files` cached per repo
  revision, loaded lazily on first `/` use, bounded).
- Repositories: open tabs, then recents.
- Commits: exact/prefix SHA match only (no full-history scan from the palette).

**Ranking:** fuzzy subsequence match with bonuses for word-start, consecutive runs, exact prefix,
and recency; ties broken by source order (commands > branches > files > repos). Matching runs off
the main actor on a snapshot of the source lists; results are capped at 50.

**Visual hierarchy:** field (body-large, SF Pro) → result rows: SF Symbol / file-type icon, primary
title with matched characters emphasized by weight (not color alone), secondary line in muted text
(path, upstream, repo), trailing shortcut glyphs in SF Mono-like keycap style from tokens. Section
headers only when mixing sources. Surface uses the elevated-surface token with the standard shadow
token; no blur animation.

**States**
- Empty query: recents + contextual commands.
- Loading (file index building): rows for other sources appear immediately; a small inline
  "Indexing files…" row with a determinate count if known. Never blocks typing.
- No results: "No matches for "…"" plus a hint about prefixes.
- Error (file index failed): one muted row "Files unavailable — <reason>"; other sources still work.
- Disabled commands are listed with muted style and the reason on the secondary line
  (e.g. "Push — no upstream configured"), never executable.

**Motion:** appear 140 ms ease-out (opacity + 4 pt upward offset), dismiss 100 ms; selection highlight
moves without animation (instant feedback when arrowing). Reduce Motion: opacity only.

**Accessibility:** field labelled "Command palette search"; results are an accessibility list; the
selected row is announced with title, kind and shortcut; disabled reason is read.

### 3.2 Keyboard workflows and menus (§17)

Audit and complete:
- App, File, Edit, View, Repository, Branch, Git (operations), Window, Help menus. Every action
  reachable from a context menu or toolbar is also in a menu (or the palette) with a consistent title.
- Shortcuts from §17: ⌘O, ⌘T, ⌘W, ⌘F, ⌘K, ⌘↩ (composer), ⌘1/2/3 (workbench modes). Tab switching:
  ⌃⇥ / ⌃⇧⇥ and ⌘⇧] / ⌘⇧[. No overrides of standard macOS shortcuts (⌘Q, ⌘H, ⌘M, ⌘`, ⌘,, text editing).
- Keyboard-only paths, each written as a test script: open repo → select commit → open file diff →
  select lines → stage → write message → commit → push; resolve a conflict; switch profile.
- Focus order: tab bar → sidebar → graph → inspector, cycling with ⇥ / ⇧⇥ between panes and
  arrow keys within; F6-style pane cycling via ⌘⌥← / ⌘⌥→ if not conflicting (decide in spec).
- Shortcut conflicts are detected by a unit test over the command registry.

### 3.3 Visual refinement pass

For each screen in §18.4 plus any other shipped screen (tab bar, new-tab page, sidebar, graph,
commit details, working directory, unified diff, split diff, blame, conflict resolver, commit
composer, profile switcher, profile editor, repository browser, settings, operation progress/errors,
confirmation sheets, command palette), review light and dark against `docs/design-system.md`:

| Check | Pass criterion |
|---|---|
| Spacing | Only spacing-scale values; consistent insets per surface level. |
| Alignment | Baselines align across columns (graph row text, inspector headers); icons optically centered. |
| Typography | Only type-scale styles; SF Mono for SHAs/paths/code; no truncation of critical info without tooltip. |
| Color | Semantic tokens only (lint: no literal colors in views); lane palette passes contrast on both backgrounds. |
| Contrast | Text ≥ 4.5:1 (≥ 3:1 for large/secondary UI where justified); diff add/del backgrounds keep code ≥ 4.5:1. |
| States | Empty, loading, normal, error designed and reachable for each screen. |
| Hover/press/selection/focus | Present, token-driven, consistent across lists. |
| Density | Compact and comfortable modes both correct. |
| Dark theme | Independently tuned, no glow borders, layered luminance correct. |

Findings are logged per screen in `docs/phases/06-polish-and-performance/visual-review.md` with
before/after screenshots.

### 3.4 Micro-interaction audit (§3.4)

Inventory every animation in the app (tab selection, sidebar expand, profile menu, commit selection,
graph↔diff transitions, drag-and-drop feedback, stage/commit success, fetch/push progress). For each:
duration within guideline ranges (hover 80–140 ms, selection 120–180 ms, panels 160–240 ms), curve
from tokens, Reduce Motion alternative, and proof that CPU returns to idle after completion (Instruments
Time Profiler / Animation Hitches trace shows no frames after the animation's end). Remove any
perpetual or decorative animation; progress indicators stop and are removed from the hierarchy when
the operation finishes; no animation on bulk graph updates.

### 3.5 Accessibility

- **Graph:** each row exposes an accessibility element: "Commit <short SHA>, <summary>, by <author>,
  <relative date>, refs: <list>, merge of N parents". Custom rotors: "Branches/refs", "Merge commits",
  "HEAD". The lane drawing itself is decorative; topology is conveyed through text (parents, children
  count, "on branch X").
- **Diff:** each line exposes "Line <old>/<new>, added|removed|context, <text>"; hunk headers are
  headings; custom rotors: "Changes", "Hunks", "Conflicts". Line selection for staging works with
  VoiceOver (select line, extend with ⇧↓, action via the actions menu: Stage selected lines).
- **Lists/trees:** sidebar and working directory expose outline semantics with expanded state.
- **Contrast & settings:** honor Increase Contrast (`accessibilityDisplayShouldIncreaseContrast`) with
  higher-contrast token variants; Reduce Transparency removes any vibrancy; Differentiate Without Color
  adds glyphs to status/diff indicators.
- **Text size:** respect the macOS sidebar size setting; offer an app-level text-size step (S/M/L) for
  code and diff views; SwiftUI views use relative type styles where practical.
- Audit with Accessibility Inspector and a full VoiceOver walkthrough; results logged.

## 4. Technical design

### 4.1 Measurement methodology

- **Builds:** always Release configuration, arm64, dSYMs generated, launched outside Xcode (no debugger
  attached). Debug builds are never used for numbers.
- **Reference machine:** recorded in every result file: Mac model identifier, chip, RAM, macOS
  version/build, Git version, power source (on AC), Low Power Mode off, display scale. The reference
  Mac is the authority for pass/fail; CI numbers are advisory.
- **Conditions:** reboot or at least quit heavy apps; Spotlight indexing finished for the bench folder;
  3 warm-up runs discarded; N ≥ 10 measured runs; report median and p90; cold-launch runs use
  `sudo purge` between runs (documented as an approximation of cold state).
- **Signposts:** `OSSignposter` with subsystem = the app's bundle identifier (placeholder `com.example.jit` until chosen) and
  categories `launch`, `repo`, `graph`, `diff`, `ops`. Intervals:
  - `launch.firstWindow` — process start (from `ProcessInfo` start time / `kinfo_proc`) to first
    window `didBecomeKey` + first frame committed.
  - `repo.open` — open request → status + first graph page displayed.
  - `graph.firstPage`, `graph.page` — request → rows on screen.
  - `diff.switch` — file selection → first diff frame drawn.
  - `tab.switch` — tab click → cached content visible.
  - Rust side: matching spans via `os_signpost` from Rust (thin FFI or the `signpost` crate if vetted)
    or emitted as Swift intervals around bridge calls — decide in P6.1 spec; keep zero cost when not
    tracing.
- **Instruments templates** (saved as `.tracetemplate` under `scripts/benchmarks/instruments/` if
  templates are portable, otherwise documented recipes):
  Time Profiler, Allocations (+ VM Tracker), Leaks, Hangs, Animation Hitches, Energy Log / Power
  Profiler, System Trace (thread states, wakeups, timer coalescing), Points of Interest/os_signpost.
- **Automation:** `xcrun xctrace record --template ... --launch -- <app>` and `xctrace export --xpath`
  to extract signpost intervals into JSON where it works reliably; fall back to manual capture with a
  recorded procedure where it doesn't.
- **Idle samplers** (`scripts/benchmarks/idle.sh`): after a settle period (default 60 s), sample for
  5 min: `top -l <n> -s 1 -pid <pid> -stats pid,cpu,idlew,mem,purg,threads`, plus optional
  `sudo powermetrics --samplers tasks --show-process-wakeups -i 1000` for wakeups/s and energy impact.
  Output: mean/p95 CPU %, wakeups/s, RSS/phys footprint start vs end, thread count.
- **Memory:** `footprint <pid>` / `vmmap --summary` for physical footprint (the number Activity Monitor
  shows); RSS is recorded but not the headline.
- **Network idle check:** `nettop -p <pid> -L 1` (or Little Snitch-free alternative `lsof -i -p`)
  over the idle window must show zero connections/bytes.

### 4.2 Benchmark harness (`scripts/benchmarks/`)

```
scripts/benchmarks/
  gen-repos.sh            # deterministic synthetic repos (seeded) into $JIT_BENCH_DIR (outside repo)
  run-all.sh              # orchestrates scenarios, writes results JSON + summary.md
  scenarios/*.sh          # launch-cold, launch-warm, idle, open-repo, graph-scroll, diff-switch,
                          # large-diff, many-files, multi-tab, open-close-loop
  idle.sh  footprint.sh   # samplers
  compare.py|swift        # regression check vs baseline (thresholds per metric)
  baseline/reference.json # committed baseline from the reference Mac
  instruments/            # templates or recipes
```

- **Synthetic repos** (generated, never committed): `linear-1k`, `branchy-10k` (≈200 branches, frequent
  merges, octopus + crisscross), `huge-100k` (100k+ commits, 1k refs, 500 tags), `many-files`
  (500 changed files mixed staged/unstaged/untracked/renamed), `large-diff` (single 50k-line text file
  rewritten in scattered hunks, plus a 5 MB minified line file), `wide-tree` (50k tracked files).
  Generated with `git fast-import` streams for speed and determinism (seeded content, fixed dates/authors).
- **Scenario drivers:** launch the release app with a launch argument / environment
  (`-JitBenchmarkScenario <name>`, compiled in all builds but inert unless set) that opens the given
  repo(s) and performs a scripted action (e.g. scroll graph N pages at fixed velocity via the scroll
  view, select files in sequence), emitting signposts. XCUITest-based drivers are allowed for
  interactive scenarios where scripted in-app actions would bypass real event paths — document which.
- **Graph scrolling FPS:** measured via Animation Hitches (hitch time ratio) and `CADisplayLink`-free
  frame timing from signposts in the graph view's draw path; target: hitch ratio < 5 ms/s, no frame
  > 16.7 ms sustained at 60 Hz (also record on 120 Hz ProMotion if available).
- **Results JSON schema** (versioned): `{schema, timestamp, git_sha, machine{...}, git_version,
  scenarios: {name: {metric: {median, p90, unit, runs}}}}`.
- **Regression check:** per-metric thresholds (e.g. launch +10 %, memory +10 %, idle CPU absolute
  +0.1 pt, hitch ratio +2 ms/s); exit non-zero on regression; prints a table.

### 4.3 Startup optimization

Measure first (Time Profiler on launch, `DYLD_PRINT_STATISTICS`-equivalent via Instruments "App
Launch" template), then apply only what the trace justifies:
- No work before first window beyond reading preferences + session JSON (small, synchronous OK if
  measured < few ms; otherwise async after window).
- Tab restoration renders tab chrome from the session file; repository loading for the active tab
  starts after first frame; inactive tabs load on first activation.
- Provider clients, Keychain reads, OAuth, proxy/CA configuration, credential helper: lazy, on first use.
- Rust library: no global initializers doing I/O; `GitLocator` version probe deferred until the first
  Git operation (cached for the session).
- Minimize static initializers and dynamic frameworks; prefer static linking of the Rust lib (already
  XCFramework static) and of the local Swift package.
- Asset catalog/fonts: system fonts only; avoid loading large images at launch.

### 4.4 Idle optimization

Target state when idle: zero timers, zero threads doing work, FSEvents stream only for the visible tab,
no animations, no network.
- **Timer audit:** grep + runtime check (System Trace) for `Timer`, `DispatchSourceTimer`,
  `Task.sleep` loops, `CVDisplayLink`, `TimelineView`, repeating `withAnimation`. Each must be justified
  and stopped when idle; relative-date labels ("3 min ago") update on window activation and on
  scroll/redraw, not via a ticking timer (or one coalesced, tolerance-heavy timer only while visible —
  decide by measurement).
- **Tab suspension:** inactive tabs release FSEvents streams, cancel in-flight reads, drop view
  hierarchies beyond a cached snapshot, and keep only compact model state; on reactivation refresh
  status (cheap) before showing stale indicators.
- **Window occlusion:** observe `NSWindow.didChangeOcclusionStateNotification`; when not visible
  (minimized, fully covered, other Space), stop FSEvents-driven refreshes (mark dirty instead), pause
  progress indicators' drawing; on becoming visible, reconcile once.
- **App inactive:** coalesce FSEvents with a longer latency (e.g. 1–2 s) or defer to `didBecomeActive`;
  measure both and choose.
- **Network:** `NWPathMonitor` (if used in Phase 5) is event-driven, never polls; verify zero idle traffic.

### 4.5 Memory

- Explicit, documented limits for every cache (graph pages, commit details, diff buffers, highlight
  spans, avatar placeholders, file index, provider repo lists). Expressed as counts/bytes in one place
  (`CacheLimits` in Rust and Swift), with eviction LRU.
- Graph: keep visible window ± overscan pages in Swift; Rust keeps compact commit records
  (interned author strings, OIDs as 20/32-byte arrays) and lane state; evict far pages, re-fetchable.
- Diff: release buffers for files not selected; large files rendered from line index + lazily
  materialized lines; highlight only visible range.
- Tabs: closed tab → session object deallocated (verified with a weak-reference test and Leaks).
- Respond to memory pressure (`DispatchSource.makeMemoryPressureSource`) by trimming caches.
- **Open/close loop test:** open and close each bench repo 50× and switch tabs 200×; physical footprint
  after loop within 10 % of after first iteration; Leaks reports 0 app-owned leaks.

### 4.6 Visual regression (§18.4)

Recommended approach (confirm in ADR-0040): in-process snapshot tests in the Swift test target that
build each screen with real data from `git-testkit`-generated temp repos (fixed dates, authors, SHAs
via deterministic commit env), host it in an offscreen `NSWindow` at a fixed size and backing scale 2,
force `NSAppearance` aqua/darkAqua, render with `cacheDisplay(in:to:)` / `bitmapImageRepForCachingDisplay`,
and compare to reference PNGs with a per-pixel tolerance + perceptual threshold (e.g. max ΔE and
% differing pixels). References live in `macos/Tests/Snapshots/__References__/<screen>-<state>-<theme>.png`.
- Relative dates are frozen via an injected clock; avatars are initials; fonts are system fonts (note:
  references are tied to a macOS major version — record it; re-baseline deliberately on OS upgrade).
- Failure output: actual, reference and diff images attached to the test result.
- A third-party snapshot library is acceptable only if it handles AppKit `NSView` well and adds no
  transitive dependency burden (ADR decides).

### 4.7 Performance regression in CI

- GitHub Actions macOS arm64 runner job: build Release, run Rust micro-benchmarks (lane layout, status
  parse, diff parse, patch build) and the non-UI scenarios with generous thresholds; upload results JSON
  as an artifact. Variance on shared runners is high — CI flags only large regressions (e.g. > 25 %);
  the reference Mac run is required before the phase PR and before each release.
- Rust micro-benchmarks: `criterion` (dev-dependency only) or a minimal custom harness if criterion's
  dependency tree is judged too heavy — decide in P6.2.

### 4.8 Security notes

Benchmark hooks (`-JitBenchmarkScenario`) must only open local paths given explicitly, perform
read-only or fixture-only mutations, and never touch network or credentials. Instruments traces and
results files must not contain secrets or real repository content; result files contain metrics only.

## 5. Edge cases & failure modes

- Thermal throttling or background indexing skews numbers → record `pmset -g therm` / check, discard
  runs, document.
- ProMotion displays: FPS targets reported at the display's refresh; 60 FPS remains the requirement.
- `powermetrics` requires sudo → script degrades to `top` and says so in the result.
- xctrace export schema differences across Xcode versions → parser pinned to the Xcode version in use;
  fallback to manual procedure.
- Snapshot references differ across macOS versions/GPUs → references pinned to the reference OS;
  tests on other OS versions are skipped with an explicit message (not silently passed).
- Optimizations that change behavior (lazy loading, suspension) can produce stale UI → every
  suspension path has a reconciliation step and a test that edits files while suspended and verifies
  correct state on reactivation.
- Memory-pressure trimming during an operation must not drop data an in-flight operation relies on
  (operations hold their own snapshots).
- A target is unattainable → report measured value, bottleneck, options and cost; do not tune the
  benchmark to hide it.

## 6. ADRs to write

- **ADR-0040** Visual regression approach (custom NSView bitmap snapshots vs library; tolerance policy;
  OS-version pinning).
- **ADR-0041** Performance measurement & regression policy (reference machine as authority, thresholds,
  CI advisory role, results schema).
- **ADR-0042** Tab suspension and occlusion policy (what is released, when, how state reconciles).
- **ADR-0043** Cache limits and memory-pressure behavior.
- **ADR-0044** Command palette architecture (single command registry shared with menus; ranking).
- Update ADR-0008 (file watching) if the visible-tab-only/inactive-app latency policy changes it.

## 7. Open questions / spikes

| Question | Spike | Decision criteria |
|---|---|---|
| Rust signposts: native `os_signpost` from Rust vs Swift-side intervals around bridge calls? | Implement both for one call; inspect in Instruments. | Zero cost when disabled; visible in Points of Interest; minimal deps. |
| Can xctrace export reliably produce signpost intervals headlessly? | Record + export one launch trace. | Works on current Xcode without manual steps → automate; else document manual. |
| Relative-date refresh: timer while visible vs on-activation only? | Measure wakeups both ways. | Choose the one with ≈0 idle wakeups and acceptable staleness (≤ 1 min while user is active). |
| Snapshot library vs custom? | Snapshot 3 screens with each. | Determinism across runs, AppKit support, dependency weight. |
| Is `criterion` acceptable as dev-dep? | `cargo tree` size, build time. | Dev-only, reasonable compile time; otherwise custom harness. |
| Increase Contrast token variants: separate set or computed? | Prototype on 3 screens. | Visual quality and maintainability in design-system.md. |
