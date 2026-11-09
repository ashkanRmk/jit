# Phase 00 — Foundation & design: progress report

Status: **complete with carry-overs** (listed below; none blocks Phase 1)
Branch / PR: `phase/00-foundation` → PR to `main` "Phase 00 — Foundation & design"
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), Xcode 27.2 (27B52),
Swift 6.4.2, Git 2.54.0 (Homebrew; Apple Git 2.54.0 / CLT 2.50.1 also present), XcodeGen 2.46.0

## Implemented
- **P0.1 Feasibility** — environment, Liquid Glass APIs verified in MacOSX27.2.sdk (all macOS 26.0+;
  `NSGlassEffectView.effectIsInteractive` is 27.0-only), process APIs, `swift-subprocess` 1.0.2, Git
  behaviors (two-step discovery, `GIT_TEST_ASSUME_DIFFERENT_OWNER`). Evidence:
  `specs/P0.1-feasibility.md`, ADR-0006 addendum.
- **P0.2 Scaffold** — `.gitignore`, `.editorconfig`, `.swift-format`, ADR-0001/0003/0004 accepted,
  ADR-0005 accepted after the spike.
- **P0.3 GitCore** — `GitVersion`, `GitLocator` (file existence only; returns real binaries, never the
  `/usr/bin/git` shim), `ProcessEnvironment` (allowlist + non-interactive vars), `ProcessRunner`
  (`posix_spawn`, `SETSID` own group, Dispatch read/exit sources, caps, timeout/cancel → SIGTERM→SIGKILL,
  quit cleanup), `RepositoryDiscovery`, `GitEngine` actor, `GitCoreError` + redaction, `GitTestKit`,
  `JitBench`. Evidence: `GitCoreTests` (46 tests), `specs/P0.3-gitcore-primitives.md`, ADR-0005.
- **P0.4 Build pipeline** — `macos/project.yml` (XcodeGen), xcconfigs (macOS 26.0, arm64, Swift 6
  complete concurrency, Hardened Runtime forced on for ad-hoc signing, sandbox off, `com.example.jit`),
  `scripts/build/{gen-xcodeproj,build-app,build-all,test-core,test-app,lint}.sh`, `.github/workflows/ci.yml`.
  Evidence: `scripts/build/build-all.sh debug` from the tree; `codesign -dv` shows `flags=0x10002(adhoc,runtime)`.
- **P0.5 Foundation window** — single window, system glass toolbar with "Open…", ⌘O, drag-and-drop,
  empty / delayed loading / loaded / error states with per-error guidance, VoiceOver announcement.
  Evidence: `JitAppTests` (4), screenshots `screenshots/foundation-*`, `specs/P0.5-foundation-window.md`.
- **P0.6 Design system** — tokens as data with light/dark/Increase Contrast variants, type, metrics,
  motion, glass helpers (`jitGlass`, `GlassControlGroup`, `FloatingGlassCapsule`, primary/secondary glass
  buttons) with Reduce Transparency fallback, content styles, debug gallery (⌥⌘D). Evidence:
  `DesignSystemTests` (12), `screenshots/design-system-*`, `docs/design-system.md`, `specs/P0.6-design-tokens.md`.
- **P0.7 Baseline** — launch probe, `scripts/benchmarks/{launch,idle}.sh`, `JitBench`. Evidence:
  `docs/performance.md`, `specs/P0.7-baseline.md`.
- **P0.8 Docs** — `docs/{product,architecture,design-system,performance,security,release}.md`, README,
  CLAUDE.md "Commands", phase design/implementation outcome notes.

## Verified
- Tests: `swift test` **58 passed** (GitCoreTests 46, DesignSystemTests 12); `xcodebuild test`
  (JitAppTests) **4 passed**; skipped: none. Core suite stress-run 20× after the final runner changes:
  **20 of 20 passed, 0 hangs**. (An earlier stress run found a real hang — `NOTE_EXIT` delivered before the child was
  reapable — fixed and covered by ADR-0005.)
- Lint: `scripts/build/lint.sh` clean (swift format strict, no UI imports in GitCore, no hardcoded
  styling/glass outside DesignSystem). Release binary contains no debug gallery/snapshot code.
- Real-workflow checks (debug app, real repositories): this repository (branch + full SHA), a bare clone,
  a linked worktree (shows main repository), a fresh `git init` (unborn "No commits yet"), a plain folder
  (not a repository), a `chmod 000` folder (permission denied). A `JIT_GIT_PATH` wrapper that sleeps 5 s
  before running Git: the window kept rendering and showed the delayed loading state at 1.5 s (UI never
  blocked). Quitting mid-discovery left no Git process (and quit now SIGTERMs live groups explicitly).
- Screenshots: `screenshots/foundation-{empty,loading,loaded,error}-{light,dark}.png` (+ worktree, bare,
  unborn, permission cases) and `screenshots/design-system-<section>-{light,dark}.png`. **They are in-app
  renders** (see `screenshots/README.md`): content is exact, Liquid Glass is not captured.

## Performance (release build)
| Metric | Previous | Now | Method |
|---|---|---|---|
| Warm launch → key window | — | median 237.1 ms, p90 240.2 ms (n=20) | `launch.sh 20` (LaunchServices) |
| Idle CPU, no repo / after discovery | — | 0.0 % / 0.02 % (60 × 1 s) | `idle.sh` |
| Idle wakeups during 60 s | — | 0 / 0 | `idle.sh` (`top` IDLEW delta) |
| Idle footprint, no repo / after discovery | — | 28 MB / 45 MB | `footprint` |
| Threads at idle | — | 4 / 3 | `top` |
| Git spawn (`git --version`) | — | p50 4.81 ms, p90 5.45 ms | `JitBench spawn-latency` |
| Discovery | — | p50 18.65 ms, p90 21.79 ms | `JitBench discovery` |
| Cold launch, idle GPU power | — | not measured (need reboot/root) | see carry-overs |

## Decisions
- ADR-0001 Record architecture decisions — accepted.
- ADR-0003 XcodeGen-generated project — accepted.
- ADR-0004 Thin app target + `JitKit` package — accepted.
- ADR-0005 Concurrency, process & memory model — own `posix_spawn` runner; `swift-subprocess` 1.0.2
  rejected (persistent kqueue monitor thread: 9 threads vs 3 after one command).
- ADR-0006 Phase 0 addendum — minimum Git 2.39 (feature table), sandbox off / Hardened Runtime on,
  bundle ID placeholder, verified glass API names.
- Design: selection/focus follow the system accent; Tidewater only tints primary glass actions.

## Deviations from plan
- `SETSID` instead of `SETPGROUP` (also detaches from the terminal). Locator returns Apple's real Git
  binary instead of running `/usr/bin/git`. Docs updated: yes (design.md §8, ADR-0005, P0.3 spec).
- `test-app.sh`/all scripts keep DerivedData in `~/Library/Developer/Xcode/DerivedData/Jit`: the xctest
  runner hung "preparing to run tests" when loading bundles from the TCC-protected `~/Documents` checkout.
- Debug builds set `ENABLE_DEBUG_DYLIB = NO`: Xcode's preview dylib failed library validation under
  Hardened Runtime with ad-hoc signing (the app crashed at launch until fixed).
- Launch/idle benchmarks launch through LaunchServices and pass paths via environment variables:
  AppKit treats path-valued launch arguments as files to open, and direct-exec background launches
  sometimes got no window.
- Screenshots are in-app renders; real captures (glass, Reduce Transparency, Increase Contrast) were not
  possible (no Screen Recording permission in the session). Docs updated: yes.
- JitAppTests are an unhosted bundle linking `Features`/`GitCore`/`GitTestKit` (hosting in the app would
  link `GitCore` twice).

## Known issues / carry-overs
- **Glass review with real screen captures** — light/dark toolbar glass, gallery glass section, and both
  with **Reduce Transparency** and **Increase Contrast** on. Needs a person (or a session granted Screen
  Recording) to run `scripts/testing/screenshot.sh` or capture manually. Medium; Phase 1 kickoff.
- **Cold launch** and **idle GPU power** (`sudo powermetrics --samplers gpu_power`) — user-run. Low; Phase 1.
- **Idle CPU burst seen only with direct-exec, inactive windows** (≈7 s at ≤ 3.1 %, once per run, not
  reproduced via LaunchServices). Medium; Phase 1 with Instruments Time Profiler.
- **CI not yet observed green** — the workflow targets `runs-on: macos-26`; first run happens on this PR.
  If the runner image lacks Xcode 26+, the job fails with an explicit message. Phase 1 kickoff.
- **Running on a real macOS 26.0 machine** not possible here (dev machine is 27.2); only 26.0-available
  APIs are used. Phase 7 clean-machine tests.
- **Repository paths containing a newline** make discovery report "unexpected layout" (`rev-parse` output
  is newline-delimited). Low; Phase 1 (parse with `--path-format` per call or `-z` alternatives).
- Increase Contrast resolution is unit-tested via the mapping function only — AppKit only yields
  high-contrast appearances while the system setting is on. Covered by the manual capture above.
- Quit with write operations in flight must delay termination instead of SIGTERM (no writes exist yet).
  Phase 3/4.

## Self-review findings
A strict review (separate reviewer, code read only) found no blockers. Fixed in this branch:
- Exit-status backstops so a process can't hang if `NOTE_EXIT` is lost (grace-timer and both-pipes-closed
  re-checks) — fixed.
- Quit sent SIGKILL; now SIGTERM, only to groups with members — fixed (write-safe quit: carry-over).
- Launch metric ended on root-view appearance while labelled "window" — reworked: LaunchServices launch,
  trigger recorded per sample, baseline is 20/20 `trigger=key` — fixed.
- `DEVELOPER_DIR` trusted by the locator but not passed to Git (shim could still pop the CLT dialog) —
  locator now returns the real binary — fixed.
- `gitInfo` cache never invalidated / duplicate concurrent probes — shared in-flight probe, re-locate on
  `ENOENT`/`EACCES` — fixed.
- `killpg` on a possibly recycled pgid after reaping — signals only groups that still have members — fixed.
- Pipe write ends not close-on-exec — fixed.
- Nits fixed: timeout seconds rounded up, overflow-safe timer math, bounded reads per event, indicator
  task cancelled with its request, redaction of `Authorization:` headers and GitHub/GitLab tokens.
- Logged: newline-in-path discovery (above); `NSWorkspace` read inside dynamic color providers (kept;
  documented thread-safe AppKit property).
- Own findings during the phase: `NOTE_EXIT` race hang (stress test), gitignore hiding `scripts/build`,
  status icons rendered without color, Tidewater selection read as grey, hardened-runtime crash — all fixed.

## Next
- Phase 1 (`docs/phases/01-shell-and-tabs`): start with the carry-over glass captures (light/dark,
  Reduce Transparency, Increase Contrast) and the CI result on this PR; then P1.1.
- Preconditions: this PR merged; bundle identifier from the owner when convenient (placeholder
  `com.example.jit` works until Phase 7).
