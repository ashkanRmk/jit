# ADR-0061: Preview-bound reset and stash-first recovery

- Status: accepted
- Date: 2026-11-18
- Phase: P8.reset
- Requirements: §9.2, §13.5, §16; ADR-0015, ADR-0027, ADR-0052

## Context

The basic reset menu confirmed only a target and mode. A user could not inspect the local changes or
commits affected, and recovering committed history did not recover discarded local edits. Git's hard
reset may also overwrite untracked files that obstruct target paths.

## Decision

- Use typed soft/mixed/keep/hard modes. Prepare an immutable read-only preview for a full commit OID.
  Count commits removed from HEAD ancestry, commits no longer reachable from target or other current
  refs, and removed commits reachable from remote-tracking refs. Show the first five unreachable
  subjects. Existing stash refs count as refs; a newly created recovery stash can retain more history.
- Bind the confirmation token to the preview UUID, normalized target, mode and stash choice. Recheck
  repository root, HEAD/ref/operation state, logical index entries/flags, raw porcelain-v2 status, all refs, and changed
  file contents inside the existing writer gate. Refuse stale previews before any mutation. File reads
  use descriptor-relative parent traversal without following symlinks; regular files are hashed in
  bounded chunks with metadata revalidation. Symlinks are hashed as link text.
- Hard and keep reset inspect target paths and refuse untracked, ignored, directory or parent-path
  obstructions, even with stash-first. This deliberately protects more local data than raw Git.
  Refuse hidden index entries for these modes, conflicted/in-progress operations and unborn HEAD.
  Invoke reset with `--no-recurse-submodules` regardless of configured recursive behavior.
- Default stash-first on for dirty hard resets; include untracked files. Require a profile only when
  actually creating a stash. Refuse dirty submodules, nested repositories and unsupported file types
  that an outer stash cannot safely save. Stash and reset share one writer job and one invalidation.
- Validate again after stash: unchanged HEAD/current branch, no unrelated ref changes, no remaining
  local changes or obstructions. Stash failure prevents reset. Once execution starts, caller
  cancellation cannot interrupt the chain. This is serialized execution, not a filesystem transaction:
  external tools can still race Git, and failures may have partial effects.
- Keep a successful stash on any subsequent failure, report its exact SHA, and never automatically
  apply/pop it onto a different base. Reuse the existing previous-HEAD recovery journal and Stashes UI.
  Recover committed history as a branch from Reflog, then restore the stash on that branch.
- Graph and Reflog offer all four preview sheets. Cancel remains the default keyboard action; hard
  reset retains the arming delay. Disable execution for blocked paths or missing stash identity.
  No polling or background history scans; dismissing a preview cancels its read work.

## Consequences and verification

This API replaces the string-mode reset entry point; all callers must first obtain a preview. Large
dirty files require content reads, and large trees require obstruction checks, so preview preparation
stays off the main actor and is cancellable. Unsupported paths/flags require explicit handling outside
this workflow. Reflog/journal recovery remains subject to object retention and pruning.

Real repositories cover mode semantics, reachability, SHA-256/detached HEAD, content/index/ref changes,
token binding, obstructions, nested repositories, binary/rename/symlink stash recovery, identity,
controlled command failures and cancellation while another writer waits. UI fixtures exercise recovery
through the journal, Reflog and branch creation; light/dark snapshots cover stash, discard, keep and
blocked states. Measurements and actual final results are in `progress-reset.md`.

Git semantics: [reset](https://git-scm.com/docs/git-reset), [stash](https://git-scm.com/docs/git-stash).
