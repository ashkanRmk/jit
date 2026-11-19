# ADR-0060: Explicit empty-commit and branch-ref policy for interactive rebase

- Status: accepted
- Date: 2026-11-18
- Phase: P8.rebase-interactive

## Decision

Use `--keep-empty --empty=ask`: commits that started empty remain; a commit made empty by replay stops
for an explicit decision. `ask` is Git's backward-compatible spelling for `stop`, including the supported
Git 2.39 baseline. The operation banner offers Skip/Abort; to retain a newly empty commit, create it
explicitly in Terminal before Continue. Jit never silently drops a now-empty commit.

Pass `--no-update-refs`, `--no-autostash`, `--no-autosquash`, `--no-rebase-merges` and `--no-fork-point`
explicitly. The editor's exact actions and order are authoritative; repository preferences cannot
silently stash work, move stacked branches, fold fixup commits or expand a range. `--force-rebase`
ensures edit/reword intentions apply even when the branch is already based on the chosen target.

Other local branches and tags stay at their old tips. Moving stacked branches is a later explicit
feature, not a hidden option. Detect published history against all local remote-tracking refs, without
a network request, and warn in both the editor and confirmation. This is a cache of known remote
history; Jit cannot know about other users' unpublished branches or unfetched server changes.

Commit cleanup is verbatim for Jit's literal prepared messages, and implicit signing is disabled until
Jit's signing configuration exists. Rebase continuations reuse those settings and the original profile
identity; existing non-Jit operation behavior stays unchanged.

## Evidence

`emptyCommitsAreKeptAndNewlyEmptyStepStops` exercises both empty cases against real repositories.
`reorderAndRewordPreservesTreeAuthorsAndOtherRefs` proves a stacked branch stays unchanged.
`planRefusesMergesAndNonAncestorAndDetectsPublishedCommits` checks remote-tracking reachability.
