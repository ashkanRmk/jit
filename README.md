# Jit

A premium, ultra-lightweight native macOS Git client — 100% Swift (SwiftUI + AppKit), native Liquid
Glass design, driving the Git CLI.

**Status: Phase 7 (packaging & release) — 1.0.0 builds as an ad-hoc-signed DMG; Developer ID signing and
notarization are blocked on credentials** ([progress](docs/phases/07-packaging-and-release/progress.md)).
Phases 0–6 are implemented (Phase 6 with carry-overs): repository tabs, a virtualized commit graph, native diff with line-level staging,
blame, everyday workflows and a three-way conflict resolver, global profiles with SSH/PAT/OAuth and
enterprise networking, the ⌘K palette and accessibility.

## Install
- **System requirements:** macOS 26 or later on Apple silicon (arm64; ADR-0049). Nothing else: Jit bundles Git
  2.56.0 and doesn't need Xcode, the Command Line Tools or Homebrew. SSH uses the system `/usr/bin/ssh`.
- Open `Jit-1.0.0.dmg` and drag **Jit** to **Applications**.
- **Until the release is notarized**, macOS blocks the ad-hoc build ("Apple could not verify…"). Only use a
  build you made yourself (`scripts/release/release.sh --adhoc`). A notarized build opens with the standard
  "downloaded from the Internet" confirmation.
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
