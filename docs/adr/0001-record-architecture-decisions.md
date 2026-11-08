# ADR-0001: Record architecture decisions

- Status: accepted
- Date: 2026-11-09
- Phase: P0
- Requirements: §21, §25 step 2

## Context
Jit is built in phases by different sessions. Decisions (and the data behind them) must survive between
sessions and be checkable against the code. The master prompt (`docs/master-prompt.md`) is frozen; the
owner amends it through ADRs.

## Decision
- Every decision that changes architecture, dependencies, platform baseline, security posture or a
  requirement is recorded as `docs/adr/NNNN-kebab-title.md` using `0000-template.md`.
- Numbers are reserved in `docs/roadmap.md` §5 (ADR backlog); gaps are allowed.
- Status moves `proposed → accepted → superseded by ADR-XXXX`. Accepted ADRs are not rewritten; later
  findings are appended as dated addenda (e.g. ADR-0006 "Phase 0 addendum").
- An ADR states its evidence (spike results, measurements, SDK declarations) — not opinions alone.
- Where an ADR and the master prompt disagree, the ADR wins.

## Consequences
- Reviewers can check code against a written decision.
- Small, local choices do not need ADRs; they go in phase specs.
