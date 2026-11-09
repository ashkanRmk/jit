# ADR-0015: Operation framework — one writer, risk classes, state tokens, cancellation

- Status: accepted
- Date: 2026-11-09
- Phase: P4
- Requirements: §13.5, §14, §16; ADR-0005, ADR-0027

## Context
Phase 4 adds remote, branch, integration, conflict and stash mutations. They must run one at a time per
repository, be cancellable where safe, never prompt, never act on a repository that changed since the user
looked at it, and destructive ones must be impossible to call without the user's explicit confirmation.

## Decision
- **One serialization primitive:** the Phase 3 `actor RepositoryHandle` and its FIFO `WriteGate`
  (`performExclusive`). Every Phase 4 mutation is a method on the handle that runs inside the gate. No second
  queue or lock exists; `OperationCenter` (Services, `@MainActor`, one per repository session) only records
  and displays operations (running + last 20, in memory) and mirrors "Waiting for X".
- **Risk classes by type:** read methods are `nonisolated`; mutating methods take a `RepoStateToken`;
  destructive methods take a `ConfirmationToken` whose initializer is internal to `GitCore` — the only way to
  get one is `ConfirmationRequest.confirm()`, and the method verifies the token names exactly its
  `DestructiveAction` (branch name, remote ref + expected OID, stash index + OID, path + choice).
- **State tokens:** `RepoStateToken` = HEAD OID, HEAD ref, FNV-1a digest of `for-each-ref`, operation state.
  Captured when a sheet is prepared; `ensureCurrent` re-reads it inside the gate and throws `.staleSnapshot`
  before anything runs. Phase 3's `RepoRevision` stays the mutation counter.
- **Cancellation:** cancelling the operation's `Task` → `ProcessRunner` sends SIGTERM to the child's process
  group (SIGKILL after 2 s). Steps that must not be interrupted once started (pull's integration step,
  state read-back after a cancelled fetch/push) run in an `uncancellable` detached task.
- **Progress:** `ProgressSink` parses `--progress` stderr bytes and yields ≤ 10 Hz into an `AsyncStream`
  created with `.bufferingNewest(1)`.
- **Errors:** `GitErrorClassifier` → `GitCoreError.failed(ClassifiedFailure)`; Services maps to
  `PresentableError`. Conflicts are outcomes (`IntegrationOutcome.stoppedWithConflicts`), not errors.

## Consequences
- A destructive call without a confirmation sheet does not compile outside GitCore's module boundary.
- Every stale or refused operation leaves a byte-identical fingerprint (tests).
- Records are per session, so quit lists running operations across tabs via `AppModel`.
