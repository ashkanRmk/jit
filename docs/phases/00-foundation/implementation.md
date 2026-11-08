# Phase 0 — Foundation & Design: implementation plan

Design: [`design.md`](design.md). Exit gate: this file §6 + [`../../roadmap.md`](../../roadmap.md) §9.

## 1. Preconditions

- [ ] Full Xcode installed and selected: `xcode-select -p` prints a path inside `Xcode.app`;
      `xcodebuild -version` succeeds. (On the planning machine only Command Line Tools were active —
      if still true, **stop** and ask the user to install Xcode and run
      `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.)
- [ ] `rustup` available; `rustup update stable` run.
- [ ] Homebrew available for `xcodegen` (or another approved install path); `xcodegen --version` works.
- [ ] Git ≥ the proposed minimum on the dev machine.
- [ ] Remote `origin` points at `https://github.com/ashkanRmk/jit` and the user can push.

## 2. Milestones

### P0.1 — Environment & feasibility review
Goal: know exactly what the toolchain supports before writing code.
- [ ] Record macOS, Xcode, Swift, Rust, Git, CPU arch, available Rust targets, signing identities
      (`security find-identity -v -p codesigning`, output summarized — never paste private data).
- [ ] Look up the **current stable UniFFI** release and its docs: proc-macro objects, `with_foreign`
      traits, error enums, library-mode bindgen, Swift 6 strict-concurrency compatibility of generated code.
- [ ] Look up the current XcodeGen version and macOS 14 deployment settings.
- [ ] Bundled-Git feasibility pre-check (ADR-0019 input): options, dependencies, licensing, signing.
- [ ] Write `docs/phases/00-foundation/specs/P0.1-feasibility.md` with findings and risks.
Files: `specs/P0.1-feasibility.md`. Done when: the findings name exact versions to pin.

### P0.2 — Scaffold, ADRs, conventions
- [ ] Create directories that get content in this phase only: `macos/`, `rust/`, `scripts/build/`,
      `scripts/benchmarks/`, `docs/adr/`.
- [ ] `.gitignore` (Rust `target/`, Xcode `DerivedData`, generated `*.xcodeproj`, generated bindings,
      XCFramework, `.DS_Store`, benchmark outputs).
- [ ] `.editorconfig`, `rustfmt.toml`, `clippy` settings in workspace `Cargo.toml`, SwiftFormat/SwiftLint
      only if the user approves the dependency (otherwise Xcode's formatter + review discipline).
- [ ] `docs/adr/0000-template.md`; ADRs 0001–0006 (status: Accepted or Proposed with the pending spike).
- [ ] `rust/rust-toolchain.toml` pinning the verified stable version + `aarch64-apple-darwin`.
Done when: tree matches roadmap §5 layout for the parts that exist; ADRs reviewed.

### P0.3 — Rust workspace and Git core primitives
- [ ] Workspace `rust/Cargo.toml` with members `git-core`, `git-ffi`, `git-testkit`, `uniffi-bindgen`;
      shared `[workspace.dependencies]` (`uniffi`, `thiserror`, `libc`). No other deps without a note.
- [ ] `git-core::version` + tests: `parses_plain_version`, `parses_apple_git_suffix`,
      `rejects_garbage`, `compares_against_minimum`.
- [ ] `git-core::locator` with an injectable filesystem probe + tests:
      `prefers_env_override_in_debug`, `prefers_homebrew_over_usr_bin`,
      `skips_usr_bin_git_when_clt_missing`, `reports_not_found`.
- [ ] `git-core::process::ProcessRunner` + tests (use `/bin/sh -c` fixtures *only in tests*):
      `passes_argv_without_shell_interpretation` (arg containing `; rm -rf` reaches the child verbatim),
      `sanitizes_environment` (child sees only allowlisted vars, `GIT_TERMINAL_PROMPT=0`),
      `caps_stdout_and_stderr`, `timeout_kills_process_group` (grandchild also dies),
      `cancel_kills_process_group`, `cancel_before_spawn_returns_cancelled`, `nonzero_exit_maps_to_error`.
- [ ] `git-core::discovery` + integration tests via `git-testkit`:
      `discovers_regular_repo`, `discovers_from_subdirectory`, `discovers_bare_repo`,
      `discovers_linked_worktree`, `reports_unborn_branch`, `reports_detached_head`,
      `not_a_repository`, `path_with_spaces_and_unicode`, `permission_denied_directory`,
      `dubious_ownership_maps_to_unsafe_repository` (simulate via `safe.directory` config if ownership
      can't be faked; otherwise document as manual check).
- [ ] `git-testkit`: isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL` pointing to an empty
      temp file, fixed dates/identity, auto-cleanup.
- [ ] `git-ffi`: `core_version`, `GitEngine` (`new`, `git_info`, `discover_repository`), `CancelToken`,
      `ProgressSink`, `CoreError`, records. Unit test that the FFI conversion preserves error variants.
Verification: `cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`.
Done when: all tests pass locally; no `unwrap()` on fallible paths outside tests.

### P0.4 — Build pipeline and project generation
- [ ] `scripts/build/build-rust.sh`, `gen-xcodeproj.sh`, `build-app.sh`, `build-all.sh` (bash,
      `set -euo pipefail`, readable errors, `--help`).
- [ ] `macos/project.yml`: app target `Jit` (macOS 14, arm64, Hardened Runtime, App Sandbox off,
      bundle id from an `xcconfig` placeholder `com.example.jit` until the user supplies one),
      pre-build script calling `build-rust.sh`, test targets.
- [ ] `macos/Packages/JitKit/Package.swift` with `JitCoreFFI` binary target, `GitCoreBridge`,
      `DesignSystem`, `Features`; Swift 6 language mode; tests target `JitKitTests`.
- [ ] Swift test `GitCoreBridgeTests.testCoreVersionRoundTrip`, `testDiscoverTempRepository`
      (creates a repo with `/usr/bin/env git` in the test, or a checked-in tiny script),
      `testCancellationThrowsCancelled`.
- [ ] `.github/workflows/ci.yml` (fmt, clippy, cargo test, build-all debug, JitKit tests).
Verification: fresh clone → `scripts/build/build-all.sh debug` succeeds; `xcodebuild test` passes;
CI green on the phase branch.
Done when: one command builds the app from a clean checkout.

### P0.5 — Foundation window calling Rust
- [ ] `JitApp` with a single window (min 960×600), title hidden, full-size content view styling that
      Phase 1's tab bar will build on.
- [ ] `FoundationView` states: empty / loading (delayed 150 ms) / loaded card / error (per error type).
- [ ] ⌘O via `NSOpenPanel` (directories only), drag-and-drop of a folder onto the window.
- [ ] `GitCore` wrapper: dedicated queue, continuation bridging, cancellation handler.
- [ ] Main-thread guard in debug: assert in the wrapper that Rust calls never run on the main thread.
Verification: open this repo, a bare repo, a linked worktree, a non-repo, an unreadable folder; check
copy and layout in light and dark; take screenshots → `screenshots/foundation-{empty,loaded,error}-{light,dark}.png`.
Done when: all five cases display correctly and the UI never beachballs (verify with a deliberately slow
fake path, e.g. a FIFO or a sleeping network mount simulation, and cancellation).

### P0.6 — Design direction and tokens v1
- [ ] `DesignSystem`: `ColorToken` (dynamic `NSColor` + SwiftUI `Color`), increase-contrast variants,
      `TypeToken`, `Space`, `Radius`, `Border`, `Shadow`, `Motion` (with Reduce Motion resolution),
      `IconSize`, `PanelMetrics`, `Density`. Button styles (primary, secondary, borderless), row
      background (rest/hover/pressed/selected), focus ring modifier.
- [ ] Token gallery window (`#if DEBUG`), per design §3.2.
- [ ] Contrast check: a unit test computes WCAG contrast for text tokens on each surface (≥ 4.5:1 for
      primary/secondary body text, ≥ 3:1 for tertiary labels and lane lines) in both themes.
- [ ] Iterate values from the design draft using rendered screenshots; record final values in
      `docs/design-system.md`.
- [ ] Lint-style test or script: grep Swift sources outside `DesignSystem` for `Color(red:`, `NSColor(`
      literals, `.font(.system(size:` — fail if found.
Verification: gallery screenshots in light, dark, increase-contrast → `screenshots/tokens-*.png`.
Done when: the gallery looks deliberate and cohesive in both themes and the contrast test passes.

### P0.7 — Baseline measurements
- [ ] Benchmark mode: launch argument `-JitBenchmarkLaunch` logs `first_window_ms` measured from process
      start (`sysctl` `kinfo_proc.kp_proc.p_starttime`) to the first `NSWindow` `didBecomeKey`/first frame,
      then quits. Also emit an `os_signpost` interval for Instruments.
- [ ] `scripts/benchmarks/launch.sh` — N warm runs (median, p90); cold-run instructions (reboot or
      `sudo purge`, documented as approximate).
- [ ] `scripts/benchmarks/idle.sh` — launch, wait 30 s to settle, sample CPU for 60 s (`top -l`/`ps`),
      memory (`footprint` or `vmmap --summary` physical footprint), wakeups (`top -stats idlew` or
      `powermetrics` when run with sudo by the user).
- [ ] Run on a release build; record Mac model, macOS, Xcode, Git, method in `docs/performance.md`.
Done when: baseline table exists with real numbers and the methods are reproducible.

### P0.8 — Documentation
- [ ] `docs/product.md` (concise product spec from §1–§12 for V1, explicit exclusions §9.3).
- [ ] `docs/architecture.md` (layers, crates, Swift modules, data flow, FFI model, process model).
- [ ] `docs/design-system.md` (direction, token tables as implemented, usage rules).
- [ ] `docs/performance.md` (budget, methods, baseline).
- [ ] `docs/security.md` (threat model v1, process rules, secrets policy, sandbox/hardened runtime).
- [ ] `docs/release.md` (stub: bundled Git feasibility notes; release steps arrive in Phase 7).
- [ ] README dev setup; CLAUDE.md "Commands" filled with the real commands.
Done when: every statement describes what exists or is clearly marked planned.

## 3. Test plan summary

| Layer | Tests |
|---|---|
| Rust unit | version, locator, process runner (argv, env, caps, timeout, cancel), error mapping |
| Rust integration | discovery matrix using `git-testkit` real repos |
| Swift unit | bridge round-trip, discovery, cancellation, token contrast, no-hardcoded-color lint |
| Manual | foundation window cases, light/dark, Reduce Motion, VoiceOver read-through |

## 4. Performance checks

- Warm launch median / p90 (release), cold launch (approximate method documented).
- Idle CPU over 60 s after 30 s settle; idle wakeups; physical footprint at idle with no repo and
  after one discovery.
- Confirm zero threads besides AppKit's own at idle after a discovery (Instruments thread view or
  `sample` output) — validates ADR-0005.

## 5. Docs to update

`README.md`, `CLAUDE.md` (Commands), `docs/product.md`, `docs/architecture.md`, `docs/design-system.md`,
`docs/performance.md`, `docs/security.md`, `docs/release.md`, `docs/adr/0000–0006`, this phase's
`progress.md`. Amend `design.md`/`implementation.md` where reality differed.

## 6. Exit checklist

- [ ] Clean clone → one command → running `Jit.app` that discovers repositories through Rust.
- [ ] `cargo test` and JitKit tests pass locally and in CI; none skipped without reason.
- [ ] Foundation window and token gallery screenshots (light/dark) committed.
- [ ] Baseline performance table recorded with environment details.
- [ ] ADR-0001…0006 written; bundled-Git feasibility notes recorded.
- [ ] Main thread never waits on Rust (debug assertion in place).
- [ ] Docs match reality; CLAUDE.md commands accurate.
- [ ] Roadmap §9 gate items satisfied; `progress.md` complete; PR opened.
