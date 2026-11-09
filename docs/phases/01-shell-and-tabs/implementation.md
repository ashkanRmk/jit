# Phase 1 — Native Shell & Repository Tabs: implementation plan

Design: [`design.md`](design.md). Exit gate: §6 below + [`../../roadmap.md`](../../roadmap.md) §9.

> **Outcome (2026-11-09):** implemented on `phase/01-shell-and-tabs`; what was built, measured, changed and
> carried over is recorded in [`progress.md`](progress.md) (the checkboxes below are the original plan).
> Notable changes: Phase 0 was not merged yet (branch cut from `phase/00-foundation` at the owner's request);
> UI automation (XCUITest) replaced by model-level app tests plus real-input checks; the tab strip is a hosted
> SwiftUI glass container in an unbordered toolbar item (spike in `specs/P1.2-tab-bar.md`).

## 1. Preconditions

- [ ] Phase 0 PR merged; `docs/phases/00-foundation/progress.md` status complete (or carry-overs accepted).
- [ ] `scripts/build/build-all.sh debug` and all tests green on `main`.
- [ ] ADR-0001…0006 accepted (the ADR-0005 concurrency/process model and the ADR-0006 minimum Git
      version and glass rules are relied on here).
- [ ] `docs/design-system.md` records the verified Liquid Glass APIs and the `DesignSystem` glass helpers exist.
- [ ] Baseline numbers from Phase 0 available for regression comparison.

## 2. Milestones

### P1.1 — App state architecture and persistence
Goal: the state skeleton every later phase builds on (design §4.1–4.2).
- [ ] Spec `specs/P1.1-state-and-persistence.md`.
- [ ] `Services`: `PreferencesStore`, `SessionStore`, `RecentsStore`, JSON file helper (atomic write,
      `0600`, versioning, corrupt-file backup), one-shot debounced writer.
- [ ] `Features/App`: `AppModel`, `TabModel`, `LayoutState`; `RepositorySession` with lifecycle states
      `unloaded/loading/active/inactive/suspended/closed` (transitions only; Git work arrives in P1.5).
- [ ] Memory-pressure source wiring to suspend inactive sessions.
- [ ] ADR-0007.
Tests: `SessionStoreTests.testRoundTrip`, `.testUnknownVersionBacksUpAndResets`,
`.testCorruptFileBacksUpAndResets`, `.testAtomicWriteLeavesNoPartialFile`, `.testFilePermissions0600`;
`AppModelTests.testCloseActivatesRightThenLeft`, `.testReopenClosedTabRestoresPosition`,
`.testOpeningSameRepoFocusesExistingTab`; `RepositorySessionTests.testLifecycleTransitions`,
`.testDeactivateCancelsInFlightWork`.
Done when: tests pass; app launches with an empty new-tab page and restores an empty session.

### P1.2 — Tab bar
- [ ] Spec `specs/P1.2-tab-bar.md` (anatomy, states, metrics from design §3.1).
- [ ] Spike toolbar-item vs titlebar-accessory placement and AppKit vs hosted SwiftUI glass container
      (design §7); record the choice in the spec.
- [ ] Unified `NSToolbar` with system sidebar/inspector toggles, overflow `⌄` button and the profile
      capsule item; window title/subtitle set from the active repository.
- [ ] `TabStripView`/`TabItemView` (AppKit, layer-backed) inside one glass container: capsule glass tabs
      with stable `glassEffectID`s, select (glass morph, ≤ 240 ms), close button, middle-click close,
      drag reorder with neighbor animation, overflow (compression → horizontal scroll inside the
      container → overflow menu), status dot, tooltips, window drag on empty space, double-click zoom
      behavior, full-screen toolbar behavior.
- [ ] Reduce Transparency fallback (`surface.chromeOpaque`) and Increase Contrast check.
- [ ] Keyboard: ⌃Tab/⌃⇧Tab, ⌘⇧]/⌘⇧[, ⌘W, ⌘⇧T; Window menu "Move Tab Left/Right".
- [ ] Accessibility: roles, labels, "tab n of m", reorder actions.
- [ ] Reduce Motion handling (no morphs; cross-fade).
Tests: `TabOrderingTests` (pure model: move, close, overflow index math);
UI tests `TabBarUITests.testNewTabCloseReopen`, `.testKeyboardCycling`, `.testMiddleClickClose`
(if XCUITest supports it; otherwise manual check documented).
Verification: screenshots `tabbar-{default,hover,overflow,many}-{light,dark}.png` plus
`tabbar-default-reducetransparency.png`; manual drag test with 3, 12 and 40 tabs; full-screen mode
check; VoiceOver pass; idle CPU unchanged with the strip visible (glass is static when idle).
Done when: tab interactions feel native to macOS 26 and smooth; no layout jumps; no glass nested in glass.

### P1.3 — New-tab page and opening repositories
- [ ] Spec `specs/P1.3-new-tab.md`.
- [ ] New-tab view (opaque content under the glass toolbar): prominent glass "Open Repository…" button
      (⌘O), opaque recents list with hover actions, empty state, missing-path rows with Locate…/Remove,
      keyboard navigation, ⌫ remove + ⌘Z undo. No glass cards.
- [ ] Window-wide folder drop overlay (opaque, not glass); drop on any tab content opens a new tab (or
      focuses existing).
- [ ] Open flow: `GitEngine` discovery → top-level path → new `TabModel(.repository)` → session activates.
- [ ] "Open Recent" menu bound to `RecentsStore`.
- [ ] Test hook: launch argument `-JitUITestOpenRepository <path>` (DEBUG/UI-test builds only) because
      `NSOpenPanel` isn't scriptable reliably.
Tests: `RecentsStoreTests.testDedupesByResolvedPath`, `.testCapsAt20`, `.testMarksMissing`;
UI `NewTabUITests.testOpenRepositoryViaHook`, `.testRecentsKeyboardOpen`.
Verification: screenshots `newtab-{empty,recents,drop,missing}-{light,dark}.png`.
Done when: all entry points open repositories; nothing on the page is a placeholder.

### P1.4 — Workbench layout skeleton
- [ ] Spec `specs/P1.4-workbench-layout.md`.
- [ ] `NSSplitViewController` with a system **sidebar** item (macOS 26 glass sidebar), main item and a
      system **inspector** item; min/max from `PanelMetrics`; collapse/expand (⌃⌘S, ⌥⌘0) with the
      system animation (instant with Reduce Motion); widths persisted globally, collapse flags per tab.
- [ ] Sidebar content uses system sidebar list styling on glass (no custom opaque fills); main and
      inspector are opaque content.
- [ ] Repository header (name, branch/detached/unborn, upstream ahead/behind, operation chip).
- [ ] Region contents per design §3.3 with loading (150 ms delayed placeholder), normal, error +
      recovery actions (Locate…, Remove Tab, Retry), bare-repository variant.
Tests: `LayoutStateTests.testWidthsClampToMinMax`, `.testPersistence`; snapshot of header states
(pure SwiftUI view rendered to bitmap if snapshot infra exists; otherwise screenshots).
Verification: screenshots `workbench-{loading,normal,error,bare}-{light,dark}.png` and one with Reduce
Transparency; resize window down to 960×600 and up to a 5K display size.
Done when: layout persists across relaunch and handles all states.

### P1.5 — `GitCore` status and operation state
- [ ] Spec `specs/P1.5-status.md`.
- [ ] `GitCore` byte-level status parser (porcelain v2, `-z`, `--branch`) → `StatusSnapshot` with compact
      `StatusEntries` + summary (no `String` per line; paths materialized on demand).
- [ ] `GitCore` `OperationStateDetector.detect(gitDir:)`.
- [ ] `actor RepositoryHandle` with generation counter, cache, `invalidate(_:)`, coalesced refresh (one in
      flight + one queued), `releaseCaches()`; `GitEngine.openRepository(at:)`.
- [ ] `Services`: `RepositorySession.refresh(reason:)` awaiting the handle and updating `statusSummary`
      and the tab's status dot on the main actor.
- [ ] `GitEngine.readGlobalIdentity()` (read-only `git config --global --get user.name/email`) for P1.8 pre-fill.
Unit tests (`swift test`, from captured porcelain samples): `parsesBranchHeadersWithUpstream`,
`parsesNoUpstream`, `parsesDetached`, `parsesUnborn`, `parsesRenameEntryZFormat`,
`parsesUnmergedEntries`, `parsesUntrackedAndIgnored`, `parsesUnicodeAndSpacesPaths`,
`parsesSubmoduleFields`, `rejectsTruncatedRecord`.
Integration (`GitTestKit`): `statusCleanRepo`, `statusMixedChangesCounts`,
`statusPartiallyStagedFileCountsBoth`, `statusDoesNotTouchIndexMtime` (asserts
`--no-optional-locks` effect), `operationStateMerge`, `operationStateRebaseWithProgress`,
`operationStateCherryPick`, `operationStateRevert`, `refreshCoalescesConcurrentRequests`,
`staleResultDiscardedAfterInvalidate`, `cancellingRefreshKillsGitProcess`.
JitBench: `status-parse` on a 100k-entry captured sample (time + allocations).
Done when: counts in the UI match `git status` for every fixture.

### P1.6 — File watching
- [ ] Spec `specs/P1.6-file-watching.md`; ADR-0008.
- [ ] `RepositoryWatcher` (FSEvents, dispatch-queue scheduled, latency 0.2 s, directory-level).
- [ ] `classifyFSEvent(path:flags:layout:) -> InvalidationKind?` pure function.
- [ ] Lifecycle integration: start on `active`, stop on `inactive`/app resign active/window
      miniaturized/occluded; revalidate on activation.
Tests: `FSEventClassifierTests` (objects/locks/logs ignored, index/head/refs/config/operation files,
worktree paths, linked worktree layout, bare layout); integration test that writes a file in a temp
repo and observes a status update within 1 s; `testNoStreamWhenAppInactive` (via lifecycle model).
Verification: edit files in an external editor → counts update; run `git commit` in Terminal → header
updates; run a script that rewrites 10,000 ignored files → measure number of status runs and CPU.
Done when: updates are timely, and there is zero activity when the app is in the background.

### P1.7 — Theme
- [ ] Appearance preference System/Light/Dark in Settings ▸ General and View ▸ Appearance; applied via
      `NSApp.appearance`; persisted; applied before the first window is shown (no flash).
Tests: `PreferencesStoreTests.testAppearancePersists`; UI `ThemeUITests.testSwitchToDarkAndBack`.
Verification: every Phase 1 screen screenshotted in both themes; Increase Contrast and Reduce
Transparency spot checks (glass chrome and content tokens).
Done when: no surface or text ignores the theme; no white flash on dark launch.

### P1.8 — Identity-only profiles
- [ ] Spec `specs/P1.8-profiles-identity.md` (model, validation, snapshot semantics for Phase 3).
- [ ] `ProfileStore` (`profiles.json`), `GitProfile`, `GitIdentity`, `ProfileSnapshot`.
- [ ] Create/edit system sheet with validation and "Fill from Git config".
- [ ] Profile capsule in the toolbar (glass); switcher as a system popover (search > 6, active check,
      New/Manage); "No Profile" warning-tinted capsule.
- [ ] Settings ▸ Profiles list/editor; delete with confirmation; deleting the active profile → none.
- [ ] "No profile" state and resolution path.
Tests: `ProfileStoreTests.testCreateEditDeletePersist`, `.testDeleteActiveLeavesNoneSelected`,
`.testSnapshotIsImmutableAfterSwitch`, `.testValidation`; `ProfileJSONTests.testNoSecretFieldsSerialized`;
UI `ProfilesUITests.testCreateAndSwitch`.
Verification: screenshots `profile-{indicator,popover,sheet,none}-{light,dark}.png`; confirm
`~/.gitconfig` checksum unchanged before/after all profile operations.
Done when: switching updates every tab's indicator instantly and global Git config is untouched.

### P1.9 — Menus and shortcuts
- [ ] Menus per design §3.6 with only working items; Branch/Git menus absent.
- [ ] Repository ▸ Refresh, Reveal in Finder, Open in Terminal (NSWorkspace), Copy Repository Path.
- [ ] Shortcut collision review vs. macOS standard shortcuts; document the table in `docs/product.md`.
Tests: UI `MenuUITests.testFileMenuItemsEnabledState`, `.testRepositoryMenuDisabledOnNewTab`.
Done when: menus enable/disable correctly for new-tab vs repository tabs.

### P1.10 — Restore, lazy loading, measurements
- [ ] Restore tabs from `session.json` before Git work; only the active tab activates.
- [ ] Missing repositories surface as error tabs without blocking.
- [ ] Measure (release build): warm/cold launch with 0 and 5 restored tabs; idle CPU, wakeups and GPU
      with 5 tabs over 60 s (glass chrome visible); tab switch latency (signpost from click to content committed) for loaded and
      unloaded tabs; memory after opening/closing a repository 50 times (DEBUG-only stress command or
      UI-test loop) — no sustained growth; idle network = none (`nettop -p <pid>` / `lsof -i -p`).
- [ ] Update `docs/performance.md`.
Done when: numbers recorded honestly; regressions versus Phase 0 explained or fixed.

## 3. Test plan summary

| Layer | Coverage |
|---|---|
| `GitCore` unit (`swift test`) | porcelain v2 parser (all record types, edge paths), operation-state detection, cache generations |
| `GitCore` integration (`GitTestKit`) | status counts on real repos, no index writes during status, coalescing, staleness, cancellation |
| `Services`/app unit | stores (persistence, corruption, permissions), app/tab model logic, layout clamping, FSEvent classifier, profiles + snapshot |
| UI (`xcodebuild test`) | new tab, open via hook, tab cycling/close/reopen, theme switch, profile create/switch, menu states |
| Manual | drag reorder, overflow, full screen, VoiceOver, Reduce Motion, Increase Contrast, Reduce Transparency, external edits |

## 4. Performance checks

| Check | Target | Method |
|---|---|---|
| Warm launch, 5 restored tabs | < 500 ms first window | `scripts/benchmarks/launch.sh` |
| Idle CPU, 5 tabs, app active | 0.0–0.2 % | `scripts/benchmarks/idle.sh` |
| Idle GPU with glass chrome | no recurring work | Instruments GPU / `powermetrics` (user-run) |
| Idle CPU, app in background | ~0 %, no FSEvents callbacks | idle script + debug counter of callbacks |
| Tab switch (loaded) | < 16 ms to committed frame | signposts in Instruments |
| Memory growth over 50 open/close | no sustained growth | footprint before/after |
| Idle network | none | `nettop`/`lsof` |
| Status refresh on 10k-file churn | coalesced; record count + CPU | P1.6 churn script |

## 5. Docs to update

`docs/architecture.md` (state, lifecycle, persistence, watching), `docs/design-system.md` (glass tab
strip, toolbar, profile capsule, popover, new-tab, workbench header patterns, "No Profile" tint exception), `docs/performance.md`, `docs/security.md`
(file permissions, NSWorkspace launching), `docs/product.md` (shortcut table, Phase 1 behavior),
ADR-0007, ADR-0008, CLAUDE.md if commands change, `progress.md`.

## 6. Exit checklist

- [ ] Demo in design §1 works end to end on real repositories (regular, bare, linked worktree,
      large repo).
- [ ] Only the active/visible tab does work; background app does none (verified).
- [ ] Global `~/.gitconfig` unchanged by any Phase 1 action (checksum evidence).
- [ ] No placeholder actions on the new-tab page, menus, or workbench.
- [ ] Screenshots for every new screen and state in light and dark (+ Reduce Transparency for chrome).
- [ ] Glass only on chrome (toolbar, tab strip, sidebar, popovers, sheets); content opaque; no nested glass.
- [ ] Performance table updated; no regressions versus Phase 0 without explanation.
- [ ] ADR-0007 and ADR-0008 written; docs updated; roadmap §9 gate satisfied; `progress.md` complete; PR opened.
