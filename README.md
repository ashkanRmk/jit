# Jit

A premium, ultra-lightweight native macOS Git client — 100% Swift (SwiftUI + AppKit), native Liquid
Glass design, driving the Git CLI.

**Status: Phase 7 (packaging & release) — 1.0.0 is distributed free as an ad-hoc-signed, non-notarized DMG**
(owner decision 2026-11-10; Developer ID signing stays available in the scripts) ([progress](docs/phases/07-packaging-and-release/progress.md)).
Phases 0–6 are implemented (Phase 6 with carry-overs): repository tabs, a virtualized commit graph, native diff with line-level staging,
blame, everyday workflows and a three-way conflict resolver, global profiles with SSH/PAT/OAuth and
enterprise networking, the ⌘K palette and accessibility.

## Install
- **System requirements:** macOS 26 or later on Apple silicon (arm64; ADR-0049). Nothing else: Jit bundles Git
  2.56.0 and doesn't need Xcode, the Command Line Tools or Homebrew. SSH uses the system `/usr/bin/ssh`.
- Download `Jit-1.0.0.dmg` from the GitHub Release, open it and drag **Jit** to **Applications**.
- **First launch — Jit is free and not notarized by Apple** (it's signed ad-hoc; owner decision, ADR-0049).
  macOS shows "“Jit” Not Opened — Apple could not verify…". Click **Done** (not Move to Trash), then either:
  - **System Settings → Privacy & Security**, scroll to "“Jit” was blocked…", click **Open Anyway**, confirm
    with your password, then click **Open**; or
  - in Terminal: `xattr -dr com.apple.quarantine /Applications/Jit.app`, then open Jit normally.
  You do this once per downloaded version. Check the DMG's SHA-256 against the release notes first:
  `shasum -a 256 ~/Downloads/Jit-1.0.0.dmg`.
- **Updating**: replace the app with the new version and repeat the first-launch step. Because ad-hoc builds
  have no stable signing identity, macOS may ask once whether the new Jit may use the Keychain items it saved
  (tokens, SSH passphrases); choose **Always Allow**.
- You can also build it yourself: `scripts/release/release.sh --adhoc` (see [`docs/release.md`](docs/release.md)).
- What's included: Jit, `jit-git-helper` (credential helper), and Git 2.56.0 under the GNU GPL v2. The license,
  the source location and a written offer are in **Help ▸ Acknowledgements**. Jit makes no network requests on
  its own and has no auto-updater (ADR-0020).
- Settings ▸ Git shows which Git is in use and lets you choose another (2.39+).

## Prerequisites
- macOS 26+ with **full Xcode 26+** selected (`xcode-select -p` must point into `Xcode.app`).
- XcodeGen (`brew install xcodegen`).
- Git 2.39+ for development builds (Homebrew or the Xcode Command Line Tools); release builds bundle Git.

No Rust toolchain or third-party Swift packages are needed (ADR-0002).

## Build and run
```bash
scripts/build/build-all.sh debug --test   # generate project, build Jit.app, run all tests
open ~/Library/Developer/Xcode/DerivedData/Jit/Build/Products/Debug/Jit.app
```
Open the project in Xcode with `scripts/build/gen-xcodeproj.sh && open macos/Jit.xcodeproj`.
All commands: [`CLAUDE.md`](CLAUDE.md#commands).

## Layout
```
macos/App/                 thin app target (AppKit entry point, menus, launch/benchmark hooks)
macos/Packages/JitKit/     GitCore, GitTestKit, Services, DesignSystem, Features, JitBench + tests
macos/project.yml          XcodeGen spec (project is generated, not committed)
scripts/build/             build, test, lint, bundled-Git build scripts
scripts/release/           release steps 01–09 + release.sh (sign, DMG, notarize, validate)
scripts/benchmarks/        launch, idle and scenario benchmarks
docs/                      product, architecture, design system, performance, security, release, ADRs, phases
```

## Documentation
- [`docs/master-prompt.md`](docs/master-prompt.md) — requirements; [`docs/roadmap.md`](docs/roadmap.md) — plan.
- [`docs/architecture.md`](docs/architecture.md), [`docs/design-system.md`](docs/design-system.md),
  [`docs/performance.md`](docs/performance.md), [`docs/security.md`](docs/security.md),
  [`docs/release.md`](docs/release.md), [`docs/product.md`](docs/product.md), [`docs/adr/`](docs/adr/).
- [`docs/phases/`](docs/phases/) — one folder per phase (design, implementation plan, kickoff prompt, progress).
