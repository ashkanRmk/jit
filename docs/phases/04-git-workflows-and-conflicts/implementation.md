# Phase 4 — Everyday Git workflows & conflicts: implementation plan

Design: [`design.md`](design.md). Requirements: §8, §9.1, §13.5, §14, §16. Invariants: roadmap §6.

## 1. Preconditions

- Phase 3 `progress.md` shows its exit gate passed (or carry-overs accepted). In particular:
  - Phase 0: `ProcessRunner` (argv, cwd, sanitized env, process-group spawning), `CancelToken`,
    progress callback interface, typed `GitError`, `git-testkit` fixture builder.
  - Phase 1: `RepositorySession`, FSEvents invalidation (including the git dir), identity-only profiles
    with an active-profile snapshot.
  - Phase 2: graph + navigator with read-only context menus and placeholders removed (not stubbed).
  - Phase 3: native text/diff renderer reusable for read-only and editable panes; per-repo mutation queue;
    commit composer applying the profile identity; discard flow with confirmation.
- Git version on the machine ≥ the ADR-0006 minimum; record whether ≥ 2.38 (`merge-tree --write-tree`)
  and ≥ 2.35 (`zdiff3`).
- Network access for the public-clone demo (any small public GitHub repository).

## 2. Milestones

Each milestone: spec in `specs/P4.k-*.md` → tests → implementation → verification → commit(s).

### P4.1 — Operation framework and execution context
Goal: every mutating Git call goes through one framework with risk classes, serialization, revision
tokens, non-interactive execution, progress and classified errors.
- [ ] Rust: `RepoHandle` writer lock; reads lock-free. Reconcile with the Phase 3 queue (ADR-0015).
- [ ] Rust: `RepoRevision` capture + `ensure_current(expected)`; `GitError::StaleSnapshot`.
- [ ] Rust: `exec::ExecContext { identity, auth: AuthPlan::NonInteractive, network: NetworkPlan::Default }`
      and `exec::remote_command` applying the env/`-c` layers from design §4.3.
- [ ] Rust: `progress::parse` (CR/LF splitting, phases, `remote:` lines) + throttle (≤ 10 Hz).
- [ ] Rust: `errors::classify` covering every §16.4 row in design §4.11; `sanitize::redact`.
- [ ] Rust: `ConfirmationToken` type that only the confirmation API can mint (constructed via an FFI call
      that records the confirmed request digest; destructive calls verify the digest).
- [ ] Swift: `OperationCenter` (per-repo FIFO, lifecycle model, bounded history 20, snapshot at enqueue,
      cancel routing, targeted invalidation dispatch).
- Files: `rust/crates/git-core/src/{exec,progress,errors,ops/mod}.rs`, `git-ffi` exports,
  `macos/.../Services/OperationCenter/`.
- Tests: `exec_env_is_non_interactive`, `exec_env_contains_no_user_derived_c_values`,
  `progress_parses_fetch_clone_push_samples` (captured stderr fixtures), `classify_maps_all_16_4_cases`
  (fixture stderr per case), `redact_strips_userinfo_and_token_prefixes`, `writer_lock_serializes_mutations`
  (two threads, interleaving detector), `stale_revision_rejected`, Swift `OperationCenterTests`
  (ordering, cancel, snapshot immutability across profile switch).
- Verify: run a fake hanging credential scenario (`GIT_ASKPASS` path) against a local HTTP server that
  returns 401 → operation fails in < 2 s, no hang.
- Done when: all mutating APIs from Phase 3 (stage/unstage/discard/commit) run through the framework
  unchanged in behavior, and the tests pass.

### P4.2 — Activity UI, confirmation sheet, error presentation
- [ ] `OperationActivity` toolbar item + popover (design §3.1).
- [ ] `ConfirmationSheet` component (design §3.2) and `ConfirmationRequest` model (title, context,
      changes, losses, recoverability, verb). Retrofit Phase 3 discard to use it.
- [ ] `PresentableError` mapping + error view with recovery actions; Unknown errors show sanitized detail.
- [ ] Repository menu: Show Activity.
- Tests: snapshot tests (light/dark) for activity states, sheet, error view; UI test: Escape/Return never
  triggers destructive button.
- Done when: screenshots reviewed in both themes; activity item is not drawing when idle (verify with
  Quartz Debug / Instruments "Core Animation" — no commits while idle).

### P4.3 — Operation-state detection and banner
- [ ] Rust `state::detect` via `--git-path` (merge, rebase-merge, rebase-apply/am, cherry-pick, revert,
      sequencer, bisect).
- [ ] Swift banner model + view; FSEvents-driven refresh; actions wired as each operation lands
      (continue/skip/abort enabled in P4.9–P4.10).
- Tests: `state_detects_merge|rebase_merge|rebase_apply|am|cherry_pick|revert|sequencer|bisect`
  (fixtures that create each state with Git), `state_in_linked_worktree`; UI snapshot of each banner.
- Verify: start a conflicting merge in Terminal → banner appears without user action.

### P4.4 — Fetch, ahead/behind, remotes inspector
- [ ] `fetch` (remote / all, explicit prune flag mirroring effective `fetch.prune`).
- [ ] Ahead/behind via `for-each-ref` upstream track; `[gone]` handling; badges in toolbar + navigator.
- [ ] Remotes inspector (read-only; masked credentials in URLs with warning).
- Tests: `fetch_updates_remote_refs` (local bare remote), `fetch_prune_explicit`, `fetch_cancel_leaves_refs_consistent`
  (kill mid-transfer on a large synthetic pack served via `file://`; refs either old or new, `git fsck
  --connectivity-only` clean), `ahead_behind_counts`, `upstream_gone_detected`, `remote_url_userinfo_masked`.
- Verify: fetch a real public repo; cancel a fetch; inspect remotes.

### P4.5 — Pull
- [ ] Two-step pull: fetch + `merge --ff-only` (default) / `merge --no-edit` / `rebase --no-autostash
      --no-update-refs`; outcomes per design §4.6; `NotFastForward` sheet offering merge/rebase.
- Tests: `pull_ff_only_fast_forwards`, `pull_ff_only_refuses_divergent_without_changes` (fingerprint
  unchanged), `pull_merge_creates_merge_commit_with_profile_committer`, `pull_rebase_replays`,
  `pull_ignores_pull_rebase_config_for_explicit_choice`, `pull_conflict_enters_state`.
- Done when: divergent pull never integrates without an explicit choice.

### P4.6 — Push
- [ ] `push --porcelain` parsing per ref; publish sheet (`-u`); rejection sheet by cause; force-with-lease
      with `--force-if-includes` via destructive sheet.
- Tests (local bare remote, two clones): `push_fast_forward`, `push_publishes_and_sets_upstream`,
  `push_rejected_non_ff_classified`, `push_rejected_by_hook_shows_remote_lines` (pre-receive hook in bare
  remote), `force_with_lease_succeeds_when_expected_matches`, `force_with_lease_fails_when_remote_moved`
  (remote unchanged afterwards), `push_cancel_reports_actual_remote_state`.
- Verify: demo step 2.

### P4.7 — Clone from URL
- [ ] Clone sheet (validation, destination, derived name, progress, cancel, retry); new-tab page entry;
      File ▸ Clone…; opens in new tab.
- [ ] Scheme allowlist; `http://` confirmation; destination-created marker for cleanup; `.gitmodules` note.
- Tests: `clone_file_url_succeeds`, `clone_rejects_dash_prefixed_url`, `clone_rejects_ext_protocol`,
  `clone_cancel_removes_created_destination`, `clone_cancel_preserves_preexisting_empty_folder`,
  `clone_into_nonempty_folder_blocked`, `clone_auth_required_fails_fast_non_interactive` (local HTTP 401).
- Verify: clone a public GitHub repo over HTTPS; cancel one midway; check directory state.

### P4.8 — Branch operations + Phase 2 write actions
- [ ] Create (from any commit/ref), switch (incl. remote → tracking, detached with explanation), rename,
      delete (`-d` then `-D` flow), delete remote, set/unset upstream.
- [ ] Switch blocked by dirty tree: path list + Cancel / Discard These Changes… (path-scoped, destructive;
      drop if the P4.8 review finds it unsafe — design §7).
- [ ] Enable navigator double-click checkout and graph/navigator context-menu write actions.
- Tests: `branch_name_validated_by_git`, `switch_carries_non_conflicting_changes`,
  `switch_blocked_lists_paths_and_changes_nothing` (fingerprint), `checkout_remote_creates_tracking`,
  `rename_keeps_upstream`, `delete_unmerged_requires_force_token`, `delete_remote_branch`,
  `set_unset_upstream`, `branch_ops_stale_revision_rejected`, `switch_to_branch_in_other_worktree_refused`.
- Verify: all context-menu actions on a real repo; light/dark screenshots of sheets.

### P4.9 — Merge and rebase
- [ ] Merge sheet (ff / no-ff / ff-only, message, identity line, preflight warnings).
- [ ] Rebase sheet (commit list, pushed-commits warning, clean-tree requirement).
- [ ] Continue / skip (destructive) / abort (destructive when resolutions exist) wired into the banner.
- [ ] Optional: `merge-tree --write-tree` conflict prediction (design §7).
- Tests: `merge_ff`, `merge_no_ff_identity_from_profile`, `merge_ff_only_refuses`, `merge_conflict_state`,
  `merge_abort_restores_fingerprint`, `merge_with_unrelated_dirty_changes_preserved`,
  `rebase_clean_replays_with_profile_committer_and_original_author`, `rebase_conflict_state_step_counts`,
  `rebase_continue_after_resolution`, `rebase_skip_drops_commit`, `rebase_abort_restores_fingerprint`,
  `rebase_requires_clean_tree`, `rebase_ignores_autostash_config`.

### P4.10 — Cherry-pick and revert
- [ ] Multi-commit cherry-pick in topological order; revert; mainline selection for merge commits.
- Tests: `cherry_pick_preserves_author_sets_committer`, `cherry_pick_multi_order`, `cherry_pick_conflict_continue`,
  `cherry_pick_abort_restores_fingerprint`, `cherry_pick_merge_commit_requires_mainline`,
  `revert_creates_commit_with_profile_identity`, `revert_conflict_abort`.

### P4.11 — Conflict model
- [ ] `conflicts()` from porcelain v2 `u` + `ls-files -u` cross-check; kind + attribute classification.
- [ ] `load_conflict` via stage blobs + `merge-file --diff3` (or zdiff3 per spike) → segments;
      working-tree reconciliation hash.
- [ ] `save_resolution` (hash guard, atomic write, mode preserved), `mark_resolved`, `resolve_with_side`.
- Tests: `conflict_kinds_uu_aa_ud_du_au_ua_dd`, `conflict_binary_symlink_submodule_detected`,
  `conflict_document_segments_match_git` (compare re-serialized document with Git's marker output),
  `conflict_crlf_preserved`, `conflict_no_trailing_newline_preserved`, `conflict_unicode_path`,
  `save_refuses_when_file_changed_externally`, `save_is_atomic_and_keeps_mode`,
  `mark_resolved_requires_matching_hash`, `opening_does_not_mark_resolved` (index still unmerged after
  load), property test: random three-way edits → taking ours everywhere yields stage 2 content merged with
  Git's clean regions exactly.

### P4.12 — Conflict resolver UI
- [ ] Three-pane (+ optional base) resolver on the Phase 3 renderer; block navigation; take ours/theirs/
      both (either order); manual edit; undo; save; mark resolved with marker-guard confirmation.
- [ ] Operation-specific labels (design §3.8 table) + one-time rebase explanation strip.
- [ ] External-change banner (Reload / Keep My Result).
- Tests: UI tests for take-ours/theirs/both, manual edit, mark-resolved disabled with unresolved blocks,
  stale-file banner; snapshot tests (light/dark) for merge and rebase labelling.
- Verify: demo steps 4 and 5 on real repos; measure resolver open time on a 5,000-line conflicted file.

### P4.13 — Non-text conflict fallbacks
- [ ] Modify/delete, delete/modify, binary, symlink, oversized/non-UTF-8, rename cases, submodule
      explanation (design §3.9), each through a confirmation.
- Tests: `resolve_modify_delete_keep|delete`, `resolve_binary_ours|theirs`, `resolve_symlink`,
  `submodule_conflict_offers_terminal_only`, `rename_rename_paths_reported`.

### P4.14 — Copy remote links
- [ ] `weblink::map` for github.com and gitlab.com (https, ssh://, scp, ports, nested namespaces, `.git`
      suffix, percent-encoding); menu items only when mappable.
- Tests: table-driven `weblink_*` cases including unknown hosts → `None`.

### P4.15 — Hardening, review, docs
- [ ] Full integration matrix (§3 below) green; interrupted-operation tests; locked-index tests.
- [ ] Strict self-review (§25 step 5): data-loss paths, races (profile switch, tab close mid-op, external
      edits), main-thread blocking, leaks (Instruments Leaks while running 50 fetch/merge cycles).
- [ ] Update docs (§5 below), write ADRs 0015, 0030–0034, finalize `progress.md`.

## 3. Test plan summary

All Git tests use real temporary repositories from `git-testkit`; remotes are local bare repositories
(`file://`) or a local HTTP server fixture for auth-failure cases.

- **Fingerprint helper (add to `git-testkit`):** `RepoFingerprint::capture(repo)` = `HEAD` (symbolic +
  OID), all refs (`for-each-ref`), index (`ls-files -s --debug`-free form: mode, OID, stage, path),
  working-tree file hashes (including untracked, excluding `.git`), operation-state files. Every abort,
  refusal and cancel test asserts `before == after`.
- **Matrix:** dirty trees (staged, unstaged, untracked, partially staged) × {switch, merge, rebase,
  cherry-pick, pull}; conflicts in merge/rebase/cherry-pick/revert; abort restores state; locked index
  (`index.lock` present) for every mutating op; rejected push variants; interrupted fetch/clone/push
  (SIGTERM at random points across 20 runs); external edits during resolution; CRLF, no trailing newline,
  Unicode and space-containing paths; linked worktrees.
- **Swift:** `OperationCenter` unit tests; UI tests for confirmation semantics, banner actions, resolver
  flows; snapshot tests for every new screen and state in light and dark.

## 4. Performance checks (release build)

| Check | Target |
|---|---|
| Idle CPU after a completed fetch/merge | back to Phase 3 baseline (0.0–0.2 %) within 2 s |
| Activity item / banner while idle | zero Core Animation commits |
| Post-operation refresh (10k-commit repo, fetch with 50 new commits) | graph updated < 150 ms after Git exits, no full reload |
| Resolver open, 5,000-line file with 20 blocks | < 250 ms to first paint |
| Memory after closing resolver | returns to pre-open level (± 2 MB) |
| Progress callback rate | ≤ 10 Hz to Swift |

## 5. Docs to update

- `docs/architecture.md`: operation framework, execution context layers, state detection, conflict model.
- `docs/security.md`: non-interactive environment, protocol policy, sanitization, temp files.
- `docs/product.md`: V1 operation list status (implemented vs planned), force-push policy.
- `docs/performance.md`: phase measurements.
- `CLAUDE.md`: any new commands (e.g. integration test filters).
- ADRs 0015, 0030–0034.

## 6. Exit checklist

- [ ] Demo steps 1–6 from design §1 performed on real repositories; screenshots in `screenshots/`.
- [ ] No operation can prompt or hang; auth failures fail fast and are explained.
- [ ] Every destructive action uses `ConfirmationSheet` + `ConfirmationToken`; plain `--force` never used.
- [ ] Every abort/refusal/cancel test proves fingerprint equality.
- [ ] Commit-creating operations use the profile snapshot; no profile → blocked with resolution path.
- [ ] Resolver never marks a file resolved without explicit confirmation; external edits detected.
- [ ] Banner reflects states created outside Jit.
- [ ] Idle CPU and memory re-measured; no regression.
- [ ] Roadmap §9 gate items 1–8 satisfied.
