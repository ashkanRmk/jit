# Jit

A premium, ultra-lightweight native macOS Git client — SwiftUI + AppKit on top of a Rust Git core.

**Status: planning.** No application code exists yet. The plan:

- [`docs/master-prompt.md`](docs/master-prompt.md) — full product and engineering requirements.
- [`docs/roadmap.md`](docs/roadmap.md) — phases, architecture, invariants, performance budget, risks.
- [`docs/phases/`](docs/phases/) — one folder per phase with `design.md`, `implementation.md` and a
  ready-to-paste `prompt.md` for starting that phase in Claude Code.

| Phase | Folder |
|---|---|
| 0 — Foundation & design | [`docs/phases/00-foundation`](docs/phases/00-foundation/) |
| 1 — Native shell & repository tabs | [`docs/phases/01-shell-and-tabs`](docs/phases/01-shell-and-tabs/) |
| 2 — Git graph & navigation | [`docs/phases/02-graph-and-navigation`](docs/phases/02-graph-and-navigation/) |
| 3 — Working directory & diff | [`docs/phases/03-working-directory-and-diff`](docs/phases/03-working-directory-and-diff/) |
| 4 — Everyday workflows & conflicts | [`docs/phases/04-git-workflows-and-conflicts`](docs/phases/04-git-workflows-and-conflicts/) |
| 5 — Profiles & providers | [`docs/phases/05-profiles-and-providers`](docs/phases/05-profiles-and-providers/) |
| 6 — Polish & performance | [`docs/phases/06-polish-and-performance`](docs/phases/06-polish-and-performance/) |
| 7 — Packaging & release | [`docs/phases/07-packaging-and-release`](docs/phases/07-packaging-and-release/) |
| 8 — Post-V1 | [`docs/phases/08-post-v1`](docs/phases/08-post-v1/) |

## Prerequisites (development)
- macOS 14+ with **full Xcode** installed and selected (`xcode-select -p` must point into `Xcode.app`).
- Rust via `rustup` (stable).
- Git 2.39+ (to be confirmed by ADR-0006).

Build instructions are added in Phase 0.
