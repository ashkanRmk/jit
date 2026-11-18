# Phase 8 — Reflog explorer & recovery: progress report

Status: **implemented, merged to main for 0.0.7** (2026-11-18)
Implementation branch: `codex/reflog-recovery`, fast-forward merged to `main`. Release notes: [0.0.7](../../releases/v0.0.7.md).
Environment: MacBook Pro `Mac17,9`, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2.
Release benchmark Git: Apple Git 2.54.0 (Git-157). Bundled runtime: Git 2.56.0.

## Preconditions

- Phase 7 completed with owner-accepted ad-hoc signing and local/test-rig carry-overs.
- Existing single writer, state tokens, confirmation sheets, conflict resolver, patch builder and command
  palette verified in source. Reset/tag workflows already shipped in 0.0.6 and are reused.
- Bundled runtime verified with `--version` and all 17 reflog integration tests.
- Started from clean local main at `7034338` (one commit beyond locally tracked origin/main). Preserved
  that graph fix as the branch base. Release publication is outside this implementation.

## Implemented

- **P8.reflog.1:** HEAD/local-branch reader with NUL parsing, correct event times, action classification,
  pages of 50 and cursors validated against both the log file stamp and repository state. Page-only
  reachability includes detached HEAD ancestry. A sole-independent-HEAD proof answers common pages in
  one Git call; other entries use exact checks with at most four processes in flight.
- Explicit, cancellable Find Lost Commits (`fsck`, progress, process-group cleanup), batched metadata,
  possible-stash markers, a 2,000-result limit and bounded output/deduplication bookkeeping.
- Recovery points captured through the existing writer for moved/deleted refs and removed older stashes,
  including partial failures. At most 50 in memory and a private atomic JSON journal outside the repo.
  Earlier sessions' saved committed states remain inspectable but do not qualify for the live shortcut.
- **P8.reflog.2:** native workbench list, reference chooser, empty/loading/error states, keyboard navigation,
  inspector, menu/palette/action-bar entry points, saved recovery points and explicit lost-commit search.
  Branch creation defaults to no checkout and uses the state captured when preparing its sheet.
  Cherry-pick, compare, copy SHA and confirmed reset reuse existing workflows. Reset/cherry-pick are
  disabled during an in-progress Git operation. The current-session recovery menu names the exact
  preceding operation and offers branch creation or a confirmed reset to its previous committed state.
- Show in Graph adds a removable temporary tip with dashed edges, without writing a ref or changing
  saved filters. Closing Reflog restores the inspector to the graph selection. Closing/hiding the tab
  cancels reads; reactivation revalidates. The covered graph is excluded from focus/accessibility.
- [ADR-0052](../../adr/0052-reflog-and-recovery-points.md), feature specs, architecture/product/testing
  documentation and roadmap updated. Future rebase/safety ADR reservations moved to 0059/0060 because
  0051 already belongs to updates and 0052 now belongs to recovery.

## Verified

- Package tests: **856 passed**, **21 skipped**. Module evidence: 426 GitCore, 192 Features, 15
  DesignSystem passed in the full serial run; Services rerun passed 223, with its 21 enterprise-rig
  tests skipped because `JIT_RIG`/the local enterprise rig were not enabled. Swift Testing reports
  “244 tests” for that Services run, which includes those skips.
- An existing `OperationCenterTests.queuedOperationShowsWhatItWaitsFor` fixture allowed its second
  operation to finish before the assertion read its waiting label. It now holds that body until after
  inspection; the full Services module then passed. Earlier concurrent verification also triggered
  timing/thread-count assertions in ProcessStream/ProcessRunner/DiffViewer tests; all passed in the
  later serial full run without competing builds. No assertion was weakened or disabled.
- Final focused rerun after review fixes: **17 reflog core tests + 4 window/feature tests passed**.
  All **17 core tests also pass against bundled Git 2.56.0**, including cancellation. The cancellation
  fixture explicitly selects its wrapper so the global test-runtime override cannot bypass its delay.
- App tests: **25 passed, 0 failed, 0 skipped** (latest xcresult summary). Debug app built by the same
  Xcode test invocation. `scripts/build/lint.sh` and `git diff --check` pass.
- Regression coverage: amend/reset/checkout classification, reflog event date vs commit date, changed
  and expired cursors, disabled/unborn logs, invalid ref inputs, SHA-256, detached HEAD, related lost
  ancestors, dropped stash discovery, dropping an older stash without moving its tip, bounded journals,
  partial failures, stale recovery refusal and unchanged repository fingerprints.
- Native UI: amend → select old reflog commit → Create Branch with Switch to it off → success.
  Git verified the branch target, unchanged HEAD/index/tracked files and preserved untracked notes.
  Real window navigation with Down updated the inspector. [Evidence and snapshots](screenshots/reflog/README.md).
- Eight new light/dark/opaque-chrome references were reviewed. Snapshots passed after recording in the
  serial full suite and again in the final focused rerun. No snapshot was skipped on this OS.

## Performance (release build)

Fixture: 100,000 synthetic commits / 500 branch parameter, 702 total refs, plus 55 appended commits to
populate a 50-entry HEAD-ancestor page; a reachable commit graph was written in this disposable fixture.
`JitBench reflog <fixture> <out>`: three warm-ups, 15 measured reads; no repository writes by the benchmark.

| Metric | Measured result | Target | Evidence |
|---|---|---|---|
| Page of 50, including reachability and cursor validation | p50 **42.75 ms**, p90 **43.90 ms**, max 44.07 ms | < 100 ms | [raw JSON](benchmarks/reflog-page.json) |

The original sequential containment implementation measured p50 1,018 ms; a four-process HEAD-first
version measured 219 ms; the independent-tip proof produced the final measurement above. Those were
separate local runs with different verification load, not a controlled A/B comparison. Release Git
resolution correctly ignores debug-only `JIT_GIT_PATH`, so this benchmark used Apple Git 2.54.0; the
bundled 2.56.0 runtime was verified separately by integration tests.

## Decisions and deviations

- ADR-0052 replaces the old planned 0050 number (0050 is author pictures).
- Used `codex/` branch convention and a separate bounded recovery journal instead of embedding it in
  the tab-layout JSON. No backup refs or numeric reflog-selector replay.
- Selection inspects a commit; Show in Graph switches back to the graph and adds its temporary tip.
  Recovery is named explicitly; no generic Undo/Redo button promises an inverse of arbitrary Git work.
- Canonical screenshot references stay in the test suite; the phase evidence directory links them.

## Known limits / carry-overs

- Pages containing many unrelated/lost histories use per-entry checks and may exceed 100 ms; that
  worst-case benchmark was not run. Reads remain cancellable and off the UI executor.
- Git-pruned objects and discarded uncommitted edits cannot be restored from this metadata journal.
  Lost-commit results are limited to 2,000, with a visible notice; stash identification is heuristic.
- No new XCUITest target, live VoiceOver walkthrough, global idle/performance rerun, clean VM or remote
  enterprise rig run was performed for this epic. The existing suites/native checks above are the evidence.

## Self-review findings

- Incorrect commit time for reflog events: fixed by using the dated reflog selector.
- Concurrent page shifts: guarded by log stamps and repository-state tokens.
- Detached HEAD ancestry: included; related lost ancestors cannot pass the independent-tip proof.
- Older stash deletion with unchanged tip: tracked separately and regression tested.
- Selected-row text contrast / wrapping marker: fixed and references re-reviewed.
- Hidden graph focus/accessibility and stale inspector after closing: fixed; window regression passes.
- Lost-scan deduplication bookkeeping now retains only the bounded result set.

## Next

Reset previews, keep mode and stash-first recovery were completed locally on 2026-11-18
([report](progress-reset.md)). Continue with remaining tag management.
