# Phase 4 — Everyday Git workflows & conflicts: implementation plan

Design: [`design.md`](design.md). Requirements: §8, §9.1, §13.5, §14, §16. Invariants: roadmap §6.
All code is Swift (ADR-0002): Git logic in the `GitCore` target, tests via `swift test` using `GitTestKit`;
UI follows ADR-0006 (macOS 26+, Liquid Glass chrome, opaque content).

## 1. Preconditions

- Phase 3 `progress.md` shows its exit gate passed (or carry-overs accepted). In particular:
  - Phase 0: `ProcessRunner` (`posix_spawn`, argv, cwd, sanitized env, own process group, Dispatch-source
    I/O, Task cancellation → `killpg`), typed `GitError`, `GitTestKit` fixture builder, `DesignSystem`
    glass usage rules.
  - Phase 1: `RepositorySession`, FSEvents invalidation (including the git dir), identity-only profiles
    with an active-profile snapshot.
  - Phase 2: graph + navigator with read-only context menus and placeholders removed (not stubbed).
  - Phase 3: native text/diff renderer reusable for read-only and editable panes; `actor RepositoryHandle`
    as the per-repo serial writer with `RepoRevision` tokens; commit composer applying the profile
    identity; discard flow with confirmation.
- Git version on the machine ≥ the ADR-0006 minimum; record whether ≥ 2.38 (`merge-tree --write-tree`)
  and ≥ 2.35 (`zdiff3`).
- Network access for the public-clone demo (any small public GitHub repository).

## 2. Milestones

Each milestone: spec in `specs/P4.k-*.md` → tests → implementation → verification → commit(s).

### P4.1 — Operation framework and execution context
Goal: every mutating Git call goes through one framework with risk classes, serialization, revision
tokens, non-interactive execution, progress and classified errors.
- [ ] `GitCore`: lift the Phase 3 `actor RepositoryHandle` into the operation framework — strict FIFO of
      mutating requests inside the actor (safe across suspension points), `nonisolated` snapshot reads.
      No additional lock or queue elsewhere (ADR-0015).
- [ ] `GitCore`: `RepoRevision` capture + `ensureCurrent(expected)`; `GitError.staleSnapshot`.
- [ ] `GitCore`: `ExecContext(identity:auth: .nonInteractive, network: .systemDefault)` and
      `GitEnvironment.remoteCommand` applying the env/`-c` layers from design §4.3.
- [ ] `GitCore`: `ProgressParser` (byte-level CR/LF splitting, phases, `remote:` lines) + throttle (≤ 10 Hz)
      feeding a bounded `AsyncStream<OperationProgress>` (`.bufferingNewest(1)`).
- [ ] `GitCore`: `GitErrorClassifier` covering every §16.4 row in design §4.11; `Redactor.redact`.
- [ ] `GitCore`: `ConfirmationToken` struct with an `internal` initializer that only the confirmation API
      (`ConfirmationRequest.confirm()`) can mint; it records the confirmed request digest and destructive
      methods verify it — enforced by Swift access control, not convention.
- [ ] `Services`: `OperationCenter` (`@MainActor`; submits to handles, mirrors pending FIFO for UI,
      lifecycle model, bounded history 20, snapshot at enqueue, cancellation = cancelling the operation's
      `Task`, targeted invalidation dispatch).
- Files: `macos/Packages/JitKit/Sources/GitCore/{Operations,Execution,Progress,Errors}/`,
  `macos/Packages/JitKit/Sources/Services/OperationCenter/`.
- Tests (Swift Testing, `swift test`): `execEnvIsNonInteractive`, `execEnvContainsNoUserDerivedCValues`,
  `progressParsesFetchClonePushSamples` (captured stderr fixtures), `classifyMapsAll16_4Cases`
  (fixture stderr per case), `redactStripsUserinfoAndTokenPrefixes`, `writerSerializesMutationsAcrossSuspension`
  (many concurrent tasks, interleaving detector), `staleRevisionRejected`,
  `taskCancellationKillsProcessGroup` (child + grandchild gone), `progressStreamDropsStaleValues`,
  `OperationCenterTests` (ordering, cancel, snapshot immutability across profile switch).
- Verify: run a fake hanging credential scenario (`GIT_ASKPASS` path) against a local HTTP server that
  returns 401 → operation fails in < 2 s, no hang.
- Done when: all mutating APIs from Phase 3 (stage/unstage/discard/commit) run through the framework
  unchanged in behavior, and the tests pass.

### P4.2 — Activity UI, confirmation sheet, error presentation
- [ ] `OperationActivity` toolbar item (standard toolbar item inside the system glass toolbar; running
      state as a `glassEffect` capsule morphed with `glassEffectID` on start/finish only) + system popover
      (design §3.1).
- [ ] `ConfirmationSheet` component (design §3.2) on a standard system sheet (glass treatment by default)
      and `ConfirmationRequest` model (title, context, changes, losses, recoverability, verb). Retrofit
      Phase 3 discard to use it.
- [ ] `PresentableError` mapping + error view with recovery actions; Unknown errors show sanitized detail.
- [ ] Repository menu: Show Activity.
- Tests: snapshot tests (light/dark, plus Reduce Transparency) for activity states, sheet, error view;
  UI test: Escape/Return never triggers destructive button.
- Done when: screenshots reviewed in both themes and with Reduce Transparency; activity item is not
  drawing when idle (verify with Instruments "Core Animation" — no commits while idle, no ongoing GPU work
  from the glass capsule).

### P4.3 — Operation-state detection and banner
- [ ] `GitCore` `OperationStateDetector` via `--git-path` (merge, rebase-merge, rebase-apply/am,
      cherry-pick, revert, sequencer, bisect).
- [ ] Banner model + view as a floating Liquid Glass bar with warning tint (design §3.3); buttons grouped in
      one `GlassEffectContainer`; content inset adjusted while shown; opaque `DesignSystem` fallback under
      Reduce Transparency; FSEvents-driven refresh; actions wired as each operation lands
      (continue/skip/abort enabled in P4.9–P4.10).
- Tests: `stateDetects{Merge,RebaseMerge,RebaseApply,Am,CherryPick,Revert,Sequencer,Bisect}`
  (fixtures that create each state with Git), `stateInLinkedWorktree`; UI snapshot of each banner in
  light, dark and Reduce Transparency.
- Verify: start a conflicting merge in Terminal → banner appears without user action.

### P4.4 — Fetch, ahead/behind, remotes inspector
- [ ] `fetch` (remote / all, explicit prune flag mirroring effective `fetch.prune`).
- [ ] Ahead/behind via `for-each-ref` upstream track; `[gone]` handling; badges in toolbar + navigator.
- [ ] Remotes inspector (read-only; masked credentials in URLs with warning).
- Tests: `fetchUpdatesRemoteRefs` (local bare remote), `fetchPruneExplicit`, `fetchCancelLeavesRefsConsistent`
  (cancel the Task mid-transfer on a large synthetic pack served via `file://`; refs either old or new,
  `git fsck --connectivity-only` clean), `aheadBehindCounts`, `upstreamGoneDetected`, `remoteURLUserinfoMasked`.
- Verify: fetch a real public repo; cancel a fetch; inspect remotes.

### P4.5 — Pull
- [ ] Two-step pull: fetch + `merge --ff-only` (default) / `merge --no-edit` / `rebase --no-autostash
      --no-update-refs`; outcomes per design §4.6; `NotFastForward` sheet offering merge/rebase.
- Tests: `pullFFOnlyFastForwards`, `pullFFOnlyRefusesDivergentWithoutChanges` (fingerprint
  unchanged), `pullMergeCreatesMergeCommitWithProfileCommitter`, `pullRebaseReplays`,
  `pullIgnoresPullRebaseConfigForExplicitChoice`, `pullConflictEntersState`.
- Done when: divergent pull never integrates without an explicit choice.

### P4.6 — Push
- [ ] `push --porcelain` parsing per ref; publish sheet (`-u`); rejection sheet by cause; force-with-lease
      with `--force-if-includes` via destructive sheet.
- Tests (local bare remote, two clones): `pushFastForward`, `pushPublishesAndSetsUpstream`,
  `pushRejectedNonFFClassified`, `pushRejectedByHookShowsRemoteLines` (pre-receive hook in bare
  remote), `forceWithLeaseSucceedsWhenExpectedMatches`, `forceWithLeaseFailsWhenRemoteMoved`
  (remote unchanged afterwards), `pushCancelReportsActualRemoteState`.
- Verify: demo step 2.

### P4.7 — Clone from URL
- [ ] Clone sheet (standard system sheet; validation, destination, derived name, progress, cancel, retry);
      new-tab page entry; File ▸ Clone…; opens in new tab.
- [ ] Scheme allowlist; `http://` confirmation; destination-created marker for cleanup; `.gitmodules` note.
- Tests: `cloneFileURLSucceeds`, `cloneRejectsDashPrefixedURL`, `cloneRejectsExtProtocol`,
  `cloneCancelRemovesCreatedDestination`, `cloneCancelPreservesPreexistingEmptyFolder`,
  `cloneIntoNonemptyFolderBlocked`, `cloneAuthRequiredFailsFastNonInteractive` (local HTTP 401).
- Verify: clone a public GitHub repo over HTTPS; cancel one midway; check directory state.

### P4.8 — Branch operations + Phase 2 write actions
- [ ] Create (from any commit/ref), switch (incl. remote → tracking, detached with explanation), rename,
      delete (`-d` then `-D` flow), delete remote, set/unset upstream.
- [ ] Switch blocked by dirty tree: path list + Cancel / Discard These Changes… (path-scoped, destructive;
      drop if the P4.8 review finds it unsafe — design §7).
- [ ] Enable navigator double-click checkout and graph/navigator context-menu write actions.
- Tests: `branchNameValidatedByGit`, `switchCarriesNonConflictingChanges`,
  `switchBlockedListsPathsAndChangesNothing` (fingerprint), `checkoutRemoteCreatesTracking`,
  `renameKeepsUpstream`, `deleteUnmergedRequiresForceToken`, `deleteRemoteBranch`,
  `setUnsetUpstream`, `branchOpsStaleRevisionRejected`, `switchToBranchInOtherWorktreeRefused`.
- Verify: all context-menu actions on a real repo; light/dark screenshots of sheets.

### P4.9 — Merge and rebase
- [ ] Merge sheet (ff / no-ff / ff-only, message, identity line, preflight warnings).
- [ ] Rebase sheet (commit list, pushed-commits warning, clean-tree requirement).
- [ ] Continue / skip (destructive) / abort (destructive when resolutions exist) wired into the banner.
- [ ] Optional: `merge-tree --write-tree` conflict prediction (design §7).
- Tests: `mergeFF`, `mergeNoFFIdentityFromProfile`, `mergeFFOnlyRefuses`, `mergeConflictState`,
  `mergeAbortRestoresFingerprint`, `mergeWithUnrelatedDirtyChangesPreserved`,
  `rebaseCleanReplaysWithProfileCommitterAndOriginalAuthor`, `rebaseConflictStateStepCounts`,
  `rebaseContinueAfterResolution`, `rebaseSkipDropsCommit`, `rebaseAbortRestoresFingerprint`,
  `rebaseRequiresCleanTree`, `rebaseIgnoresAutostashConfig`.

### P4.10 — Cherry-pick and revert
- [ ] Multi-commit cherry-pick in topological order; revert; mainline selection for merge commits.
- Tests: `cherryPickPreservesAuthorSetsCommitter`, `cherryPickMultiOrder`, `cherryPickConflictContinue`,
  `cherryPickAbortRestoresFingerprint`, `cherryPickMergeCommitRequiresMainline`,
  `revertCreatesCommitWithProfileIdentity`, `revertConflictAbort`.

### P4.11 — Conflict model
- [ ] `conflicts()` from porcelain v2 `u` + `ls-files -u` cross-check; kind + attribute classification.
- [ ] `loadConflict` via stage blobs + `merge-file --diff3` (or zdiff3 per spike) → byte-buffer segments
      (ranges, no per-line objects); working-tree reconciliation hash.
- [ ] `saveResolution` (hash guard, atomic write, mode preserved), `markResolved`, `resolveWithSide`.
- Tests: `conflictKinds{UU,AA,UD,DU,AU,UA,DD}`, `conflictBinarySymlinkSubmoduleDetected`,
  `conflictDocumentSegmentsMatchGit` (compare re-serialized document with Git's marker output),
  `conflictCRLFPreserved`, `conflictNoTrailingNewlinePreserved`, `conflictUnicodePath`,
  `saveRefusesWhenFileChangedExternally`, `saveIsAtomicAndKeepsMode`,
  `markResolvedRequiresMatchingHash`, `openingDoesNotMarkResolved` (index still unmerged after
  load), seeded randomized test (fixed seeds, many iterations): random three-way edits → taking ours
  everywhere yields stage 2 content merged with Git's clean regions exactly.

### P4.12 — Conflict resolver UI
- [ ] Three-pane (+ optional base) resolver on the Phase 3 renderer; block navigation; take ours/theirs/
      both (either order); manual edit; undo; save; mark resolved with marker-guard confirmation.
- [ ] Chrome/content split (design §3.8): header block navigator and footer actions as one floating
      `GlassEffectContainer` control group (Mark as Resolved `.glassProminent` when primary); ours/theirs/
      base/result panes opaque `DesignSystem` surfaces; per-block inline actions are plain buttons.
- [ ] Operation-specific labels (design §3.8 table) + one-time rebase explanation strip.
- [ ] External-change banner (Reload / Keep My Result).
- Tests: UI tests for take-ours/theirs/both, manual edit, mark-resolved disabled with unresolved blocks,
  stale-file banner; snapshot tests (light/dark/Reduce Transparency) for merge and rebase labelling.
- Verify: demo steps 4 and 5 on real repos; measure resolver open time on a 5,000-line conflicted file;
  scroll the result pane under the glass controls and confirm text stays crisp and 60 FPS holds.

### P4.13 — Non-text conflict fallbacks
- [ ] Modify/delete, delete/modify, binary, symlink, oversized/non-UTF-8, rename cases, submodule
      explanation (design §3.9), each through a confirmation.
- Tests: `resolveModifyDelete{Keep,Delete}`, `resolveBinary{Ours,Theirs}`, `resolveSymlink`,
  `submoduleConflictOffersTerminalOnly`, `renameRenamePathsReported`.

### P4.14 — Copy remote links
- [ ] `WebLink.map` for github.com and gitlab.com (https, ssh://, scp, ports, nested namespaces, `.git`
      suffix, percent-encoding); menu items only when mappable.
- Tests: parameterized `@Test(arguments:)` `webLink*` cases including unknown hosts → `nil`.

### P4.15 — Hardening, review, docs
- [ ] Full integration matrix (§3 below) green; interrupted-operation tests; locked-index tests.
- [ ] Strict self-review (§25 step 5): data-loss paths, races (profile switch, tab close mid-op, external
      edits), main-thread blocking, leaks (Instruments Leaks while running 50 fetch/merge cycles).
- [ ] Update docs (§5 below), write ADRs 0015, 0030–0034, finalize `progress.md`.

## 3. Test plan summary

All Git tests use real temporary repositories from `GitTestKit` and run with `swift test`; remotes are
local bare repositories (`file://`) or a local HTTP server fixture (a small `GitTestKit` helper on
Network.framework, or `git http-backend` behind it) for auth-failure cases.

- **Fingerprint helper (add to `GitTestKit`):** `RepoFingerprint.capture(repo)` = `HEAD` (symbolic +
  OID), all refs (`for-each-ref`), index (`ls-files -s --debug`-free form: mode, OID, stage, path),
  working-tree file hashes (including untracked, excluding `.git`), operation-state files. Every abort,
  refusal and cancel test asserts `before == after`.
- **Matrix:** dirty trees (staged, unstaged, untracked, partially staged) × {switch, merge, rebase,
  cherry-pick, pull}; conflicts in merge/rebase/cherry-pick/revert; abort restores state; locked index
  (`index.lock` present) for every mutating op; rejected push variants; interrupted fetch/clone/push
  (SIGTERM at random points across 20 runs); external edits during resolution; CRLF, no trailing newline,
  Unicode and space-containing paths; linked worktrees.
- **App / UI (Xcode):** `OperationCenter` unit tests; UI tests for confirmation semantics, banner actions,
  resolver flows; snapshot tests for every new screen and state in light, dark and Reduce Transparency.

## 4. Performance checks (release build)

| Check | Target |
|---|---|
| Idle CPU after a completed fetch/merge | back to Phase 3 baseline (0.0–0.2 %) within 2 s |
| Activity item / banner while idle | zero Core Animation commits |
| Post-operation refresh (10k-commit repo, fetch with 50 new commits) | graph updated < 150 ms after Git exits, no full reload |
| Resolver open, 5,000-line file with 20 blocks | < 250 ms to first paint |
| Memory after closing resolver | returns to pre-open level (± 2 MB) |
| Progress stream rate | ≤ 10 Hz to the main actor; stream buffer bounded to 1 |
| Glass chrome (banner shown, activity capsule visible) while idle | no ongoing GPU/CPU work (Instruments) |

## 5. Docs to update

- `docs/architecture.md`: operation framework (single actor writer), execution context layers, state
  detection, conflict model.
- `docs/design-system.md`: banner glass bar, activity capsule, resolver floating control group, Reduce
  Transparency fallbacks.
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
- [ ] Glass only on chrome (toolbar items, banner, sheets, popovers, resolver controls); all text panes and
      lists opaque; Reduce Transparency verified.
- [ ] Idle CPU and memory re-measured; no regression.
- [ ] Roadmap §9 gate items 1–8 satisfied.
