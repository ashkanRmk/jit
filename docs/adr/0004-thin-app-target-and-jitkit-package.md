# ADR-0004: Thin app target + local Swift package `JitKit`

- Status: accepted
- Date: 2026-11-09
- Phase: P0
- Requirements: §13.1, §13.6, §18; ADR-0002

## Context
Core logic must be testable with `swift test` without building an app bundle, and UI code must not leak
into the Git engine. SwiftPM targets give enforced module boundaries for free.

## Decision
One local package, `macos/Packages/JitKit`, with these targets:

| Target | Kind | Imports | Purpose |
|---|---|---|---|
| `GitCore` | library | Foundation, Darwin only | Git location, process execution, discovery, parsers (ADR-0002/0005) |
| `GitTestKit` | library (test support) | Foundation, GitCore | real temporary repositories with isolated config |
| `DesignSystem` | library | SwiftUI, AppKit | tokens, glass helpers, content styles |
| `Features` | library | SwiftUI, AppKit, GitCore, DesignSystem | screens and view models |
| `JitBench` | executable (dev only) | GitCore, GitTestKit | micro-benchmarks writing JSON |
| `GitCoreTests`, `DesignSystemTests` | tests | — | `swift test` |

`Services` (Phase 1), `JitGitHelper` and `TestRig` (Phase 5) are added when they get content. The Xcode
app target `Jit` (`macos/App`) contains only the `@main` app, window scenes, menus and launch
instrumentation; `JitAppTests` covers engine wiring through the app.

## Consequences
- `swift test --package-path macos/Packages/JitKit` runs all core and design-system tests.
- `GitCore` cannot accidentally import UI frameworks: a test scans its sources.
- GitTestKit is never linked into the shipping app (only test targets and JitBench depend on it).
