# Performance

Budget (§15.1, `docs/roadmap.md` §7) and measured results. Numbers are reported as measured; nothing
here is estimated. Raw outputs are written to `scripts/benchmarks/out/` (git-ignored).

## Phase 6 — final report (2026-11-09)

Reference Mac (ADR-0041): MacBook Pro `Mac17,9`, Apple M5 Pro, 24 GB, macOS 27.2 (26B123), Git 2.54.0 (Homebrew), AC
power, Low Power Mode off. Release build, launched through LaunchServices outside Xcode, medians and p90 over ≥ 10
runs after a warm-up. **Conditions:** the machine was busy throughout (load average ≈ 4.5; GitKraken's renderer
and WindowServer ≈ 45 % CPU each, Claude, Teams) — absolute times carry that noise (diff switch varied 43–53 ms
between identical runs). Full results: `scripts/benchmarks/baseline/reference.json` (+ `reference-summary.md`);
start-of-phase baseline: `baseline/phase6-start.json`. Repositories: `scripts/benchmarks/gen-repos.sh`.

### §15.1 targets

| Metric | Target | Phase 6 start | Final | Method | Status |
|---|---|---|---|---|---|
| Warm launch → first window key | < 500 ms | 264.6 / p90 274.3 ms | **259.3 / p90 266.1 ms** | `scenarios/launch-warm.sh` (n = 10) | met |
| Cold launch → first window key | < 1 s | 236.0 / p90 253.8 ms | **241.0 / p90 249.5 ms** | `scenarios/launch-cold.sh` (`sudo purge` before each of 5 runs — an approximation of cold) | met |
| Idle CPU after settling | 0.0–0.2 % | 0.0 % (top), 2.4 % peak with 5 tabs (not reproducible) | **0.00 %** (0, 1, 5 tabs); powermetrics 0.007–0.10 ms/s CPU visible / minimized / hidden (≤ 0.01 %) | `scenarios/idle.sh`, `powermetrics.sh` | met |
| Idle wakeups | minimal | top IDLEW 1–9/s (noisy) | **0–0.34 interrupt wakeups/s, 0 package-idle wakeups** (powermetrics) | same | met |
| Idle network | none | none | **0 sockets, 0 bytes** (0, 1, 5 tabs; 30–60 s windows) | `network-idle.sh` | met |
| Idle memory, no repository | < 120 MB | 32 MB | **32 MB** | `footprint` | met |
| Memory, typical repository open | < 200 MB | 71 MB (1 tab, branchy-10k) | **72 MB**; 5 tabs 70–74 MB; 6 tabs after switching 110 MB; 100k fully loaded 102 MB | idle / multi-tab / graph-scroll | met |
| Graph scrolling | 60 FPS | step 1.68 / p95 2.04 ms | **1.63 / p95 1.92 ms, 0 of 400 steps > 16.7 ms** (huge-100k) | `graph-scroll` (programmatic steps; Animation Hitches by hand: not run) | met (main-thread budget) |
| Diff switching | immediate for normal files | 63.5 / p90 68.7 ms | **51.9 / p90 53.7 ms** (43–53 across runs) | `diff-switch` (many-files, file → file) | met (< Phase 3's 50 ms budget in most runs; see bottlenecks) |
| Tab switching | immediate (< 16 ms, P1) | 16.7 / p90 27.8 ms | **17.4 / p90 31.6 ms** | `multi-tab` (6 tabs, select → next main-queue turn) | **near miss** (see bottlenecks) |
| Idle memory growth | none | open/close ×50: 150 → 531 MB, settled 411 MB | **149 → 157 MB, settled 66 MB; `leaks`: 0** | `open-close-loop` | met |

### Other Phase 6 metrics

| Metric | Start | Final | Method |
|---|---|---|---|
| Repo open → first graph rows, branchy-10k | 169.9 / p90 181.3 ms | 178.6 / p90 180.7 ms | `open-repo` |
| Repo open, many-files (500 changes) | 134.7 ms | 137.2 ms | `many-files` |
| Graph first page, huge-100k (no commit-graph, 1,000 refs, 500 tags) | 707.5 ms | 735.2 ms (single run) | `graph-scroll` |
| Page append (main thread) | 0.34 ms | 0.35 ms | `graph-scroll` |
| 50,000-line diff (200 hunks) switch | — (was hidden by the minified file) | 155.3 / p90 170.6 ms, 191 MB | `large-diff` |
| 5 MB single-line diff switch / footprint | 194 ms / **1,215 MB** | 167.5 ms / **211 MB** | `large-diff` |
| Lane layout 10k / 100k (parse + layout + store) | 5.6 / 49.4 ms | 5.6 / 50.3 ms | `JitBench micro` |
| Status parse, 100k entries | 8.6 ms | 8.1 ms | same |
| Diff parse, 50k-line patch (3.1 MB) | 0.96 ms | 0.97 ms | same |
| Patch build, one line of the 50k-line file | 8.5 ms | 9.4 ms | same |
| Glass cost (glass vs `-JitOpaqueChrome`, huge-100k) | — | idle Jit energy 0.017 vs 0.015; scroll step 1.71 vs 1.80 ms (0 over 16.7 ms both); Jit energy while scrolling 948 vs 843 (+12 %); tab switch 17.2 vs 15.8 ms | `scenarios/glass-cost.sh` (single runs) |

`JitBench micro`: within a run, p90 is within 0.1–4.5 % of the median; between the two runs above the medians moved
0.6–10 % (patch build 8.5 → 9.4 ms) on the busy machine — above the design's 3 % criterion, so CI uses the loose
(2.5×) thresholds and only the reference-Mac run counts. The custom harness is kept (no third-party dependency).

### Optimizations (each from a trace or benchmark)

1. **Closed tabs leaked** (heap: 50 graph controllers, sessions, handles after 50 cycles). Hosted SwiftUI views
   held their owning controller (graph bar/overlay, diff chrome) and `WorkbenchController.connect` closures captured
   models strongly. Teardown on close + weak captures → 531 → 157 MB peak, 411 → 66 MB settled, 0 leaks.
2. **Diff switch** spent its time in 7 sequential Git processes (snapshot token before and after the diff) and in
   byte-wise fingerprint hashing (183 samples). Concurrent token reads, one fingerprint per token, word-wise content
   hash → 63.5 → 43–52 ms.
3. **5 MB minified line**: 220 MB of `CTLine` glyph advances, ≈ 400 MB large mallocs, 236 MB GPU surfaces. Lines
   laid out up to 10,000 characters, width capped → 1,215 → 211 MB.
4. **Tab switch** re-applied split-view divider positions every time (190 main-thread samples / 40 switches → 0).
   Latency unchanged; reverted three toolbar guards that did not measurably help.
5. **Launch**: the accounts service (Keychain, `NWPathMonitor`) was created at launch through the window
   controller; now lazy (`LaunchWorkTests`). Launch time itself needed no change (first-window layout ≈ 60 ms
   dominates main-thread time).

### Bottlenecks and options for what is not clearly met

- **Tab switch (17.4 ms median, p90 31.6 ms vs < 16 ms).** Time Profiler: about half is `NSToolbarView` layout
  of the SwiftUI tab strip (glass tab selection re-render ≈ 1.4 ms of it per the opaque A/B), the rest SwiftUI
  relayout of the shown workbench; the p90 comes from switching onto the 100k and 50k-file tabs. Options: render the
  tab strip as AppKit views (large change, loses the glass morph), or keep each workbench's hosted SwiftUI subtrees
  stable across switches (medium). Phase 1 measured 6.6 ms with far less chrome; the measured value is reported,
  not tuned.
- **Diff switch for normal files (≈ 43–53 ms).** Three Git process waves (token, diff, token) ≈ 18–20 ms and a ≈
  13 ms SwiftUI relayout of the inspector per switch. Option: replace the after-diff token's processes with
  file-system fingerprints of `.git/index` and the file (safe only together with the write-gate re-check; deferred
  as a data-safety decision, §26 priority 1).
- **Large files (155–168 ms for 4–5 MB files)** are dominated by Git hashing and diffing the file twice.
- **Graph first page on huge-100k (≈ 0.7 s)** is Git's `--topo-order` walk without a commit-graph file and 1,500
  refs; with a commit-graph Phase 2 measured 143–156 ms. Option: offer `git commit-graph write` (mutation; needs an
  explicit user action).

### Not measured

- Instruments Animation Hitches during a real trackpad fling and live-resize drag (programmatic steps and AppleScript
  resizes were measured instead).
- Compositor-side GPU cost of glass: powermetrics' per-process GPU counter reads 0 for Jit and WindowServer on this
  machine, and WindowServer energy is dominated by other apps.
- Release-build memory of the repository browser and credential-delivery overhead (Phase 5 carry-overs; no real
  provider accounts in this environment).

## Phase 4 — 2026-11-09

MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Git 2.54.0 (Homebrew), release builds unless noted.

| Metric (implementation.md §4) | Target | Measured | Method |
|---|---|---|---|
| Idle CPU after a completed fetch, banner visible (repo mid-cherry-pick), activity item shown | 0.0–0.2 % | **0.00 %** mean over 30 samples, **0** idle wakeups in 58 s, 3 threads, 64 MB footprint | release app, Repository ▸ Fetch, 10 s settle, `top -l 31 -s 2 -stats cpu,idlew,threads`, `footprint` |
| Resolver open, 5,000-line file with 20 blocks (classify + stage blobs + `merge-file` + parse) | < 250 ms | **59–60 ms** (3 runs) | `swift test -c release --filter load5000LineConflictWith20Blocks` |
| Auth failure without prompt (local HTTP 401) | fail fast | ~50 ms isolated (debug) | `authFailureFailsFastWithoutPrompt` |
| Progress stream rate | ≤ 10 Hz, buffer 1 | 99 updates in < 100 ms → ≤ 2 yielded; `.bufferingNewest(1)` keeps only the newest | `progressThrottledToTenHertz`, `progressStreamDropsStaleValues` |

Not measured: Core Animation commits / GPU with the banner visible (needs Instruments / root `powermetrics`; CPU
and wakeups above were 0), post-operation graph refresh on a 10k-commit repo with 50 new commits, memory after
closing the resolver, Leaks during 50 fetch/merge cycles.

## Phase 3 — 2026-11-09

MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Git 2.54.0 (Homebrew), release builds unless noted.
`swift run -c release --package-path macos/Packages/JitKit JitBench phase3` and `… JitBench renderer-spike`
(offscreen 1000×800 window; generated repositories in a temporary sandbox).

| Metric (implementation.md §4) | Target | Measured | Method |
|---|---|---|---|
| Diff open → first paint (2k-line file; Git read + token + parse + layout + draw) | < 50 ms | **p50 41.5 ms**, max 63.2 ms (n = 21) | `JitBench phase3` |
| Renderer first paint, 2,401 / 60,001 rows (view only) | — | 5.7 ms (28.2 ms cold) / 8.0 ms | `JitBench renderer-spike` (ADR-0011) |
| Diff scroll, 50k-line diff | 60 FPS, 0 hitches > 1 frame | full redraw per step: p50 0.83 ms, p99 1.05 ms, max 1.53 ms, 0 / 400 steps > 16.7 ms | `renderer-spike` (programmatic steps, not Instruments) |
| Diff memory, 50k-line file (57,143 rows) | < 30 MB | +3.0 MB footprint (document 3.3 MB: 28 B/line beyond Git's output) | `phase3`, `diffDocumentMemory50kLines` |
| Memory after 200 diff open/close cycles | no growth (± 2 MB) | 25.0 → 25.5 MB (Δ 0.5 MB) | `phase3` (`task_info` phys_footprint) |
| Status refresh, 1k changed files | < 100 ms | p50 20.1 ms | `phase3` |
| Stage one line end to end (token, patch, check, apply, verify), 300-line file | < 150 ms | p50 51.9 ms, max 55.5 ms | `phase3` |
| Blame first lines, 5k-line file | < 200 ms | p50 5.1 ms (debug test: 6.1 ms) | `phase3`, `blameFirstLinesOf5kLineFile` |
| Idle CPU, repository open (release app) | 0.0–0.2 % | 0.0 % mean and max, 1.0 wakeup/sample, 6 threads, 50 MB | `idle.sh phase3-diffdemo` (40 samples) |

Renderer comparison (TextKit 2 on the same documents, now removed): 52.7 ms / 910.7 ms first paint, 18–19 of 400
steps over 16.7 ms, +102 MB at 60k rows — see ADR-0011.

Not measured: Instruments Animation Hitches during a real trackpad fling over the diff, GPU while idle with a
diff open (`powermetrics` needs root), idle *after a commit made in the app* (the release app was measured with
the repository open; commits were exercised in tests and the debug app), Allocations-instrument verification of
inactive-tab release (verified by `DiffReleaseTests` instead).

## Phase 2 — 2026-11-09

MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Git 2.54.0 (Homebrew), release builds. Repositories:
`history-1000/10000/100000` fixtures (no commit-graph unless stated) and a clone of `github.com/git/git`
(86,059 commits from all refs, 1,012 tags, no commit-graph unless stated).

| Metric (implementation.md §4) | Target | Measured | Method |
|---|---|---|---|
| First 300 rows visible, 100k fixture, from history start | < 150 ms | **143–156 ms** with a commit-graph; **413–427 ms** without | `JIT_BENCHMARK_GRAPH=1`, 3 runs each |
| Same, git/git | — | 142–157 ms with; 485–504 ms without | same |
| Same, 1k fixture | — | 111–123 ms | same |
| Folder opened → first rows drawn (adds discovery + status) | — | 188–206 ms with; 458–566 ms without | same |
| `git log` first 300 rows (loader only) | — | 32–35 ms with; 284–379 ms without (100k) | `JitBench history-source`, ADR-0010 |
| Page append, main thread | < 16 ms | median 0.27–0.30 ms, max 0.33 ms | same (`insertRows`) |
| Scroll step (one screen, layout + display), 400 steps | 60 FPS | median 1.56 ms, p95 1.76–1.94 ms, max 10.9 ms; 0 steps > 16.7 ms | same |
| Row draw (graph cell) | ≤ 2 ms p95 | p95 0.012 ms (fixtures), 0.110 ms (git/git) | same |
| `CommitStore`, 100k commits | ≤ 25 MB | **18.1 MB (189 B/commit)**; git/git 86k: 53.4 MB (wide lane sets, ADR-0022) | `CommitStoreMemoryTests`, benchmark |
| App footprint, 100k loaded | < 200 MB (typical repo) | 86 MB (100k fixture), 129 MB (git/git all loaded), 61 MB idle after first pages | benchmark, `footprint` |
| Search over loaded 100k | < 30 ms | 2.4 ms (100k), 3.2 ms (git/git) | benchmark |
| Lane layout, 100k rows | < 150 ms | 13 ms (parse + layout + store 60 ms) | `lanesLayout100kUnder150ms` |
| Refs parse, 10k refs | < 100 ms | 4 ms | `refs10kBranchesUnder100ms` |
| External commit → graph updated | < 500 ms | 37 ms after the refs event + FSEvents 0.2 s latency | `externalCommitAppearsAsReplacementKeepingRows` |
| Idle CPU, 100k open | 0.0–0.2 % | 0.0 % (61 + 30 + 30 samples, active and inactive) | `idle.sh` |
| Idle wakeups | no regression | 1.0/s active with 100k open, 0.57/s inactive; **baseline without a repository 2.0/s** in the same session | `idle.sh` (fixed parser, below) |
| Reader process while idle | 0 CPU | 0.00 ms over 2 s; footprint 16 MB (commit-graph) – 93 MB (git/git, none); killed when the tab hides | `JitBench history-source` |

Not measured (carried over): Instruments Animation Hitches during a trackpad fling (the scroll numbers above
are main-thread cost per programmatic scroll step), memory with three large tabs, `powermetrics`.

**Correction to Phase 1:** `top`'s IDLEW column in logging mode is per sample interval, not cumulative; Phase 1's
"0 wakeups" was last − first of that column. `idle.sh` now reports the per-sample mean/max (and strips `top`'s
`+` suffix that made the parser fail). Re-measured baseline without a repository: 2.0 wakeups/s.

## Phase 1 — 2026-11-09

Environment as Phase 0 (MacBook Pro `Mac17,9`, M5 Pro, macOS 27.2, Xcode 27.2, Git 2.54.0 Homebrew), **release**
build unless noted. "5 tabs" = a restored session with a regular clone of this repository (active), a linked
worktree, a merge in progress, a rebase in progress and a 50,000-file repository (`JIT_APP_SUPPORT` state dir).

| Metric | Target | Phase 0 | Phase 1 | Method |
|---|---|---|---|---|
| Warm launch → key window, no tabs | < 500 ms | 237.1 ms median | **256.8 ms median, p90 265.0** (n = 20, all `key`; final build — an earlier run gave 261.0) | `JIT_BENCH_LABEL=key-0tabs launch.sh --key 20` |
| Warm launch → key window, 5 restored tabs | < 500 ms | — | **293.0 ms median, p90 302.1** (n = 20) | `JIT_APP_SUPPORT=<5 tabs> launch.sh --key 20` |
| Idle CPU, no repository, app active | 0.0–0.2 % | 0.0 % | **0.0 %** mean and max, **0** wakeups in 60 s, 3 threads, **31 MB** | `JIT_ACTIVATE=1 idle.sh p1-no-repo-active` |
| Idle CPU, 5 tabs, app active (glass chrome on screen, one FSEvents stream) | 0.0–0.2 % | — | **0.0 %** mean and max, **0** wakeups, energy 0.0, 3–4 threads, **40–41 MB** (two runs, incl. the final build) | `JIT_ACTIVATE=1 idle.sh p1-5tabs-active` |
| Idle CPU, 5 tabs, app in background | ~0 %, no FSEvents callbacks | — | **0.0 %**, **0** wakeups, 3 threads, 40 MB (no session active; callback counter test in `AppModelTests.testNoStreamWhenAppInactive`) | `idle.sh p1-5tabs-background` (never activated) |
| Tab switch, loaded tab (select → layout + display committed) | < 16 ms | — | **median 6.6–7.0 ms, p90 9.6–10.1 ms** (4 runs × 25 switches, last on the final build; 16.7 ms before keeping hidden views in place) | `JIT_BENCHMARK_TAB_SWITCH=1` |
| Tab switch, first show (builds the workbench, starts loading) | — | — | median 33.6 ms (n = 5 × 3 runs) | same |
| Memory over open/close cycles | no sustained growth | — | 31.6 MB → 42.2 (10 cycles, warm-up) → **43.3 (50)**; 200 cycles: ≈ 16–21 KB per cycle after warm-up | `JIT_STRESS_OPEN_CLOSE=<repo> [JIT_STRESS_CYCLES=200]` |
| Idle network | none | — | **none**: no sockets (`lsof -i -p`), no traffic (`nettop -p`) with 5 tabs | manual, release |
| `status-parse`, 100k entries (14 MB sample) | — | — | **p50 8.68 ms**, p90 8.90; ≈ 5.3 MB of arrays beyond Git's output buffer | `JitBench status-parse` |
| `git status` on the 50k-file fixture | — | — | ≈ 60 ms wall, ≈ 0.43 s CPU (parallel `lstat`) | `/usr/bin/time` |
| 10,000 ignored files rewritten (≈ 1.3 s) with the tab visible | coalesced | — | **9 status runs** (18 before the duty-cycle rest), ≈ 3.9 s Git CPU, +0.07 s app CPU; nothing after the churn stops | debug build, `/usr/bin/log stream` count of refreshes |
| Cold launch, idle GPU power | < 1 s / no recurring work | not measured | **not measured** — needs a reboot / root (`powermetrics`) | user-run |

Reading:
- **Launch +20 ms vs Phase 0.** Phase 1 builds an AppKit window with a toolbar, a hosted SwiftUI tab strip and
  profile capsule, a code-built menu bar and reads three JSON files before the first frame; restoring 5 tabs adds
  another ≈ 33 ms (cached titles only, no Git work). Both stay well inside the 500 ms budget; Phase 6 owns further
  launch work.
- **Idle is idle**, with the glass chrome on screen and an FSEvents stream running for the visible tab; the
  Phase 0 "inactive-window CPU burst" did not reproduce in any of the three 60 s runs.
- **Memory:** a heap diff between 30 and 130 cycles shows no Jit object surviving a closed tab (one `AppModel`,
  one `TabModel`, no sessions, handles, watchers or controllers) and `leaks` reports 0 leaks. The residual growth
  is framework-internal: SwiftUI `GlassContainer` per-view-identity state (dictionary capacity, ≈ 0.6 MB / 100
  cycles) and AppKit `NSKeyValueDependency` records (≈ 62 per cycle, not from Jit's own KVO — removed and
  re-measured). Recorded as a Phase 6 carry-over (Instruments Allocations generations; try pooling workbench
  controllers so a new tab reuses SwiftUI identities).
- **Churn:** coalescing keeps one status in flight plus one queued; a queued refresh now rests as long as the last
  status took (≤ 1 s, one cancellable sleep) so Git runs at most about half the time during a build. Ignore-aware
  event filtering is a Phase 6 option.

## Phase 0 baseline — 2026-11-09

Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), Xcode 27.2 (27B52),
Swift 6.4.2, Git 2.54.0 (Homebrew). **Release** build (`scripts/build/build-app.sh release`), arm64,
ad-hoc signed, Hardened Runtime. Machine otherwise idle (an AI coding session and its terminal were
running).

| Metric (§15.1) | Target | Phase 0 result | Method |
|---|---|---|---|
| Warm launch → first window key | < 500 ms | **median 237.1 ms, p90 240.2 ms** (n = 20, all ended on the key window) | `scripts/benchmarks/launch.sh 20` |
| Cold launch | < 1 s | **not measured** — needs a reboot or `sudo purge` (user-run) | see Methods |
| Idle CPU, no repository | 0.0–0.2 % | **0.0 %** mean and max over 60 × 1 s samples | `scripts/benchmarks/idle.sh no-repo` |
| Idle CPU after one discovery | 0.0–0.2 % | **0.02 %** mean (one 1.0 % sample, 59 × 0.0 %) | `JIT_OPEN=<this repo> scripts/benchmarks/idle.sh after-discovery` |
| Idle wakeups during the 60 s window | — | **0** (both cases; 5 in total since launch) | same runs, `top` IDLEW delta |
| Energy impact at idle (`top` POWER) | — | **0.0** (no repo), 0.02 (after discovery) | same runs |
| Threads at idle | — | **4** (no repo) / **3** (after discovery) | same runs, `top` TH |
| Idle memory, no repository | < 120 MB | **28 MB** physical footprint | `footprint <pid>` in `idle.sh` |
| Memory after one discovery | — | **45 MB** physical footprint | same |
| Git process spawn (`git --version`) | — | **p50 4.81 ms, p90 5.45 ms** (n = 200) | `JitBench spawn-latency` |
| Repository discovery (4 Git calls) | — | **p50 18.65 ms, p90 21.79 ms** (n = 200) | `JitBench discovery` |
| App bundle size (release) | — | 976 KB | `du -sh Jit.app` |
| Idle GPU power with glass chrome | no recurring work | **not measured** — `powermetrics` needs root (user-run) | see Methods |

Reading: at idle the app does no work — no CPU, no wakeups, no energy impact — with the Liquid Glass
toolbar on screen. ADR-0005's "no idle threads" holds: after a discovery, the process has fewer threads
(3) than at launch, and no Dispatch source, timer or child process remains.

### Observation followed up in Phase 1 (not reproduced)
Earlier in the Phase 0 session the release binary was launched directly from a shell (not through LaunchServices),
so its window stayed inactive. Both such runs showed one burst of 0.7–3.1 % CPU lasting about 7 s, with
worker threads briefly rising from 4 to 13, at an unrelated time after launch (35 s and 73 s). `sample` at
5 ms intervals did not catch the work. Neither a key-window run nor the two
LaunchServices runs above reproduced it. Next step: Instruments Time Profiler on an inactive window.
Recorded in `docs/phases/00-foundation/progress.md`.

## Methods

- **Launch** (`launch.sh`): `open -n -W --env JIT_BENCHMARK_OUTPUT=<file> -a Jit.app --args
  -JitBenchmarkLaunch` — a LaunchServices launch, like a user's. The app reads the kernel start time of
  its own process (`sysctl KERN_PROC_PID → kp_proc.p_starttime`), stops at the first
  `NSWindow.didBecomeKey`, waits one main-queue turn so the frame commits, prints
  `first_window_ms=<ms> trigger=key`, and quits. One warm-up run is discarded. An `os_signpost` interval
  ("Launch", subsystem `jit.performance`) is emitted for Instruments. If the app is not activated (for
  example launched from a background process), the measurement instead ends when the root view appears
  (`trigger=content`). The trigger is recorded per sample; all 20 baseline samples were `key`.
  The output path travels in the environment because AppKit treats path-like launch arguments as files
  to open.
- **Cold launch** (not automated): reboot (or `sudo purge` for an approximation), then run
  `scripts/benchmarks/launch.sh 1`.
- **Restored-tab states** (`JIT_APP_SUPPORT=<dir>` with a `session.json`): passed to `open` with `--env` by
  `launch.sh` and `idle.sh` so benchmarks never read or write the user's own state.
- **Tab switch** (`JIT_BENCHMARK_TAB_SWITCH=1`, all builds): with ≥ 2 restored tabs, the app selects every tab in
  turn, measuring `select` → `layoutSubtreeIfNeeded` + `displayIfNeeded` of the window (the committed frame);
  round 1 = first show of each tab, rounds 2–6 = loaded tabs. Also an `os_signpost` interval "TabSwitch".
- **Open/close stress** (`JIT_STRESS_OPEN_CLOSE=<repo>`, `JIT_STRESS_CYCLES`, `JIT_STRESS_HOLD=1` keeps the app
  running for `heap`): opens the repository, waits for its status, closes the tab; reports `phys_footprint`.
- **Idle** (`idle.sh`): launch through LaunchServices, wait 30 s, then `top -l 61 -s 1 -pid <pid>
  -stats pid,cpu,idlew,power,th`. The first sample has no CPU delta and is dropped. `top`'s IDLEW is a
  cumulative counter, so the report gives its increase during sampling. `footprint <pid>` gives the
  physical footprint. `JIT_ACTIVATE=1` brings the app to the front first.
- **GPU / energy with glass** (user-run, needs root): with the app idle on screen,
  `sudo powermetrics --samplers gpu_power -i 1000 -n 60`, and Instruments ▸ Energy Log / GPU. Expected
  result: no recurring GPU work from Jit while nothing changes.
- **Micro-benchmarks**: `swift run -c release --package-path macos/Packages/JitKit JitBench
  [spawn-latency|discovery|all] [--iterations N]` — real Git, a fresh `GitTestKit` sandbox repository,
  3 warm-up iterations, `ContinuousClock`, JSON per benchmark.
- **History fixtures** (Phase 2): `scripts/benchmarks/make-history-fixture.sh --standard` builds
  `history-1000`, `history-10000` and `history-100000` under `$JIT_FIXTURES` (default
  `~/Library/Caches/jit-bench/`, outside the repository) with `git fast-import` from GitTestKit's
  `SyntheticHistory`: `main` + up to 8 concurrent feature branches, a merge every 20 commits, the newest
  50 feature branches kept as refs, 200 tags (every 4th annotated), `origin/main` trailing `main`. Fixed
  seed, dates and identities: the same arguments give the same HEAD (`history-100000` →
  `f7f267864f778bf8e05824a9fd47c2521cac93a5`). Build time on the reference Mac: 0.5 s / 0.9 s / 6.2 s.
  Custom sizes: `make-history-fixture.sh <commits> <branches> <out>`. Real-world cross-check: a clone of
  `https://github.com/git/git` at `~/Code/git-src`.

## Phase 5 (debug build, MacBook Pro M5 Pro, macOS 27.2, Git 2.54.0)
| Metric | Result | Method |
|---|---|---|
| Idle CPU, repo open, account + custom CA configured | 0.0 %, ~1 idle wakeup / 20 s, 64 MB | `top -pid` |
| Idle network | none | `nettop -p` |
| Launch | no Keychain reads or network (lazy `AccountsService`) | code review |
Release-build measurements for Phase 5 (credential overhead, browser memory) are carried over to Phase 6.

## Release build — Phase 7 (1.0.0, installed from the DMG)

Measured on 2026-11-10 on the reference Mac (MacBook Pro M5 Pro, macOS 27.2, busy desktop at load ≈ 2.5–3).
App: `/Applications/Jit.app`, the ad-hoc-signed arm64 build installed from `Jit-1.0.0.dmg`, Hardened
Runtime, **bundled Git 2.56.0** (Phase 6 used Homebrew Git 2.54.0). Command: `JIT_BENCH_APP=/Applications/Jit.app
JIT_APP_SUPPORT=<tmp> scripts/benchmarks/run-all.sh`. Results: `benchmarks/results/20261110-000744-180ea82.json`.

| Metric | Phase 6 final | Release 1.0.0 | Note |
|---|---|---|---|
| Warm launch (first window) | 259.3 ms | 270.2 ms (p90 273) | +4 %, within the Phase 6 threshold; bundle is in /Applications, Gatekeeper/syspolicy checks on first exec |
| Cold launch (approx.) | 241.0 ms | 256.5 ms | not a true cold start (no purge) |
| Open repo (branchy-10k) | — | 158.9 ms; first graph page 124.1 ms | compare: ok |
| Graph scroll step (100k) | 1.63 / p95 1.92 ms | 1.45 / p95 1.66 ms, 0 > 16.7 ms | |
| Diff switch (small files) | 51.9 ms | 47.4 ms | |
| 5 MB-line diff footprint | 211 MB | 213.5 MB (minified) / 191 MB (table) | |
| Tab switch | 17.4 / p90 31.6 ms | full run 19.6 / p90 28.3 ms; isolated reruns 14.2 and 13.2 ms (DerivedData build the same: 14.5, 13.8 ms) | compare flagged the full-run value; reruns show it is load noise, not a release regression |
| Idle CPU 0/1/5 tabs | 0.00 % | 0.00 %; powermetrics 0.020 / 0.007 / 0.000 ms/s | |
| Idle wakeups 0/1/5 tabs | — | 0.033 / 0 / 0 per s (powermetrics) | |
| Idle network | 0 | 0 bytes, 0 sockets (0/1/5 tabs) | §19 |
| Memory no repo / 1 repo / 5 tabs | 32 / 72 / 70 MB | 31 / 72 / 69 MB | |
| Open/close ×50 | 157 peak / 66 MB settled | 156.5 / 65.8 MB | |
| JitBench micro diff-parse-50k | 0.968 ms | full run 1.139 ms; rerun 0.98 ms | flagged once; rerun within noise |

Verdict: no release regression beyond Phase 6 thresholds. The two `compare.sh` flags didn't reproduce in
isolated reruns. The bundled Git (2.56, system libcurl) costs nothing measurable against Homebrew 2.54.
