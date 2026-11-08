# Phases

Each phase folder contains:

| File | Written by | Purpose |
|---|---|---|
| `design.md` | planning (now) | What the user experiences and how it is built: interactions, visual hierarchy, states, technical design, data flow, APIs across the bridge, edge cases, ADRs to write. |
| `implementation.md` | planning (now) | Ordered milestones with tasks, files/modules touched, tests, verification steps, and the exit checklist. |
| `prompt.md` | planning (now) | The kickoff prompt to paste into a fresh Claude Code session at the repository root. |
| `progress.md` | the implementing agent | The honest end-of-phase report (template below). Created during the phase, finalized at the end. |
| `specs/` | the implementing agent | Short feature specs written before each significant feature (§21): behavior, failure cases, tests. |

The overall plan, invariants, ADR backlog and performance budget are in [`../roadmap.md`](../roadmap.md).
The requirements source is [`../master-prompt.md`](../master-prompt.md).

Exceptions: Phase 6 adds `visual-review.md` (and `docs/testing.md` if missing). Phase 8 is a backlog
of independent epics, so each epic runs on `epic/<name>` and reports in `progress-<epic>.md` with
screenshots under `screenshots/<epic>/`.

## Workflow for a phase

1. **Branch:** `phase/NN-short-name` from `main` (e.g. `phase/02-graph-and-navigation`).
2. **Start:** open Claude Code at the repo root, paste the block from `prompt.md`.
3. **Per milestone:** write/update the spec in `specs/` → write tests → implement → build → run tests →
   exercise the real workflow → screenshots (light + dark) for UI → measure where relevant → commit.
4. **Commits:** Conventional Commits (`feat(graph): …`, `fix(core): …`, `docs(adr): …`), small and
   focused, each leaving the build green.
5. **End:** finalize `progress.md`, update `docs/` to match reality, open a PR to `main` titled
   `Phase NN — <name>`; the PR body links `progress.md`.
6. **Next phase** starts only after the PR is merged (or carry-overs are explicitly accepted).

## `progress.md` template

```markdown
# Phase NN — <name>: progress report

Status: in progress | complete | complete with carry-overs | blocked (<on what>)
Branch / PR: <branch>, <PR link>
Environment: <Mac model>, macOS <ver>, Xcode <ver>, Swift <ver>, Rust <ver>, Git <ver>

## Implemented
- <milestone id> <what now works> — evidence: <test names, screenshots path, commands>

## Verified
- Tests: `cargo test` <n passed>, Swift <n passed>, UI <n passed>; skipped: <none | list + reason>
- Real-workflow checks: <what was exercised against which repos>
- Screenshots: `docs/phases/NN-.../screenshots/<name>-{light,dark}.png`

## Performance (release build)
| Metric | Previous | Now | Method |
|---|---|---|---|

## Decisions
- ADR-XXXX <title> — <one-line outcome>

## Deviations from plan
- <what changed and why; docs updated: yes/no>

## Known issues / carry-overs
- <issue> — severity, new home (phase/milestone)

## Self-review findings
- <finding> — fixed in <commit> | logged as <issue>

## Next
- <first milestone of next phase, any preconditions>
```

## Conventions shared by all phase docs

- Milestone IDs: `P<phase>.<n>` (e.g. `P3.6`). Specs are named `specs/P3.6-partial-staging.md`.
- Bridge API sketches in design docs are illustrative Rust/Swift signatures; the implementing agent
  adjusts names to what UniFFI actually supports and records significant changes.
- "Planned" is the only allowed label for visible-but-unbuilt functionality, and only where showing
  it helps the user (otherwise hide it).
- Screenshots live in each phase's `screenshots/` folder, named `<screen>-<state>-<light|dark>.png`.
