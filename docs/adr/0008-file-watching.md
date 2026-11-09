# ADR-0008: File watching

- Status: accepted
- Date: 2026-11-09
- Phase: P1
- Requirements: §4.3, §14, §15.3–§15.4; ADR-0005, ADR-0007

## Context
Counts, HEAD and operation state must update within about half a second of changes made outside Jit
(editors, Terminal), while an idle app — and every hidden tab — does no work. Options: polling (forbidden),
per-file FSEvents (`kFSEventStreamCreateFlagFileEvents`, high event volume on builds), directory-level
FSEvents, kqueue per directory (doesn't scale), relying on `core.fsmonitor` (opt-in per repository).

## Decision
- One directory-level `FSEventStream` per **active** repository session (visible tab, active app, window
  neither miniaturized nor occluded), flags `UseCFTypes | WatchRoot`, latency 0.2 s (FSEvents' own
  coalescing; no timers of ours), scheduled on a private serial dispatch queue. Roots: worktree plus any
  git/common directory outside it; the git dir for bare repositories.
- A pure classifier maps each path to `InvalidationKind`s (worktree, index, head, refs, config,
  operationState) or ignores it (`objects/`, `logs/`, `*.lock`, …). Directory-level events for the git dir
  itself invalidate all git-dir kinds. Dropped/must-rescan → everything; root changed → existence check.
- Each batch invalidates the `RepositoryHandle` generation and schedules one refresh; refreshes coalesce
  (one in flight + one queued) at the session and in the handle.
- Status runs with `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0` so it never rewrites `.git/index`
  (which would fire FSEvents → status → … a CPU feedback loop). Proven by an mtime test with a control.
- Leaving the foreground stops the stream; returning revalidates once. Jit does not enable or disable
  `core.fsmonitor`; Git uses it if the user configured it.

## Consequences
- Zero callbacks and zero Git runs in the background (verified by a callback counter and idle sampling).
- Heavy churn in ignored build output still produces coalesced status runs while the tab is visible;
  ignore-aware filtering is a Phase 6 option if the measured cost (progress.md) matters.
- Changes made while a tab is hidden appear on its next activation (one revalidation), not live.
