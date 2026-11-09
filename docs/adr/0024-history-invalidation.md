# ADR-0024: History invalidation on ref changes

- Status: accepted
- Date: 2026-11-09
- Phase: P2
- Requirements: §5, §14; ADR-0008, ADR-0010

## Context
Commits, branch moves and fetches made outside Jit arrive as FSEvents on `.git/HEAD`, `refs/` and
`packed-refs`. Reloading all history on every event would flicker and waste work; never reloading would
show stale or unreachable commits.

## Decision
`GitCore.HistoryInvalidation.decide(old:new:history:query:)` → `unchanged | labelsOnly | reload`:
- `unchanged` when the refs revision (FNV-1a of `for-each-ref` output + HEAD) is equal.
- `labelsOnly` when every ref in the view's scope and HEAD point at commits already loaded, every loaded
  branch tip that a ref pointed at is still pointed at, and pinned refs did not move. The controller swaps
  the `RefSnapshot`; visible rows redraw labels; rows, lanes and colours stay.
- `reload` otherwise (new commits, deleted or force-moved branches): `HistoryController` loads a new
  `HistoryLoader` in the background up to max(300, min(loaded, 5000)) rows and swaps atomically; the
  table keeps the selection and the first visible commit by object id.
- Inactive tabs record "dirty" and re-read refs once on activation (their watcher is off).

## Consequences
- Measured: an external commit is visible 37 ms after the refs event (`externalCommitAppearsAsReplacementKeepingRows`),
  plus FSEvents' 0.2 s latency — under the 500 ms target.
- A loaded row's `.head` flag may be stale after HEAD moves; the UI draws the HEAD ring from the current
  `RefSnapshot`, not from the flag.
- Colours of loaded rows are kept on label-only updates (no recolouring on screen) even if a fresh load
  would assign differently.
