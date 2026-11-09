# ADR-0014: Git hooks policy

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6.2, §16, §19; ADR-0028

## Context
Repositories ship hooks (pre-commit, prepare-commit-msg, commit-msg, post-commit) that teams rely on for
checks and formatting. A Git client that silently skips them breaks those workflows; one that hides their
output leaves users guessing why a commit failed. Hooks are also code from the repository that runs on
the user's Mac.

## Decision
- Commits run hooks exactly as Git does: Jit invokes `git commit` and adds nothing that changes hook
  behaviour. No editor ever opens (`GIT_EDITOR=true` in the sanitized environment; the message comes on
  stdin with `-F -`).
- The combined output of Git and the hooks is shown in the composer's "Hook output" disclosure after the
  attempt; a failing hook's exit status and output are shown as the error. (Live streaming during the
  hook run is not built; the output appears when Git finishes.)
- `--no-verify` is offered only through the explicit secondary item "Commit Without Running Hooks…",
  which asks for confirmation each time and is never remembered.
- Cancelling a running commit kills its process group, hooks included (`commitCancelKillsHook`).
- `docs/security.md`: opening a repository and committing can execute that repository's hooks, as Git does.

## Consequences
- Evidence: `CommitTests.commitHookFailureReportsOutput`, `commitNoVerifyOnlyWhenRequested`,
  `commitCancelKillsHook`.
- Long hooks show only a spinner until they finish (no partial output yet).
