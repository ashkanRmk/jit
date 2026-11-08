# CLAUDE.md — Jit

Native macOS Git client. SwiftUI + AppKit UI, Rust Git core (`rust/crates/git-core`) exposed through
UniFFI (`rust/crates/git-ffi`), driving the Git CLI. No web views, Electron, Tauri, local servers,
databases or daemons.

## Where things are
- Requirements (source of truth): `docs/master-prompt.md` — cite sections as §N.N.
- Plan, invariants, ADR backlog, perf budget: `docs/roadmap.md`.
- Per-phase design, implementation plan, kickoff prompt, progress report: `docs/phases/NN-*/`.
- Architecture decisions: `docs/adr/NNNN-title.md`.

## Priorities when trading off (§26)
1. Protect the user's repositories and data. 2. Correct Git behavior. 3. Excellent UX.
4. UI responsiveness. 5. Low idle resource use. 6. Low memory. 7. Fast startup.
8. Simple, maintainable code. 9. Power-user features.

## Hard rules
- Never block the main thread on Rust or Git. Never poll. No repeating timers or perpetual animations.
- Launch Git with argv arrays, a fixed cwd, `--` before paths, `GIT_TERMINAL_PROMPT=0`. Never build
  shell strings from user input, paths, branch names or remote URLs.
- Secrets live only in the Keychain. Never in argv, URLs, env dumps, logs or preferences.
- Never modify `~/.gitconfig` or `~/.ssh/config`. Identity is applied per invocation.
- Every mutation is serialized per repository and validated against the snapshot it was prepared on.
- Destructive actions require explicit, specific confirmation.
- Colors, type, spacing, radii and motion come from `DesignSystem` tokens — never hardcoded in views.
- No mock data, placeholder buttons or fake success in shipped UI. Unbuilt = absent or "Planned".
- Never fabricate test, benchmark, signing or notarization results.

## How to work
Spec (`docs/phases/NN-*/specs/`) → tests → implement → build → run tests → exercise the real workflow
→ light/dark screenshots for UI → measure → update docs → commit (Conventional Commits).
Use real temporary Git repositories in tests (`git-testkit`), not mocked Git output.

## Commands
_Filled in by Phase 0 once they exist. Keep this section accurate._
- Build Rust + bindings: `TBD`
- Generate Xcode project: `TBD`
- Build app: `TBD`
- Rust tests: `TBD`
- Swift tests: `TBD`
- Benchmarks: `TBD`
