# Phase 4 — Everyday Git workflows & conflicts: progress report

Status: complete with carry-overs
Branch / PR: `phase/04-git-workflows-and-conflicts` (not pushed yet)
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Xcode 27.2, Swift 6.4.2, Git 2.54.0
(Homebrew; ≥ 2.38 `merge-tree --write-tree` and ≥ 2.35 `zdiff3` both available)

Preconditions checked before starting: Phase 3 merged to `main`; 439 package tests green on `main`; the app built.

## Implemented
- **P4.1 Operation framework** — the Phase 3 `RepositoryHandle` write gate is the single writer for every new
  mutation; `RepoStateToken` staleness checks inside the gate; `ConfirmationToken` (internal init, minted only by
  `ConfirmationRequest.confirm()`, verified per action); `ExecContext`/`GitEnvironment` (non-interactive remote
  env, protocol policy, identity via env); `ProgressParser`/`ProgressSink` (≤ 10 Hz, `.bufferingNewest(1)`);
  `GitErrorClassifier` (§16.4) → `PresentableError`; `OperationCenter` per repository. Evidence:
  `FrameworkTests` (16), `OperationCenterTests` (11), ADR-0015, ADR-0032.
- **P4.2 Activity, confirmation, errors** — toolbar activity item + popover (⌥⌘A), `ConfirmationSheet`, error
  sheet with recovery actions. Pointer-tested (fetch, push rejection, force-push sheet, delete). Screenshot
  `force-push-confirmation-light.png`.
- **P4.3 Operation state + banner** — `operationState()` for merge / rebase (both backends) / am / cherry-pick /
  revert / sequencer / bisect, linked worktrees; floating tinted-glass banner with Resolve Next / Continue / Skip /
  Abort. A cherry-pick started in Terminal appeared without user action. `StateDetectionTests` (9);
  `banner-merging-light.png`, `banner-cherry-pick-dark.png`.
- **P4.4–P4.6 Fetch, pull, push** — explicit prune, cancellable fetch with ref-delta report, ahead/behind,
  read-only remotes sheet with masked URLs, two-step pull (ADR-0030), porcelain push with rejection causes, publish
  with upstream, force-with-lease + `--force-if-includes` only. `RemoteOperationTests` (31).
- **P4.7 Clone** — URL validation/allowlist, insecure-HTTP confirmation, Jit-created destination, cancel cleanup,
  submodule note; clone sheet (File ▸ Clone…, ⇧⌘N, new-tab page). Real HTTPS clone of
  `octocat/Hello-World` opened in a new tab; a `git/git` clone cancelled at 5 % left no folder and no Git process.
- **P4.8 Branch operations** — create / switch / track remote / detach (explained once) / rename / delete (second
  sheet with unmerged commits) / delete remote (leased) / set-unset upstream; graph + navigator write menus,
  double-click checkout, branch popover switches. `BranchOperationTests` (13); `blocked-switch-light.png`.
- **P4.9–P4.10 Merge, rebase, cherry-pick, revert** — strategies, `merge-tree` conflict prediction, rebase plan
  with pushed-commit warning, mainline choice, continue / skip / abort. `IntegrationTests` (27 incl. dirty-tree
  matrix); `merge-sheet-light.png`.
- **P4.11 Conflict model** — porcelain-v2 `u` records, attributes, `merge-file --zdiff3` documents with collision-
  proof marker size, byte-exact render, hash-guarded atomic save, explicit mark. `ConflictTests` (24 incl. seeded
  property test vs `git merge-file --ours/--theirs/--union`), ADR-0031.
- **P4.12 Resolver UI** — opaque `CodeLinesView` panes (ours | base | theirs, result) with syntax colours, one
  floating glass control group, block actions, manual edit (plain-text editor), undo/redo, external-change banner,
  operation labels (ADR-0033) + one-time rebase explanation. `resolver-merge-resolved-light.png`,
  `resolver-rebase-labels-light.png`, `resolver-cherry-pick-dark.png`.
- **P4.13 Fallbacks** — modify/delete, binary, symlink, submodule, both-deleted, non-UTF-8/oversized; validated
  against the conflict kind inside the gate. Tests in `ConflictTests`, `SafetyRegressionTests`.
- **P4.14 Web links** — github.com / gitlab.com commit and branch links (ADR-0034). `WebLinkTests` (20). Copied
  `https://github.com/octocat/Hello-World/commit/b1b3f97…` from the real clone.
- **P4.15–P4.16 Stash** — core (`StashTests`, 13) and UI: navigator Stashes section, create sheet (⌥⌘S),
  command-bar Stash / Pop, Stash and Switch, drop with SHA.
- **P4.17 Hardening** — independent safety review; all eight findings fixed with regression tests
  (`SafetyRegressionTests`, 11): restore-after-failed-switch honesty, partial-edit detection, missing≠empty hash,
  resolver path containment, fallback validation, pull/abort/skip/delete bound to the state shown, remote delete
  leased, refspec validation, clone TOCTOU.

## Verified
- Tests: `scripts/build/test-core.sh` — GitCore 382, Services 54, Features 70, DesignSystem 15: **521 passed**;
  `scripts/build/test-app.sh` (JitAppTests incl. `Phase4MenuTests`) passed; `scripts/build/lint.sh` clean.
  Skipped: none.
- Real-workflow checks (debug app, isolated `JIT_APP_SUPPORT`, real repositories with a local bare remote and a
  second clone), demo steps from design §1:
  1. Clone: HTTPS clone of `octocat/Hello-World` → new tab; `git/git` cancelled mid-transfer → folder removed.
  2. Fetch updated `origin/main`; Push on a diverged branch → rejection sheet → Force Push with Lease sheet
     (expected SHA, commits lost) → cancelled; remote unchanged.
  3. New branch (Branch ▸ New Branch…), rename (label menu), delete `feature/clean` → `-d` refused → unmerged
     sheet → confirmed `-D`; switch with a dirty `notes.txt` → blocked sheet listing exactly that file → Stash and
     Switch.
  4. Merge `feature/greeting` → banner "Merging … · 1 conflicted file" → resolver: block 1 ours, block 2 theirs,
     block 3 hand-edited → staged diff verified byte-for-byte → Continue → merge commit authored and committed by
     the profile (Ada Lovelace), not the global Git identity.
  5. Rebase with a conflict: labels "Upstream being rebased onto … (ours)" / "Your commit 9cfbcb5 … (theirs)" +
     explanation strip; Skip Commit (confirmed) finished the rebase with profile committer and original author;
     another rebase aborted → working-tree/index/refs/HEAD/state-file fingerprint identical to before
     (`565a977c…` before and after).
  6. Copy Link to Commit on GitHub → exact URL in the clipboard.
  Plus: stash pop with a conflict kept the stash and opened the resolver; resolved; dropped via the confirmation.
- Screenshots: `docs/phases/04-git-workflows-and-conflicts/screenshots/*.png` (5 light, 2 dark; real captures).

## Performance (release build)
| Metric | Previous | Now | Method |
|---|---|---|---|
| Idle CPU after fetch, banner + activity visible | 0.0 % (P3, repo open) | 0.00 %, 0 wakeups / 58 s, 64 MB | `top`/`footprint` on the release app |
| Resolver open, 5,000 lines / 20 blocks | — | 59–60 ms (budget 250 ms) | `load5000LineConflictWith20Blocks`, `-c release` |
| Auth failure (HTTP 401) | — | ~50 ms (debug, isolated) | `authFailureFailsFastWithoutPrompt` |
Details in `docs/performance.md`.

## Decisions
- ADR-0015 — the Phase 3 write gate is the only writer; state tokens + confirmation tokens; Task cancel → `killpg`.
- ADR-0030 — pull = fetch + explicit integration (ff-only default); force push lease-only.
- ADR-0031 — conflict documents from stages via `merge-file --zdiff3` (zdiff3 chosen over diff3), hash-guarded saves.
- ADR-0032 — non-interactive remote environment; `GIT_PROTOCOL_FROM_USER=0` deliberately not set (breaks `file://`).
- ADR-0033 — ours/theirs labels per operation. ADR-0034 — web link mapping.

## Deviations from plan
- `RepoStateToken` is a new type; Phase 3's `RepoRevision` stays the mutation counter (design called it an
  extension of `RepoRevision`).
- `OperationCenter` is per repository session (not one app-wide object); `AppModel` aggregates for quit.
- Activity item is a plain system toolbar item inserted only while there is activity; no custom `glassEffectID`
  morph capsule (the system toolbar glass already provides it).
- Resolver block actions are a plain strip above the result pane and manual edits use a sheet editor, not inline
  per-block buttons / in-place editing.
- Phase 3's DiscardSheet was not rebuilt on `ConfirmationSheet` (same rules; keeps its line preview).
- "Discard These Changes…" on a blocked switch was dropped (design §7 review): Stash and Switch covers it safely.
- Stash inspector shows the stash commit's combined tracked changes, not three sections; no graph "Show stashes".
- `RepoFingerprint` excludes `ORIG_HEAD` (Git rewrites it at every merge/rebase start, even when aborted).
- Two pre-existing debug-build latency assertions (`blameFirstLinesOf5kLineFile`, plus my
  `taskCancellationKillsProcessGroup`) now use `PerfBudget.limit`: they flaked only when the full, larger suite
  saturated the CPU (release numbers are unchanged and recorded separately).

## Bugs found by exercising the app (fixed)
- The tab's error/loading overlay (an `NSHostingView` over the graph) hit-tested to itself and swallowed every
  click on the command bar → hidden once the repository is open.
- `upstream(of:)` used `refs/heads/<b>@{upstream}` (invalid) → Push offered "Publish" for tracked branches.
- Command-bar overflow measured the overflowing content instead of the offered width.
- Stash list requested before the repository finished loading was dropped (Pop stayed disabled).
- Resolver: equal side panes, header/strip layout priorities, unedited-file check, smart quotes in the editor.

## Known issues / carry-overs
- Not exercised by pointer (tests only): pull with merge/rebase from the menu, publish sheet submit, set
  upstream sheet, revert / cherry-pick mainline sheet, remotes sheet, external-change banner, binary/symlink
  fallbacks, quit confirmation with running operations. The session's screen locked near the end of the pass.
- Not captured: Reduce Transparency / Increase Contrast screenshots of banner, sheets and resolver (needs the
  system setting); Instruments Core Animation / GPU while the banner is visible; Leaks over 50 fetch/merge cycles;
  post-operation refresh timing on a 10k-commit repository. Phase 6.
- Navigator stash rows: very long messages truncate; the inspector does not show untracked stash files.
- Timing assertions under heavy external load: with load average 16–27 (other apps saturating the CPU), full
  debug runs twice failed timing-only checks in Phase 0/2 tests (`cancellingAReadKillsTheGroup`,
  `lanesLayout100kUnder150ms`), each passing in isolation; the final full run (load ≈ 11) passed. The Phase 4
  resolver benchmark asserts its 250 ms budget only in release builds (57–60 ms measured). Severity low; Phase 6
  should isolate perf tests from the parallel functional suite.
- Hook output and `remote:` lines appear when Git finishes (not streamed into the activity row).
- Credentials, SSH key selection, host-key acceptance UI, custom CA/proxy → Phase 5 (hook: `ExecContext`).
- Next: Phase 5 (not started).
