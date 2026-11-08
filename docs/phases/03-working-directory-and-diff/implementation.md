# Phase 3 — Working Directory & Diff: Implementation Plan

Design: [`design.md`](design.md). Requirements: §4.5, §6, §7, §9.1 Files, §14, §16, §18.2, §19.

Ordering principle: the **safety core** (byte-exact diff model → patch builder → check/apply/verify →
tests) is built and proven in `GitCore` (`swift test`) before any line-level UI exists. UI for line actions is only
connected once the test matrix is green.

## 1. Preconditions

From Phase 2 `progress.md` (exit gate passed or carry-overs accepted):
- [ ] Graph, commit inspector with changed-file list, compare lists, WIP row working.
- [ ] `GitTestKit` topology builder; benchmark fixtures; signposts in place.
- [ ] `RepositoryHandle` actor with generation counter + `invalidate(kinds)`; Task cancellation →
      `killpg` in `ProcessRunner`; bounded progress stream.
- [ ] Phase 1: identity-only profiles with an active-profile selection and switcher; FSEvents
      watcher delivering worktree/index change classes; session state persistence.
- [ ] Status porcelain v2 parser exists (basic).
- [ ] Sanitized Git environment (`GIT_TERMINAL_PROMPT=0`, non-interactive `GIT_EDITOR`) in `ProcessRunner`.

If any is missing, implement it as `P3.0` and record it in `progress.md`.

## 2. Milestones

### P3.1 Full status model & working-directory panel (file level)
- [ ] Extend status parser: renames/copies (score, source), type changes, submodule sub-states,
      conflict entries (`u` lines) with stage modes, untracked (`?`), partially staged detection.
- [ ] Lazy `numstat` for visible paths (staged and unstaged).
- [ ] `RepositoryHandle` FIFO write gate (reentrancy-safe across `await`) + `RepoRevision` (ADR-0027);
      busy state / pending queue surfaced through `RepositorySession`.
- [ ] File-level `stage(_:)` / `unstage(_:)` (incl. new files, deletions, renames, unborn HEAD).
- [ ] `WorkingDirectoryViewController` (flat/tree, filter, sort, sections, counts, badges, drag
      between sections, context menu, Open in Editor, Reveal in Finder, Copy Path).
- [ ] Clean / loading / error / huge states; index.lock error mapping.
- [ ] Glass header and composer action bar per ADR-0006; rows opaque; Reduce Transparency checked.
Files: `GitCore/Status/*`, `GitCore/Stage.swift`, `GitCore/Repository/WriteGate.swift`, `Features/WorkingDirectory/*`.
Tests: `statusRenameStaged`, `statusPartiallyStaged`, `statusConflictEntries`,
`statusSubmoduleModified`, `statusUnicodeAndNewlinePaths`, `statusUntrackedNormalMode`,
`stagePathsNewDeletedRenamed`, `unstagePathsOnUnbornHead`, `writeGateSerializesAcrossAwaits`
(two mutations with injected suspension points never interleave), `staleReadResultsDiscarded`;
UI `StageAndUnstageFileByDrag`.
Done when: real repo workflows work; screenshots (clean, normal, conflicts present) light/dark.

### P3.2 File-level discard with recovery (ADR-0025)
- [ ] `RecoveryStore` (location, permissions, meta.json, launch-time pruning).
- [ ] `discard(_:)` with token validation; tracked → recovery copy then `git restore --worktree`;
      untracked → move to Trash (`Services`) after token check.
- [ ] Discard confirmation sheet (design §3.2) with preview; "Recently Discarded" menu.
Tests: `discardTrackedKeepsStagedChanges`, `discardWritesRecoveryCopyFirst`,
`discardUntrackedMovesToTrash`, `discardStaleTokenRefused`, `discardUnrelatedFilesByteIdentical`.
Done when: tests pass; sheet screenshots both themes.

### P3.3 Byte-exact diff engine (ADR-0026)
- [ ] `DiffInvocation` canonical argv for all `DiffTarget`s; empty-tree base for unborn HEAD;
      synthesized new-file patch for untracked.
- [ ] `PatchParser` on bytes: headers (rename/copy/mode/new/deleted/binary/submodule), C-quoted paths,
      hunks, lines with EOL kind, no-newline markers; stable `HunkID`/`LineID`; flat columnar
      records over one byte buffer (no class or `String` per line).
- [ ] `DiffDocument` (immutable, `Sendable`) with unified/split/full-file row tables, context
      expansion (new layout table over the shared buffer), search.
- [ ] `SnapshotToken` capture (index entry, worktree git-blob SHA-1, size/mtime, HEAD, revision).
Files: `GitCore/Diff/{DiffInvocation,PatchParser,DiffDocument,SnapshotToken}.swift`.
Tests: parser golden tests over real `git diff` output for: CRLF, mixed EOL, no trailing newline
(old/new/both), rename with edits, copy, mode change, symlink, binary, submodule, empty file, Unicode
paths, paths with spaces/quotes/newlines/leading dash; `roundtripParseSerializeIdenticalBytes`
(parse → re-emit → byte-equal to Git output); `splitLayoutAlignment`; `fullFileRowsMatchPostimage`;
`diffDocumentMemory50kLines` (bytes/line recorded).
Done when: round-trip property holds for every fixture.

### P3.4 Patch builder & selection apply (ADR-0013) — safety core, no UI yet
- [ ] Selection → patch per the table in design §4.4 for Stage / Unstage / Discard / KeepOnly.
- [ ] Independent expected-result model (apply selection to pre-image in memory).
- [ ] Check (`git apply --check`) → recovery copy (discard) → apply → verify → rollback paths.
- [ ] New-file / deleted-file / rename cases; unsupported-case detection with reason codes
      (`Binary`, `Symlink`, `Submodule`, `TypeChange`, `WhitespaceIgnored`, `FilterConversion`,
      `AmbiguousEol`, `Truncated`).
- [ ] Private temp-dir patch files (`0600`), cleanup.
Files: `GitCore/Patch/PatchBuilder.swift`, `GitCore/Patch/SelectionApplier.swift`.
Tests — integration matrix (§7.4), each asserting target content == expected **and** every other line,
file and index entry byte-identical:
`stageSingleAddedLine`, `stageSingleDeletedLine`, `stageMixedLinesOneHunk`,
`stageLinesAcrossAdjacentHunks`, `stageOnPartiallyStagedFile`, `unstageSingleLine`,
`unstageLinesAcrossHunks`, `discardSingleLine`, `keepOnlySelectedLines`,
`stageLinesOfUntrackedFile`, `stagePartialDeletionOfDeletedFile`, `stageFullDeletion`,
`unstageAllLinesOfNewFile`, `crlfStageAndDiscard`, `mixedEolFile`,
`noTrailingNewline` (parameterized: added/removed/both), `unicodePath`, `pathWithSpacesQuotesLeadingDash`,
`modeChangeWithContent`, `symlinkRefused`, `binaryRefused`, `submoduleRefused`,
`renameStagedUnstageLines`, `autocrlfTrueMatrix`, `eolAttributeMatrix`, `filterAttributeRefused`,
`concurrentModificationDetectedBeforeApply` (token), `concurrentModificationDuringApplyRollsBack`
(inject a write between check and apply via test hook), `indexLockPresentRefused`,
`ignoreWhitespaceDiffRefused`.
Property tests (seeded `SplitMix64`-style generator in `GitTestKit`, no third-party dependency;
`JIT_PROPERTY_CASES` env: ≥ 2,000 cases in CI, 50,000 locally before exit; failing seed printed and
re-runnable via `JIT_PROPERTY_SEED`): random file content
(LF/CRLF/mixed, optional final newline, Unicode), random edits, random partial staging of some lines
first, random selection → for each operation assert result == model and unrelated bytes untouched;
plus `stageThenUnstageSameSelectionRestoresIndex`, `discardNeverTouchesIndex`.
Done when: matrix + property tests pass; ADR-0013 records the allow/refuse table from spike S3.

### P3.5 Renderer spike & decision (ADR-0011)
- [ ] Prototype both candidates on: 2k-line diff, 50k-line diff, side-by-side alignment, line selection,
      text copy, VoiceOver basics.
- [ ] Measure (release, reference Mac): open-to-first-paint, scroll hitches, memory.
- [ ] Write ADR-0011; delete the losing prototype.
Done when: ADR merged with numbers.

### P3.6 Diff viewer (read paths)
- [ ] `CodeLinesView` (reusable) + `DiffViewController`: gutters, line numbers, change bars,
      backgrounds, hunk headers, collapsed context with expansion, unified/split/full-file layouts,
      tabs width, whitespace visualization, long lines, soft-wrap toggle, binary/empty/large/stale states.
- [ ] Diff targets: unstaged, staged, commit (from Phase 2 inspector — now enables opening diffs),
      commit↔commit, commit↔worktree.
- [ ] Search (⌘F/⌘G), next/prev change (⌥↓/⌥↑), go to line (⌘L).
- [ ] Glass chrome (ADR-0006): layout switcher, change navigator and find bar as floating glass
      capsules in one container over the opaque body; body scrolls under them with the system
      scroll-edge effect; Reduce Transparency fallback; no glass per row.
- [ ] Focused Diff mode with 200 ms transition; minimum width handling for split.
- [ ] DesignSystem `diff.*` tokens per theme; contrast check script.
Tests: `DiffRowLayoutTests` (split filler rows), `CollapsedContextTests`, snapshot
`diff_{unified,split,fullfile}_{light,dark}`, `diff_binary_state`, `diff_large_truncated`,
`diff_no_newline_marker`; UI `NavigateChangesAndSearch`.
Done when: screenshots reviewed and refined in both themes; perf targets in §4 met or honestly reported.

### P3.7 Syntax highlighting & word diff (ADR-0012, ADR-0029)
- [ ] Spike S2: tree-sitter C runtime via SwiftPM C target (or SwiftTreeSitter — record dependency
      weight) vs hand-written Swift lexers — binary size, speed, quality → ADR-0012 and final language set.
- [ ] `HighlightCache` actor: off-main, visible range + margin, lazy as the user scrolls, compact span
      records; `syntax.*` tokens per theme.
- [ ] Word-level diff for paired runs with limits; toggle.
Tests: `highlightSpansUTF16OffsetsWithEmoji`, `highlightLimitsFallbackPlain`,
`highlightCancelOnDocumentClose`, `wordDiffPairsAndLimits`; snapshot `diff_highlighted_{light,dark}`.
Done when: highlighting never blocks first paint; no layout shift when spans arrive.

### P3.8 Line / hunk / file actions in the UI
- [ ] Line selection model (click/drag/⇧/⌘, keyboard), hunk header actions that morph with selection,
      floating glass selection-action capsule.
- [ ] Wire Stage/Unstage/Discard/Keep Only to `RepositoryHandle.apply(_:)` (write gate); disabled
      states with reason help tags for every unsupported reason code.
- [ ] Discard/keep-only confirmation sheet with exact preview of lost lines.
- [ ] Stale handling: reload + clear selection + explanation; busy state while writer runs.
- [ ] Success feedback (row move, count tick), Reduce Motion.
Tests: UI `Scenario_C_PartialStaging` (end-to-end §24 C on a real temp repo, asserting file contents via
Git afterwards), `LineSelectionModelTests`, `ActionAvailabilityTests` (each reason code → disabled + text).
Done when: Scenario C passes as a UI test and manually; screenshots of selection states.

### P3.9 Blame
- [ ] `blame` as a bounded `AsyncThrowingStream` (`--incremental`), options `-w`, `-M`, revision;
      respects `blame.ignoreRevsFile`.
- [ ] `BlameViewController` on `CodeLinesView` with grouped gutter, age ramp, hover, click → graph.
Tests: `blameIncrementalParsesAllLines`, `blameCancel`, `blameIgnoreRevsFileRespected`,
snapshot `blame_{light,dark}`.
Done when: blame of a 5k-line file starts showing lines < 200 ms.

### P3.10 Commit composer (ADR-0014, ADR-0028)
- [ ] Composer UI (identity line, summary/description, counters, amend toggle with pushed-commit
      warning and reset-author option, disabled reasons, no-profile CTA, hook output disclosure,
      draft persistence, ⌘↩); glass action bar with prominent Commit button; fields on opaque surfaces.
- [ ] `RepositoryHandle.commit` in `GitCore`: `-F -` stdin, env identity snapshot, amend/reset-author,
      explicit no-verify, Task cancellation kills the process group, hook output streaming.
- [ ] After commit: status + graph refresh (new commit selected), fields cleared.
Tests: `commitUsesProfileIdentityEnv`, `commitDoesNotModifyAnyConfig`
(hash `~/.gitconfig` stand-in via `GIT_CONFIG_GLOBAL` temp file + repo `.git/config` before/after),
`commitRespectsRepoConfigButProfileOverridesIdentity`, `amendKeepsAuthorSetsCommitter`,
`amendResetAuthor`, `amendMessageOnly`, `commitOnUnbornBranch`, `commitHookFailureReportsOutput`,
`commitNoVerifyOnlyWhenRequested`, `commitCancelKillsHook`, `profileSwitchDuringCommitUsesSnapshot`,
`commitBlockedWithConflicts`; UI `CommitWithShortcut`.
Done when: Scenario C ends with a commit authored by the active profile; global config untouched.

### P3.11 Performance, memory & accessibility verification
- [ ] Release-build measurements (§4 table) incl. memory after opening/closing 200 diffs (no growth).
- [ ] Inactive tab releases diff buffers (verified with Allocations).
- [ ] VoiceOver pass on file list, diff rows, hunk rotor, composer.
- [ ] Glass check: Reduce Transparency + Increase Contrast screenshots; no GPU cost while idle with a
      diff open (Instruments, no continuous compositing).
- [ ] Idle check after a commit: CPU ≈ 0, no lingering processes/animations.
- [ ] Finalize ADRs 0011–0014, 0025–0029.
Done when: numbers recorded honestly in `progress.md` and `docs/performance.md`.

## 3. Test plan summary

| Layer | What | Where |
|---|---|---|
| `GitCore` unit (`swift test`) | status parser, patch parser, patch builder table, token, word diff, write gate | `JitKit/Tests/GitCoreTests` |
| Golden | `git diff` outputs → parsed model → re-emitted bytes | `JitKit/Tests/GitCoreTests/DiffGolden` + `Resources/diff/` |
| Integration (real temp repos) | full §7.4 matrix; commit/identity; blame; discard/recovery | `JitKit/Tests/GitCoreTests/{Apply,Commit,Blame,Discard}` |
| Property (seeded generator) | random edits × random selections × operations; unrelated bytes untouched | `JitKit/Tests/GitCoreTests/Apply/ApplyPropertyTests.swift` |
| Feature unit | selection model, action availability, layout rows | `JitKit/Tests/*` |
| Snapshot | WD panel, diff layouts, highlighting, blame, composer, sheets × themes | `JitKit/Tests/Snapshots` |
| UI | Scenario C end-to-end, stage by drag, commit ⌘↩, diff navigation | `macos/UITests` |

Every destructive or partial test asserts: target equals expected; all other worktree files, all other
index entries, and untouched lines of the target are byte-identical (§7.5, §18.2).

## 4. Performance checks (release build; record hardware, macOS, Git, repo)

| Metric | Target | Method |
|---|---|---|
| Diff open → first paint (2k-line file) | < 50 ms | signpost |
| Diff scroll (50k lines) | 60 FPS, 0 hitches > 1 frame / 10 s | Instruments Animation Hitches |
| Diff memory (50k lines) | < 30 MB | Allocations |
| Memory after 200 diff open/close cycles | no growth (± 2 MB) | `footprint` before/after |
| Status refresh (1k changed files) | < 100 ms | signpost |
| Stage lines (normal file) end-to-end | < 150 ms incl. verify | signpost |
| Blame first lines (5k-line file) | < 200 ms | signpost |
| Idle CPU after commit | 0.0–0.2 % | `top -l`, `powermetrics` |

## 5. Docs to update

- `docs/architecture.md` — status/diff/patch/apply/commit pipeline, write gate, `GitCore` diff API.
- `docs/design-system.md` — `diff.*`, `syntax.*`, `status.*` tokens per theme; renderer metrics; glass
  capsule placement over diff content.
- `docs/security.md` — hooks policy, no textconv/ext-diff, temp patch files, recovery store, identity env.
- `docs/performance.md` — Phase 3 results.
- `docs/adr/0011–0014, 0025–0029`.
- `CLAUDE.md` — commands for property tests (`JIT_PROPERTY_CASES`, `JIT_PROPERTY_SEED`), golden updates.

## 6. Exit checklist

- [ ] Scenario C (§24) passes as an automated UI test and manually.
- [ ] Full §7.4 integration matrix + property tests pass (50k local cases recorded in `progress.md`).
- [ ] Every unsupported granular case is disabled with a clear explanation (no risky workaround).
- [ ] Discards: confirmation explains change/loss/recoverability; recovery copies verified.
- [ ] Commit identity from the profile snapshot; no config file modified (test-proven).
- [ ] Diff viewer reviewed in light/dark, unified/split/full-file; screenshots committed.
- [ ] No WebView/Monaco/CodeMirror; highlighting lazy; no main-thread blocking (Hangs instrument clean).
- [ ] No glass on diff lines, file rows or scrolling content; one serialization point (write gate) only.
- [ ] Roadmap §9 phase exit gate satisfied.
