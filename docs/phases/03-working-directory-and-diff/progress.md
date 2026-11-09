# Phase 03 — Working directory & diff: progress report

Status: **in progress** (P3.0–P3.7 complete; P3.8 next)
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
- **P3.1 (panel)** — `Features/WorkingDirectory/`: the inspector shows the working-directory panel while the
  WIP row is selected (replaces the Phase 2 path list). Header in a `safeAreaBar` (system scroll-edge effect):
  branch, `N staged · N unstaged · N untracked`, filter (⌥⌘F, fuzzy on path), List/Tree, sort (Path, Name,
  Status, Size of Change). Sections Conflicts (only when present, not stageable, tooltip), Staged (Unstage
  All), Unstaged (Stage All; untracked marked `U`). Rows: coloured status letter, half-filled glyph for
  partially staged files (listed in both sections), file-type symbol, name + dimmed directory, `old → new`
  for renames, `+x`/`−x`, symlink and submodule badges, `+a −d` from lazy numstat, hover Stage/Unstage.
  Native `List` (virtualized, multi-selection); Space toggles stage/unstage of the selection; drag between
  Staged and Unstaged (selection-aware, drop highlight); context menu Stage/Unstage, Open in Editor (⇧⌘O),
  Reveal in Finder, Copy Path, Copy Relative Path, Show File History; tree folders collapse and their menu
  acts on all children. Clean state (check glyph, "Working tree clean", last commit subject), 2pt hairline
  after 150 ms, inline error banner with Retry (index.lock message; lock files never removed). Rows are
  rebuilt off the main actor; the model follows `session.status` through Observation (no polling).
  GitCore: `RepositoryHandle.lineStats(staged:paths:)` (`git --literal-pathspecs diff [--cached -M]
  --numstat -z`, read-only, chunked argv). ADR-0027 written.
  Evidence: `LineStatsTests` (5), `WorkingDirectoryTests` (11, including
  `stageAndUnstageByDragMoveRowsBetweenSections` driving the drag/drop path through a real session,
  `lockedIndexShowsBannerAndRetryWorks`, `spaceTogglesAndStatsLoadLazily`); screenshots
  `screenshots/working-directory-{normal,conflicts}-{light,dark}.png`.
- **P3.2 File-level discard with recovery** (ADR-0025) — GitCore `discardToken(for:)` (index record +
  working-tree fingerprint), `discardPreview(for:)` (first 20 lost/restored lines, counts, binary),
  `discard(_:hooks:)` inside the write gate: re-validate every token, recovery copy first, untracked to the
  Trash, then `git restore --worktree`; staged changes kept. Services `RecoveryStore` (0700/0600, meta.json,
  7 days / 500 MB pruning at launch) and `RepositorySession.discard`. Panel: "Discard Changes…" for unstaged
  rows and folders (not submodules or conflicts), confirmation sheet per design §3.2 (title, repo · branch,
  what changes / is lost / how to recover, line preview or file list; Cancel default, red Discard without a
  shortcut), stale-token banner without Retry. Repository ▸ Recently Discarded (reveal copy, Show Recovery
  Folder). Debug arg `-JitDiscardSheet <path>` opens the sheet for screenshots.
  Evidence: `DiscardTests` (7), `RecoveryStoreTests` (3), `WorkingDirectoryTests` discard flow (3);
  screenshots `screenshots/discard-sheet-{light,dark}.png`.
- **P3.3 Byte-exact diff engine** (ADR-0026) — `GitCore/Diff/`: `DiffTarget` (unstaged, staged incl.
  rename source, commit vs first parent / empty tree, commit range, commit → worktree), `DiffOptions`,
  `DiffInvocation` (canonical argv), `PatchParser` (bytes in, 16-byte `LineRecord`s, C-unquoted paths,
  extended headers, binary/submodule/symlink/mode flags, CRLF and no-newline per line), `PatchStorage.serialize`,
  `DiffDocument` (immutable, `Sendable`; packed unified/split/full-file row tables, context gaps and
  `expandingContext`, `search`, `LineID`/`HunkID`, `fileBytes(ofLine:)`), `SnapshotToken` and
  `RepositoryHandle.openDiff` (token before/after, synthesized untracked patch). No UI yet (diff viewer
  follows the renderer decision in P3.5).
  Evidence: `DiffEngineTests` (13 tests, 23 cases with parameters); round trip holds for every fixture;
  `diffDocumentMemory50kLines`: 100,000 lines → 51.8 B/line in total, 28.0 B/line beyond Git's output,
  0.27 s read + parse + layout (debug build).
- **P3.4 Patch builder & selection apply** (ADR-0013) — `GitCore/Patch/PatchBuilder.swift` (pure: selection
  table, own headers, recomputed hunk positions, ambiguous-final-newline detection, independent expected
  result by splicing the target's current bytes, reason codes) and `SelectionApplier.swift`
  (`RepositoryHandle.apply`: token → filter check → patch → private `0600` file → `git apply --check` →
  recovery copy → apply → verify → index rollback via `update-index --index-info`). New `GitCoreError`
  cases `refused`, `verificationFailed`. `RepositorySession.apply/openDiff`. `GitTestKit.SplitMix64`.
  Evidence: `ApplyTests` (28 incl. parameters — the §7.4 matrix; `renameStagedUnstageLines` is a refusal in
  V1), mutation check (a broken builder fails 6 of them), `ApplyPropertyTests` (150 cases by default,
  2,000 with `CI`; seed printed).
- **P3.5 Renderer spike & decision** (ADR-0011) — `CodeLinesView` (virtualized fixed-row renderer, `CTLine`
  cache, one or two columns, gutters, change bars, search highlights, row accessibility) and
  `DiffRowsSource` built; TextKit 2 prototype measured in `JitBench renderer-spike` and then removed.
  Release numbers (M5 Pro): CodeLinesView 2,401 rows first paint 5.7 ms (28.2 ms cold), 60,001 rows 8.0 ms,
  0/400 frames over 16.7 ms, max 1.75 ms; TextKit 2 52.7 ms / 910.7 ms first paint, 18–19/400 slow frames,
  +102 MB at 60k rows.
- **P3.6 Diff viewer** — `Features/DiffViewer/`: `DiffViewModel` (targets, layouts persisted, loading with
  120 ms spinner, reload on status change keeping expansion when bytes are equal, binary / mode-only / empty /
  too-large (64 MB) / failed states, gaps, change navigation, go to line, search with case option),
  `DiffViewController` (opaque `CodeLinesView` body, floating glass chrome in one container with full and
  compact forms via `ViewThatFits`: title, Unified / Side by Side / Full File, change navigator, find
  capsule, options menu (show/ignore whitespace, go to line), Focus Diff). Opens below the file list in the
  inspector (working directory: unstaged / staged incl. rename source; commit, compare (direct or since
  merge base) and commit → working tree from the Phase 2 file lists). Focused Diff covers the graph pane
  under the toolbar with a 200 ms fade (instant with Reduce Motion), Esc returns. Menus: Find ▸ Go to Line…
  (⌘L), Find Next/Previous (⌘G/⇧⌘G) reach the diff through the responder chain, View ▸ Focus Diff (⌥⌘↩),
  Next/Previous Change (⌥↓/⌥↑). Debug args `-JitOpenDiff <path>`, `-JitFocusDiff YES`, `-diffLayout`.
  Evidence: `DiffViewerTests` (split filler rows, collapsed context expansion, change navigation + search +
  go to line, renderer geometry/whitespace), contrast test for gutter/marks on diff backgrounds; screenshots
  `diff-{unified,split,fullfile}-{light,dark}.png` (focused), `diff-unified-inspector-{light,dark}.png`,
  `diff-no-newline-light.png`, `diff-binary-dark.png`.
- **P3.7 Syntax highlighting & word diff** (ADR-0012, ADR-0029) — hand-written lexers by language family,
  off-main highlighting with limits and cancellation, `syntax.*` tokens (AA on canvas and diff backgrounds,
  all variants), word diff via own Myers on tokens for paired lines; options menu toggles.
  Evidence: `HighlightTests` (8); screenshots `diff-highlighted-{light,dark}.png`. Tree-sitter was not
  prototyped (recorded in ADR-0012).

## Verified
- Tests: `scripts/build/test-core.sh` — **335 passed** (43 + 227 + 52 + 13 across the four test targets);
  skipped: none. Xcode app tests not run yet this phase. Lint clean (`scripts/build/lint.sh`).
- Real workflow: debug app on a clone with an upstream (1 ahead), a second branch and staged/unstaged/untracked
  changes — breadcrumb, `3 changes`, Terminal and search render in both themes (screenshots above).
  Not yet exercised by pointer: branch popover, overflow at a narrow width, Show Labels toggle.

## Decisions
- ADR-0027: FIFO write gate inside `RepositoryHandle`; reads never take it; every finished mutation bumps
  `RepoRevision` and invalidates status.

## Deviations from plan
- The command bar lives in the graph pane (where the Phase 2 bar was), constrained to the pane's safe area,
  rather than spanning graph + inspector: the macOS 26 inspector floats over the pane's trailing edge, so the
  bar already clears it. Spec to be updated when the working-directory panel lands.
- Branch popover has no "Recent" section yet: Jit records no branch-switch history before Phase 4.
- ⌃F6 focus for the bar is not wired yet.
- The panel is a SwiftUI `List` (`WorkingDirectoryView` + `WorkingDirectoryModel`), not an
  `NSViewController`: the inspector is SwiftUI, and `List` gives AppKit table virtualization, selection and
  keyboard handling. Rows hold path `String`s (one per changed file) because filter, sort and tree need them;
  status parsing itself stays byte-level (ADR-0005).
- Drop highlight uses `accent.muted`; there is no `fill.dropTarget` token yet.
- The composer action bar arrives with the composer in P3.10 (no placeholder now).
- No XCUITest target exists in the project, so `StageAndUnstageFileByDrag` is a model-level test with a
  real session (`stageAndUnstageByDragMoveRowsBetweenSections`); a pointer drag in the running app has not
  been exercised.

## Known issues / carry-overs
- `LiveProcessGroups.killAll` sends SIGTERM to every live group at app quit, write commands included; Phase 3
  writes (stage/unstage) are short, but quitting must wait for gated writes before P3.4 lands.
- Narrow-window overflow screenshot and Reduce Transparency screenshots (bar and panel) still to capture.
- Clean-state screenshot not captured: a clean tree has no WIP row, so the panel only shows its clean state
  briefly when the tree becomes clean while selected (verified by `cleanTreeLoadsLastCommitSubject`).
- Not yet exercised by pointer: drag between sections, context menu, Space, tree collapse, ⇧⌘O / ⌥⌘F.
- Untracked directories (`scratch/`) are staged as a whole; on-demand expansion is not built.
- Paths that are not valid UTF-8 are listed with replacement characters and cannot be staged from the panel.
- Discard into the real Trash is not exercised by tests (it would fill the user's Trash); tests inject a
  trash hook, and `RecoveryStore.discardHooks` calls `FileManager.trashItem`.
- Not yet exercised by pointer: Discard Changes… menu, confirming in the sheet, Recently Discarded menu.
- Diff viewer: no soft wrap (fixed rows, ADR-0011); search works in unified and full-file layouts only;
  renamed files in commit diffs opened with a path filter show as add + delete pair-less (the path filter
  hides the rename source); the commit-inspector diff path was exercised in tests only, not by pointer.
- Copy detection (`-C`) is not part of the canonical command; the copy header is covered by parsing Git's
  own `-C` output.
- Next: P3.4 patch builder and selection apply (safety core).
