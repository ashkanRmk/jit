# ADR-0030: Pull is fetch + explicit integration; force push is lease-only

- Status: accepted
- Date: 2026-11-09
- Phase: P4
- Requirements: §9.1, §16

## Context
`git pull` integrates according to user configuration (`pull.rebase`, `pull.ff`), so the same button can
merge, rebase or refuse. Plain `--force` overwrites commits others pushed.

## Decision
- Pull = `fetch <upstream remote>` then exactly one of: `merge --ff-only <upstream>` (default; diverged →
  `NotFastForward` without running Git), `merge --no-edit --ff <upstream>`, or
  `rebase --no-autostash --no-autosquash --no-update-refs <upstream>`. `git pull` is never invoked, so
  `pull.*` configuration cannot change the chosen action. Rebase/merge flags are explicit for the same reason.
- Force push is only `forcePushWithLease(expected:token:)` →
  `--force-with-lease=refs/heads/<b>:<expected> --force-if-includes`, offered from the rejection sheet and
  branch menus through a high-risk confirmation that shows the expected remote SHA and the commits that would
  leave the branch. The source contains no `"--force"` / `"-f"` argument (test).

## Consequences
Divergence always needs an explicit choice. If someone pushed after the last fetch, the lease fails and the
remote is unchanged (`forceWithLeaseFailsWhenRemoteMoved`).
