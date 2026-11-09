# Performance

Budget (§15.1, `docs/roadmap.md` §7) and measured results. Numbers are reported as measured; nothing
here is estimated. Raw outputs are written to `scripts/benchmarks/out/` (git-ignored).

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

### Observation to follow up (Phase 1)
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
