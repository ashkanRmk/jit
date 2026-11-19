# ADR-0063: Direct commit message edits and drops

- Status: accepted
- Date: 2026-11-19
- Phase: P8.commit-surgery
- Requirements: §9.2, §13.5, §16; ADR-0015, ADR-0052, ADR-0059/0060

## Context

Editing one commit message or dropping one commit should not require configuring the general rebase
editor. Reusing its replay engine preserves the existing conflict, continuation and recovery behavior.
HEAD also needs a message-only path that preserves root and merge commits and cannot accidentally
include staged changes.

## Decision

- Prepare a repository-created `CommitSurgeryPlan` with immutable action, selected OID, original
  message/author, originating worktree git directory, repository state and private replay plan. Only the replacement message is editable.
  Require an attached branch, no operation in progress and a clean tracked index/worktree. Untracked
  files remain untouched, subject to Git's obstruction checks during replay.
- For an older message edit or any supported drop, select the commit's sole parent as the rebase
  boundary and generate exactly one reword/drop step; keep later commits in order. Reuse the validated
  bounded linear range, publication flags, private messages, helper, writer and explicit no-update-refs
  policy. Refuse off-branch commits, root/merge drops and older ranges containing merges.
- For a HEAD message edit, run `commit --amend --only --allow-empty --cleanup=verbatim -F -` inside the
  writer. Recheck repository state and clean tracked files immediately before writing. This preserves
  the tree, parents and original author, including root and merge HEADs. Feed the message through stdin;
  the profile captured at confirmation supplies the committer. Hooks run; implicit signing is disabled
  consistently with interactive rebase until signing has its own UX.
- Accept nonblank UTF-8 messages up to 1 MiB without NUL. Read the original raw commit message without
  Git's display formatting; refuse invalid UTF-8 instead of silently replacing bytes. Use a native
  plain-text editor with smart substitutions disabled, so quotes, shell syntax and comment lines remain
  literal.
- Edit Message opens the focused message sheet, then review with the replacement text. Drop opens
  review directly. Both show the selected commit, affected count, author, active identity, known
  publication warning and copyable previous tip. Return/Escape cancel review; only the explicit action
  button mints authorization. Editing after confirmation invalidates the exact payload token.
- Bind replay authorization to its plan ID and complete steps; bind HEAD authorization to its plan ID,
  OID and replacement message. Revalidate the captured repository state inside the serialized writer.
  Existing operation tracking, resolver, Continue/Skip/Abort and persistent recovery journal apply.
- Cancel stale asynchronous preparation and guard publication by generation, session lifecycle and
  current sheet/editor state. Graph menus explain disabled multi-selection and unsupported commit shapes;
  the core performs the authoritative reachability and state checks.

## Verification

Real-repository tests cover HEAD/older/root/merge message edits, middle/HEAD drops, literal text,
unchanged trees/parents/authors/other refs, dirty/staged/stale/off-branch/detached refusals, changed tokens,
hook rejection, a dependent drop conflict followed by Abort, and recovery of removed changes.
Controller, snapshot and native graph-menu evidence is recorded in
[the implementation report](../phases/08-post-v1/progress-commit-surgery.md).
