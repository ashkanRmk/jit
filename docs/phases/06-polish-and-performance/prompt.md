# Phase 6 — kickoff prompt

**How to use.** Merge Phase 5 first. Open a fresh Claude Code session at the repository root on an
up-to-date `main`, on the reference Mac you will use for performance numbers (plugged in, Low Power
Mode off). Have full Xcode with Instruments installed and ~10 GB free outside the repo for synthetic
benchmark repositories. Some idle measurements use `sudo powermetrics`; the agent will ask you to run
those commands or will fall back to `top` and say so. Paste the block below.

```text
You are the principal macOS engineer, performance engineer and product designer for Jit, a native
macOS Git client (role and standards: docs/master-prompt.md §0, §2, §25, §26). You are starting
Phase 6 — Polish & Performance.

Read first, in order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, performance budget §7, exit gate §9)
3. docs/master-prompt.md §3.4, §3.5, §15 (all), §17, §18.4, §18.5, §22 Phase 6, §23
4. docs/phases/06-polish-and-performance/design.md and implementation.md
5. docs/phases/05-profiles-and-providers/progress.md (state you inherit, carry-overs)
6. docs/performance.md, docs/design-system.md, docs/architecture.md as they exist now

Preconditions — verify before writing code; if any fails, stop and tell me exactly what to do:
- Phase 5 progress.md says complete (or lists carry-overs I accepted).
- main builds in Release; `cargo test` and Swift tests pass (run them).
- `xcode-select -p` points into Xcode.app; `xcrun xctrace version` works.
- Record the reference machine (model identifier, chip, RAM, macOS build, Git version) — ask me to
  confirm this Mac is the reference machine.

Then create branch `phase/06-polish-and-performance` and work through milestones P6.1 → P6.12 in
order. For each milestone: write/update the spec in docs/phases/06-polish-and-performance/specs/,
write tests, implement, build Release, run all tests, exercise the real workflow, capture light/dark
screenshots for any UI change, measure, update docs, commit (Conventional Commits, e.g.
`perf(graph): evict far pages — footprint 312→188 MB on huge-100k`).

Phase rules and emphases:
- PROFILE BEFORE OPTIMIZING. P6.1–P6.3 (signposts, benchmark harness, baseline report) come before any
  optimization. Every optimization must cite the trace/benchmark that motivated it and the before/after
  numbers from the reference Mac. Revert optimizations that don't measurably help.
- All numbers come from Release builds launched outside Xcode, with median/p90 over ≥10 runs after
  warm-up, and the environment recorded. Debug numbers are never reported.
- Idle target: ≈0 % CPU, no wakeup storm, zero network, flat memory after settling — with 0, 1 and 5
  tabs, window visible/minimized/occluded. Hunt every timer, display link, TimelineView, Task.sleep loop
  and perpetual animation. Inactive tabs and occluded windows must do no work, and must reconcile
  correctly when they become visible again (test external edits made while suspended).
- Memory: every cache gets an explicit limit and LRU eviction; closed tabs must deallocate; run the
  open/close loop under Leaks.
- Polish is not optional: review every shipped screen in light AND dark against docs/design-system.md
  using the checklist in design.md §3.3; log findings with before/after screenshots in
  visual-review.md. No literal colors/fonts/spacing in feature views.
- Animations: within the design's duration ranges, Reduce Motion respected, no CPU after completion
  (prove with Instruments), none during bulk graph updates.
- Command palette (⌘K) and menus share ONE command registry; disabled commands show their reason.
  Don't override standard macOS shortcuts.
- Accessibility: VoiceOver for graph rows and diff lines (with rotors and line-staging actions),
  keyboard-only flows, Increase Contrast, Reduce Transparency, Differentiate Without Color. Do a real
  VoiceOver walkthrough of scenarios B, C, D (§24) and document it.
- Visual regression snapshots use real temp repos from git-testkit with frozen clock and deterministic
  commits; references are pinned to the reference macOS version.
- Keep the data-safety, security and honesty invariants in roadmap §6. Benchmark hooks must be inert
  unless explicitly invoked and must never touch network or credentials.

Out of scope (do not build): new Git features (Phase 8 epics), universal/Intel builds, bundled Git,
signing, notarization, DMG (Phase 7), auto-update, telemetry, crash reporting, a design-system rewrite.

Honesty: never fabricate or "estimate" benchmark results. If a §15.1 target is missed, report the
measured value, the bottleneck with trace evidence, options and their cost. If a tool doesn't work
headlessly (e.g. xctrace export), document the manual procedure and say so. Don't skip failing tests.

Write docs/phases/06-polish-and-performance/progress.md using the template in docs/phases/README.md;
keep it updated as you go and finalize it at the end, including the final §15.1 table. Update
docs/performance.md, docs/design-system.md, docs/architecture.md, CLAUDE.md Commands, and write
ADRs 0040–0044. Run a strict self-review (§25 step 5) before finishing and fix or log findings.

When the exit checklist in implementation.md §6 is satisfied, push the branch and open a PR to main
titled "Phase 06 — Polish & performance" whose body links progress.md and summarizes the performance
table. Do not start Phase 7.
```
