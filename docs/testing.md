# Testing

How Jit is tested, and how to run, record and re-baseline each suite. Rules: real temporary Git repositories
(`GitTestKit`), never mocked Git output; no skipped tests without a recorded reason.

## Suites

| Suite | Command | Notes |
|---|---|---|
| Package tests (GitCore, Services, Features, DesignSystem) | `scripts/build/test-core.sh` | Swift Testing; parallel. Timing assertions get headroom in debug (`PerfBudget`) and with `JIT_TEST_TIMING_SCALE`. |
| Native history actions | `scripts/testing/native-rebase-acceptance.sh` | Separate XCUITest scheme; foreground desktop and Developer Tools authorization required. |
| Signed in-app updates | `scripts/testing/signed-update-acceptance.sh /path/to/stage/Jit.app` | Native updater UI, real DMG and restarted release executable. |
| App tests | `scripts/build/test-app.sh` | Xcode test target hosted in the app. |
| Lint | `scripts/build/lint.sh` | swift-format, GitCore import rule, styling/glass rule. |
| Snapshot (visual regression) | `swift test --package-path macos/Packages/JitKit --filter SnapshotTests` | ADR-0040; see below. |
| Benchmark tooling | `python3 -m unittest discover -s scripts/benchmarks/tests` | `results.py` parse/compare. |
| Rig (enterprise) | `JIT_RIG=1 swift test … --filter "Rig\|Diagnostics"` | needs `scripts/testing/enterprise-rig/up.sh`. |

## Signed in-app updates

Run the package tests with `scripts/build/test-core.sh --filter UpdateTests`. Coverage includes a missing
or altered signature, a different signing key, a valid signature for another version, malformed signed
bytes, a tampered DMG, a different bundle signing pin, wrong bundle metadata and a valid swap.

Run `scripts/testing/signed-update-acceptance.sh /path/to/stage/Jit.app` against a packaged candidate,
using an unlocked macOS desktop with Developer Tools authorization and OpenSSL 3. It generates a
disposable key and a local GitHub-shaped release feed, then tests **Install and Restart** with native
macOS UI events. First it changes the signed DMG and replaces the legacy checksum. Jit rejects it and
the app bundle stays intact. Then it uses the genuine signed DMG and checks that the new app starts at
the same installation path with a different process ID and the expected version. The resulting
`.xcresult` is retained in a temporary directory printed by the script. The transport is local and the
outgoing debug app is test-specific. For broader compatibility, run the clean-machine protocol in ADR-0048.

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

## Reflog and recovery (Phase 8)

- Run `swift test --package-path macos/Packages/JitKit --filter 'Reflog|RecoveryJournalTests'` with
  `JIT_APP_SUPPORT` pointing to a temporary directory. Core cases use real SHA-1/SHA-256 repositories,
  compare safety fingerprints, expire reflogs, drop older stashes and check cancellation process cleanup.
- `ReflogFeatureTests` exercises a real window, lost-tip graph queries, branch recovery and stale-state
  refusal. `ReflogSnapshotTests` covers reflog/lost-commit/recovery-point lists in light/dark, plus opaque
  chrome variants. Snapshot journal dates are normalized; commits and targets come from real Git.
- Native QA: amend, open Repository ▸ Reflog, inspect the old commit, Create Branch (Switch to it off),
  and verify the old SHA is preserved while HEAD/index/worktree stay unchanged. See the
  [evidence](phases/08-post-v1/screenshots/reflog/README.md).
- Read-only release benchmark: `JitBench reflog <fixture> <output-directory>` (three warm-ups, 15 reads).
  Do not run timing-sensitive suites alongside builds or benchmark generation. `JIT_TEST_SERIAL=1`
  is available for the package suite.

## Native history actions

`NativeRebaseInputTests` exercises real AppKit windows/responder routing, literal text input and native
pasteboard drop validation. Tab enters the selected message; Command-Return opens review from the
list or message. In the review sheet, Return cancels; Tab twice from Copy then Space explicitly
confirms. It does not synthesize a WindowServer drag session. The separate
`JitNativeInputAcceptance` XCUITest scheme runs in light and dark appearances, uses pointer/keyboard
events, drags both directions, edits a message, cancels the default confirmation, then explicitly
executes and checks Git history/tree/identity. Native drag tests use `click(forDuration:thenDragTo:)`;
`press(forDuration:thenDragTo:)` sends touch input and does not exercise AppKit mouse dragging.

Run `scripts/testing/native-rebase-acceptance.sh` from an unlocked foreground desktop with macOS
Developer Tools authorization enabled. The script refuses when authorization is disabled; it never
changes that setting. It builds and registers a separately identified ad-hoc app copy, uses temporary
repositories/app support, and retains `.xcresult` screenshots outside the checkout. Each run has a
unique bundle ID and passes its exact application URL to XCTest so older QA copies cannot intercept
launches. The script resolves the actual Git binary with `xcrun --find git` before running the sandboxed
UI runner, where the `/usr/bin/git` shim cannot invoke xcrun. Jit's normal signing,
app support and repository remain untouched. UI test runner library validation is disabled only for the
ad-hoc test bundle, not the Jit app. An automation-mode initialization timeout means the test body did
not run; it is not evidence that drag passed or failed.

`CommitSurgeryNativeAcceptanceTests` adds light/dark graph context-menu workflows: older and HEAD
message edits, literal multiline input, Return cancellation, explicit save/drop, and Reflog → Create
Branch at Previous State. Git assertions verify messages, unchanged edit trees/parents, only the selected
drop's file removal, author/profile committer, clean status and recovered branch contents. These run in
the same isolated `JitNativeInputAcceptance` scheme (four cases total). Success notifications expire
before the next same-named operation is checked, preventing stale-toast assertions.

The script forwards xcodebuild arguments for focused runs, for example:
`-only-testing:JitNativeInputUITests/CommitSurgeryNativeAcceptanceTests`.
The shared native fixture moves a window that opened on another display onto the primary display
using a native title-bar drag; secondary-display XCTest screenshot creation is unreliable on this setup.
Do not run other GUI suites or interact with the pointer/keyboard during native acceptance.
`CommitSurgerySnapshotTests` pins its four references separately to macOS 27.0; the global snapshot
OS pin is unchanged.
