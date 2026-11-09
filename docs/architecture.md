# Architecture

Status: Phase 1. This describes what exists; planned parts are marked **(planned, Phase N)**.
Decisions: ADR-0002 (pure Swift), ADR-0003 (XcodeGen), ADR-0004 (package layout), ADR-0005 (process,
concurrency, memory), ADR-0006 (macOS 26+, Liquid Glass), ADR-0007 (state and persistence), ADR-0008
(file watching).

## Layers

```
Chrome (Liquid Glass): toolbar + glass tab strip, system sidebar, popovers, sheets  ┐ AppKit shell + SwiftUI
Content (opaque): new-tab page, workbench header/status, inspector; later graph, diff ┘ Features (@MainActor)
          │  @Observable models, async calls, value types
Services: AppModel's stores (session, recents, preferences, profiles), RepositorySession,
          │  RepositoryWatcher (FSEvents), JSON persistence — imports GitCore directly (no bridge)
GitCore (Foundation/Darwin only): GitEngine actor, RepositoryHandle actor (per repository), StatusParser,
          │  OperationStateDetector, GitLocator, ProcessRunner, RepositoryDiscovery
          │  posix_spawn, argv arrays
git CLI (installed; bundled from Phase 7)
```

## Targets (`macos/Packages/JitKit`, app in `macos/App`)

| Target | Contents today |
|---|---|
| `GitCore` | `GitVersion`, `GitLocator`, `ProcessEnvironment`, `ProcessRunner`, `GitEngine` (actor), `GitCommand`, `RepositoryDiscovery`/`RepositoryInfo`, `RepositoryHandle` (actor), `StatusParser`/`StatusSnapshot`/`StatusEntries`/`StatusSummary`/`BranchHeader`, `OperationStateDetector`, `InvalidationKind`, `GitIdentity`, `GitCoreError` + redaction; `ProcessStream` (on-demand stdout with backpressure); **Phase 2:** `ObjectID`/`ObjectFormat`/`StableHash`, `RefSnapshot`/`GitRef`/`RefParser`, `HistoryLoader` (actor) + `HistoryQuery`, `LogParser`, `CommitStore` (`CommitChunk`, `HistorySnapshot`, `CommitRow`, `EdgeSegment`), `LaneLayouter`, `HistorySearch`, `CommitDetails`/`ChangedFile`/compare, `HistoryInvalidation` |
| `GitTestKit` | `GitSandbox` (temp dir, isolated `HOME`/config, fixed identity/dates), `TestRepo`, `Topology` (fast-import DSL), `SyntheticHistory` (1k–100k fixtures), `RandomTopology` (seeded DAGs) |
| `Services` | `StoreLocation`, `JSONFile`, `DebouncedWriter`, `SessionStore`/`SessionState`/`JSONValue`, `RecentsStore`, `PreferencesStore`, `ProfileStore`/`GitProfile`/`ProfileSnapshot`/`ProfileValidation`, `RepositorySession` + `StatusDot`, `HistoryController` (per-tab history, pages, refs refresh), `RepositoryWatcher` + `FSEventClassifier`, `MemoryPressureMonitor` |
| `DesignSystem` | `GraphMetrics`/`GraphColorTable`/`GraphTypography`/`AvatarStyle` (Phase 2), color tokens, type, metrics (+ tab/profile/overlay metrics), motion, glass helpers (+ `GlassTabStrip`, `glassTab`), profile swatches, content styles |
| `Features` | `AppModel`, `TabModel`, `TabOrdering`, `LayoutState`; AppKit shell (`MainWindowController`, `WorkbenchController`, content container + drop target), tab strip, new-tab page, workbench views, **GitGraph** (`GraphViewController`, cells, `GraphRowCache`, `GraphBar`, `GraphBenchmark`), **BranchNavigator** (`NavigatorTreeBuilder`, outline), **CommitInspector** (`InspectorModel`, details/compare/WIP views), profile capsule/switcher/editor, `SettingsWindowController`, `MainMenu`, `RepositoryActions`; `DesignSystemGallery` (`#if DEBUG`) |
| `JitBench` | `spawn-latency`, `discovery`, `status-parse` → JSON; `make-history` (fixtures), `history-source` (loader timings) |
| App `Jit` | `AppDelegate` (`@main`, AppKit lifecycle, appearance, menus, settings, launch hooks), `LaunchProbe`, `Benchmarks` (env-gated tab-switch and open/close stress), `DebugLaunchActions` (debug only) |
| `JitAppTests` | `AppModel`, tab ordering, layout and menu validation against real repositories |

## State (ADR-0007)

- One main window. `AppModel` (`@MainActor @Observable`) owns the ordered `TabModel`s, the active tab, an
  in-memory reopen stack (10), and the stores. `TabModel` carries only what the tab strip shows (title,
  branch, status dot); a repository tab also owns a `RepositorySession`.
- `RepositorySession` (`Services`): lifecycle `unloaded → loading → active ⇄ inactive → suspended`,
  `closed`; separate observable `info`, `status`, `error`. It owns the `RepositoryHandle` and, while
  active, the watcher. Only the visible tab of a foreground window is active (`AppModel.setForeground`,
  driven by app activation, miniaturize and occlusion notifications). Memory pressure suspends inactive
  sessions and drops their cached controllers.
- The window controller keeps one content controller per loaded tab (instant switching): a hosted
  new-tab page or a `WorkbenchController` (`NSSplitViewController`: system sidebar, main, system inspector).

## Persistence (ADR-0007)

`~/Library/Application Support/Jit` (`0700`; `JIT_APP_SUPPORT` overrides): `session.json` (window frame,
layout widths, tabs with cached title/branch, per-tab collapse flags and an opaque `ui` blob, active tab),
`recents.json` (20, de-duplicated by resolved path), `profiles.json`. Versioned; unreadable or
unknown-version files are backed up and reset. Writes are atomic (`0600` temp + `fsync` + `rename`), off the
main actor, debounced by one cancellable one-shot task, flushed at quit. Preferences in `UserDefaults`.

## Data flow (Phase 1)

1. Launch: `applicationWillFinishLaunching` applies the appearance preference and builds the menu bar;
   `applicationDidFinishLaunching` reads the JSON files synchronously, restores tabs from cached titles
   (sessions `unloaded`), and shows the window. One main-queue turn later the window reports foreground
   and only the active tab's session loads.
2. Opening (⌘O, recents, drop, Finder, `JIT_OPEN`): `GitEngine.openRepository(at:)` discovers once and
   returns a `RepositoryHandle`; the resolved top level focuses an existing tab, replaces the active
   new-tab page, or becomes a new tab.
3. `RepositorySession` asks the handle for `status()`: one `git --no-optional-locks status
   --porcelain=v2 -z --branch` parsed byte-level, plus operation markers read from the git dir. The
   session publishes `status`; `AppModel` mirrors title/branch/dot into the `TabModel`, recents and the
   window title/subtitle.
4. While active, FSEvents batches are classified into invalidations → `handle.invalidate` → one coalesced
   refresh (ADR-0008). Hiding the tab or leaving the foreground stops the stream and cancels work; coming
   back revalidates once.

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

System components provide glass for the toolbar items, split-view sidebar, popovers, sheets and
`.glassProminent` buttons. The one custom glass surface is the tab strip: a SwiftUI `GlassEffectContainer`
(`DesignSystem.GlassTabStrip`) hosted in an **unbordered** toolbar item, so the toolbar adds no second
platter around it. Content (new-tab page, workbench main and inspector, drop overlay) is opaque
`surface.*` and runs under the toolbar with the soft scroll-edge effect. Rules: `docs/design-system.md`.

## Concurrency rules

- Swift 6 language mode, complete strict concurrency, typed throws (`throws(GitCoreError)`).
- View models are `@MainActor @Observable`; they call `GitCore` actors from `Task {}` and never block.
- `RepositoryHandle` is the single per-repository serialization point (mutations join it in Phase 3+).
- No timers anywhere in the app: debounced writes and the 150 ms loading placeholder are one-shot
  cancellable tasks; FSEvents latency provides event coalescing.
- Debug builds assert `dispatchPrecondition(.notOnQueue(.main))` on every spawn path.

## History (Phase 2: ADR-0009, 0010, 0021–0024)

```
FSEvents (refs/HEAD) ─► RepositorySession ─► HistoryController (main actor, @Observable)
                                              │  refs() ─► RefSnapshot          ─► navigator, labels
                                              │  HistoryLoader (actor) ── git log --topo-order -z (ProcessStream,
                                              │     LogParser ─► LaneLayouter ─► CommitStoreBuilder    backpressure)
                                              ▼
                                      HistorySnapshot (sealed CommitChunks, immutable, Sendable)
                                              ▼
                     GraphViewController ─ NSTableView ─ GraphRowCache (strings for visible rows only)
```
- One reader per visible history view; killed when the tab hides (rows kept), restarted with `--skip`.
- Pages: 300 first, then 2,000 when the visible range is within 500 rows of the end; appended with
  `insertRows`, no reload. Refs changes: labels in place or background reload + atomic swap (ADR-0024).
- Commit details/compare run on `RepositoryHandle` (LRU of 32 details); selecting another commit cancels
  the previous request (and its Git process).

## Working directory, diff and commit (Phase 3: ADR-0011–0014, 0025–0029)
```
RepositorySession ── status ─► WorkingDirectoryModel ─► WorkingDirectoryView (List; sections, drag, menu)
        │                                │ selection
        │ stage/unstage/discard/apply/commit (write gate)          ▼
        ▼                          DiffViewModel ── openDiff ─► DiffDocument (PatchStorage + packed rows)
RepositoryHandle ── WriteGate (FIFO, ADR-0027)                │                    │
   ├─ stage / unstage (pathspec on stdin)                     ▼                    ▼
   ├─ discard (token → recovery copy → Trash / restore)  DiffViewController ─ CodeLinesView (ADR-0011)
   ├─ apply(SelectionRequest): token → PatchBuilder → check →  ├─ Highlighter (off-main lexers, ADR-0012)
   │     recovery → apply → verify → rollback (ADR-0013)        └─ WordDiff (Myers, ADR-0029)
   ├─ commit (identity env, hooks as Git, ADR-0014/0028)  BlameModel ─ blame --incremental (pull stream)
   └─ openDiff / lineStats / blame (reads, never gated)   CommitComposerModel ─ CommitDrafts
```
- **One serialization point:** every mutation (`stage`, `unstage`, `discard`, `apply`, `commit`) runs in
  `RepositoryHandle.performExclusive`; reads never wait for it. Each finished mutation bumps `RepoRevision`
  and invalidates status; `RepositorySession.pendingWrites` drives busy states.
- **Byte-exact diffs (ADR-0026):** one canonical `git diff` argv; parsing keeps Git's bytes and 16-byte line
  records; single-file working-tree diffs are read with full context so expansion and full-file layout are
  table changes over the same buffer. A `SnapshotToken` (HEAD, index record, worktree fingerprint + blob id)
  is taken before and after the read.
- **Line actions (ADR-0013):** the pure `PatchBuilder` produces the patch and, independently, the expected
  target bytes; `SelectionApplier` refuses on a changed token, checks, keeps a recovery copy for discards,
  applies, verifies and rolls back.
- **Memory:** inactive tabs drop diff documents, rows, spans and blame text (targets kept, reloaded on
  return); strings exist only for visible rows.

## Workflows and conflicts (Phase 4: ADR-0015, 0030–0034)
```
UI (command bar, menus, graph/navigator menus, banner, resolver)
   └─ OperationsController (per tab): prepares sheets with a RepoStateToken, captures the profile snapshot on
      confirm, turns outcomes into the next sheet (not fast-forward, push rejected, blocked switch, conflicts)
         └─ RepositorySession.perform → OperationCenter (records, progress, cancel) → RepositoryHandle
               ├─ performExclusive (the Phase 3 FIFO write gate — the only writer)
               ├─ fetch / pull (fetch + uncancellable integrate) / push --porcelain / force-with-lease
               ├─ switch / branch / rename / delete / upstream; merge / rebase / cherry-pick / revert
               ├─ continue / skip / abort; conflicts / loadConflict / saveResolution / markResolved
               └─ stash list / push / apply / pop / drop / stash-and-switch
cloneRepository(_:engine:) — free function (no repository yet)
```
- **Execution:** `GitEnvironment.remoteCommand(ExecContext)` (non-interactive auth, protocol policy) and
  `integrationCommand` (identity via env: committer always, author for new commits). Phase 5 extends
  `AuthPlan` / `NetworkPlan`.
- **Staleness and confirmation:** `RepoStateToken` (HEAD, HEAD ref, refs digest, operation state) is validated
  inside the gate; destructive methods verify a `ConfirmationToken` minted by the sheet.
- **State detection:** `operationState()` reads the per-worktree git dir (merge, rebase-merge/apply, am,
  cherry-pick, revert, sequencer, bisect) after FSEvents `.operationState/.index/.head` and after operations.
- **Progress:** `ProgressSink` parses `--progress` stderr bytes (CR/LF), ≤ 10 Hz into `.bufferingNewest(1)`.
- **Conflicts:** stage blobs → `merge-file --zdiff3` → byte-range segments; the resolver renders panes from
  the same buffer with `CodeLinesView`; choices render back to bytes identical to Git's `--ours/--theirs/--union`.
- **Errors:** `GitErrorClassifier` (C-locale stderr) → `ClassifiedFailure` → `PresentableError` with recovery
  actions.

## Phase 5 — profiles, authentication and networking
- `ProfileStore` (v2) holds profiles, hosting accounts, self-managed instances and global network settings;
  `AccountsService` (lazy, no I/O at launch) builds the `ExecContext` an operation captures at enqueue:
  identity + `AuthPlan.profile(ProfileAccessProvider)` holding an immutable `ProfileSnapshot`.
- GitCore asks the provider right before spawning Git (`ExecContext.prepareAccess(for: urls)`) and receives a
  `RemoteAccess` (helper path, broker endpoint, SSH plan, per-origin CA/proxy) that `GitEnvironment` turns into
  `-c` options and environment; the returned lease tears the broker down after Git exits.
- `AccessResolver` is pure: URLs × snapshot → broker policy, SSH plan, scoped network, mismatch hints.
- Provider API clients (`GitHubProvider`, `GitLabProvider`) use per-instance ephemeral URLSessions with
  `ScopedTrustDelegate` and proxy dictionaries; OAuth refresh is single-flight and just in time.
- `jit-git-helper` (Foundation-only executable) is embedded at `Contents/Helpers/`; `TestRig` is dev-only.
