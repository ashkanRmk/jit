# Phase 0 — kickoff prompt

**Before you start**
- Finish installing Xcode (27.2 was started from the App Store during planning) and select it:
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then
  `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`. The agent stops if Xcode 26+
  isn't selected.
- XcodeGen is installed (`brew install xcodegen` if not). No Rust toolchain is needed.
- Have push access to `https://github.com/ashkanRmk/jit`.
- Open a fresh Claude Code session at the repository root and paste the block below.

```text
You are the principal engineer building Jit, a premium, ultra-lightweight native macOS Git client:
100% Swift 6 (SwiftUI + AppKit), native Liquid Glass design on macOS 26+, a Foundation-only GitCore
module driving the Git CLI. Your full role and standards are in docs/master-prompt.md §0 and §25–§26,
as amended by docs/adr/0002-pure-swift-core.md (no Rust, no UniFFI) and
docs/adr/0006-platform-baseline-and-liquid-glass.md (macOS 26+, Liquid Glass). Where the master prompt
says "Rust core", read GitCore. You are implementing, not advising.

This session covers PHASE 0 — FOUNDATION & DESIGN only.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (owner decisions at the top, invariants §6, ADR backlog §5, exit gate §9)
3. docs/adr/0002-pure-swift-core.md and docs/adr/0006-platform-baseline-and-liquid-glass.md
4. docs/master-prompt.md §1–§3, §13, §15.1, §19, §21, §22 (Phase 0), §25
5. docs/phases/00-foundation/design.md
6. docs/phases/00-foundation/implementation.md
7. docs/phases/README.md (workflow + progress.md template)

Preconditions — check before writing any code (implementation.md §1):
- `xcode-select -p` must point inside Xcode.app and `xcodebuild -version` must report Xcode 26 or newer
  with a macOS 26+ SDK. If not, STOP and tell me exactly how to finish installing/selecting Xcode. Do
  not try to work around missing Xcode.
- xcodegen installed, git present.
If any precondition fails, report it clearly and stop.

Then:
- Create branch `phase/00-foundation` from main.
- Work milestones P0.1 → P0.8 in order. For each: write a short spec in
  docs/phases/00-foundation/specs/, write tests, implement, build, run tests, exercise the real
  workflow, screenshot UI in light and dark (and Reduce Transparency for glass), then commit
  (Conventional Commits, small commits).
- Verify APIs against the installed SDK and current documentation before using them — especially the
  Liquid Glass APIs (glassEffect, GlassEffectContainer, glassEffectID, .glass/.glassProminent,
  NSGlassEffectView, NSGlassEffectContainerView, scroll-edge effects) and swift-subprocess. Pin what you
  verify. Do not invent APIs.

Emphases and pitfalls for this phase:
- The phase must END WITH A WORKING NATIVE WINDOW CALLING GitCore, not only documentation.
- GitCore imports Foundation/Darwin only. No class per commit/line later; parse Git output as bytes.
- Never execute /usr/bin/git or xcrun blindly: on machines without CLT it opens an install dialog.
  The locator checks for a real Git binary by file existence first and probes the version lazily.
- ProcessRunner: posix_spawn with an argv array, explicit cwd, environment built from an allowlist,
  GIT_TERMINAL_PROMPT=0 and non-interactive editor vars, own process group (POSIX_SPAWN_SETPGROUP),
  Swift task cancellation and timeouts → killpg SIGTERM then SIGKILL, bounded output, pipes and exit
  observed with Dispatch sources so no thread ever blocks waiting on a child. There must be no API that
  runs a shell string. Run the posix_spawn vs swift-subprocess spike and record the result in ADR-0005.
- No idle threads, timers or long-lived processes (ADR-0005).
- Tests use real temporary repositories via GitTestKit with an isolated HOME/global config; core tests
  run with `swift test`.
- Design: Liquid Glass only on chrome (toolbar, sidebar, floating controls, popovers, sheets) via system
  components or the official glass APIs; content stays opaque. No NSVisualEffectView stacks or custom
  blurs. The "Quiet Instrument, under glass" direction in design.md §3.3 is a starting point — refine
  values by looking at rendered screenshots, keep light and dark content colors designed independently,
  verify contrast with a test, support Reduce Transparency / Increase Contrast / Reduce Motion, and keep
  views free of hardcoded colors/fonts/blurs.
- The foundation window is product UI: designed empty/loading/loaded/error states.
- Measure the baseline with a release build (including idle GPU/energy with glass chrome) and document
  the method (P0.7). Never fabricate numbers.

Out of scope (do not build): tabs, recents, status, file watching, profiles, persistence, history,
graph, diff, staging, remote operations, authentication, providers, signing/notarization, bundled Git
(feasibility notes only). Do not add Rust or any FFI layer.

Honesty and verification:
- Do not claim anything works without running it. Do not skip or silence failing tests.
- If something can't be verified in this environment, say so in progress.md.

Finish:
- Update docs listed in implementation.md §5 to match reality; fill CLAUDE.md "Commands".
- Write docs/phases/00-foundation/progress.md using the template in docs/phases/README.md.
- Run a strict self-review (master-prompt §25 step 5), fix blockers, log the rest.
- Push the branch and open a PR to main titled "Phase 00 — Foundation & design" linking progress.md.
- Do not start Phase 1.
```
