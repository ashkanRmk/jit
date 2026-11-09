# Jit

A premium, ultra-lightweight native macOS Git client — 100% Swift (SwiftUI + AppKit), native Liquid
Glass design, driving the Git CLI.

**Status: Phase 1 (native shell & repository tabs) on branch `phase/01-shell-and-tabs`.** One window with
glass repository tabs restored on relaunch, a new-tab page with recents and drag-and-drop, a workbench
skeleton showing branch, upstream, operation state and live working-directory counts (FSEvents, only for
the visible tab), System/Light/Dark appearance, and identity-only Git profiles that never touch your
global Git config. Reports: [`docs/phases/01-shell-and-tabs/progress.md`](docs/phases/01-shell-and-tabs/progress.md),
[`docs/phases/00-foundation/progress.md`](docs/phases/00-foundation/progress.md).

## Prerequisites
- macOS 26+ with **full Xcode 26+** selected (`xcode-select -p` must point into `Xcode.app`).
- XcodeGen (`brew install xcodegen`).
- Git 2.39+ (Homebrew or the Xcode Command Line Tools).

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
scripts/build/             build, test, lint scripts
scripts/benchmarks/        launch and idle benchmarks
docs/                      product, architecture, design system, performance, security, release, ADRs, phases
```

## Documentation
- [`docs/master-prompt.md`](docs/master-prompt.md) — requirements; [`docs/roadmap.md`](docs/roadmap.md) — plan.
- [`docs/architecture.md`](docs/architecture.md), [`docs/design-system.md`](docs/design-system.md),
  [`docs/performance.md`](docs/performance.md), [`docs/security.md`](docs/security.md),
  [`docs/release.md`](docs/release.md), [`docs/product.md`](docs/product.md), [`docs/adr/`](docs/adr/).
- [`docs/phases/`](docs/phases/) — one folder per phase (design, implementation plan, kickoff prompt, progress).
