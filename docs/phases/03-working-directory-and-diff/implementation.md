# Phase 3 — Working Directory & Diff: Implementation Plan

Design: [`design.md`](design.md). Requirements: §4.5, §6, §7, §9.1 Files, §14, §16, §18.2, §19.

Ordering principle: the **safety core** (byte-exact diff model → patch builder → check/apply/verify →
tests) is built and proven in Rust before any line-level UI exists. UI for line actions is only
connected once the test matrix is green.

## 1. Preconditions

From Phase 2 `progress.md` (exit gate passed or carry-overs accepted):
- [ ] Graph, commit inspector with changed-file list, compare lists, WIP row working.
- [ ] `git-testkit` topology builder; benchmark fixtures; signposts in place.
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
- [ ] `RepoWriter` mutex + `RepoRevision` (ADR-0027); Swift `actor RepositoryWriter` with busy state.
- [ ] File-level `stage_paths` / `unstage_paths` (incl. new files, deletions, renames, unborn HEAD).
- [ ] `WorkingDirectoryViewController` (flat/tree, filter, sort, sections, counts, badges, drag
      between sections, context menu, Open in Editor, Reveal in Finder, Copy Path).
- [ ] Clean / loading / error / huge states; index.lock error mapping.
Files: `git-core/src/{status.rs,stage.rs,writer.rs}`, `Features/WorkingDirectory/*`.
Tests: `status_rename_staged`, `status_partially_staged`, `status_conflict_entries`,
`status_submodule_modified`, `status_unicode_and_newline_paths`, `status_untracked_normal_mode`,
`stage_paths_new_deleted_renamed`, `unstage_paths_on_unborn_head`, `writer_serializes_mutations`,
`stale_read_results_discarded` (Swift); UI `StageAndUnstageFileByDrag`.
Done when: real repo workflows work; screenshots (clean, normal, conflicts present) light/dark.

### P3.2 File-level discard with recovery (ADR-0025)
- [ ] `RecoveryStore` (location, permissions, meta.json, launch-time pruning).
- [ ] `discard_paths` with token validation; tracked → recovery copy then `git restore --worktree`;
      untracked → move to Trash (Swift side) after token check.
- [ ] Discard confirmation sheet (design §3.2) with preview; "Recently Discarded" menu.
Tests: `discard_tracked_keeps_staged_changes`, `discard_writes_recovery_copy_first`,
`discard_untracked_moves_to_trash`, `discard_stale_token_refused`, `discard_unrelated_files_byte_identical`.
Done when: tests pass; sheet screenshots both themes.

### P3.3 Byte-exact diff engine (ADR-0026)
- [ ] `DiffInvocation` canonical argv for all `DiffTarget`s; empty-tree base for unborn HEAD;
      synthesized new-file patch for untracked.
- [ ] `PatchParser` on bytes: headers (rename/copy/mode/new/deleted/binary/submodule), C-quoted paths,
      hunks, lines with EOL kind, no-newline markers; stable `HunkId`/`LineId`.
- [ ] `DiffDocument` with unified/split/full-file row tables, context expansion, search.
- [ ] `SnapshotToken` capture (index entry, worktree git-blob SHA-1, size/mtime, HEAD, revision).
Files: `git-core/src/diff/{invocation.rs,parser.rs,document.rs,token.rs}`, `git-ffi/src/diff.rs`.
Tests: parser golden tests over real `git diff` output for: CRLF, mixed EOL, no trailing newline
(old/new/both), rename with edits, copy, mode change, symlink, binary, submodule, empty file, Unicode
paths, paths with spaces/quotes/newlines/leading dash; `roundtrip_parse_serialize_identical_bytes`
(parse → re-emit → byte-equal to Git output); `split_layout_alignment`; `full_file_rows_match_postimage`.
Done when: round-trip property holds for every fixture.

### P3.4 Patch builder & selection apply (ADR-0013) — safety core, no UI yet
- [ ] Selection → patch per the table in design §4.4 for Stage / Unstage / Discard / KeepOnly.
- [ ] Independent expected-result model (apply selection to pre-image in memory).
- [ ] Check (`git apply --check`) → recovery copy (discard) → apply → verify → rollback paths.
- [ ] New-file / deleted-file / rename cases; unsupported-case detection with reason codes
      (`Binary`, `Symlink`, `Submodule`, `TypeChange`, `WhitespaceIgnored`, `FilterConversion`,
      `AmbiguousEol`, `Truncated`).
- [ ] Private temp-dir patch files (`0600`), cleanup.
Files: `git-core/src/patch_builder.rs`, `git-core/src/apply.rs`.
Tests — integration matrix (§7.4), each asserting target content == expected **and** every other line,
file and index entry byte-identical:
`stage_single_added_line`, `stage_single_deleted_line`, `stage_mixed_lines_one_hunk`,
`stage_lines_across_adjacent_hunks`, `stage_on_partially_staged_file`, `unstage_single_line`,
`unstage_lines_across_hunks`, `discard_single_line`, `keep_only_selected_lines`,
`stage_lines_of_untracked_file`, `stage_partial_deletion_of_deleted_file`, `stage_full_deletion`,
`unstage_all_lines_of_new_file`, `crlf_stage_and_discard`, `mixed_eol_file`,
`no_trailing_newline_{added,removed,both}`, `unicode_path`, `path_with_spaces_quotes_leading_dash`,
`mode_change_with_content`, `symlink_refused`, `binary_refused`, `submodule_refused`,
`rename_staged_unstage_lines`, `autocrlf_true_matrix`, `eol_attribute_matrix`, `filter_attribute_refused`,
`concurrent_modification_detected_before_apply` (token), `concurrent_modification_during_apply_rolls_back`
(inject a write between check and apply via test hook), `index_lock_present_refused`,
`ignore_whitespace_diff_refused`.
Property tests (proptest, ≥ 2,000 cases in CI, 50,000 locally before exit): random file content
(LF/CRLF/mixed, optional final newline, Unicode), random edits, random partial staging of some lines
first, random selection → for each operation assert result == model and unrelated bytes untouched;
plus `stage_then_unstage_same_selection_restores_index`, `discard_never_touches_index`.
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
- [ ] Focused Diff mode with 200 ms transition; minimum width handling for split.
- [ ] DesignSystem `diff.*` tokens per theme; contrast check script.
Tests: `DiffRowLayoutTests` (split filler rows), `CollapsedContextTests`, snapshot
`diff_{unified,split,fullfile}_{light,dark}`, `diff_binary_state`, `diff_large_truncated`,
`diff_no_newline_marker`; UI `NavigateChangesAndSearch`.
Done when: screenshots reviewed and refined in both themes; perf targets in §4 met or honestly reported.

### P3.7 Syntax highlighting & word diff (ADR-0012, ADR-0029)
- [ ] Spike S2 (grammar sizes, parse time) → final grammar set.
- [ ] Background parse of pre/post images; `highlights(range)` lazy spans; `syntax.*` tokens per theme.
- [ ] Word-level diff for paired runs with limits; toggle.
Tests: `highlight_spans_utf16_offsets_with_emoji`, `highlight_limits_fallback_plain`,
`highlight_cancel_on_document_close`, `wordiff_pairs_and_limits`; snapshot `diff_highlighted_{light,dark}`.
Done when: highlighting never blocks first paint; no layout shift when spans arrive.

### P3.8 Line / hunk / file actions in the UI
- [ ] Line selection model (click/drag/⇧/⌘, keyboard), hunk header actions that morph with selection.
- [ ] Wire Stage/Unstage/Discard/Keep Only to `apply_selection` through `RepositoryWriter`; disabled
      states with reason help tags for every unsupported reason code.
- [ ] Discard/keep-only confirmation sheet with exact preview of lost lines.
- [ ] Stale handling: reload + clear selection + explanation; busy state while writer runs.
- [ ] Success feedback (row move, count tick), Reduce Motion.
Tests: UI `Scenario_C_PartialStaging` (end-to-end §24 C on a real temp repo, asserting file contents via
Git afterwards), `LineSelectionModelTests`, `ActionAvailabilityTests` (each reason code → disabled + text).
Done when: Scenario C passes as a UI test and manually; screenshots of selection states.

### P3.9 Blame
- [ ] `blame` streaming (`--incremental`), options `-w`, `-M`, revision; respects `blame.ignoreRevsFile`.
- [ ] `BlameViewController` on `CodeLinesView` with grouped gutter, age ramp, hover, click → graph.
Tests: `blame_incremental_parses_all_lines`, `blame_cancel`, `blame_ignore_revs_file_respected`,
snapshot `blame_{light,dark}`.
Done when: blame of a 5k-line file starts showing lines < 200 ms.

### P3.10 Commit composer (ADR-0014, ADR-0028)
- [ ] Composer UI (identity line, summary/description, counters, amend toggle with pushed-commit
      warning and reset-author option, disabled reasons, no-profile CTA, hook output disclosure,
      draft persistence, ⌘↩).
- [ ] `commit` in Rust: `-F -` stdin, env identity snapshot, amend/reset-author, explicit no-verify,
      cancel kills process group, hook output streaming.
- [ ] After commit: status + graph refresh (new commit selected), fields cleared.
Tests: `commit_uses_profile_identity_env`, `commit_does_not_modify_any_config`
(hash `~/.gitconfig` stand-in via `GIT_CONFIG_GLOBAL` temp file + repo `.git/config` before/after),
`commit_respects_repo_config_but_profile_overrides_identity`, `amend_keeps_author_sets_committer`,
`amend_reset_author`, `amend_message_only`, `commit_on_unborn_branch`, `commit_hook_failure_reports_output`,
`commit_no_verify_only_when_requested`, `commit_cancel_kills_hook`, `profile_switch_during_commit_uses_snapshot`
(Swift), `commit_blocked_with_conflicts`; UI `CommitWithShortcut`.
Done when: Scenario C ends with a commit authored by the active profile; global config untouched.

### P3.11 Performance, memory & accessibility verification
- [ ] Release-build measurements (§4 table) incl. memory after opening/closing 200 diffs (no growth).
- [ ] Inactive tab releases diff buffers (verified with Allocations).
- [ ] VoiceOver pass on file list, diff rows, hunk rotor, composer.
- [ ] Idle check after a commit: CPU ≈ 0, no lingering processes/animations.
- [ ] Finalize ADRs 0011–0014, 0025–0029.
Done when: numbers recorded honestly in `progress.md` and `docs/performance.md`.

## 3. Test plan summary

| Layer | What | Where |
|---|---|---|
| Rust unit | status parser, patch parser, patch builder table, token, word diff | `git-core/src/**` |
| Rust golden | `git diff` outputs → parsed model → re-emitted bytes | `git-core/tests/diff_golden/` |
| Rust integration | full §7.4 matrix on real temp repos; commit/identity; blame; discard/recovery | `git-core/tests/{apply,commit,blame,discard}.rs` |
| Rust property | random edits × random selections × operations; unrelated bytes untouched | `git-core/tests/apply_prop.rs` |
| Swift unit | selection model, action availability, layout rows, writer serialization | `JitKit/Tests/*` |
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

- `docs/architecture.md` — status/diff/patch/apply/commit pipeline, writer serialization, bridge API.
- `docs/design-system.md` — `diff.*`, `syntax.*`, `status.*` tokens per theme; renderer metrics.
- `docs/security.md` — hooks policy, no textconv/ext-diff, temp patch files, recovery store, identity env.
- `docs/performance.md` — Phase 3 results.
- `docs/adr/0011–0014, 0025–0029`.
- `CLAUDE.md` — commands for property tests (`PROPTEST_CASES`), golden updates.

## 6. Exit checklist

- [ ] Scenario C (§24) passes as an automated UI test and manually.
- [ ] Full §7.4 integration matrix + property tests pass (50k local cases recorded in `progress.md`).
- [ ] Every unsupported granular case is disabled with a clear explanation (no risky workaround).
- [ ] Discards: confirmation explains change/loss/recoverability; recovery copies verified.
- [ ] Commit identity from the profile snapshot; no config file modified (test-proven).
- [ ] Diff viewer reviewed in light/dark, unified/split/full-file; screenshots committed.
- [ ] No WebView/Monaco/CodeMirror; highlighting lazy; no main-thread blocking (Hangs instrument clean).
- [ ] Roadmap §9 phase exit gate satisfied.
