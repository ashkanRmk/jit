# ADR-0003: XcodeGen-generated Xcode project

- Status: accepted
- Date: 2026-11-09
- Phase: P0
- Requirements: §13.6, §21

## Context
The app target is thin (ADR-0004); almost all code lives in the local Swift package `JitKit`. A
checked-in `.xcodeproj` produces unreadable merge conflicts and hides build settings in a pbxproj.
Options: (a) checked-in `.xcodeproj`, (b) XcodeGen spec, (c) Tuist. XcodeGen 2.46.0 is installed; it is
a single Homebrew binary with no project-side runtime dependency. Tuist adds a Swift-manifest toolchain
and caches that are more than this project needs.

## Decision
- `macos/project.yml` is the source of truth. `scripts/build/gen-xcodeproj.sh` runs
  `xcodegen generate --spec macos/project.yml`; `macos/Jit.xcodeproj` is git-ignored.
- Build settings that matter (deployment target 26.0, Swift 6, Hardened Runtime, arm64, bundle ID) live
  in `project.yml` and `macos/App/Config/*.xcconfig`.
- CI and `scripts/build/build-all.sh` always regenerate before building.

## Consequences
- XcodeGen (Homebrew) is a development prerequisite; scripts check for it and explain how to install it.
- Opening the project in Xcode requires running the generator first.
- Revisit if XcodeGen stops tracking new Xcode project formats.
