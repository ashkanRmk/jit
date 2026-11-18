# ADR-0062: Tag management and exact-object deletion

- Status: accepted
- Date: 2026-11-18
- Phase: P8.tags
- Requirements: §9.2, §13.5, §16; ADR-0015, ADR-0027, ADR-0052

## Context

Basic name validation, lightweight/annotated creation and single-tag push existed in the graph menu.
Remaining management needs tag metadata, local and remote deletion, recovery values and discoverable
sidebar/palette actions. Annotated tag object IDs differ from their target commit IDs; comparing or
saving only the commit loses the annotation and can confirm the wrong object.

## Decision

- Keep `check-ref-format refs/tags/<name>` as the name authority. Creation resolves the selected full
  OID to a commit and uses Git's create-without-force behavior. Return the created direct object OID
  inside the writer so optional push can refuse a locally replaced tag. No global Git config changes.
- Annotations require the captured profile's committer identity and a nonempty message (at most 1 MiB,
  no NUL). Write it in a fresh 0700 directory as a 0600 file; `tag -a --cleanup=verbatim -F <file>` keeps
  comment lines and formatting. A defer removes it on success, error or cancellation. Disable implicit
  tag signing until the signing epic supplies its own UX. Lightweight tags require no identity.
- Read metadata only on demand from the exact object: type, fully peeled target/type, tagger/date and
  annotation. Bound raw object output to 4 MiB and displayed annotation to 16,384 characters, with a
  truncation notice and Copy Full Message. Existing signature blocks are omitted from message display;
  the UI makes no verification claim. Blob/tree/nested/SHA-256 tags remain manageable.
- Local deletion binds confirmation to tag name/direct OID and binds details to the repository. Recheck
  repository state and tag identity inside the writer, then use `update-ref --no-deref -d <ref> <old>`.
  The CAS closes the external-ref-change race; no dereferencing of a symbolic tag into another ref.
  Refuse symbolic tags. The existing journal saves the direct object, preserving the annotation for
  exact restoration with Git before pruning. Return both object and target; leave working files alone.
- Push an immutable source OID to exactly one tag ref. Explicitly disable follow-tags, mirror and recursive
  submodule push regardless of config. No forced tag replacement. Treat porcelain rejection as failure
  even if the process exits zero, while retaining authentication/transport classification.
- Remote deletion previews the direct OID at the effective push URL, not the fetch URL. Support a
  distinct push destination and normalize relative local paths to avoid accidental remote-name lookup.
  Refuse multiple push URLs, embedded credentials and URL rules that would rewrite this resolved endpoint
  again. Network invocations use `GitEnvironment` and a scoped profile access lease.
- Bind remote confirmation to a unique preview, tag, remote, repository, endpoint, state and OID. Recheck
  state/config and re-read remote metadata in the writer; refuse symbolic/missing/moved tags. Execute
  one deletion with an explicit `--force-with-lease=<tag-ref>:<old-object>`, never plain force. Keep the
  local tag and warn if the remote object differs or no local recovery tag exists.
- A remote server still controls its own behavior; an OID lease does not lock all external configuration
  or symbolic-ref changes. Jit checks advertised metadata again immediately before deleting, but cannot
  make the remote protocol a transaction over arbitrary server-side configuration. No rollback claims
  after network failures. Recovery requires the object to remain available in some local copy.
- Reuse the creation sheet with an Annotated toggle, multiline editor, Cmd-Return submission, identity
  guidance and remembered push choice.
  Sidebar add/context actions, graph-label actions and palette commands open the shared workflow.
  Details use a transient popover in the sidebar and a sheet elsewhere. Closing cancels reads and releases
  the hosted view. Local/remote deletion uses ConfirmationSheet, default Cancel, a copyable exact object,
  and the existing arming delay for remote deletion. Busy guards apply at execution.
- Create and optional push are separate tracked jobs. On push failure, explicitly retain/name the local
  tag; never delete it to simulate rollback. Local deletion is recorded in persistent Recovery Points.

## Verification

Real repositories and bare remotes cover invalid/duplicate names, identity, exact metadata, older targets,
message permissions and cleanup on all exits, wrong/stale confirmation, local journal recovery, configured
mirror/follow-tags, remote divergence, separate push URLs, hook rejection, SHA-256, symbolic refs and changed
remote symbolic tags. Native/snapshot/timing evidence and final results are in `progress-tags.md`.

Git semantics: [tag](https://git-scm.com/docs/git-tag), [push](https://git-scm.com/docs/git-push),
[update-ref](https://git-scm.com/docs/git-update-ref), [ls-remote](https://git-scm.com/docs/git-ls-remote).
