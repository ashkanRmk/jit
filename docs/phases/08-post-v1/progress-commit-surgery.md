# Phase 8 — Direct Edit Message and Drop Commit

Status: implemented locally/unreleased (2026-11-19), branch `feat/commit-surgery`.
Spec: [P8.commit-surgery.1](specs/P8.commit-surgery.1-edit-message-and-drop.md).
Decision: [ADR-0063](../../adr/0063-direct-commit-message-edit-and-drop.md).

## Implemented

- Single-selection graph menu **Edit Message…** and **Drop Commit…**. Disabled items explain busy,
  dirty, detached, multi-selection and known unsupported commit shapes. The core checks current-branch
  reachability and linear-range support before presenting a prepared action.
- Edit opens the complete original message in a native plain-text editor with smart substitutions
  disabled. Command-Return opens review, including the replacement message. Drop opens review directly.
  Both show author/profile identity, affected commits, known publication warning and copyable old tip.
  Return/Escape cancel review; only the explicit Save Message / Drop Commit button executes.
- Older edits and drops generate one reword/drop step in the existing rebase engine. HEAD edits use
  message-only amend, retaining tree/parents/author, including root/merge HEAD and empty commits.
  Other branch/tag pointers remain fixed. Profile committer identity is captured on confirmation.
- Immutable plan provenance binds its originating working tree and exact confirmation payload.
  Serialized writes recheck repository state and clean tracked files. UTF-8 messages are bounded to 1 MiB with no NUL. Literal Unicode, quotes,
  shell syntax, comment lines and trailing newlines are retained. Hooks continue to run. The shared
  message helper avoids appending an extra newline when one is already present, verified against raw commit bytes for both execution paths.
- Existing operation progress, conflict resolver, Continue/Skip/Abort and persistent recovery journal
  are reused. Recovery records retain the direct action's name. Reflog's quick recovery control now
  recognizes these actions and interactive rebase; its earlier operation-name allowlist omitted them.
- Preparation cancellation/generation/lifecycle guards prevent a late read from reopening a cancelled
  sheet or replacing a newer dialog. Neither action opens the general interactive-rebase editor.

## Verification

All package targets pass: GitCore **495**, Services **244**, Features **225**, DesignSystem **15**
(**979 tests reported**). The full serial run passed Core/Services/DesignSystem; the feature target (225 reported tests)
passed on its final rerun after correcting the zoom assertion's coordinate space. There are **21 expected
enterprise-rig skips** and **15 snapshot test skips** pinned to the other macOS version; the new four
commit-surgery references and existing interactive-rebase references were verified on this OS.
Debug app build and the app test bundle passed: **25 tests, zero failures/skips**.
Native acceptance passed in both appearances: **2 direct-action tests** and **2 rebase drag/keyboard
tests**, with zero failures/skips in each final class run. The direct-action run also verified the exact
recovery branch SHA and removed file's restored contents. All ten window captures were reviewed.
After the final singular/plural copy correction, all 11 direct-action core tests and all 25 app tests
passed again. Final lint and `git diff --check` passed.

Local Xcode results:
- Direct actions: `jit-native-acceptance.r4AWG7/results.xcresult` (temporary directory printed by the script).
- Rebase class: `jit-native-acceptance.CIme5x/results.xcresult` (both rebase cases passed; this earlier
  combined run also contains superseded direct-action notification-query failures).
- App: `Test-Jit-2026.11.19_14-54-10-+0330.xcresult` in Jit's DerivedData test logs.

- `CommitSurgeryTests`: older/HEAD message edits, empty root/merge HEAD, middle/HEAD drops, exact literal
  messages, retained trees/authors/parents/unrelated refs, publication warning, dirty/staged/stale/
  detached/off-branch refusal, changed authorization payload, identical-history wrong-repository refusal,
  hook rejection, dependent-drop conflict then Abort with identical repository fingerprint, and reflog recovery of the removed changes.
- `CommitSurgeryFeatureTests`: cancelled/superseded/closed-session preparation, confirmed execution,
  stale-state error routing, recovery control availability and menu validation. Tests await journal
  synchronization rather than treating the operation's earlier finished signal as journal completion.
- The workspace zoom regression now compares rendered window coordinates with one backing-pixel
  tolerance. Its former logical-coordinate check reported a 0.667-point difference at 75% zoom, which
  renders as a single pixel on the Retina display. Diagnostics include appearance, size and zoom.
- Four light/dark references in `CommitSurgerySnapshotTests` were recorded, reviewed and verified
  twice, with a separate macOS 27.0 pin. The global snapshot OS pin remains unchanged.
- Native acceptance uses disposable history/app support, the separately identified QA app and actual
  macOS pointer/keyboard events. It checks older/HEAD edits, cancellation before mutation, drop and
  Reflog → Create Branch at Previous State, then verifies real Git history and restored contents.
  [Window-only evidence](screenshots/commit-surgery-native/README.md) covers the five workflow stages.

## Performance

The full serial debug run prepared 50-commit direct plans in 152.0 ms (Edit Message) and 150.9 ms
(Drop Commit). The earlier focused serial run measured 183.1 ms / 163.0 ms; a concurrent Git-spawning
test run observed 239.6 ms / 217.3 ms.
Preparation is asynchronous and bounded by the existing rebase-range limit. These are local observations
on a busy machine, not release benchmarks.

## Limits

- Root/merge drops, older edits crossing merges, detached history and dirty tracked files are refused.
  Root/merge HEAD message edits are supported. Untracked files are retained subject to Git's replay
  obstruction checks. Existing rebase empty-commit and submodule limitations still apply.
- Move, squash/fixup target selection, graph drag reorder and split remain planned.
- Live VoiceOver and release idle/memory acceptance were not performed for this slice. Repository hooks
  may refuse writes; Git reflog expiration/garbage collection bounds recovery. No release/push/merge
  was performed.
