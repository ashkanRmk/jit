# Phase 2 — Kickoff prompt

**How to use:** merge Phase 1 to `main` first. Open a fresh Claude Code session at the repository
root and paste the block below. Keep the reference Mac plugged in for performance measurements, and
have a local clone of a large public repository (e.g. `git clone https://github.com/git/git
~/Code/git-src`) available outside this repo.

**Before you start:** confirm `docs/phases/01-shell-and-tabs/progress.md` says complete (or lists
accepted carry-overs) and that full Xcode is selected (`xcode-select -p`).

```text
You are the principal macOS / Rust / Git engineer and product designer described in
docs/master-prompt.md §0, implementing Phase 2 (Git graph & navigation) of Jit, a native macOS Git
client (SwiftUI + AppKit, Rust git-core via UniFFI, Git CLI).

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, perf budget §7, exit gate §9)
3. docs/master-prompt.md §3 (design), §4.3–§4.4, §5 (entire), §9.1 tags, §14, §15, §18, §23
4. docs/phases/02-graph-and-navigation/design.md and implementation.md
5. docs/phases/01-shell-and-tabs/progress.md and the ADRs in docs/adr/

Preconditions: verify every item in implementation.md §1 against the actual code (not just the
progress report). If something is missing, implement it as milestone P2.0 and record it. If the
environment is broken (no full Xcode, build fails on main), stop and tell me exactly what to fix.

Work on branch `phase/02-graph-and-navigation` from main. Execute milestones P2.1 → P2.12 in order.
For each milestone: write a short spec in docs/phases/02-graph-and-navigation/specs/ → write tests →
implement → build → run all tests → exercise the real workflow on real repos → screenshots (light and
dark) for UI → measure where relevant → commit (Conventional Commits, e.g. `feat(graph): …`).

Phase emphases:
- The graph is the flagship. Do not accept a visually mediocre graph. Design the node/edge/label
  language from design.md §3.2, render it, look at screenshots in both themes and both densities,
  and refine until it is calm, precise and original. Never copy the reference screenshots' look.
- Lane layout must be deterministic and prefix-stable: rows already laid out never change when more
  history loads. Prove it with golden files and the page-size property test before building UI on it.
- Run the spikes (S1 history source, S2 renderer FPS, S3 sync rows cost) and decide by measured
  numbers recorded in ADRs; delete losing prototypes.
- Virtualize everything: no SwiftUI view or CALayer per historical commit; only visible rows plus
  overscan cross the bridge; append pages with insertRows, no reload, no animation.
- Zero idle work: no timers, no polling; the history reader must not consume CPU while idle;
  inactive tabs defer refresh until activated.
- Read-only Git invocations neutralise program-executing display config (ext-diff, textconv,
  log.showSignature) per ADR-0023; all user strings go in argv, paths after `--`.

Out of scope (do NOT build; leave absent, not as dead buttons): checkout and any branch mutation,
copy remote link, opening diffs (Phase 3), blame (Phase 3), merge/rebase/cherry-pick (Phase 4),
provider avatars (Phase 5), worktree/stash navigator sections (Phase 8).

Verification and honesty: use real Git repositories (testkit fixtures, the 100k fast-import fixture,
the Git source clone). Release builds for performance. Report measured numbers with hardware, macOS,
Git version and repo size; if a target is missed, report the number and the bottleneck — never
fabricate. No skipped tests without a recorded reason.

At the end: write docs/phases/02-graph-and-navigation/progress.md using the template in
docs/phases/README.md, update the docs listed in implementation.md §5, run the strict self-review from
master-prompt §25 step 5 and fix or log findings, push the branch and open a PR to main titled
"Phase 02 — Git graph & navigation" linking progress.md. Do not start Phase 3.
```
