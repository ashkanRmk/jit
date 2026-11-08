# Phase 1 — Native Shell & Repository Tabs: implementation plan

Design: [`design.md`](design.md). Exit gate: §6 below + [`../../roadmap.md`](../../roadmap.md) §9.

## 1. Preconditions

- [ ] Phase 0 PR merged; `docs/phases/00-foundation/progress.md` status complete (or carry-overs accepted).
- [ ] `scripts/build/build-all.sh debug` and all tests green on `main`.
- [ ] ADR-0001…0006 accepted (FFI concurrency model and minimum Git version are relied on here).
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
- [ ] Spike titlebar placement (design §7) and record the choice in the spec.
- [ ] `TabStripView`/`TabItemView` (AppKit, layer-backed): select, close button, middle-click close,
      drag reorder with neighbor animation, overflow (compression → horizontal scroll with edge fades →
      overflow menu), status dot, tooltips, window drag on empty space, double-click zoom behavior.
- [ ] Keyboard: ⌃Tab/⌃⇧Tab, ⌘⇧]/⌘⇧[, ⌘W, ⌘⇧T; Window menu "Move Tab Left/Right".
- [ ] Accessibility: roles, labels, "tab n of m", reorder actions.
- [ ] Reduce Motion handling.
Tests: `TabOrderingTests` (pure model: move, close, overflow index math);
UI tests `TabBarUITests.testNewTabCloseReopen`, `.testKeyboardCycling`, `.testMiddleClickClose`
(if XCUITest supports it; otherwise manual check documented).
Verification: screenshots `tabbar-{default,hover,overflow,many}-{light,dark}.png`; manual drag test
with 3, 12 and 40 tabs; full-screen mode check; VoiceOver pass.
Done when: tab interactions feel native and smooth; no layout jumps.

### P1.3 — New-tab page and opening repositories
- [ ] Spec `specs/P1.3-new-tab.md`.
- [ ] New-tab view: Open tile (⌘O), recents list with hover actions, empty state, missing-path rows with
      Locate…/Remove, keyboard navigation, ⌫ remove + ⌘Z undo.
- [ ] Window-wide folder drop overlay; drop on any tab content opens a new tab (or focuses existing).
- [ ] Open flow: discovery via bridge → top-level path → new `TabModel(.repository)` → session activates.
- [ ] "Open Recent" menu bound to `RecentsStore`.
- [ ] Test hook: launch argument `-JitUITestOpenRepository <path>` (DEBUG/UI-test builds only) because
      `NSOpenPanel` isn't scriptable reliably.
Tests: `RecentsStoreTests.testDedupesByResolvedPath`, `.testCapsAt20`, `.testMarksMissing`;
UI `NewTabUITests.testOpenRepositoryViaHook`, `.testRecentsKeyboardOpen`.
Verification: screenshots `newtab-{empty,recents,drop,missing}-{light,dark}.png`.
Done when: all entry points open repositories; nothing on the page is a placeholder.

### P1.4 — Workbench layout skeleton
- [ ] Spec `specs/P1.4-workbench-layout.md`.
- [ ] `NSSplitViewController` with sidebar / main / inspector items, min/max from `PanelMetrics`,
      collapse/expand (⌃⌘S, ⌥⌘0) animated with `motion.panel`, widths persisted globally,
      collapse flags per tab.
- [ ] Repository header (name, branch/detached/unborn, upstream ahead/behind, operation chip).
- [ ] Region contents per design §3.3 with loading (150 ms delayed placeholder), normal, error +
      recovery actions (Locate…, Remove Tab, Retry), bare-repository variant.
Tests: `LayoutStateTests.testWidthsClampToMinMax`, `.testPersistence`; snapshot of header states
(pure SwiftUI view rendered to bitmap if snapshot infra exists; otherwise screenshots).
Verification: screenshots `workbench-{loading,normal,error,bare}-{light,dark}.png`; resize window
down to 960×600 and up to a 5K display size.
Done when: layout persists across relaunch and handles all states.

### P1.5 — Rust status and operation state
- [ ] Spec `specs/P1.5-status.md`.
- [ ] `git-core::status` parser (porcelain v2, `-z`, `--branch`) → `StatusSnapshot` with entries + summary.
- [ ] `git-core::repo_state::operation_state(git_dir)`.
- [ ] `RepositoryHandle` with generation counter, cache, `invalidate`, coalesced refresh (one in flight +
      one queued), `release_caches`.
- [ ] Bridge: `open_repository`, `info`, `status_summary`, `invalidate`, `release_caches`; Swift
      `RepositorySession.refresh(reason:)` updating `statusSummary` and the tab's status dot.
- [ ] `read_global_identity()` (read-only `git config --global --get user.name/email`) for P1.8 pre-fill.
Rust tests (unit, from captured porcelain samples): `parses_branch_headers_with_upstream`,
`parses_no_upstream`, `parses_detached`, `parses_unborn`, `parses_rename_entry_z_format`,
`parses_unmerged_entries`, `parses_untracked_and_ignored`, `parses_unicode_and_spaces_paths`,
`parses_submodule_fields`, `rejects_truncated_record`.
Rust integration (`git-testkit`): `status_clean_repo`, `status_mixed_changes_counts`,
`status_partially_staged_file_counts_both`, `status_does_not_touch_index_mtime` (asserts
`--no-optional-locks` effect), `operation_state_merge`, `operation_state_rebase_with_progress`,
`operation_state_cherry_pick`, `operation_state_revert`, `refresh_coalesces_concurrent_requests`,
`stale_result_discarded_after_invalidate`.
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
Verification: every Phase 1 screen screenshotted in both themes; increase-contrast spot check.
Done when: no surface or text ignores the theme; no white flash on dark launch.

### P1.8 — Identity-only profiles
- [ ] Spec `specs/P1.8-profiles-identity.md` (model, validation, snapshot semantics for Phase 3).
- [ ] `ProfileStore` (`profiles.json`), `GitProfile`, `GitIdentity`, `ProfileSnapshot`.
- [ ] Create/edit sheet with validation and "Fill from Git config".
- [ ] Profile indicator in tab bar; switcher popover (search > 6, active check, New/Manage).
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
- [ ] Measure (release build): warm/cold launch with 0 and 5 restored tabs; idle CPU and wakeups with
      5 tabs over 60 s; tab switch latency (signpost from click to content committed) for loaded and
      unloaded tabs; memory after opening/closing a repository 50 times (DEBUG-only stress command or
      UI-test loop) — no sustained growth; idle network = none (`nettop -p <pid>` / `lsof -i -p`).
- [ ] Update `docs/performance.md`.
Done when: numbers recorded honestly; regressions versus Phase 0 explained or fixed.

## 3. Test plan summary

| Layer | Coverage |
|---|---|
| Rust unit | porcelain v2 parser (all record types, edge paths), operation-state detection, cache generations |
| Rust integration | status counts on real repos, no index writes during status, coalescing, staleness |
| Swift unit | stores (persistence, corruption, permissions), app/tab model logic, layout clamping, FSEvent classifier, profiles + snapshot |
| Swift UI | new tab, open via hook, tab cycling/close/reopen, theme switch, profile create/switch, menu states |
| Manual | drag reorder, overflow, full screen, VoiceOver, Reduce Motion, increase contrast, external edits |

## 4. Performance checks

| Check | Target | Method |
|---|---|---|
| Warm launch, 5 restored tabs | < 500 ms first window | `scripts/benchmarks/launch.sh` |
| Idle CPU, 5 tabs, app active | 0.0–0.2 % | `scripts/benchmarks/idle.sh` |
| Idle CPU, app in background | ~0 %, no FSEvents callbacks | idle script + debug counter of callbacks |
| Tab switch (loaded) | < 16 ms to committed frame | signposts in Instruments |
| Memory growth over 50 open/close | no sustained growth | footprint before/after |
| Idle network | none | `nettop`/`lsof` |
| Status refresh on 10k-file churn | coalesced; record count + CPU | P1.6 churn script |

## 5. Docs to update

`docs/architecture.md` (state, lifecycle, persistence, watching), `docs/design-system.md` (tab bar,
popover, new-tab tile, workbench header patterns), `docs/performance.md`, `docs/security.md`
(file permissions, NSWorkspace launching), `docs/product.md` (shortcut table, Phase 1 behavior),
ADR-0007, ADR-0008, CLAUDE.md if commands change, `progress.md`.

## 6. Exit checklist

- [ ] Demo in design §1 works end to end on real repositories (regular, bare, linked worktree,
      large repo).
- [ ] Only the active/visible tab does work; background app does none (verified).
- [ ] Global `~/.gitconfig` unchanged by any Phase 1 action (checksum evidence).
- [ ] No placeholder actions on the new-tab page, menus, or workbench.
- [ ] Screenshots for every new screen and state in light and dark.
- [ ] Performance table updated; no regressions versus Phase 0 without explanation.
- [ ] ADR-0007 and ADR-0008 written; docs updated; roadmap §9 gate satisfied; `progress.md` complete; PR opened.
