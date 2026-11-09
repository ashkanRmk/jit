# Product

A premium, ultra-lightweight native macOS Git client. Source requirements: `docs/master-prompt.md`
(§1–§12), amended by ADR-0002 (pure Swift core — no Rust/UniFFI) and ADR-0006 (macOS 26+, native
Liquid Glass). Plan: `docs/roadmap.md`.

**What exists today (Phase 1):** one main window with repository tabs in native Liquid Glass chrome —
glass capsule tabs in the toolbar (drag to reorder, middle-click/⌘W to close, ⌘⇧T to reopen, ⌃Tab and
⌘⇧[ / ⌘⇧] to cycle, overflow scrolling plus an all-tabs menu), restored on relaunch with only the active
tab loading; a new-tab page (Open Repository…, recents with Locate…/Remove/undo, drop a folder anywhere);
a workbench skeleton per repository (system glass sidebar with the repository summary, header with
branch/detached/unborn, upstream ahead/behind and an operation chip, staged/unstaged/untracked/conflicted
counts, inspector with Finder/Terminal actions, loading/error/bare states) that updates live from FSEvents
while visible; System/Light/Dark appearance; identity-only Git profiles (create/edit/delete, Fill from Git
config, toolbar capsule and switcher, "No Profile" warning state) that never touch global Git config; and
menus with only working items. No graph, diff, staging, commit or network operations yet.

## Keyboard shortcuts (Phase 1)

Checked against macOS standard shortcuts (HIG) and the roadmap registry; ⌘1–⌘3 stay reserved for
workbench modes.

| Shortcut | Action | Notes |
|---|---|---|
| ⌘, | Settings… | standard |
| ⌘T / ⌘O | New Tab / Open Repository… | standard meanings |
| ⌘W / ⇧⌘W | Close Tab / Close Window | as in Safari; ⌘W closes the Settings window when it is key |
| ⇧⌘T | Reopen Closed Tab | as in Safari |
| ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ | Show next / previous tab | as in Safari, Xcode |
| ⌃⌘S / ⌥⌘0 | Show/Hide Sidebar / Inspector | ⌃⌘S as in Finder/Mail; ⌥⌘0 as in Xcode |
| ⌃⌘F | Enter Full Screen | standard |
| ⌘R | Repository ▸ Refresh | as browsers' Reload |
| ⌥⌘R / ⌥⌘T / ⌥⌘C | Reveal in Finder / Open in Terminal / Copy Repository Path | ⌥⌘T is Finder's "Show/Hide toolbar" only inside Finder; no conflict in Jit |
| ⌘Z / ⇧⌘Z | Undo / Redo (e.g. removing a recent) | standard |
| ⌘M, ⌘H, ⌥⌘H, ⌘Q, ⌘? | Minimize, Hide, Hide Others, Quit, Help | standard |

## Phase 4 shortcuts
⇧⌘N Clone Repository… · ⌥⌘A Show Activity · ⌥⌘S Stash Changes… · resolver: ⌥⌘↓ / ⌥⌘↑ next / previous block,
⌘S save, ⇧⌘R mark as resolved, ⌘Z / ⇧⌘Z undo / redo, Esc close.

## V1 scope (planned, by phase)
- **Shell & tabs (P1, done):** one main window with repository tabs restored on relaunch, new-tab page,
  live status, identity-only profiles and a global profile indicator.
- **Graph & navigation (P2):** virtualized commit graph for 100k+ commits at 60 FPS, branch navigator,
  commit details, search/filter, file history.
- **Working directory & diff (P3):** native unified/split diff, syntax highlighting, file/hunk/line
  stage, unstage and discard proven safe by tests, blame, commit and amend with profile identity.
- **Everyday workflows & conflicts (P4, done):** fetch (prune explicit), pull (fetch + fast-forward only by
  default; merge or rebase only on explicit choice), push with publish/upstream, rejection explanations and
  force-with-lease only (never plain `--force`), clone from URL with progress/cancel, branch create / switch /
  check out remote / detach / rename / delete (unmerged needs a second confirmation) / delete remote / upstream,
  merge, rebase, cherry-pick, revert with continue / skip / abort, an operation banner for states started
  anywhere, a three-way conflict resolver with non-text fallbacks, stash (create, apply, pop, drop, Stash and
  Switch), GitHub/GitLab web links, activity history. Remote operations never prompt: public HTTPS and
  ssh-agent keys work; credentials arrive in P5.
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
