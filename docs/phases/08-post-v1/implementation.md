# Phase 8 — Post-V1: implementation backlog

> Status: **planned**. Epics are independent units of work, each on branch `epic/<name>` with its own
> report `progress-<epic>.md` in this folder (template: [`../README.md`](../README.md)). Specs go in
> `specs/P8.<epic>.<k>-<slug>.md`. Read [`design.md`](design.md) first.

## 1. Preconditions

**For any epic**
- [ ] V1 released: `docs/phases/07-packaging-and-release/progress.md` shows the Phase 7 exit gate passed
      (or release blocked only on external credentials, with the owner's go-ahead to continue).
- [ ] P4 operation framework (risk classes, writer queue, `RepoRevision`, confirmation sheet, operation
      bar with continue/skip/abort) and P4 conflict resolver exist and are tested.
- [ ] P3 patch builder and `git apply --check` validation exist and are tested.
- [ ] P6 command palette exists (epics register their actions there).
- [ ] Bundled Git version recorded (ADR-0019); feature checks below use the *bundled* version.

**Epic dependencies (hard)**

| Epic | Requires |
|---|---|
| `stash` | — |
| `reflog` | — |
| `reset` | `reflog` recommended (recovery wording); `stash` optional ("Stash first") |
| `tags` | — (`signing` optional) |
| `rebase-interactive` | `reflog`; helper binary from P5 (ADR-0016) |
| `commit-surgery` | `rebase-interactive` |
| `history-filters` | — |
| `worktrees` | — |
| `patches` | — |
| `remotes` | — |
| `branch-history` | `rebase-interactive`, `reflog` |
| `signing` | — |
| `submodules` | — |
| `lfs` | — |

Each epic's milestones follow: goal → tasks → files → tests → verification → done when. File paths
follow the module layout established in Phase 0 (ADR-0004); names below are indicative.

---

## 2. Milestones by epic

### Epic `stash` — Stash manager

**P8.stash.1 — Core stash operations**
- Goal: list, inspect, push, apply, pop, drop, clear in `git-core` with revision validation.
- Tasks:
  - [ ] `git-core/src/stash.rs`: list parser (`-z` format), `StashEntry`, push/apply/pop/drop/branch.
  - [ ] OID validation for index-addressed ops; `StaleState` on mismatch.
  - [ ] Register operation kinds and risk classes; FFI exports.
- Tests: `stash_list_parses_messages_with_newlines_and_unicode`, `stash_push_include_untracked_roundtrip`,
  `stash_push_keep_index_preserves_index_bytes`, `stash_push_paths_only_stashes_selected`,
  `stash_pop_conflict_keeps_stash`, `stash_drop_rejects_shifted_index`, `stash_apply_untracked_collision_errors`.
- Verify: `cargo test -p git-core stash`.
- Done when: all tests pass on real temp repos; unrelated files byte-identical after every op.

**P8.stash.2 — Stash UI**
- Goal: sidebar section, create sheet, read-only stash diff, apply/pop/drop flows.
- Tasks:
  - [ ] `Features/Stash`: `StashStore` (lazy, FSEvents on `refs/stash`, `logs/refs/stash`), sidebar rows.
  - [ ] Create sheet (⌥⌘S) with toggles gated on Git version (`--staged` needs ≥ 2.35).
  - [ ] Inspector stash diff using the P3 renderer (staged / unstaged / untracked sections).
  - [ ] Pop/apply → resolver on conflict; drop → destructive sheet with SHA copy.
  - [ ] Optional graph toggle "Show stashes"; command palette entries.
- Tests: UI `testCreateStashFromWorkingDirectory`, `testPopWithConflictOpensResolver`,
  `testDropShowsRecoverySha`; snapshot tests for sidebar/sheet in light and dark.
- Verify: manual run on a repo with staged, unstaged and untracked changes; screenshots.
- Done when: demo — stash part of a WD, switch branch, pop with a conflict, resolve, drop another stash.

### Epic `reflog` — Reflog explorer & recovery

**P8.reflog.1 — Core reflog + recovery points**
- Tasks:
  - [ ] `git-core/src/reflog.rs`: paged reader, action classification from `%gs`.
  - [ ] On-demand reachability for a page; `find_unreachable` (fsck) with cancel + progress.
  - [ ] `RecoveryPoint` recorded by every rewrite/destructive op in the session op log (bounded 50).
  - [ ] ADR-0050.
- Tests: `reflog_page_classifies_actions`, `reflog_marks_unreachable_after_reset`,
  `find_unreachable_lists_dropped_stash`, `find_unreachable_cancels_and_kills_process`,
  `recovery_point_recorded_for_amend`.
- Done when: tests pass; fsck cancellation leaves no child process (`pgrep` check in test).

**P8.reflog.2 — Reflog explorer UI**
- Tasks:
  - [ ] Workbench mode + ref picker; virtualized entry list.
  - [ ] Graph integration: temporary tip lane for an unreachable selection (dashed style token).
  - [ ] Actions: create branch here, cherry-pick, compare, copy SHA; "Reset here" appears when `reset` exists.
  - [ ] "Undo last operation" for session-recorded ops (through reset sheet once `reset` exists; until
        then offer "Create branch at previous state").
- Tests: UI `testRecoverCommitAfterHardResetViaBranch`; snapshot light/dark.
- Done when: demo — amend a commit, find the pre-amend commit in reflog, create a branch at it.

### Epic `reset` — Reset modes

**P8.reset.1 — Preview + execution**
- Tasks:
  - [ ] `reset_preview` (files lost, unreachable commits count/subjects), `reset` for soft/mixed/keep/hard.
  - [ ] "Stash first" chain in one writer job (abort reset if stash fails).
- Tests: `reset_soft_keeps_index_and_worktree`, `reset_mixed_unstages`, `reset_keep_aborts_on_conflicting_changes`,
  `reset_hard_preview_lists_lost_files`, `reset_hard_leaves_untracked_files`, `reset_stash_first_chain_atomic`,
  `reset_rejects_stale_revision`.

**P8.reset.2 — Reset UI**
- Tasks:
  - [ ] Graph context submenu with per-mode explanations; destructive sheet for hard.
  - [ ] Recovery info line from the recorded `RecoveryPoint`.
- Tests: UI `testHardResetSheetListsFilesAndOffersStash`; snapshots.
- Done when: demo — hard reset with "Stash first", then recover the commits from reflog.

### Epic `tags` — Tag management

**P8.tags.1 — Create/delete/push**
- Tasks:
  - [ ] Name validation via `git check-ref-format "refs/tags/<name>"`.
  - [ ] Lightweight + annotated create (message via 0600 temp file, tagger from profile snapshot env).
  - [ ] Push one tag, delete local (record target), delete remote (destructive).
- Tests: `tag_annotated_uses_profile_identity`, `tag_name_validation_rejects_invalid`,
  `tag_delete_local_returns_target`, `tag_push_rejected_when_remote_differs` (local bare remote fixture).

**P8.tags.2 — Tag UI**
- Tasks: create sheet, sidebar tag rows with popover details, actions, palette entries.
- Tests: UI `testCreateAnnotatedTagAndPush`; snapshots.
- Done when: demo — create an annotated tag on an older commit, push to a local bare remote, delete it remotely.

### Epic `rebase-interactive` — Interactive rebase

**P8.rebase-interactive.1 — Spike + ADR-0051/0052**
- Tasks:
  - [ ] Prototype helper-as-editor vs `exec` lines on a 50-commit fixture; record results.
  - [ ] Decide empty-commit policy and `--update-refs` default; write ADR-0051, ADR-0052.
- Done when: ADRs merged with measured/observed evidence.

**P8.rebase-interactive.2 — Plan, validation, helper**
- Tasks:
  - [ ] `git-core/src/rebase_interactive.rs`: `rebase_plan` (merge detection, published flags,
        unsupported reasons), `rebase_validate`.
  - [ ] Helper subcommands `sequence-editor` and `message-editor` (amend ADR-0016); temp dir 0700.
  - [ ] State-machine additions: interactive rebase, stopped-for-edit, progress from `msgnum`/`end`.
- Tests: `plan_rejects_range_with_merge`, `validate_rejects_leading_squash`, `reorder_two_independent_commits`,
  `reword_message_with_quotes_newlines_and_unicode`, `squash_combines_messages`, `fixup_discards_message`,
  `drop_removes_commit_tree_matches_expected`, `edit_stops_and_continue_after_amend`,
  `conflict_mid_rebase_then_abort_restores_original_head`, `update_refs_moves_stacked_branch`,
  `committer_identity_from_profile_snapshot`, `helper_never_receives_user_text_in_argv`.

**P8.rebase-interactive.3 — Editor UI**
- Tasks:
  - [ ] Focused editor: action pickers, drag + ⌥⌘↑/↓ reorder, letter shortcuts, inline reword editor,
        squash message preview, result preview graph, rewrite banner.
  - [ ] Run with progress; resolver labels for rebase ours/theirs; edit-stop WD state; operation bar.
  - [ ] Relaunch recovery: detect in-progress rebase and show Continue/Abort.
- Tests: UI `testReorderAndRewordThenRun`, `testConflictDuringInteractiveRebaseResolveContinue`,
  `testAbortRestoresBranch`; VoiceOver labels audit; snapshots light/dark.
- Done when: demo — on a 10-commit branch: reorder, reword, squash two, drop one, resolve one conflict, finish;
  then abort a second run and confirm the branch is unchanged.

### Epic `commit-surgery` — Direct commit actions

**P8.commit-surgery.1 — Plan generators**
- Tasks: `reword(oid,msg)`, `drop(oid)`, `move(oid, after)`, `squash(oid, into)` generating validated plans;
  HEAD reword routes to amend.
- Tests: `surgery_drop_middle_commit`, `surgery_move_up_independent_commit`, `surgery_reword_older_commit`,
  `surgery_squash_into_parent`, `surgery_refuses_merge_in_range`.

**P8.commit-surgery.2 — Graph actions**
- Tasks: context menu items, in-lane drag to reorder (current branch only), message sheet, destructive drop sheet.
- Tests: UI `testEditOlderCommitMessageFromGraph`, `testDragCommitToReorder`.
- Done when: demo — edit an older message, drop a commit and recover it through reflog. "Split commit" stays listed as Planned.

### Epic `history-filters` — Additional filtering

**P8.history-filters.1 — Core filter mapping + ADR-0058**
- Tasks: `HistoryFilter` → argv mapping; layout cache keyed by filter; streaming pickaxe with cancel.
- Tests: `filter_author_and_date_range`, `filter_paths_rewrites_parents_connected_graph`,
  `filter_first_parent_lanes`, `filter_ancestry_path`, `filter_pickaxe_cancel`,
  `filter_values_never_interpreted_as_options` (values starting with `-`).

**P8.history-filters.2 — Filter UI**
- Tasks: filter tokens, path drop target, per-tab persistence, filtered-mode header, simplified-edge style token.
- Tests: UI `testCombineFiltersAndClear`; snapshots; perf check below.
- Done when: demo — filter the 100k fixture by path + author + date and scroll at 60 FPS.

### Epic `worktrees` — Worktree manager

**P8.worktrees.1 — Core + session model (ADR-0053)**
- Tasks: porcelain parser; add/remove/lock/unlock/prune; `CommonDirGroup` invalidation; per-common-dir ref-write lock.
- Tests: `worktree_list_parses_locked_prunable_detached`, `worktree_add_new_branch`,
  `worktree_remove_dirty_requires_force`, `ref_change_in_one_worktree_invalidates_sibling_session`,
  `concurrent_ref_writes_across_worktrees_serialized`.

**P8.worktrees.2 — UI**
- Tasks: sidebar section, add sheet, open-in-tab, "checked out in ‹path›" badges, destructive remove sheet.
- Tests: UI `testAddWorktreeOpensTab`, `testCheckoutBranchUsedByWorktreeDisabled`.
- Done when: demo — create a worktree for a branch, commit in it, see the graph update in the main tab.

### Epic `patches` — Patch workflows

**P8.patches.1 — Create & apply core**
- Tasks: format-patch, diff export, selection export (P3 builder), apply check report, apply/`am` with
  AM state machine, temp file hygiene; ADR-0054.
- Tests: `export_commits_then_am_reproduces_trees`, `export_selection_applies_cleanly`,
  `apply_check_reports_per_file_failure`, `apply_is_atomic_on_failure`, `apply_three_way_fallback_conflict`,
  `am_conflict_continue_and_abort`, `binary_patch_roundtrip`.

**P8.patches.2 — UI + sharing**
- Tasks: export menus, share picker, drop-to-apply, preview sheet, `PatchSharingProvider` with local providers only.
- Tests: UI `testDropPatchShowsPreviewAndApplies`; snapshots.
- Done when: demo — export 3 commits, share via AirDrop/Mail picker (shown, not sent), apply the series to another clone.

### Epic `remotes` — Advanced remote management

**P8.remotes.1 — Core**
- Tasks: config-based remote parser; add/rename/set-url(push)/remove; prune dry-run + run; URL validation and credential stripping.
- Tests: `remote_add_rejects_embedded_credentials`, `remote_rename_moves_tracking_refs`,
  `remote_remove_reports_deleted_refs`, `remote_prune_dry_run_matches_run`, `remote_separate_push_url`.

**P8.remotes.2 — UI**
- Tasks: remotes section, edit sheets, destructive remove/prune sheets, "changes repository configuration" note.
- Done when: demo — add a second remote, set a separate push URL, prune stale branches.

### Epic `branch-history` — Advanced branch manipulation

**P8.branch-history.1 — Core**
- Tasks: force-move branch with preview, `rebase --onto`, squash-branch plan, `git cherry` comparison,
  force-with-lease push path (lease SHA from last observed tracking ref, `--force-if-includes` when supported).
- Tests: `force_move_preview_lists_lost_commits`, `rebase_onto_range`, `squash_branch_single_commit_same_tree`,
  `cherry_marks_equivalent_patches`, `force_with_lease_rejected_when_remote_moved` (local bare remote).

**P8.branch-history.2 — Graph drag & drop**
- Tasks: drag branch label onto commit → popover actions; compare-branches view; force-push sheet.
- Tests: UI `testDragBranchOntoCommitRebase`, `testForcePushSheetShowsReplacedCommits`.
- Done when: demo — rebase a feature branch by drag, publish with force-with-lease, see a rejected lease handled.

### Epic `signing` — Signing configuration

**P8.signing.1 — Core**
- Tasks: per-invocation signing config from profile; key discovery (GPG colons output, SSH pubkeys);
  verification on selection; app-managed allowed-signers file; ADR-0055.
- Tests: `ssh_signed_commit_verifies_with_allowed_signers` (test key generated in fixture),
  `gpg_missing_reports_actionable_error`, `signing_failure_does_not_create_unsigned_commit`,
  `global_gitconfig_unchanged_after_signed_commit`. GPG tests skipped only when `gpg` absent, with recorded reason.

**P8.signing.2 — UI**
- Tasks: profile signing section, composer indicator, commit-details signature status, tag signing toggle.
- Done when: demo — SSH-signed commit and tag with the active profile; status shows "Good signature".

### Epic `submodules` — Submodule management

**P8.submodules.1 — Core (ADR-0056)**
- Tasks: porcelain v2 submodule fields; status/update/init/sync/add/deinit; path safety checks; Git version gate.
- Tests: `status_reports_submodule_new_commits`, `update_init_recursive`, `refuses_path_escape`,
  `refuses_symlinked_submodule_path`, `clone_does_not_recurse_by_default`, `deinit_dirty_requires_confirmation`.

**P8.submodules.2 — UI**
- Tasks: WD rows, pointer diff with commit list, sidebar section, open as tab, clone toggle.
- Done when: demo — clone a repo with submodules, init on demand, view a pointer change, open the submodule tab.

### Epic `lfs` — Git LFS

**P8.lfs.1 — Spike + ADR-0057**
- Tasks: bundle-vs-detect evaluation (size, signing, notarization, licensing); filter policy write-up.

**P8.lfs.2 — Core**
- Tasks: detection; pointer parsing; track/untrack; fetch/pull/prune with progress/cancel; locks via helper credentials;
  safe reads without LFS.
- Tests: `pointer_file_parsed`, `track_updates_gitattributes_only`, `reads_work_without_lfs_installed`,
  `fetch_cancel_kills_process` (local LFS test server or skip with reason).

**P8.lfs.3 — UI**
- Tasks: LFS object card in diff, banner when missing, actions menu, locks list.
- Done when: demo — repo with LFS images: pointer cards, fetch objects, image preview, lock/unlock (where server supports).

---

## 3. Test plan summary

- Every epic adds Rust integration tests on real temp repositories built with `git-testkit`; remote
  scenarios use local bare repositories (and a local HTTP server where auth/LFS is required).
- Destructive and rewrite tests assert byte-identical unrelated content (files, index entries, refs not
  targeted) — same helper as P3/P4 (`assert_unrelated_unchanged`).
- Each epic adds UI tests for its demo flow and snapshot tests for new screens in light and dark.
- Relaunch-in-the-middle tests for every new multi-step state (interactive rebase, `am`, sequencer).
- Tests that need external tools (`gpg`, `git-lfs`) skip only with an explicit recorded reason.

## 4. Performance checks (per epic, release build)

| Check | Budget |
|---|---|
| Idle CPU with the epic's views open, after settling | No regression vs V1 (0.0–0.2 %) |
| New FSEvents subscriptions | None beyond existing per-repo stream (filter paths, don't add streams) |
| Reflog page / stash list / worktree list load | < 100 ms on the 100k fixture |
| Rebase plan for 50 commits incl. published detection | < 150 ms |
| Filtered graph scrolling | 60 FPS on the 100k fixture |
| Memory with epic views open | < +15 MB over V1 typical-repo figure |

Record numbers in `progress-<epic>.md` with machine, macOS, Git version and method.

## 5. Docs to update (per epic)

- `docs/product.md` (feature now real), `docs/architecture.md` (new operation kinds/states),
  `docs/security.md` (new untrusted inputs, helper usage), `docs/design-system.md` (new tokens),
  `docs/roadmap.md` (epic status), ADRs listed in design §6, README feature list.

## 6. Exit checklist (per epic)

- [ ] All epic milestones done or carried over with reason.
- [ ] Demo in "Done when" performed against real repositories; screenshots light/dark saved in
      `screenshots/<epic>/`.
- [ ] Destructive/rewrite operations show the §16.3 sheet and record a `RecoveryPoint`.
- [ ] No new background activity; idle CPU re-measured.
- [ ] Actions registered in menus, context menus and command palette; keyboard + VoiceOver checked.
- [ ] ADRs written; docs updated; nothing unbuilt shown as working.
- [ ] Roadmap §9 phase exit gate items satisfied for this epic's scope.
- [ ] `progress-<epic>.md` finalized; PR `Epic — <name>` opened to `main`.
