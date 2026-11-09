# ADR-0027: Per-repository write serialization (FIFO write gate)

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §4.5, §16, §26 (priority 1–2); ADR-0005, ADR-0007

## Context
Every mutation must run alone per repository and in the order the user asked for it (stage, then unstage
of the same file must not swap). `RepositoryHandle` is an actor, but actor isolation does not serialize
async work: a mutation suspends while Git runs, and the actor then accepts the next call (reentrancy).
Two `git add`/`git restore` children could overlap and race on `.git/index.lock`, or finish out of order.

## Decision
- A FIFO `WriteGate` lives inside `RepositoryHandle`. `performExclusive(_:invalidating:_:)` acquires it,
  runs the body (which may suspend any number of times), then records the mutation and releases the gate
  directly to the next waiter, so no third caller can slip in between.
- Waiters park on a `CheckedContinuation`. A caller cancelled while queued leaves the queue and gets
  `.cancelled`; its body never runs. A body that has started is not interrupted by the gate.
- Every finished mutation, success or failure, bumps a monotonic `RepoRevision` and invalidates the status
  cache (`.index`, `.worktree` by default), because a failed Git command may still have changed something.
- Reads (status, numstat, diffs, history) never take the gate. They keep the generation rule: a read
  result older than the current generation is never returned (`staleReadResultsDiscarded`).
- `writeGateState()` reports the running description and the queue; `RepositorySession.pendingWrites`
  surfaces this to the UI.
- `index.lock` held by another process is refused before running Git and mapped from Git's error to
  `GitCoreError.indexLocked`. Jit never deletes lock files.

## Consequences
- Evidence: `writeGateSerializesAcrossAwaits` (two mutations with injected suspension points never
  interleave), `writeGateReportsPendingAndDropsCancelledWaiter`, `stageAndUnstageGoThroughTheGate`.
- The UI may queue several actions quickly; they run in order rather than being rejected.
- One serialization point per repository, inside GitCore, so Phase 4's OperationCenter can sit on top of
  it without a second lock.
- App quit still sends SIGTERM to live process groups, writes included. Quitting must wait for gated writes
  before line-level staging (P3.4) lands.
