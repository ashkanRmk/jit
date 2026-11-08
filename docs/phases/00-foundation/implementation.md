# Phase 0 — Foundation & Design: implementation plan

Design: [`design.md`](design.md). Exit gate: this file §6 + [`../../roadmap.md`](../../roadmap.md) §9.
Pre-accepted decisions: [ADR-0002](../../adr/0002-pure-swift-core.md) (pure Swift, no Rust/UniFFI) and
[ADR-0006](../../adr/0006-platform-baseline-and-liquid-glass.md) (macOS 26+, native Liquid Glass).

## 1. Preconditions

- [ ] Full Xcode 26 or newer installed and selected: `xcode-select -p` prints a path inside `Xcode.app`;
      `xcodebuild -version` succeeds and reports ≥ 26 (Xcode 27.2 was being installed from the App Store
      during planning). If not, **stop** and ask the user to finish installing Xcode and run
      `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, `sudo xcodebuild -license accept`
      and `xcodebuild -runFirstLaunch`.
- [ ] macOS 26 SDK present (`xcrun --sdk macosx --show-sdk-version` ≥ 26) — run only after Xcode is selected.
- [ ] XcodeGen installed (`xcodegen --version`; 2.46.0 was installed via Homebrew during planning).
- [ ] Git ≥ the proposed minimum on the dev machine.
- [ ] Remote `origin` points at `https://github.com/ashkanRmk/jit` and the user can push.
- No Rust toolchain is needed (ADR-0002).

## 2. Milestones

### P0.1 — Environment & feasibility review
Goal: know exactly what the toolchain supports before writing code.
- [ ] Record macOS, Xcode, Swift, SDK, Git, CPU arch, signing identities
      (`security find-identity -v -p codesigning`, output summarized — never paste private data).
- [ ] Verify the **Liquid Glass APIs in the installed SDK**: SwiftUI `glassEffect`, `GlassEffectContainer`,
      `glassEffectID`, `.glass`/`.glassProminent` button styles, scroll-edge / background-extension
      modifiers; AppKit `NSGlassEffectView`, `NSGlassEffectContainerView`; toolbar/sidebar glass behavior;
      Reduce Transparency hooks. Record exact names/signatures.
- [ ] Check `swift-subprocess` (current release, platforms, process-group and env support) for the P0.3 spike.
- [ ] Look up the current XcodeGen version and macOS 26 deployment settings / Swift 6 settings in `project.yml`.
- [ ] Bundled-Git feasibility pre-check (ADR-0019 input): options, dependencies, licensing, signing.
- [ ] Write `docs/phases/00-foundation/specs/P0.1-feasibility.md` with findings and risks.
Files: `specs/P0.1-feasibility.md`. Done when: the findings name exact versions and API names to use.

### P0.2 — Scaffold, ADRs, conventions
- [ ] Create directories that get content in this phase only: `macos/` (`App/`, `Packages/JitKit/`,
      `Resources/`), `scripts/build/`, `scripts/benchmarks/`.
- [ ] `.gitignore` (Xcode `DerivedData`, generated `*.xcodeproj`, `.build/`, `.swiftpm/`, `.DS_Store`,
      benchmark outputs).
- [ ] `.editorconfig`; formatting via the toolchain's `swift format` with a checked-in configuration
      (SwiftLint only if the user approves the dependency).
- [ ] ADRs 0001, 0003, 0004 (Accepted) and 0005 (Proposed until the P0.3 spike lands) from
      `docs/adr/0000-template.md`. ADR-0002 and ADR-0006 already exist — link, don't rewrite.
Done when: tree matches roadmap §5 layout for the parts that exist; ADRs reviewed.

### P0.3 — `JitKit` package and `GitCore` primitives
- [ ] `macos/Packages/JitKit/Package.swift`: platforms `.macOS(.v26)`, Swift 6 language mode, targets
      `GitCore`, `GitTestKit`, `DesignSystem`, `Features`, `JitBench` (executable), test targets
      `GitCoreTests`, `DesignSystemTests`. No external dependencies unless the spike justifies one.
- [ ] **Spike:** minimal `ProcessRunner` on `posix_spawn` vs on `swift-subprocess`, both running
      `git --version` with env allowlist and process-group kill. Pick per design §7 criteria; finalize ADR-0005.
- [ ] `GitVersion` + tests: `parsesPlainVersion`, `parsesAppleGitSuffix`, `rejectsGarbage`,
      `comparesAgainstMinimum`.
- [ ] `GitLocator` with an injectable filesystem probe + tests: `prefersEnvOverrideInDebug`,
      `prefersHomebrewOverUsrBin`, `skipsUsrBinGitWhenCLTMissing`, `reportsNotFound`,
      `probesVersionLazily`.
- [ ] `ProcessRunner` + tests (use `/bin/sh -c` fixtures *only in tests*):
      `passesArgvWithoutShellInterpretation` (arg containing `; rm -rf` reaches the child verbatim),
      `sanitizesEnvironment` (child sees only allowlisted vars, `GIT_TERMINAL_PROMPT=0`, editor vars),
      `capsStdoutAndStderr`, `timeoutKillsProcessGroup` (grandchild also dies),
      `taskCancellationKillsProcessGroup`, `cancelledBeforeSpawnThrowsCancelled`, `nonzeroExitMapsToError`,
      `noThreadBlockedWhileWaiting` (run 64 concurrent `sleep` children; assert the cooperative pool stays
      responsive and thread count stays bounded).
- [ ] `RepositoryDiscovery` + integration tests via `GitTestKit`:
      `discoversRegularRepo`, `discoversFromSubdirectory`, `discoversBareRepo`,
      `discoversLinkedWorktree`, `reportsUnbornBranch`, `reportsDetachedHead`,
      `notARepository`, `pathWithSpacesAndUnicode`, `permissionDeniedDirectory`,
      `dubiousOwnershipMapsToUnsafeRepository` (simulate via `safe.directory` config if ownership
      can't be faked; otherwise document as manual check).
- [ ] `GitTestKit`: isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL` pointing to an empty
      temp file, fixed dates/identity, auto-cleanup.
- [ ] `GitEngine` actor: `gitInfo()`, `discoverRepository(at:)`; error summaries for every case.
- [ ] `JitBench`: `spawn-latency` and `discovery` benchmarks writing JSON to `scripts/benchmarks/out/`.
Verification: `swift test --package-path macos/Packages/JitKit` passes; `swift format lint` clean.
Done when: all tests pass locally; no force-unwraps/`try!` on fallible paths outside tests; `GitCore`
imports no AppKit/SwiftUI (checked by a test or script).

### P0.4 — Build pipeline and project generation
- [ ] `scripts/build/gen-xcodeproj.sh`, `build-app.sh`, `test-core.sh`, `build-all.sh` (bash,
      `set -euo pipefail`, readable errors, `--help`).
- [ ] `macos/project.yml`: app target `Jit` (macOS 26.0, arm64, Swift 6, Hardened Runtime, App Sandbox
      off, bundle id from an `xcconfig` placeholder `com.example.jit` until the user supplies one),
      depends on the local `JitKit` package products, app unit-test target `JitAppTests`.
- [ ] App-level test `JitAppTests.testDiscoverTempRepositoryThroughEngine` (uses `GitTestKit`),
      `testCancellationThrowsCancelled`.
- [ ] `.github/workflows/ci.yml`: macOS runner with Xcode 26+ selected explicitly, Homebrew `xcodegen`,
      `test-core.sh`, `build-all.sh debug`, `xcodebuild test -scheme Jit`.
Verification: fresh clone → `scripts/build/build-all.sh debug` succeeds; `xcodebuild test` passes;
CI green on the phase branch (or the exact runner limitation is reported).
Done when: one command builds the app from a clean checkout.

### P0.5 — Foundation window calling `GitCore`
- [ ] `JitApp` with a single window (min 960×600), unified system toolbar (glass by default) with the
      "Open…" toolbar button, content extending under the toolbar with the scroll-edge effect.
- [ ] `FoundationView` states: empty / loading (delayed 150 ms) / loaded card / error (per error type).
- [ ] ⌘O via `NSOpenPanel` (directories only), drag-and-drop of a folder onto the window.
- [ ] View model calls `GitEngine` in a `Task`; cancellation on new selection/window close.
- [ ] Debug main-thread guard: `dispatchPrecondition(condition: .notOnQueue(.main))` inside `ProcessRunner`
      spawn/wait paths.
Verification: open this repo, a bare repo, a linked worktree, a non-repo, an unreadable folder; check
copy and layout in light and dark and with Reduce Transparency; take screenshots →
`screenshots/foundation-{empty,loaded,error}-{light,dark}.png` (+ `-reducetransparency`).
Done when: all five cases display correctly and the UI never beachballs (verify with a deliberately slow
fake path, e.g. a FIFO or a sleeping network mount simulation, and cancellation).

### P0.6 — Design direction and tokens v1 (Liquid Glass native)
- [ ] `DesignSystem`: `ColorToken` (dynamic `NSColor` + SwiftUI `Color`, light/dark/Increase Contrast),
      `TypeToken`, `Space`, `Radius` (concentric with system shapes), `Border`, `Shadow` (content only),
      `Motion` (with Reduce Motion resolution, incl. `glassMorph`), `IconSize`, `PanelMetrics`, `Density`.
- [ ] Glass helpers that encode the usage rules: e.g. `GlassToolbarGroup` (wraps a
      `GlassEffectContainer`), `FloatingGlassCapsule`, `PrimaryGlassButtonStyle` (`.glassProminent` +
      `accent.tint`), each with a Reduce Transparency fallback to `surface.chromeOpaque`. Content helpers:
      row background (rest/hover/pressed/selected), content card, focus ring.
- [ ] Design-system gallery window (`#if DEBUG`), per design §3.2, including glass-over-content and the
      allowed/forbidden glass examples.
- [ ] Decide system accent vs Tidewater for focus/selection (design §3.3) from screenshots.
- [ ] Contrast check: a unit test computes WCAG contrast for text tokens on each content surface
      (≥ 4.5:1 for primary/secondary body text, ≥ 3:1 for tertiary labels and lane lines) in both themes
      and Increase Contrast.
- [ ] Iterate values from the design draft using rendered screenshots; record final values and the glass
      usage rules (with verified API names) in `docs/design-system.md`.
- [ ] Lint-style test or script: grep Swift sources outside `DesignSystem` for `Color(red:`, `NSColor(`
      literals, `.font(.system(size:`, `NSVisualEffectView`, raw `.glassEffect(` — fail if found (glass goes
      through `DesignSystem` helpers or system components).
Verification: gallery screenshots in light, dark, Increase Contrast, Reduce Transparency →
`screenshots/design-system-*.png`.
Done when: the gallery looks deliberate, native to macOS 26 and cohesive in both themes, and the
contrast test passes.

### P0.7 — Baseline measurements
- [ ] Benchmark mode: launch argument `-JitBenchmarkLaunch` logs `first_window_ms` measured from process
      start (`sysctl` `kinfo_proc.kp_proc.p_starttime`) to the first `NSWindow` `didBecomeKey`/first frame,
      then quits. Also emit an `os_signpost` interval for Instruments.
- [ ] `scripts/benchmarks/launch.sh` — N warm runs (median, p90); cold-run instructions (reboot or
      `sudo purge`, documented as approximate).
- [ ] `scripts/benchmarks/idle.sh` — launch, wait 30 s to settle, sample CPU for 60 s (`top -l`/`ps`),
      memory (`footprint` or `vmmap --summary` physical footprint), wakeups (`top -stats idlew` or
      `powermetrics` when run with sudo by the user), with the glass toolbar visible and the window both
      key and inactive.
- [ ] GPU/energy at idle with glass chrome: Instruments Energy/GPU or `powermetrics --samplers gpu_power`
      (user-run with sudo) — confirm glass adds no recurring work when nothing changes.
- [ ] `JitBench` results (spawn latency, discovery) recorded.
- [ ] Run on a release build; record Mac model, macOS, Xcode, Git, method in `docs/performance.md`.
Done when: baseline table exists with real numbers and the methods are reproducible.

### P0.8 — Documentation
- [ ] `docs/product.md` (concise product spec from §1–§12 for V1, explicit exclusions §9.3, owner
      amendments ADR-0002/0006).
- [ ] `docs/architecture.md` (layers, `JitKit` targets, data flow, concurrency/process model, glass vs
      content layering).
- [ ] `docs/design-system.md` (direction, token tables as implemented, glass usage rules with verified APIs).
- [ ] `docs/performance.md` (budget, methods, baseline).
- [ ] `docs/security.md` (threat model v1, process rules, secrets policy, sandbox/hardened runtime).
- [ ] `docs/release.md` (stub: bundled Git feasibility notes; release steps arrive in Phase 7).
- [ ] README dev setup; CLAUDE.md "Commands" filled with the real commands.
Done when: every statement describes what exists or is clearly marked planned.

## 3. Test plan summary

| Layer | Tests (`swift test` unless noted) |
|---|---|
| `GitCore` unit | version, locator, process runner (argv, env, caps, timeout, cancel, no blocked threads), error mapping |
| `GitCore` integration | discovery matrix using `GitTestKit` real repos |
| `DesignSystem` unit | token contrast (both themes + Increase Contrast), Reduce Transparency fallbacks resolve |
| App (`xcodebuild test`) | engine discovery through the app target, cancellation |
| Lint scripts | no hardcoded colors/fonts/blur outside `DesignSystem`; `GitCore` has no UI imports |
| Manual | foundation window cases, light/dark, Reduce Transparency, Increase Contrast, Reduce Motion, VoiceOver read-through |

## 4. Performance checks

- Warm launch median / p90 (release), cold launch (approximate method documented).
- Idle CPU over 60 s after 30 s settle; idle wakeups; physical footprint at idle with no repo and
  after one discovery.
- Idle GPU/energy with glass chrome visible (key and inactive window).
- Confirm no extra threads besides AppKit's own at idle after a discovery (Instruments thread view or
  `sample` output) — validates ADR-0005.
- `JitBench`: process spawn latency (p50/p90), discovery latency.

## 5. Docs to update

`README.md`, `CLAUDE.md` (Commands), `docs/product.md`, `docs/architecture.md`, `docs/design-system.md`,
`docs/performance.md`, `docs/security.md`, `docs/release.md`, `docs/adr/0001`, `0003`, `0004`, `0005`, the
ADR-0006 addendum, this phase's `progress.md`. Amend `design.md`/`implementation.md` where reality differed.

## 6. Exit checklist

- [ ] Clean clone → one command → running `Jit.app` (macOS 26, glass toolbar) that discovers repositories
      through `GitCore`.
- [ ] `swift test` and `xcodebuild test` pass locally and in CI; none skipped without reason.
- [ ] Foundation window and design-system gallery screenshots (light/dark, Reduce Transparency) committed.
- [ ] Baseline performance table recorded with environment details, including idle GPU/energy.
- [ ] ADR-0001, 0003, 0004, 0005 written; ADR-0006 addendum added; bundled-Git feasibility notes recorded.
- [ ] Main thread never waits on Git (debug precondition in place); no thread blocks on a child process.
- [ ] Docs match reality; CLAUDE.md commands accurate.
- [ ] Roadmap §9 gate items satisfied; `progress.md` complete; PR opened.

## 7. Phase 0 outcome (2026-11-09)

Status of every milestone, with evidence, is in [`progress.md`](progress.md). Differences from this plan:
P0.4 test-app uses DerivedData outside the repository (TCC); P0.5 screenshots are in-app renders; P0.6
Reduce Transparency / Increase Contrast captures and P0.7 cold-launch and GPU power numbers are
carried over (they need user-granted permissions or root).
