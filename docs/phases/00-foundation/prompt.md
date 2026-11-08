# Phase 0 — kickoff prompt

**Before you start**
- Install full Xcode and select it (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`).
  The planning machine only had Command Line Tools; the agent will stop if that is still true.
- Have Homebrew available (for `xcodegen`) and push access to `https://github.com/ashkanRmk/jit`.
- Open a fresh Claude Code session at the repository root and paste the block below.

```text
You are the principal engineer building Jit, a premium, ultra-lightweight native macOS Git client
(SwiftUI + AppKit UI, Rust Git core via UniFFI, Git CLI underneath). Your full role and standards are
in docs/master-prompt.md §0 and §25–§26. You are implementing, not advising.

This session covers PHASE 0 — FOUNDATION & DESIGN only.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, ADR backlog §5, exit gate §9)
3. docs/master-prompt.md §1–§3, §13, §15.1, §19, §21, §22 (Phase 0), §25
4. docs/phases/00-foundation/design.md
5. docs/phases/00-foundation/implementation.md
6. docs/phases/README.md (workflow + progress.md template)

Preconditions — check before writing any code (implementation.md §1):
- `xcode-select -p` must point inside Xcode.app and `xcodebuild -version` must work. If not, STOP and
  tell me exactly how to install/select Xcode. Do not try to work around missing Xcode.
- rustup present (run `rustup update stable`), xcodegen installable/installed, git present.
If any precondition fails, report it clearly and stop.

Then:
- Create branch `phase/00-foundation` from main (if main has no commits yet, make the planning docs
  the initial commit on main first, then branch).
- Work milestones P0.1 → P0.8 in order. For each: write a short spec in
  docs/phases/00-foundation/specs/, write tests, implement, build, run tests, exercise the real
  workflow, screenshot UI in light and dark, then commit (Conventional Commits, small commits).
- Verify library versions and APIs against current documentation before using them (UniFFI
  especially). Pin what you verify. Do not invent APIs.

Emphases and pitfalls for this phase:
- The phase must END WITH A WORKING NATIVE WINDOW CALLING RUST, not only documentation.
- Never execute /usr/bin/git or xcrun blindly: on machines without CLT it opens an install dialog.
  The locator checks for a real Git binary by file existence first.
- ProcessRunner: argv only, explicit cwd, env_clear + allowlist, GIT_TERMINAL_PROMPT=0, process-group
  cancellation and timeouts, bounded output capture. There must be no API that runs a shell string.
- Rust API is synchronous and owns no idle threads (ADR-0005). The Swift wrapper runs calls on
  dedicated dispatch queues (never the main thread, never blocking the cooperative pool) and wires
  Task cancellation to CancelToken.
- Tests use real temporary repositories via git-testkit with an isolated HOME/global config.
- Design tokens are a real design system: the "Quiet Instrument" direction in design.md §3.3 is a
  starting point — refine values by looking at rendered screenshots, keep light and dark designed
  independently, verify contrast with a test, and keep views free of hardcoded colors/fonts.
- The foundation window is product UI: designed empty/loading/loaded/error states.
- Measure the baseline with a release build and document the method (P0.7). Never fabricate numbers.

Out of scope (do not build): tabs, recents, status, file watching, profiles, persistence, history,
graph, diff, staging, remote operations, authentication, providers, signing/notarization, bundled Git
(feasibility notes only).

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
