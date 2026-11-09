# CLAUDE.md — Jit

Native macOS Git client, 100% Swift. SwiftUI + AppKit UI in the native Liquid Glass design language
(macOS 26+), a Foundation-only `GitCore` module (`macos/Packages/JitKit/Sources/GitCore`) driving the
Git CLI. No Rust/FFI (ADR-0002), no web views, Electron, Tauri, local servers, databases or daemons.

## Where things are
- Requirements (source of truth): `docs/master-prompt.md` — cite sections as §N.N.
- Plan, invariants, ADR backlog, perf budget: `docs/roadmap.md`.
- Per-phase design, implementation plan, kickoff prompt, progress report: `docs/phases/NN-*/`.
- Architecture decisions: `docs/adr/NNNN-title.md`. ADR-0002 (pure Swift) and ADR-0006 (macOS 26+,
  Liquid Glass) amend the master prompt — they win where the two disagree.

## Priorities when trading off (§26)
1. Protect the user's repositories and data. 2. Correct Git behavior. 3. Excellent UX.
4. UI responsiveness. 5. Low idle resource use. 6. Low memory. 7. Fast startup.
8. Simple, maintainable code. 9. Power-user features.

## Hard rules
- Never block the main thread on Git or `GitCore` work. Never poll. No repeating timers or perpetual animations.
- `GitCore` imports Foundation/Darwin only — never AppKit/SwiftUI. No class per commit or diff line;
  parse Git's `-z` output as bytes; materialize `String`s only for visible rows (ADR-0005).
- Launch Git with argv arrays, a fixed cwd, `--` before paths, `GIT_TERMINAL_PROMPT=0`. Never build
  shell strings from user input, paths, branch names or remote URLs.
- Secrets live only in the Keychain. Never in argv, URLs, env dumps, logs or preferences.
- Never modify `~/.gitconfig` or `~/.ssh/config`. Identity is applied per invocation.
- Every mutation is serialized per repository and validated against the snapshot it was prepared on.
- Destructive actions require explicit, specific confirmation: `ConfirmationSheet` → `ConfirmationToken`
  (minted only by `ConfirmationRequest.confirm()`); never plain `--force` (force-with-lease only).
- Remote Git commands go through `GitEnvironment.remoteCommand(ExecContext)`; mutations take a `RepoStateToken`
  and run inside `RepositoryHandle.performExclusive` (the one writer).
- Colors, type, spacing, radii and motion come from `DesignSystem` tokens — never hardcoded in views.
- Follow standard macOS conventions (Human Interface Guidelines) for window chrome, controls and their placement:
  system toolbar items and positions (e.g. the sidebar toggle beside the window controls with a sidebar
  tracking separator), standard menus, shortcuts, sheets and popovers. Jit's own visual identity lives in
  content (graph, diff, lists), never in replacing standard chrome behaviour.
- Liquid Glass on chrome only (toolbar, tab bar, sidebar, popovers, sheets), via system components or the
  official glass APIs; content (graph, diff, code, lists) stays opaque. No hand-made blur stacks.
- No mock data, placeholder buttons or fake success in shipped UI. Unbuilt = absent or "Planned".
- Never fabricate test, benchmark, signing or notarization results.

## How to work
Spec (`docs/phases/NN-*/specs/`) → tests → implement → build → run tests → exercise the real workflow
→ light/dark screenshots for UI → measure → update docs → commit (Conventional Commits).
Use real temporary Git repositories in tests (`GitTestKit`), not mocked Git output.

## Commands
Run from the repository root. Requires full Xcode 26+ selected and `brew install xcodegen`.
- Generate Xcode project: `scripts/build/gen-xcodeproj.sh` (writes git-ignored `macos/Jit.xcodeproj`)
- Build app: `scripts/build/build-app.sh [debug|release]` (DerivedData: `~/Library/Developer/Xcode/DerivedData/Jit`, override `JIT_DERIVED_DATA`)
- Everything from a clean checkout: `scripts/build/build-all.sh [debug|release] [--test]`
- Core tests (`swift test`): `scripts/build/test-core.sh`
- App/UI tests: `scripts/build/test-app.sh`
- Lint (swift format + architecture rules): `scripts/build/lint.sh`
- Benchmarks: `[JIT_APP_SUPPORT=<state dir>] scripts/benchmarks/launch.sh [--key] [runs]`,
  `[JIT_OPEN=<repo>] [JIT_APP_SUPPORT=<dir>] scripts/benchmarks/idle.sh [label]`,
  `swift run -c release --package-path macos/Packages/JitKit JitBench [spawn-latency|discovery|status-parse|all]`;
  env-gated app modes `JIT_BENCHMARK_TAB_SWITCH=1`, `JIT_STRESS_OPEN_CLOSE=<repo>` (all builds)
- History fixtures (outside the repo, `~/Library/Caches/jit-bench/`): `scripts/benchmarks/make-history-fixture.sh --standard`
  (or `<commits> <branches> <out>`); graph benchmark: `JIT_BENCHMARK_GRAPH=1 JIT_OPEN=<repo> <release Jit binary>`
- Lane golden files: `UPDATE_GOLDEN=1 swift test --package-path macos/Packages/JitKit --filter LaneGoldenTests`
  (review the diff of `Tests/GitCoreTests/Resources/lanes/` by hand)
- Property tests: `JIT_PROPERTY_CASES=<n>` (default 150, 2,000 when `CI` is set), `JIT_PROPERTY_SEED=<seed>`
  re-runs a printed failing seed: `swift test --package-path macos/Packages/JitKit --filter ApplyPropertyTests`
  (conflict documents: `--filter randomThreeWayEditsMatchGit`, default 60 cases, 400 with `CI`)
- Phase 4 integration suites (real repos, local bare remotes, a local HTTP 401 stub):
  `swift test --package-path macos/Packages/JitKit --filter "FrameworkTests|RemoteOperationTests|BranchOperationTests|IntegrationTests|ConflictTests|StashTests|SafetyRegressionTests"`;
  abort/refusal tests compare `RepoFingerprint` (GitTestKit) before and after
- State: `JIT_APP_SUPPORT=<dir>` replaces `~/Library/Application Support/Jit` (tests, screenshots, benchmarks —
  never run experiments against the real one)
- Screenshots (real captures; needs Screen Recording): `scripts/testing/screenshot.sh <light|dark> <out.png>`
- Debug launch args: `-JitOpen <path>` / env `JIT_OPEN` (all builds), `-JitAppearance light|dark`,
  `-JitShowGallery YES`, `-JitGallerySection <name>`, `-JitShowSettings general|profiles`,
  `-JitShowProfilePopover YES`, `-JitShowProfileEditor YES`, `-JitUITestOpenRepository <path>`,
  `-JitSnapshot <png>` (debug only; renders the window to PNG, glass approximated),
  `-JitGraphSelectRow <n>` [`-JitGraphCompareRow <m>`], `-JitGraphSearch <text>` [`-JitGraphOnlyMatches YES`],
  `-JitGraphSelectWIP YES`, `-JitDiscardSheet <path>`, `-graphDensity compact|comfortable` (debug only except the last)
