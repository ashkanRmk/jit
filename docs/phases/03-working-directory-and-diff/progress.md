# Phase 03 — Working directory & diff: progress report

Status: **in progress** (P3.0 complete; P3.1 GitCore part complete, working-directory panel next)
Branch / PR: `phase/03-working-directory-and-diff` (from `main` at `019ea8d`), no PR yet
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro), macOS 27.2, Xcode 27.2, Swift 6.4.2, Git 2.54.0 (Homebrew)

## Preconditions (implementation.md §1)
Verified against the code: graph, inspector with changed files, compare, WIP row; `GitTestKit`; `RepositoryHandle`
generation + `invalidate`; cancellation → `killpg`; identity-only profiles with an active profile; FSEvents
watcher with worktree/index kinds; porcelain v2 status parser (renames, `u` records, submodule field already
parsed); sanitized non-interactive Git environment. **Missing:** child stdin (needed for
`--pathspec-from-file=-` and, in P3.10, `commit -F -`) — added as part of P3.0 (`ProcessSpec.stdin`, written
with `DispatchIO`, `F_SETNOSIGPIPE` on the write end).

## Implemented
- **P3.0 Repository command bar** (`specs/P3.0-command-bar.md`) — replaces the Phase 2 graph bar: location
  breadcrumb (repo menu: Reveal in Finder, Copy Path; branch with `↑A ↓B`, detached `HEAD 1a2b3c4`, unborn
  `main — no commits`; branch popover with filter, Current/Local/Remote, selecting reveals the branch tip in the
  graph), `N changes` (selects the WIP row; hidden when clean; a partially staged file counts once), Terminal,
  then the unchanged scope menu and search. Labels drop first, then Terminal moves into a `⋯` menu
  (`CommandBarLayout.make`); View ▸ Command Bar ▸ Show Labels. Sync/branch/stash/undo are absent (Phases 4/8).
  Evidence: `CommandBarTests` (11), screenshots `screenshots/command-bar-{light,dark}.png`.
- **P3.1 (GitCore part)** — status model: `changedFiles` / `partiallyStaged` counts; typed views on
  `StatusEntries` (rename/copy + score, `ConflictKind` for all seven unmerged combinations, submodule
  sub-states, type changes, modes, staged/unstaged sides, raw path bytes). FIFO write gate (`WriteGate`,
  `RepositoryHandle.performExclusive`, ADR-0027) that serializes across suspension points, reports
  current/pending operations and drops cancelled waiters; monotonic `RepoRevision`. File-level `stage`
  (`git add --all`) and `unstage` (`restore --staged`; `rm --cached` on an unborn branch) with literal
  pathspecs fed NUL-separated on stdin; `index.lock` refused up front and mapped from Git's error.
  `RepositorySession.stage/unstage` with `pendingWrites` / `isBusy`.
  Evidence: `StageTests` (12: `stagePathsNewDeletedRenamed`, `stageKeepsUnrelatedIndexEntriesAndWorktreeBytes`,
  `stageTreatsPathsLiterally`, `stageDirectoryFromUntrackedNormalMode`, `unstageRestoresHeadVersionAndKeepsWorktree`,
  `unstageStagedRenameNeedsBothPaths`, `unstagePathsOnUnbornHead`, `stageThenUnstageRestoresIndex`,
  `indexLockPresentRefused`, `staleReadResultsDiscarded`, `writeGateSerializesAcrossAwaits`,
  `writeGateReportsPendingAndDropsCancelledWaiter`, `stageAndUnstageGoThroughTheGate`), `StatusModelTests` (5:
  rename staged, conflicts from a real merge, submodule modified, type change, Unicode/newline paths + untracked
  normal mode), `ProcessRunnerTests` stdin (3), `testStageAndUnstageRefreshStatusAndClearBusy`.

## Verified
- Tests: `scripts/build/test-core.sh` — **259 passed** (40 + 173 + 34 + 12 across the four test targets);
  skipped: none. Xcode app tests not run yet this phase. Lint clean (`scripts/build/lint.sh`).
- Real workflow: debug app on a clone with an upstream (1 ahead), a second branch and staged/unstaged/untracked
  changes — breadcrumb, `3 changes`, Terminal and search render in both themes (screenshots above).
  Not yet exercised by pointer: branch popover, overflow at a narrow width, Show Labels toggle.

## Decisions
- ADR-0027 (to be written with P3.1 completion): gate lives inside `RepositoryHandle`; reads never take it.

## Deviations from plan
- The command bar lives in the graph pane (where the Phase 2 bar was), constrained to the pane's safe area,
  rather than spanning graph + inspector: the macOS 26 inspector floats over the pane's trailing edge, so the
  bar already clears it. Spec to be updated when the working-directory panel lands.
- Branch popover has no "Recent" section yet: Jit records no branch-switch history before Phase 4.
- ⌃F6 focus for the bar is not wired yet.

## Known issues / carry-overs
- `LiveProcessGroups.killAll` sends SIGTERM to every live group at app quit, write commands included; Phase 3
  writes (stage/unstage) are short, but quitting must wait for gated writes before P3.4 lands.
- Narrow-window overflow screenshot and Reduce Transparency screenshot still to capture.
- Next: P3.1 UI (`WorkingDirectoryViewController`, sections, drag between sections, context menu), then P3.2.
