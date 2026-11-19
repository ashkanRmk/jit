# Phase 8 — Interactive rebase

Status: implemented and verified locally, unreleased.
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
- `InteractiveRebaseFeatureTests` exercise controller/session/confirmation, cancellation, actual
  resolver model → Mark as Resolved → Continue, Abort and dragged-commit movement. Three additional
  `NativeRebaseInputTests` pass through actual NSWindow responder routing, NSTextView typing and
  native pasteboard/drop validation against rendered row geometry; foreign sources are refused.
  These adapter tests do not synthesize a WindowServer drag session.
- Four new editor snapshots cover light/dark and opaque chrome. References are pinned separately to
  macOS 27.0; the existing 27.2 snapshot pin was preserved. These are rendered view captures, not
  composited Liquid Glass screenshots.
- Debug app build and the 25 app tests passed. Swift formatting / styling / architecture lint and
  whitespace checks passed.
- Full package run: Services 244, GitCore 484, Features 220 and DesignSystem 15 tests passed (963 total).
  All 25 app tests passed in the final repeat. Four updated snapshots were reviewed and passed twice
  without recording; the native handle changes the glyph/frame, and the global OS pin remains unchanged.
- The runner now serializes only `posix_spawn` setup on one Dispatch queue. Child I/O, exit,
  cancellation and waiting remain concurrent. The original 64-child `<32` extra-thread assertion is
  unchanged: a cold run measured 7 → 12 threads and a ~21 μs detached probe; the final full GitCore
  run measured 18 → 18 threads and ~7 μs. All 18 ProcessRunner tests passed, including a new queued-launch
  cancellation/reaping regression. PID fixture startup uses a bounded five-second readiness deadline
  under parallel load, with task cancellation on early exit; kill/cancellation and thread limits remain
  unchanged. ADR-0005 records the launch change.
- Native keyboard verification in the isolated desktop app confirmed selection and ⌥⌘↑ reordering.
  Native responder tests cover all six action letters, both reorder directions, sheet suppression,
  Escape dismissal and literal `presfd` typing / arrow ownership inside NSTextView. Tab now enters
  the selected inline message; ⌘Return opens review from the list or message. A complete desktop
  keyboard-only pass entered a multiline message, canceled review with Return, reopened with ⌘Return,
  used Tab twice → Space to explicitly confirm, and reached Succeeded. Git verified the six expected
  subjects, preserved tree/author, active-profile committer and clean worktree. The editor now uses
  scoped AppKit responder routing instead of hidden SwiftUI shortcut buttons.
- Drag source and destination use AppKit with same-editor/source/pasteboard validation and synchronous
  movement/cleanup. A click selects the handle; movement starts a drag using the retained mouse-down
  event. The rendered-row regression verifies that native hit testing reaches the handle.
- Both `JitNativeInputAcceptance` XCUITests passed, with zero failures or skips, in light and dark.
  Each used actual mouse click-and-drag in both directions, keyboard reorder, Tab into the message,
  literal multiline typing and arrow ownership, ⌘Return review, Return cancellation with HEAD unchanged,
  then Tab/Space confirmation. Both reached Succeeded and checked Git subjects/tree/authors/committer
  and a clean worktree. [Window-only evidence](screenshots/interactive-rebase-native/README.md) shows
  the editor after drag, native text editing and completion; all six captures were reviewed.
- `scripts/testing/native-rebase-acceptance.sh` prepares an ad-hoc app copy with a unique bundle ID,
  uses its exact URL, and isolates repositories/app support. The script supplies the resolved Git
  executable because the sandboxed UI runner cannot use the xcrun-backed `/usr/bin/git` shim.
  macOS mouse tests use XCTest's `click(forDuration:thenDragTo:)`, not its touch-only press gesture.
  Developer Tools authorization was enabled with owner approval on 2026-11-19.

## Performance

A 50-commit plan measured 100.1 ms in the final focused debug run (146.3 ms in an earlier run), against
its 150 ms target. These are local observations on a busy machine, not a release benchmark.
The reproducible [editor spike](benchmarks/rebase-editor-spike.json) preserved exact messages, trees
and authors for both approaches: native editors 2.063 s, exec/amend 1.779 s, 50 commits each.
No release idle-CPU/memory regression benchmark or live VoiceOver walkthrough was performed.

## Limits / carry-overs

- Native drag and keyboard acceptance are complete. Live VoiceOver acceptance remains open.
- The ProcessRunner thread-count failure is fixed without relaxing its threshold.
- Merge-preserving and root-inclusive rebase, automatic stacked-branch updates and signing are outside
  this version. Newly empty commits can be skipped, or explicitly kept via Terminal before Continue.
  Submodule conflicts retain the existing Terminal fallback.
- Repository hooks still run. Git's reflog expiration/garbage collection still bounds recovery.
- Externally finishing/aborting a Jit rebase can leave private preparation until the next Jit rebase
  replaces it. Mismatched preparation refuses continuation rather than using the wrong messages.

## Next

Direct commit surgery can generate plans through this engine. Release/push/merge was not performed.
