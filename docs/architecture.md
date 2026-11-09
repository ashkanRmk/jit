# Architecture

Status: Phase 0. This describes what exists; planned parts are marked **(planned, Phase N)**.
Decisions: ADR-0002 (pure Swift), ADR-0003 (XcodeGen), ADR-0004 (package layout), ADR-0005 (process,
concurrency, memory), ADR-0006 (macOS 26+, Liquid Glass).

## Layers

```
Chrome (system Liquid Glass): toolbar, sidebar, popovers, sheets          ┐ SwiftUI + AppKit
Content (opaque): foundation card, gallery; later graph, diff, lists      ┘ Features (@MainActor view models)
          │  async calls, value types
Services (planned, Phase 1): RepositorySession actors, file watching, profiles
          │
GitCore (Foundation/Darwin only): GitEngine actor, GitLocator, ProcessRunner, RepositoryDiscovery
          │  posix_spawn, argv arrays
git CLI (installed; bundled from Phase 7)
```

## Targets (`macos/Packages/JitKit`, app in `macos/App`)

| Target | Contents today |
|---|---|
| `GitCore` | `GitVersion`, `GitLocator` (+ `FileProbe`), `ProcessEnvironment`, `ProcessRunner`, `GitEngine` (actor), `GitCommand`, `RepositoryDiscovery`/`RepositoryInfo`, `GitCoreError` + redaction |
| `GitTestKit` | `GitSandbox` (temp dir, isolated `HOME`/config, fixed identity/dates), `TestRepo` |
| `DesignSystem` | color tokens (data + dynamic `NSColor`), type, metrics, motion, glass helpers, content styles |
| `Features` | `FoundationModel` + `FoundationView`; `DesignSystemGallery` (`#if DEBUG`) |
| `JitBench` | `spawn-latency`, `discovery` micro-benchmarks → JSON |
| App `Jit` | `JitApp` (one `Window` + debug gallery window, menus), `AppDelegate` (launch probe, quit cleanup), `DebugLaunchActions` (debug only) |
| `JitAppTests` | model + engine against real repositories |

## Data flow (Phase 0)

1. The app creates `GitEngine()` at launch — no I/O.
2. ⌘O / drop / `-JitOpen` → `FoundationModel.open(url)` cancels any running discovery and starts a
   `Task` on the main actor; after 150 ms without a result it shows the spinner.
3. `GitEngine.gitInfo()` locates Git by file existence (Homebrew, then Apple's real Git binary inside the
   selected developer directory or the Command Line Tools — never the `/usr/bin/git` shim), probes
   `git --version` once (one shared probe for concurrent callers), checks `GitVersion.minimum` (2.39)
   and caches the result; if the cached binary disappears, the next command re-locates once.
4. `RepositoryDiscovery` runs `rev-parse` (layout), `rev-parse --show-toplevel` (work trees only),
   `symbolic-ref -q HEAD` and `rev-parse -q --verify HEAD^{commit}`; stderr (C locale) is classified
   into typed errors.
5. The model publishes `.loaded(info, git)` or `.failed(url, error)`; the view animates the change.

## Process model (ADR-0005)

- `ProcessRunner.run(_:)` is `@concurrent`; it spawns with `posix_spawn` (argv array,
  `posix_spawn_file_actions_addchdir`, stdin `/dev/null`, `POSIX_SPAWN_SETSID` + `CLOEXEC_DEFAULT`,
  default signals), environment from an allowlist, non-interactive Git variables last.
- One serial `DispatchQueue` per command owns: two read sources (stdout capped, stderr last 64 KiB),
  a process-exit source (+ registration re-check and a 1 ms retry for the `NOTE_EXIT`-before-reapable
  race), and one-shot timers (timeout, kill grace, pipe drain). The caller's task waits on a checked
  continuation — no thread is held.
- Cancellation = Swift task cancellation → `SIGTERM` to the group, `SIGKILL` after 2 s. After the
  leader is reaped, the group is signalled only while it still has members (no recycled pgid). On app
  quit, `ProcessRunner.terminateAllRunning()` sends `SIGTERM` to every live group (Phase 0 runs only
  read commands; write operations must delay termination — Phase 3/4).
- Nothing runs when idle: no threads, timers, sources or child processes exist between commands.

## Glass vs content

System components provide all glass in Phase 0 (window toolbar, `NavigationSplitView` sidebar,
`.glass`/`.glassProminent` buttons, popovers, sheets). Custom glass exists only in the gallery, through
`DesignSystem`'s `jitGlass(in:)`. Content is opaque `surface.*` tokens and runs under the toolbar with the
soft scroll-edge effect. Rules: `docs/design-system.md`.

## Concurrency rules

- Swift 6 language mode, complete strict concurrency, typed throws (`throws(GitCoreError)`).
- View models are `@MainActor @Observable`; they call `GitEngine` from `Task {}` and never block.
- Debug builds assert `dispatchPrecondition(.notOnQueue(.main))` on every spawn path.
