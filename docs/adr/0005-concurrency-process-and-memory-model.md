# ADR-0005: Concurrency, process and memory model

- Status: accepted
- Date: 2026-11-09
- Phase: P0
- Requirements: §2.2, §13.5, §14, §15.3, §15.5; ADR-0002

## Context
`GitCore` runs the Git CLI for everything. Every invocation must be cancellable, bounded, unable to
prompt, and must not hold a thread while the child runs. Phase 2+ hold large histories in memory.

### Spike: own `posix_spawn` wrapper vs `swift-subprocess` (2026-11-09)

Both ran `git --version` on the dev machine (M5 Pro, macOS 27.2, release builds) with an explicit
environment, own process group and group teardown. Threads counted with `task_threads` one second after
the command finished:

| Criterion | Own wrapper (`ProcessRunner`) | `swift-subprocess` 1.0.2 |
|---|---|---|
| Process group + group kill | `POSIX_SPAWN_SETSID` + `killpg` | `processGroupID`/`createSession` + `teardownSequence(toProcessGroup:)` ✓ |
| Full env control | ✓ (built from an allowlist) | ✓ (`Environment.custom`) |
| Non-blocking I/O, no thread held | Dispatch read/process sources | ✓ via a kqueue monitor thread |
| Threads alive after one command (idle) | **3** | **9** (persistent kqueue monitor `pthread` + helper threads) |
| Dependencies | none | 1 package (no transitive deps on Apple platforms) |
| Swift 6 strict concurrency | ✓ | ✓ |

The package is good, but its monitor thread stays alive for the process lifetime, which conflicts with
"no idle threads" (§15.3), and the wrapper we need is ~350 lines we fully control.

## Decision

**Process execution — own `ProcessRunner` (no `swift-subprocess`).**
- `posix_spawn` with an argv array; there is no API that takes a shell string.
- Working directory via `posix_spawn_file_actions_addchdir` (macOS 26); stdin `/dev/null`.
- `POSIX_SPAWN_SETSID`: the child gets a new session and process group (pgid = pid) and **no
  controlling terminal**, so neither Git nor ssh can prompt on a tty. (Stronger than `SETPGROUP` alone,
  which keeps the parent's terminal.) Also `POSIX_SPAWN_CLOEXEC_DEFAULT`, default signal dispositions,
  empty signal mask.
- Environment built from scratch (`ProcessEnvironment`): `HOME`, `USER`, `LOGNAME`, `TMPDIR`,
  `SSH_AUTH_SOCK` inherited; minimal `PATH`; `LC_ALL=C`; `GIT_TERMINAL_PROMPT=0`; askpass →
  `/usr/bin/false`; editors → `true`; `GIT_OPTIONAL_LOCKS=0` for reads. Non-interactive keys are applied
  last so no override can re-enable prompts.
- Pipes are non-blocking and read by `DispatchSource` read sources; exit is observed with a
  `DispatchSource` process source plus `waitpid(WNOHANG)` (re-checked on source registration, and
  retried on a 1 ms one-shot timer when `NOTE_EXIT` arrives before the child is reapable — a race
  found by stress-testing). All state for one command is confined to one serial queue; the awaiting
  task suspends on a checked continuation and holds no thread.
- Cancellation is Swift task cancellation only: `withTaskCancellationHandler` → `SIGTERM` to the group,
  `SIGKILL` after a 2 s grace. Timeouts use the same path. After the leader exits, pipes held open by
  leftover group members are given the grace period, then the group is killed.
- Output is bytes (`[UInt8]`), stdout capped per command (`outputTooLarge` kills the group), stderr
  keeps the last 64 KiB. User-facing text comes from our own mapping; raw stderr (C locale) is only a
  redacted `detail`.
- Debug builds assert `dispatchPrecondition(.notOnQueue(.main))` on the spawn path; `run` is
  `@concurrent` so it never inherits the caller's actor.

**Concurrency.**
- `GitCore` APIs are `async throws(GitCoreError)`. `GitEngine` is an actor (no I/O in `init`).
  Phase 1 adds one `actor RepositoryHandle` per open repository that serializes mutations.
- Progress (Phase 4+) uses `AsyncStream` with `.bufferingNewest(1)`, throttled to ≤ 10 Hz.
- Features call `GitCore` from `@MainActor` view models via `Task {}` and never block.
- No idle threads, repeating timers or long-lived processes. Dispatch sources and one-shot timers exist
  only while a command runs. (Long-lived `git cat-file --batch` readers, if added in Phase 2, live only
  while their repository is visible.)

**Memory (rules for Phase 2+).**
- No class instance per commit, ref or diff line. Commit stores are struct-of-arrays of fixed-width
  values (object IDs as 20/32-byte inline values, parent indices as `Int32`), with strings interned.
- Parse Git output as bytes (`-z` NUL-separated formats); materialize `String`s only for visible rows.
- Caches are bounded (count and bytes) and dropped for repositories that are not visible.

## Consequences
- No third-party dependency for process execution; we own the edge cases (and their tests:
  argv, env, caps, timeout, cancellation, group kill, SIGTERM-ignoring children, 64 concurrent children
  without parked threads).
- `setsid` means Git can never ask on a terminal; credential delivery (Phase 5) must go through
  askpass/credential helpers, which is the plan anyway.
- Revisit if `swift-subprocess` drops its persistent monitor thread, or if we need Windows/Linux.
