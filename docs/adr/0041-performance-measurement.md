# ADR-0041: Performance measurement and regression policy

- Status: accepted
- Date: 2026-11-09
- Phase: P6
- Requirements: §15 (all), §18.5; design §4.1, §4.2, §4.7

## Context
Phase 6 needs repeatable numbers for every §15.1 target, a way to see them in Instruments, and a regression
check. Findings while building it: `xctrace record --launch <app>` resolves the bundle identifier through
LaunchServices and started a stale Debug UI-test build of Jit; scripted traces only enable dynamic tracing for
the Points of Interest category; `top`'s IDLEW column swung 5–14 wakeups/s between identical idle runs on a
busy machine while `powermetrics` showed ≈ 0.1/s.

## Decision
- **Authority:** the reference Mac (MacBook Pro `Mac17,9`, M5 Pro, 24 GB, macOS 27.2) decides pass/fail.
  Release builds launched outside Xcode only; median and p90 over ≥ 10 runs after a warm-up; environment
  (model, chip, RAM, OS build, Git, power source, Low Power Mode, thermal state) recorded in every result.
- **Instrumentation:** one `Signposts` registry in GitCore (Points of Interest, subsystem `com.ashkanrmk.jit`),
  names `<category>.<what>`, details only counts or a Git subcommand. Scenario drivers measure through the
  same intervals (`-JitBenchmarkScenario`, inert unless passed).
- **Harness:** `scripts/benchmarks/run-all.sh` → `benchmarks/results/<date>-<sha>.json` (schema 1:
  `{schema, timestamp, git_sha, machine, git_version, build, scenarios{name{metric{median,p90,unit,runs}}},
  errors}`) + Markdown summary. Traces via `instruments/trace.sh` (app started through `/usr/bin/env` so
  xctrace traces the intended binary) and `signposts.py` / `hotspots.py`.
- **Idle:** CPU, wakeups, GPU and energy from `powermetrics` (sudo, read-only) when available; `top` is kept
  as a fallback and recorded, not used for pass/fail. Network from `nettop` + `lsof`.
- **Thresholds** (`results.py compare`): times and memory +10 %; idle CPU +0.1 pt (`%`) or +2 ms/s;
  wakeups +1/s; threads +2; energy +0.5; idle network must stay 0 bytes. Missing metrics fail. `--loose`
  multiplies by 2.5 for CI.
- **CI** (GitHub Actions, macOS arm64): release build, `JitBench micro` and the compare tool in loose mode —
  advisory; only large regressions fail. The reference-Mac run is required before the phase PR and releases.

## Consequences
- Every optimization cites before/after numbers from the same tooling; changes that do not measurably help
  are reverted (Phase 6 reverted three toolbar guards on that basis).
- Benchmarks on a loaded machine carry noise (Phase 6: GitKraken and WindowServer at ≈ 45 % CPU each);
  reports state the conditions.
- xctrace's table schema can change with Xcode; `signposts.py` is pinned to the Xcode version in use.
