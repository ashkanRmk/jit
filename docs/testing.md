# Testing

How Jit is tested, and how to run, record and re-baseline each suite. Rules: real temporary Git repositories
(`GitTestKit`), never mocked Git output; no skipped tests without a recorded reason.

## Suites

| Suite | Command | Notes |
|---|---|---|
| Package tests (GitCore, Services, Features, DesignSystem) | `scripts/build/test-core.sh` | Swift Testing; parallel. Timing assertions get headroom in debug (`PerfBudget`) and with `JIT_TEST_TIMING_SCALE`. |
| App tests | `scripts/build/test-app.sh` | Xcode test target hosted in the app. |
| Lint | `scripts/build/lint.sh` | swift-format, GitCore import rule, styling/glass rule. |
| Snapshot (visual regression) | `swift test --package-path macos/Packages/JitKit --filter SnapshotTests` | ADR-0040; see below. |
| Benchmark tooling | `python3 -m unittest discover -s scripts/benchmarks/tests` | `results.py` parse/compare. |
| Rig (enterprise) | `JIT_RIG=1 swift test … --filter "Rig\|Diagnostics"` | needs `scripts/testing/enterprise-rig/up.sh`. |

## Visual regression (ADR-0040)

- References: `macos/Packages/JitKit/Tests/FeaturesTests/__Snapshots__/<screen>-<variant>.png`, variants `light`,
  `dark`, `light-ic`/`dark-ic` (Increase Contrast), `light-rt`/`dark-rt` (Reduce Transparency rendering).
- Pinned to the macOS version in `os-version.txt`; on another version the suite is disabled with that reason.
- Failure output: actual and diff PNGs in `$TMPDIR/jit-snapshots/` (path in the failure message).
- **Re-baseline** (OS upgrade or an intended visual change): `UPDATE_SNAPSHOTS=1 swift test --package-path
  macos/Packages/JitKit --filter SnapshotTests`, then review every changed PNG in the diff by eye and commit them
  with the reason. Run the suite twice afterwards to confirm it is stable.
- Live glass is not captured offscreen; review it with `JIT_SCREENSHOT_REGION=1 scripts/testing/screenshot.sh
  <light|dark> <out.png> -- -JitOpen <repo> [-JitShowCommandPalette YES]`.

## Benchmarks (ADR-0041)

- Repositories: `scripts/benchmarks/gen-repos.sh` (deterministic; `$JIT_BENCH_DIR`, default
  `~/Library/Caches/jit-bench/p6`).
- Full run: `scripts/benchmarks/run-all.sh` (release app, every scenario, micro-benchmarks; results in
  `benchmarks/results/`), then `scripts/benchmarks/compare.sh <results.json>` against
  `scripts/benchmarks/baseline/reference.json`.
- Single scenario: `scripts/benchmarks/scenarios/app-scenario.sh <open-repo|graph-scroll|diff-switch|large-diff|
  many-files|multi-tab|open-close-loop> <repo>…`; idle: `scenarios/idle.sh <0|1|5> <repo>…`; glass cost:
  `scenarios/glass-cost.sh <repo>`.
- Traces: `scripts/benchmarks/instruments/trace.sh '<template>' <seconds> <out.trace> [-- app args]`, then
  `signposts.py <trace>` (intervals) and `hotspots.py <trace> [--under F | --callers-of F]` (Time Profiler).
- Updating the baseline: run `run-all.sh` on the reference Mac under the recorded conditions, review the
  summary, copy the JSON to `scripts/benchmarks/baseline/reference.json` with the reason in the commit message.
