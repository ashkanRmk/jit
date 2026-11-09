# ADR-0033: Ours/theirs labelling per operation

- Status: accepted
- Date: 2026-11-09
- Phase: P4
- Requirements: §8

## Decision
Never "local/remote". `ConflictLabels.make(for:currentBranch:)`:
merge — "Current branch X (ours)" / "Incoming Y (theirs)"; rebase — "Upstream being rebased onto: <onto> +
already-replayed commits (ours)" / "Your commit abc1234 “subject” (theirs)", plus a one-time-per-session strip
explaining the inversion; cherry-pick — current branch / "Picked commit …"; revert — current branch /
"Reverse of …". The sources (MERGE_MSG, rebase-merge files, *_HEAD) are read by `operationState()`.

## Consequences
Labels stay correct for operations started in Terminal; tests check the rebase wording.
