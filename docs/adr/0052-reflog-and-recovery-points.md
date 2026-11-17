# ADR-0052: Reflog explorer and recovery points

- Status: accepted
- Date: 2026-11-18
- Phase: P8.reflog
- Requirements: §9.2, §13.5, §16, §19; ADR-0005, ADR-0015, ADR-0027

## Context

The 0.0.6 workflows already include amend and confirmed resets. Users need to inspect earlier committed
states and preserve a lost commit without discarding their current work. ADR-0050, the number reserved
in the original Phase 8 plan, is occupied by author pictures; recovery therefore uses 0052.

## Decision

- Read HEAD or an exact local branch in pages of 50 with NUL-delimited `reflog show`. Use `%gD` with
  `--date=raw` for the event timestamp; `%ct` describes the commit and can be months older than a reset.
- A cursor carries the exact reference, offset, log inode/size/nanosecond modification stamp and a
  `RepoStateToken`. Recheck at the end of the read and before appending a later page. Concurrent
  changes or expiration produce a refreshable stale-state error, never silently shifted entries.
- Reachability includes all refs and detached HEAD ancestry. Only the requested page is checked.
  First test whether HEAD is the sole independent tip among HEAD and the page's commits. This proves
  the entire page reachable in one Git call. Otherwise use exact HEAD-ancestry/ref-containment checks,
  with at most four in flight. Multiple independent tips never imply that their ancestors are reachable.
  No full `rev-list --all` enumeration or background scans.
- Find Lost Commits is an explicit cancellable read: `fsck --unreachable --no-reflogs --no-lost-found
  --progress`. Reuse ProcessRunner's task cancellation and process-group teardown. Output is bounded
  to 64 MiB; metadata/results to 2,000 commits, with a visible limit notice. Batch metadata reads and
  mark two/three-parent WIP/On commits as *possible* stashes, not a guaranteed identification.
- Ref-affecting mutations capture previous HEAD and refs **inside the existing writer gate**. Compare
  after execution, including failed/cancelled mutations because they can have changed refs. Preserve
  previous state if final-state inspection fails; never turn a completed mutation into an error only
  because journal inspection failed. File-only writes avoid this overhead and retain the existing
  `RecoveryStore` discard-copy mechanism.
- Stash pop/drop/clear also compare the stash log: removing an older stash can leave the tip unchanged.
  These snapshots have a 2 MiB OID-output bound and fail safely before writing if exceeded.
- The handle keeps at most 50 recovery points. Services persist a bounded, versioned `0600` JSON
  journal in Application Support, separate from the Git repository and the tab-layout JSON. Journal
  I/O runs on its actor, never the UI executor. Reopening the journal does not make old operations
  eligible for the current-session recovery shortcut. The explorer shows saved branch/stash committed
  states; exact metadata for other ref object types is retained without offering commit-only actions.
- Recovery always targets the recorded **full immutable OID**, never an executable `HEAD@{1}` selector.
  “Create Branch Here” defaults to no checkout and validates the state captured when its sheet opens.
  Reset and cherry-pick reuse existing confirmation, identity and conflict workflows. The shortcut
  names the preceding Jit operation and offers branch creation or a confirmed reset; it is not a blind
  inverse operation and promises no recovery of discarded uncommitted edits.
- A selected lost graph tip is a query-only addition, with dashed edges at its tip and a removable
  Recovery chip. It is not persisted in tab filters and creates no repository ref.

## Consequences and verification

- Recovery cannot resurrect objects Git has already pruned. The journal is metadata, not a backup.
- Closing/hiding a tab cancels reflog and fsck reads; resuming revalidates the list. The covered graph
  is hidden from keyboard and accessibility navigation while the explorer is open.
- Real-repository tests cover timestamp correctness, action classification, changed/expired cursors,
  SHA-256, detached HEAD, dropped stashes, state safety and partial failures. The deterministic fsck
  cancellation fixture delays the **real** Git invocation and verifies both its wrapper and child die.
- Native QA recovered an amended-away commit into a new branch while leaving HEAD, index, tracked
  files and an untracked notes file unchanged. Light/dark and opaque-chrome snapshots are recorded.
- Measurements and final test results belong in `progress-reflog.md`, including any unmet target.

Git semantics: [reflog](https://git-scm.com/docs/git-reflog),
[fsck](https://git-scm.com/docs/git-fsck),
[independent tips](https://git-scm.com/docs/git-merge-base).
