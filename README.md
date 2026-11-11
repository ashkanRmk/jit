# Jit

A premium, ultra-lightweight native macOS Git client — 100% Swift (SwiftUI + AppKit), native Liquid
Glass design, driving the Git CLI. No Electron, web views, background daemons or telemetry.

**[Website](https://ashkanrmk.github.io/jit/)** · **[Download the latest test build](https://github.com/ashkanRmk/jit/releases)**
(macOS 26+, Apple silicon, ~11 MB with Git included) · [Release notes](docs/releases/v0.0.5.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/graph-dark.webp">
  <img src="site/assets/shots/graph-light.webp" width="1000" alt="Jit showing the commit graph of a repository with feature branches merging into main, the branch sidebar on the left and the selected commit's details on the right.">
</picture>

| Working copy | Side-by-side diff |
|---|---|
| <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/wip-dark.webp"><img src="site/assets/shots/wip-light.webp" alt="Uncommitted changes at the top of the graph, with unstaged and staged files and the commit summary and description fields."></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/shots/diff-dark.webp"><img src="site/assets/shots/diff-light.webp" alt="A side-by-side diff of a Swift file with added and removed lines highlighted, next to the commit's author and changed files."></picture> |

Screenshots follow your GitHub light/dark appearance. They are real captures of Jit 0.0.5.

## Status

**V1 (Phases 0–7) is implemented and merged to `main`. The current version is 0.0.5, a test build with
in-app updates, provider tabs in Settings ▸ Accounts and diff fixes ([notes](docs/releases/v0.0.5.md)).**

| Phase | State | Report |
|---|---|---|
| 0 Foundation & design | done | [progress](docs/phases/00-foundation/progress.md) |
| 1 Native shell & repository tabs | done | [progress](docs/phases/01-shell-and-tabs/progress.md) |
| 2 Git graph & navigation | done | [progress](docs/phases/02-graph-and-navigation/progress.md) |
| 3 Working directory & diff | done | [progress](docs/phases/03-working-directory-and-diff/progress.md) |
| 4 Git workflows & conflicts | done | [progress](docs/phases/04-git-workflows-and-conflicts/progress.md) |
| 5 Profiles & providers | done | [progress](docs/phases/05-profiles-and-providers/progress.md) |
| 6 Polish & performance | done, with carry-overs | [progress](docs/phases/06-polish-and-performance/progress.md) |
| 7 Packaging & release | done, with carry-overs | [progress](docs/phases/07-packaging-and-release/progress.md) |
| 8 Post-V1 epics | planned, not started | [design](docs/phases/08-post-v1/design.md) |

Builds are **ad-hoc signed and not notarized** (owner decision 2026-11-10: free distribution, no paid
Apple Developer Program; ADR-0049). Developer ID signing and notarization are scripted but have never been run.
Last full local run: 745 core tests passed, 0 failed; app tests and lint clean.

## What Jit does (V1)
- **Repository tabs** — one window, tabs restored on relaunch (only the active tab loads), new-tab page with
  recents, live status from FSEvents while visible, no polling.
- **Commit graph** — virtualized graph for large histories, branch navigator, commit details, search and
  filter, file history, compare two commits.
- **Working directory & diff** — native unified/split diff with syntax highlighting and word diff;
  stage, unstage and discard by file, hunk or line; blame; commit and amend with the profile's identity.
- **Everyday workflows** — fetch, pull (fast-forward only by default), push (force-with-lease only, never plain
  `--force`), clone, branch create/switch/rename/delete/upstream, merge, rebase, cherry-pick, revert with
  continue/skip/abort, stash, activity history.
- **Conflicts** — three-way resolver with explicit ours/theirs labels and non-text fallbacks.
- **Profiles & providers** — global profiles applied per invocation (never touches `~/.gitconfig` or
  `~/.ssh/config`); SSH, PAT and OAuth with secrets only in the Keychain; GitHub and GitLab including
  self-managed, custom CA and proxy; remote repository browser; connectivity diagnostics.
- **Polish** — ⌘K command palette, accessibility (VoiceOver rotors, Reduce Motion, differentiate without
  color), memory-pressure trimming and tab suspension.
- **Packaging** — bundled, relocatable Git 2.56.0; Settings ▸ Git to choose another (2.39+).

Not in V1 by design: pull/merge request management, code review, CI dashboards, AI assistant.

## What remains
**Release**
- Releases are test builds (0.0.x) published as GitHub pre-releases; there is no 1.0 release yet.
- CI on `main` is not green: the last run did not start (GitHub Actions billing/spending limit), and the run
  before it failed the advisory performance gate. The gate was relaxed afterwards but that change is unverified in CI.

**Never verified**
- Developer ID signing, notarization, stapling and Gatekeeper acceptance (no certificate).
- Clean-machine acceptance on a fresh macOS 26 VM without developer tools (ADR-0048).
- OAuth sign-in against real providers — no OAuth clients are registered, so OAuth shows "not configured"
  (PAT and SSH work). Real GitHub/GitLab accounts were not used; only the local enterprise rig.
- Live VoiceOver walkthrough, Instruments animation-hitch and Metal traces, and a by-eye review of settings,
  repository browser, resolver and clone sheet under Reduce Transparency / Increase Contrast.

**Known gaps**
- No XCUITest target (keyboard-only commit and conflict flows, accessibility audit are untested at UI level).
- Tab switch is 17.4 ms median against a 16 ms target.
- In a short window with a diff open, the inspector gives the file list too little height.
- The website ([ashkanrmk.github.io/jit](https://ashkanrmk.github.io/jit/), source in [`site/`](site/)) is not
  deployed yet: GitHub Pages is not enabled for the repository, and its Pages workflow is blocked by the same
  GitHub Actions billing limit.

**Post-V1 (Phase 8, all unstarted)** — reflog explorer, reset, tags, interactive rebase, commit surgery,
history filters, worktrees, patches, advanced remotes, branch history manipulation, signing, submodules, LFS.

## Install
- **System requirements:** macOS 26 or later on Apple silicon (arm64; ADR-0049). Nothing else: Jit bundles Git
  2.56.0 and doesn't need Xcode, the Command Line Tools or Homebrew. SSH uses the system `/usr/bin/ssh`.
- **Get the app:** download `Jit-<version>.dmg` from the newest test build on
  [GitHub Releases](https://github.com/ashkanRmk/jit/releases) (pre-releases; currently 0.0.5), open it and drag
  **Jit** to **Applications**. Or build the DMG yourself with `scripts/release/release.sh --adhoc` (see
  [`docs/release.md`](docs/release.md)); a DMG built on your own Mac is not quarantined and opens without the
  step below.
- **First launch — Jit is not notarized by Apple** (it's signed ad-hoc). A DMG downloaded from the internet
  makes macOS show "“Jit” Not Opened — Apple could not verify…". Click **Done** (not Move to Trash), then either:
  - **System Settings → Privacy & Security**, scroll to "“Jit” was blocked…", click **Open Anyway**, confirm
    with your password, then click **Open**; or
  - in Terminal: `xattr -dr com.apple.quarantine /Applications/Jit.app`, then open Jit normally.

  You do this once per downloaded version. Check the DMG's SHA-256 against the release notes first:
  `shasum -a 256 ~/Downloads/Jit-<version>.dmg`.
- **Updating**: replace the app with the new version and repeat the first-launch step. Because ad-hoc builds
  have no stable signing identity, macOS may ask once whether the new Jit may use the Keychain items it saved
  (tokens, SSH passphrases); choose **Always Allow**.
- What's included: Jit, `jit-git-helper` (credential helper), and Git 2.56.0 under the GNU GPL v2. The license,
  the source location and a written offer are in **Help ▸ Acknowledgements**. Jit makes no network requests on
  its own, with two exceptions, both in **Settings ▸ General**: author pictures are looked up at
  gravatar.com by a hash of the author's email, for commits on screen (ADR-0050, on by default); and with
  **Update Jit automatically** on (off by default) Jit asks GitHub for new releases at most once a day,
  downloads a newer one and installs it when you quit (ADR-0051).
- Updating: the bell at the top right opens **What's New** — the change log, **Check for Updates** and
  **Install and Restart**. Nothing is requested until you check, unless automatic updates are on.

## Develop

Prerequisites:
- macOS 26+ with **full Xcode 26+** selected (`xcode-select -p` must point into `Xcode.app`).
- XcodeGen (`brew install xcodegen`).
- Git 2.39+ for development builds (Homebrew or the Xcode Command Line Tools); release builds bundle Git.

No Rust toolchain or third-party Swift packages are needed (ADR-0002).

```bash
scripts/build/build-all.sh debug --test   # generate project, build Jit.app, run all tests
open ~/Library/Developer/Xcode/DerivedData/Jit/Build/Products/Debug/Jit.app
```
Open the project in Xcode with `scripts/build/gen-xcodeproj.sh && open macos/Jit.xcodeproj`.

| Task | Command |
|---|---|
| Core tests | `scripts/build/test-core.sh` |
| App/UI tests | `scripts/build/test-app.sh` |
| Lint (format + architecture rules) | `scripts/build/lint.sh` |
| Benchmarks | `scripts/benchmarks/run-all.sh [--quick]` |
| Bundled Git | `scripts/build/build-git.sh`, `scripts/build/test-bundled-git.sh` |
| Release DMG | `scripts/release/release.sh [--adhoc]` |

All commands, debug launch arguments and test rigs: [`CLAUDE.md`](CLAUDE.md#commands) and
[`docs/testing.md`](docs/testing.md).

## Layout
```
macos/App/                 thin app target (AppKit entry point, menus, launch/benchmark hooks)
macos/Packages/JitKit/     GitCore, GitTestKit, Services, DesignSystem, Features, JitBench + tests
macos/project.yml          XcodeGen spec (project is generated, not committed)
scripts/build/             build, test, lint, bundled-Git build scripts
scripts/release/           release steps 01–09 + release.sh (sign, DMG, notarize, validate)
scripts/benchmarks/        launch, idle and scenario benchmarks
scripts/testing/           screenshots, local enterprise test rig
benchmarks/                benchmark baselines and results
docs/                      product, architecture, design system, performance, security, release, ADRs, phases
```

## Documentation
- [`docs/master-prompt.md`](docs/master-prompt.md) — requirements; [`docs/roadmap.md`](docs/roadmap.md) — plan.
- [`docs/architecture.md`](docs/architecture.md), [`docs/design-system.md`](docs/design-system.md),
  [`docs/performance.md`](docs/performance.md), [`docs/security.md`](docs/security.md),
  [`docs/testing.md`](docs/testing.md), [`docs/release.md`](docs/release.md),
  [`docs/product.md`](docs/product.md), [`docs/adr/`](docs/adr/) (49 decisions).
- [`docs/phases/`](docs/phases/) — one folder per phase (design, implementation plan, kickoff prompt, progress).

## License
Jit is released under the [MIT License](LICENSE). The Git it bundles is licensed separately under the GNU GPL v2
(Help ▸ Acknowledgements).
