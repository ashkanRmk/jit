# ADR-0002: Pure Swift core over the Git CLI (no Rust, no UniFFI)

- Status: accepted (decided by the project owner, 2026-11-08)
- Date: 2026-11-08
- Phase: P0 (pre-decided during planning)
- Requirements: §1, §2.2, §2.4, §13, §13.4. **Supersedes** the master prompt's §1 rows "Git engine: Rust"
  and "Swift/Rust bridge: UniFFI", and §13.2–§13.3.

## Context
The product goal is a very lightweight, efficient native Mac app — Fork-level weight, far below
Electron clients such as GitKraken. The weight gap versus Electron comes from the native UI and the
absence of a browser engine, not from the core's language. The core's job is to run the Git CLI,
parse its output, lay out the commit graph, build patches and track operation state. Swift handles
this comfortably when data is kept compact. A Rust core would add a second language, a UniFFI bridge
with marshalling copies on every call, an XCFramework build pipeline, duplicated concurrency
primitives (Rust lock + Swift actor), and harder cross-language profiling.

## Decision
- All application code is Swift 6 (strict concurrency). No Rust, no UniFFI, no FFI bridge.
- Git logic lives in a **`GitCore`** target of the local Swift package (`macos/Packages/JitKit`). It imports
  Foundation (and Darwin/System) only — never AppKit or SwiftUI — so it is unit-testable with
  `swift test` and the module boundary stays as clean as a separate crate would have been.
- Test fixtures live in a **`GitTestKit`** target (temporary real repositories, fingerprints,
  `assertUnrelatedUnchanged`).
- Git backend stays the installed (later bundled) **Git CLI**, launched through a thin `posix_spawn`
  wrapper (`ProcessRunner`) with argv arrays, explicit cwd, env allowlist and process groups.
- Concurrency, process and memory rules are in ADR-0005.
- Helper executables (credential helper / askpass, post-V1 editor helper) are small Swift executable
  targets. The syntax highlighter may use the tree-sitter C runtime through a SwiftPM C target (C, not Rust).

## Consequences
- One language, one build system (Xcode + SwiftPM). Phase 0 no longer needs rustup, cargo,
  UniFFI, uniffi-bindgen or XCFramework scripts.
- No bridge copies; Features receive `GitCore` value types directly through `Services`.
- One per-repository serialization primitive (a Swift actor), not two.
- The `gix` escape hatch is gone. Hot read paths instead use efficient Git usage: streamed `git log`
  pages, long-lived `git cat-file --batch` readers for visible repositories, commit-graph awareness.
  A C library (e.g. libgit2) is considered only if profiling proves a bottleneck those can't fix.
- Memory compactness is no longer a language default and must be enforced by rule (ADR-0005): no class
  per commit/line, struct-of-arrays stores, byte-level parsing, strings materialized only for visible rows.
- **Revisit if:** Phase 2/3/6 profiling shows a parsing or layout hot path that Swift cannot bring within
  the §15.1 budget after optimization; record measurements before reintroducing another language.
