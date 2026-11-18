# Phase 8 — Interactive rebase

Status: implemented locally, unreleased, with validation carry-overs.
Branch: `feat/interactive-rebase` (not merged or pushed).
Environment: Apple silicon MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.2 (27B52), Git 2.56.1.
Work and verification: 2026-11-18–19.

## Implemented

- Graph **Interactive Rebase from Here…** includes the selected commit through HEAD. **Branch →
  Interactive Rebase…** and the command palette open an excluded-base / optional-onto chooser.
- A focused, opaque workbench editor lists oldest first with author, short SHA and diffstat. Pick,
  Reword, Edit, Squash, Fixup and Drop; inline messages; visible drag handles/drop indicator; selection,
  reorder controls and shortcuts; a resulting-history graph. A lazy stack keeps rows virtualized.
- Published-history warnings inspect all known remote-tracking refs without fetching. Reordering edits
  to the same path shows a risk hint. The result preview collapses squash/fixup groups and omits drops.
- Immutable plan provenance and typed steps. The existing confirmation binds exact steps/plan ID and
  shows the previous branch tip. The writer validates the captured refs/HEAD/operation, clean tracked
  tree, helper availability and plan before execution. Other branch pointers stay unchanged.
- Native interactive rebase through two fixed modes of the existing bundled helper. Private files use
  0700/0600 permissions; messages remain literal, including quotes, shell syntax, Unicode and comment
  lines. Original-OID message lookup survives extra conflict editors and skipped steps. Fixups refer
  to existing message values instead of duplicating large messages on disk.
- Prepared messages and captured committer identity survive reopening. Continue/Skip validate them
  against Git's original tip, branch and onto target. Abort works without the helper. Existing conflict
  resolver, operation banner and recovery journal are reused. Edit stops identify Git's amend marker
  and offer Working Directory → Amend → Continue. Progress is event-driven and throttled, with no timer.
- Source/custom messages are bounded to 1 MB each / 16 MB total. Ranges are limited to 1–500 commits;
  detached/unborn HEAD, non-ancestor bases, merges, root-inclusive ranges and stale plans are refused.
- ADR-0059/0060 record the editor spike, message lifetime, initially/newly empty commit policy and
  explicit no-update-refs / no-autostash / no-autosquash behavior. ADR-0016 documents helper modes.

## Verification

- `InteractiveRebaseTests`: 17 tests (parameterized cases add further executions), all passed. Real
  repositories cover each action, combined-message chains, all-drop, unrelated refs/tree preservation,
  authors/committer, quoting, stale/dirty refusals, published reachability, path-order risk, private file
  modes, initial/newly empty commits, missing helper, reopened edit continuation and skip/abort.
- The ten-commit test reorders, rewords, squashes, drops, resolves a conflict, continues and verifies
  eight resulting commits and the expected files/messages. Abort separately restores the fingerprint.
- Five `InteractiveRebaseFeatureTests` exercise the controller/session/confirmation, cancellation,
  actual resolver model → Mark as Resolved → Continue, Abort, and native drag-provider data transfer.
  All passed, including the two parameterized conflict outcomes. A final regression pass also passed
  61 existing GitCore integration/conflict/status tests and 12 Services recovery/operation tests.
- Four new editor snapshots cover light/dark and opaque chrome. References are pinned separately to
  macOS 27.0; the existing 27.2 snapshot pin was preserved. These are rendered view captures, not
  composited Liquid Glass screenshots.
- Debug app build and the 25 app tests passed. Swift formatting / styling / architecture lint and
  whitespace checks passed.
- Full package run: Services 244 tests passed, Features 216 tests passed, DesignSystem 15 tests passed.
  GitCore ran 483 tests with one existing diff test timing out at 10 seconds under concurrent load.
  All 13 DiffEngineTests passed in isolation afterward. A serial 483-test GitCore run cleared that
  timeout but failed the existing `noThreadBlockedWhileWaiting` thread-count assertion. It also
  reproduced alone: 6 → 38 threads (delta 32, asserted <32), while the detached probe completed in
  ~10 microseconds. ProcessRunner production/test code was not changed. The full suite is not green.
- Native app verification used a disposable repository and isolated app support: reorder control,
  Reword picker, literal multiline message editing, explicit rewrite confirmation and successful
  completion with resulting Git history checked. Plain `r` opened Reword and `presfd` typed literally
  inside the message editor. Native pointer automation did not confirm drag-to-drop; this remains a
  manual acceptance item. The model and NSItemProvider transfer have automated coverage.

## Performance

A 50-commit plan measured 100.1 ms in the final focused debug run (146.3 ms in an earlier run), against
its 150 ms target. These are local observations on a busy machine, not a release benchmark.
The reproducible [editor spike](benchmarks/rebase-editor-spike.json) preserved exact messages, trees
and authors for both approaches: native editors 2.063 s, exec/amend 1.779 s, 50 commits each.
No release idle-CPU/memory regression benchmark or live VoiceOver walkthrough was performed.

## Limits / carry-overs

- Manual native drag-to-drop, latest-layout keyboard-only walkthrough and live VoiceOver acceptance
  remain open; reorder buttons and model behavior are verified. No XCUITest target was added.
- The existing ProcessRunner thread-count failure remains open; no threshold was relaxed to make it pass.
- Merge-preserving and root-inclusive rebase, automatic stacked-branch updates and signing are outside
  this version. Newly empty commits can be skipped, or explicitly kept via Terminal before Continue.
  Submodule conflicts retain the existing Terminal fallback.
- Repository hooks still run. Git's reflog expiration/garbage collection still bounds recovery.
- Externally finishing/aborting a Jit rebase can leave private preparation until the next Jit rebase
  replaces it. Mismatched preparation refuses continuation rather than using the wrong messages.

## Next

Direct commit surgery can generate plans through this engine. Release/push/merge was not performed.
