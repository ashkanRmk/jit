# Phase 8 — Remaining tag management

Status: implemented and verified locally/unreleased (2026-11-18).
Branch: `codex/tag-management`, based on main `29f445e` (0.0.8 released).
Milestones: P8.tags.1/P8.tags.2. Decision: [ADR-0062](../../adr/0062-tag-management-and-exact-object-deletion.md).

## Implemented

- Extended existing Git-validated lightweight/annotated creation. Annotations use profile committer
  identity, a 0600 message file in a 0700 directory, verbatim cleanup and guaranteed normal-path cleanup
  on success/failure/cancellation. Invalid/duplicate names, empty/NUL/oversized messages and stale state
  are refused. Return the created object to bind optional push to that exact tag.
- On-demand details show kind, direct object, fully peeled target/type, tagger/date and annotation.
  Blob/tree/nested/SHA-256 tags are supported. Raw objects are bounded to 4 MiB; long annotation previews
  show a limit notice and offer Copy Full Message. No signature-verification claim.
- Local deletion confirms the exact tag object and uses a no-dereference CAS under the existing writer.
  The recovery journal retains the direct object and the result names both object/target. HEAD, index,
  working files and remote copies are kept. Symbolic local tags are refused.
- Push exactly one immutable tag object to one explicit remote destination; override configured mirror,
  follow-tags and recursive submodule push. Never force a replacement. Create/push partial success is
  explained and the created local tag is retained.
- Remote deletion reads the effective push destination, even with a different fetch URL, confirms its
  exact object/destination, rechecks state/config and advertised metadata in the writer, and uses an
  explicit object lease. Changed, missing, symbolic or ambiguous tags are refused. Multiple push URLs,
  embedded URL credentials and rewrites that would reroute the prepared endpoint are refused.
- Shared creation sheet now has an Annotated toggle, multiline editor, profile guidance, remembered
  push choice, Cmd-Return submission and a submission guard. Sidebar add/context, graph labels and
  palette expose creation/details/actions. Annotated/lightweight rows have distinct icons and labels.
- Sidebar details use a transient popover; other entry points use the same content in a sheet. Reads
  cancel and hosted content releases on close. Refresh reads the current tag, and confirmation uses
  that refreshed object. Remote selection is explicit; deletion uses default Cancel and remote arming.

## Verification

- Full serial package suite: **920 tests reported, 21 enterprise-rig skips, zero failures**: GitCore 459,
  Features 202, Services 244 including skips, DesignSystem 15 (**899 passed**).
- Focused bundled-Git 2.56.0 checks: **14 tag operation tests**, including parameterized name, permission,
  cancellation and deletion cases; **4 feature tests** and **2 snapshot tests** (12 image cases) passed.
- Real repos/bare remotes cover older commits, identity/annotation metadata, message-file permissions
  and cleanup, exact local deletion/journal recovery, wrong/stale tokens, moved tag/destination, separate
  push URL, configured mirror/follow-tags, hook refusal, missing/multiple destinations, SHA-256, blob/
  nested tags, symbolic tags and remote symbolic tags introduced after preview.
- Twelve light/dark/opaque references reviewed. After the multiline editor fix, references were recorded
  and two consecutive comparison runs passed. Final focused feature checks passed; Debug build, lint
  and diff checks passed.
- App tests: **25 passed, zero failures/skips**. Final result:
  `Test-Jit-2026.11.18_15-34-31-+0330.xcresult` in DerivedData/Jit/Logs/Test.
- Native app with isolated `JIT_APP_SUPPORT` and disposable repository/bare remote: created `qa-v1` on
  an older commit using multiline input, pressed Return without submitting, and pushed successfully.
  Sidebar add opened creation at HEAD and retained the push preference. Inspected light popover and
  dark details sheet; palette Cmd-Return opened tag actions. Remote confirmation armed after its delay;
  Return cancelled. Explicit deletion removed only the remote tag. Local deletion then removed the
  local row and recorded direct object `dc73a1ad6c890ae8c5deb14af8dc11fc8a88103e` in Recovery Points.
- Independent Git checks confirmed unchanged HEAD/index/tracked and untracked file contents, the
  older peeled target, exact remote/local deletion and restoration of the full annotation from its
  recorded direct object. [Native captures and snapshot index](screenshots/tags/README.md).

## Native findings

- The initial annotation field treated Return as submit. Replaced it with TextEditor, made submission
  Cmd-Return, and guarded duplicate activation. This was found by real multiline input, not a snapshot.
- Refresh initially retained the old ref object after an external update. It now explicitly reads the
  current ref and shares the same exact-object local deletion preparation.
- Sidebar popover presentation now waits until the context menu finishes tracking and checks the row's
  current identity. Dark context-menu automation timed out while the app's main thread was idle in
  AppKit menu tracking; native dark checks were completed through the palette's shared details sheet.
  The light sidebar popover was exercised; a dark sidebar popover check remains an automation limit.
- Raw Git can follow a symbolic remote tag deletion into a branch. Jit refuses advertised symbolic
  tags and checks again immediately before deletion; a bare-remote regression preserves the branch.

## Performance

Read-only release benchmark: 100k-commit fixture, 200 tags; exact details for `v0.0.1`, three warm-ups,
15 measured reads. Mac17,9, macOS 27.2.1, Apple Git 2.54.0. No background scan or polling.

| Metric | Median | p90 | Maximum | Evidence |
|---|---:|---:|---:|---|
| Exact tag details | 25.45 ms | 25.77 ms | 25.89 ms | [raw JSON](benchmarks/tag-details.json) |

## Limits / next

- Recovery metadata does not keep Git objects alive. Exact annotation restoration uses Git and must
  happen before pruning. Remote deletion recovery requires a copy of the remote object to exist locally.
- A remote server controls its own behavior; an OID lease cannot atomically lock all external symbolic-ref
  or configuration changes. Jit rechecks advertised metadata and destination before the leased deletion.
- Tag lists are local refs; this is not a separate remote-tag catalog. Multiple push destinations and
  unsafe/credential-bearing URL configurations need separate handling. Signing remains in its own epic.
- No live VoiceOver audit, new XCUITest target, enterprise rig or clean VM run for this feature.
- No version bump, merge or release. Next planned feature: interactive rebase and its safety spike.
