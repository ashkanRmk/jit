# Performance

Budget (§15.1, `docs/roadmap.md` §7) and measured results. Numbers are reported as measured; nothing
here is estimated. Raw outputs are written to `scripts/benchmarks/out/` (git-ignored).

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
