# Product

A premium, ultra-lightweight native macOS Git client. Source requirements: `docs/master-prompt.md`
(§1–§12), amended by ADR-0002 (pure Swift core — no Rust/UniFFI) and ADR-0006 (macOS 26+, native
Liquid Glass). Plan: `docs/roadmap.md`.

**What exists today (V1, Phases 0–7 implemented; 1.0.0 built, not yet published):** one main window with
repository tabs in native Liquid Glass chrome, restored on relaunch with only the active tab loading; a new-tab
page with recents and a remote repository browser; a virtualized commit graph with branch navigator, commit
details, search/filter, file history and compare; native unified/split diff with syntax highlighting and
file/hunk/line stage, unstage and discard; blame; commit and amend; fetch, pull, push (force-with-lease only),
clone, branch operations, merge, rebase, cherry-pick, revert, stash and a three-way conflict resolver; global
profiles with SSH/PAT/OAuth in the Keychain, GitHub and GitLab (incl. self-managed, custom CA, proxy) that never
touch global Git config; the ⌘K command palette and accessibility support; a bundled Git 2.56.0 with
Settings ▸ Git. Status updates live from FSEvents while visible; nothing polls. What is still open:
[`roadmap.md` §10](roadmap.md#10-current-state-and-what-remains).

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

## V1 scope (by phase — all implemented)
- **Shell & tabs (P1, done):** one main window with repository tabs restored on relaunch, new-tab page,
  live status, identity-only profiles and a global profile indicator.
- **Graph & navigation (P2, done):** virtualized commit graph for 100k+ commits at 60 FPS, branch navigator,
  commit details, search/filter, file history.
- **Working directory & diff (P3, done):** native unified/split diff, syntax highlighting, file/hunk/line
  stage, unstage and discard proven safe by tests, blame, commit and amend with profile identity.
- **Everyday workflows & conflicts (P4, done):** fetch (prune explicit), pull (fetch + fast-forward only by
  default; merge or rebase only on explicit choice), push with publish/upstream, rejection explanations and
  force-with-lease only (never plain `--force`), clone from URL with progress/cancel, branch create / switch /
  check out remote / detach / rename / delete (unmerged needs a second confirmation) / delete remote / upstream,
  merge, rebase, cherry-pick, revert with continue / skip / abort, an operation banner for states started
  anywhere, a three-way conflict resolver with non-text fallbacks, stash (create, apply, pop, drop, Stash and
  Switch), GitHub/GitLab web links, activity history. Remote operations never prompt: public HTTPS and
  ssh-agent keys work; credentials arrive in P5.
- **Profiles & providers (P5, done):** SSH/PAT/OAuth via the Keychain, GitHub and GitLab (incl. self-managed,
  custom CA, proxy).
- **Polish & performance (P6, done with carry-overs), Packaging & release (P7, done with carry-overs):**
  §15.1 targets measured and reported, accessibility, command palette, and an arm64 DMG with bundled Git —
  ad-hoc signed and not notarized (owner decision, ADR-0049 addendum).

## Explicitly excluded from V1 (§9.3)
Pull/merge request creation or management, code review workflows, provider CI/CD dashboards and
pipeline management, hosted collaboration services, an AI coding assistant, a general-purpose IDE.
Provider APIs are used only for authentication, repository discovery, client metadata and clone URLs.
Post-V1 epics (interactive rebase, worktree management, reflog, reset UI, tags, patches, LFS,
submodules…) are parked in `docs/phases/08-post-v1`.

## Product principles
Native-first, performance-first (near-zero idle cost), correctness-first (protect the user's data),
simplicity-first. Glass on chrome only; content opaque and calm. No telemetry. No mock data or fake
success in shipped UI — unbuilt features are absent or labelled "Planned".

## Profiles & accounts (Phase 5)
- One global profile, chosen manually (toolbar switcher, Repository ▸ Profile, ⌃⌘P). A profile = identity +
  optional authentication (GitHub, GitLab.com or a self-managed GitLab; HTTPS account; SSH key or agent).
- Supported auth: personal access tokens (GitHub, GitLab.com, self-managed), SSH keys/agent, and browser sign-in
  where an OAuth client is configured (GitLab PKCE, GitHub device flow — not available in builds without
  registered client IDs).
- Self-managed GitLab: base URL with path prefix, custom CA certificates, proxy (System/PAC, Manual, Direct),
  connectivity diagnostics with a copyable report.
- Remote repository browser (File ▸ Browse Remote Repositories…) and clone with the active profile.
- Known limitations: no proxy authentication for SSH; host-key scanning can't use a proxy; OAuth requires
  registered client IDs; unsigned dev builds may ask for the login keychain password after a rebuild.
