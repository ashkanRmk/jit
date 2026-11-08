# Product

A premium, ultra-lightweight native macOS Git client. Source requirements: `docs/master-prompt.md`
(§1–§12), amended by ADR-0002 (pure Swift core — no Rust/UniFFI) and ADR-0006 (macOS 26+, native
Liquid Glass). Plan: `docs/roadmap.md`.

**What exists today (Phase 0):** a native window that opens a folder and shows what `GitCore`
discovered — repository kind (regular, bare, linked worktree), top level, Git directory, branch /
detached / unborn HEAD, and the Git executable and version — with designed empty, loading and error
states; and a debug-only design-system gallery. Nothing else below is built yet.

## V1 scope (planned, by phase)
- **Shell & tabs (P1):** one main window with repository tabs restored on relaunch, new-tab page, live
  status, identity-only profiles and a global profile indicator.
- **Graph & navigation (P2):** virtualized commit graph for 100k+ commits at 60 FPS, branch navigator,
  commit details, search/filter, file history.
- **Working directory & diff (P3):** native unified/split diff, syntax highlighting, file/hunk/line
  stage, unstage and discard proven safe by tests, blame, commit and amend with profile identity.
- **Everyday workflows & conflicts (P4):** fetch/pull/push/clone, branch operations,
  merge/rebase/cherry-pick/revert, visual three-way conflict resolution.
- **Profiles & providers (P5):** SSH/PAT/OAuth via the Keychain, GitHub and GitLab (incl. self-managed,
  custom CA, proxy).
- **Polish & performance (P6), Packaging & release (P7):** §15.1 targets, accessibility, signed and
  notarized DMG with bundled Git.

## Explicitly excluded from V1 (§9.3)
Pull/merge request creation or management, code review workflows, provider CI/CD dashboards and
pipeline management, hosted collaboration services, an AI coding assistant, a general-purpose IDE.
Provider APIs are used only for authentication, repository discovery, client metadata and clone URLs.
Post-V1 epics (interactive rebase, stash UI, worktree management, reflog, reset UI, tags, patches, LFS,
submodules…) are parked in `docs/phases/08-post-v1`.

## Product principles
Native-first, performance-first (near-zero idle cost), correctness-first (protect the user's data),
simplicity-first. Glass on chrome only; content opaque and calm. No telemetry. No mock data or fake
success in shipped UI — unbuilt features are absent or labelled "Planned".
