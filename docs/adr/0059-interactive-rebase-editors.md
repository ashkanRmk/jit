# ADR-0059: Native interactive rebase with prepared editors

- Status: accepted
- Date: 2026-11-18
- Phase: P8.rebase-interactive
- Requirements: §8, §9.2, §13.5, §16; ADR-0016, ADR-0027, ADR-0052

## Decision

Use native `git rebase -i` and extend the bundled `jit-git-helper` with `sequence-editor` and
`message-editor` modes. The generated todo contains only validated actions and full original commit
IDs. User-authored messages go through private files, never shell commands or process arguments.
Only the helper's quoted executable path and a constant subcommand appear in Git's editor commands.
The helper compares canonical filesystem paths: Foundation path normalization can collapse macOS's
`/private/var` alias and must not invalidate the binding to Git's editor target.

Plans capture HEAD, symbolic branch, all refs and operation state. The destructive confirmation binds
both the plan ID and exact step array; execution checks it and the snapshot inside the existing writer.
Detached/unborn HEAD, active operations, dirty tracked files, non-ancestor bases, merge-containing
ranges and more than 500 commits are refused. Graph “from here” includes the selected commit by using
its parent as the excluded base. Root-inclusive and merge-preserving rebases remain unsupported.

Private preparation is stored per worktree under `gitDirectory/jit-interactive-rebase` (0700 directory,
0600 todo and manifest). This intentionally survives conflicts, edit stops and app relaunch. It stores
literal messages and the captured identity, with no credentials. Continue/Skip bind it to Git's
`orig-head`, `head-name` and `onto`; a missing helper or mismatched preparation refuses continuation
and preserves data. Abort needs no editor helper. Finished/aborted operations remove the preparation;
an externally completed rebase can leave preparation until the next Jit rebase replaces it.

Messages are selected by the original object ID in Git's completed todo, including squash/fixup
chains. An editor-call counter is unsafe: conflict continuation can invoke an extra editor, while
skip can remove an invocation. Authors stay with their commits; the captured profile supplies the
committer across continuation and relaunch. Edit stops use Git's `amend` marker and route to Working
Directory. Existing sequencer controls, rebase-specific conflict labels and recovery journal are reused.
Progress reads sequencer counters on stderr events through the existing throttled sink, with no timer.

## Spike

`scripts/testing/rebase-editor-spike.py` compares native reword editors and generated `pick` +
`exec git commit --amend -F` lines on real 50-commit repos. Both preserved all exact multiline/Unicode
messages, tree and authors. In this run (Git 2.56.1), native editors took 2.063 seconds and exec/amend
1.779 seconds; these are single observations, not performance guarantees. The native editor approach
keeps Git's reword/squash semantics and avoids custom shell commands in its sequencer todo.
[Recorded result](../phases/08-post-v1/benchmarks/rebase-editor-spike.json).

## Verification

Real repository tests cover all six actions, squash/fixup chains, all-drop, literal shell syntax in
messages/helper paths, conflict/continue, edit/amend/continue after reopening, skip, abort, stale
confirmation, dirty trees, published detection, initial/newly empty commits and a mixed ten-commit
workflow. Feature tests cover confirmation, cancellation and execution through RepositorySession.
