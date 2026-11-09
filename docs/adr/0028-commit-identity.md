# ADR-0028: Commit identity application

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6.2, §10.2, §26; ADR-0014

## Context
Jit's profiles (Phase 1) decide who a commit is by. Users often have a different `user.email` in their
global or repository configuration; Jit must never rewrite those files, and a profile switch while a
commit runs must not change the commit already started.

## Decision
- When the user presses Commit, the composer captures `ProfileSnapshot` → `IdentitySnapshot` (author,
  committer). The snapshot is a value: later profile switches cannot affect it
  (`profileSwitchDuringCommitUsesSnapshot`).
- Identity is applied **only** through the child's environment for that one invocation
  (`GitCommand.environment`, merged last): `GIT_COMMITTER_NAME/EMAIL` always; `GIT_AUTHOR_NAME/EMAIL`
  except when amending without "Reset author", so Git keeps the original author. Nothing is written to
  `~/.gitconfig` or `.git/config` (`commitDoesNotModifyAnyConfig` hashes both before and after).
- Repository configuration otherwise applies (`commit.cleanup`, signing, hooks). When the repository's
  resolved `user.email` differs from the profile, the composer says so: "Repository config says … — Jit
  will use the active profile."
- Amend: loads HEAD's message (the draft comes back when amend is turned off); warns when HEAD is already
  in its upstream; offers "Reset author to <profile>" when HEAD's author differs (off by default).
- No active profile → Commit is disabled and the identity line becomes "Choose a profile to commit".

## Consequences
- Evidence: `CommitTests` (11), `CommitComposerTests` (3), Scenario C ends with a commit authored by the
  active profile (`LineActionTests.scenarioCPartialStaging`).
- Identity is never in argv (`-c user.name=…` would show in process listings).
