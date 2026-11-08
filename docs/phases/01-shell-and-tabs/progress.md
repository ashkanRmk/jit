# Phase 01 — Native shell & repository tabs: progress report

Status: **complete with carry-overs** (listed below)
Branch / PR: `phase/01-shell-and-tabs` (cut from the tip of `phase/00-foundation` — Phase 0's PR #1 was not merged
yet and the owner asked to start Phase 1), PR "Phase 01 — Native shell & repository tabs"
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2,
Git 2.54.0 (Homebrew), XcodeGen 2.46.0

## Kickoff carry-overs from Phase 0
- **CI on PR #1** had failed in 0 s: `ci.yml` used `${{ runner.temp }}` in job-level `env`, where the `runner`
  context isn't available. Fixed (`ci: set DerivedData path from a step…`); the first run with the fix built,
  linted and tested the Phase 0 code green on `macos-26`. PR #1 still contains the broken workflow until that
  commit is cherry-picked onto it.
- **Real glass captures:** Screen Recording is available in this session, so every Phase 1 screenshot is a real
  window-server capture (glass included). **Reduce Transparency / Increase Contrast** need the system setting
  toggled by a person (Jit and this agent don't change system settings): `scripts/testing/capture-accessibility.sh
  <suffix>` is ready for that — carried over below.
- **Inactive-window CPU burst** (Phase 0 observation): not reproduced in three 60 s idle runs (active, background).
- Cold launch / GPU power: still user-run (reboot / root) — carried over.

## Implemented
- **P1.1 State & persistence** — new `Services` target: versioned atomic `0600` JSON files with backup-on-corrupt,
  one-shot debounced writer, `SessionStore`, `RecentsStore`, `PreferencesStore`, `ProfileStore`; `AppModel`,
  `TabModel`, `LayoutState`; `RepositorySession` lifecycle; memory-pressure source; ADR-0007. Evidence:
  `SessionStoreTests` (7), `RecentsStoreTests` (4), `AppModelTests` (14), `RepositorySessionTests` (9),
  `specs/P1.1-state-and-persistence.md`.
- **P1.2 Tab bar** — unbordered toolbar item hosting one SwiftUI `GlassEffectContainer`; capsule tabs with status
  dots, selection tint + morph, hover, close button, middle-click, drag reorder, overflow scrolling + all-tabs
  menu, ⌃Tab/⌘⇧[ ]/⌘W/⌘⇧T, Move Tab Left/Right, VoiceOver labels/actions, Reduce Transparency/Motion and
  Increase Contrast handling; window title/subtitle set for the system. Spike result in `specs/P1.2-tab-bar.md`.
  Evidence: `TabOrderingTests`, `MenuStateTests`, real-input checks below, `screenshots/tabbar-*`.
- **P1.3 New-tab page** — primary glass Open Repository…, opaque recents (keyboard, ⌫ + ⌘Z, hover actions,
  missing rows with Locate…/Remove), window-wide opaque drop overlay, open flow focusing existing tabs, Open
  Recent menu, Finder/`open -a` folders, `-JitUITestOpenRepository`. Evidence: `screenshots/newtab-*`, tests above.
- **P1.4 Workbench skeleton** — `NSSplitViewController` with system glass sidebar and inspector; header (branch /
  detached / unborn, upstream ↑↓ or "upstream gone", operation chip); status cards; loading (after 150 ms) /
  error (Retry, Locate…, Remove Tab) / bare states; global widths, per-tab collapse. Evidence:
  `LayoutStateTests`, `screenshots/workbench-*`.
- **P1.5 `GitCore` status** — byte-level porcelain v2 `-z` parser into compact `StatusEntries`;
  `OperationStateDetector`; `RepositoryHandle` actor (generation cache, coalescing, stale discard, cancellation
  kills Git); `openRepository`, `readGlobalIdentity`; discovery reports `pathNotFound` for missing folders.
  Evidence: `StatusParserTests` (11, one with 5 malformed inputs), `OperationStateDetectorTests`,
  `StatusIntegrationTests` (14), JitBench `status-parse`.
- **P1.6 File watching** — directory-level FSEvents per visible repository, pure classifier, coalesced refreshes
  with a churn duty-cycle rest, root-deleted → error, stream only in the foreground; ADR-0008. Evidence:
  `FSEventClassifierTests` (8), `RepositorySessionTests` (live edit < 1 s, commit from outside, no events while
  inactive, churn, deleted repo, no index-write loop), `AppModelTests.testNoStreamWhenAppInactive`.
- **P1.7 Theme** — System/Light/Dark in Settings ▸ General and View ▸ Appearance, applied before the window
  exists, live on change. Evidence: `PreferencesStoreTests.testAppearancePersists`, every screenshot in both themes.
- **P1.8 Identity-only profiles** — `GitIdentity` (GitCore), `GitProfile`/`ProfileSnapshot`/validation (Services),
  toolbar capsule (system prominent warning tint for "No Profile"), switcher popover, editor sheet with read-only
  "Fill from Git config", Settings ▸ Profiles with delete confirmation. Evidence: `ProfileStoreTests` (5),
  `ProfileJSONTests`, `screenshots/profile-*`, `settings-*`, `~/.gitconfig` checksum below.
- **P1.9 Menus & shortcuts** — code-built menu bar with only working items (no Branch/Git menus), validation for
  new-tab vs repository tabs, NSWorkspace actions, shortcut table in `docs/product.md`. Evidence: `MenuStateTests` (3).
- **P1.10 Restore & measurements** — cached-title restore, active-tab-only loading after the first frame, error
  tabs for missing repositories, all measurements below. `docs/performance.md` updated.

## Verified
- Tests: `swift test` **120 passed** (GitCoreTests 73, ServicesTests 35, DesignSystemTests 12) — stress-run 5×
  after the final changes, 5/5 green; `xcodebuild test` (JitAppTests)
  **23 passed**; skipped: none. Lint clean.
- Real-workflow checks (debug app, real repositories, real input via MacOS-MCP pointer/keyboard events): this
  repository (counts matched `git status` exactly: 3/6/9/0, ↑2 ↓0), a clone, a bare clone, a linked worktree, a
  merge in progress ("Merging", conflict → danger dot), an interactive rebase stopped on a conflict ("Rebasing 2/3",
  detached), a 50,000-file repository (101 unstaged / 300 untracked), a missing path (error tab), 40 tabs. ⌃Tab
  cycling, middle-click close, close-button click (found broken, fixed), ⌘W, ⌘⇧T reopen at position, drag reorder,
  window drag from empty strip space, overflow scroll-into-view, external edit → count updated, profile created via
  "Fill from Git config", quit flushes session (order, active tab, window frame). Quit leaves no Git process.
- `~/.gitconfig` SHA-256 before and after all profile operations (incl. Fill from Git config):
  `b00247605a19f522c00f8aee694e21f1d36d5ddcf0706883015c5d9842af930f` — unchanged (re-checked at the end of the
  phase). State files `0600`.
- Screenshots: `docs/phases/01-shell-and-tabs/screenshots/` — 42 real captures (21 screens × light/dark), see its README.

## Performance (release build)
| Metric | Previous | Now | Method |
|---|---|---|---|
| Warm launch → key, no tabs | 237.1 ms median | 256.8 ms median, p90 265.0 (n = 20) | `launch.sh --key 20` |
| Warm launch → key, 5 restored tabs | — | 293.0 ms median, p90 302.1 (n = 20) | `JIT_APP_SUPPORT=<5 tabs> launch.sh --key 20` |
| Idle CPU / wakeups, no repo, active | 0.0 % / 0 | 0.0 % / 0, 31 MB | `idle.sh` |
| Idle CPU / wakeups, 5 tabs, active | — | 0.0 % / 0, 40–41 MB, 3–4 threads (2 runs) | `JIT_ACTIVATE=1 idle.sh` |
| Idle CPU / wakeups, 5 tabs, background | — | 0.0 % / 0, 40 MB | `idle.sh` |
| Tab switch, loaded | — | 6.6–7.0 ms median, p90 ≤ 10.1 | `JIT_BENCHMARK_TAB_SWITCH=1` |
| Tab switch, first show | — | 33.6 ms median | same |
| Memory, 50 open/close cycles | — | 31.6 → 42.2 (warm-up, 10) → 43.3 MB | `JIT_STRESS_OPEN_CLOSE` |
| Idle network | — | none (no sockets, no traffic) | `lsof -i`, `nettop` |
| Status parse, 100k entries | — | 8.68 ms p50 | JitBench |
| 10k ignored-file churn, visible tab | — | 9 status runs, ≈ 3.9 s Git CPU, 0 after | log count |
| Cold launch, idle GPU power | not measured | not measured (user-run) | — |

Full table, reading and methods: `docs/performance.md`.

## Decisions
- ADR-0007 State management & persistence — accepted (small `@Observable` models, one main window, AppKit
  lifecycle, atomic versioned JSON + `UserDefaults`, lifecycle states).
- ADR-0008 File watching — accepted (directory-level FSEvents for the visible tab of a foreground window, pure
  classifier, coalescing, `--no-optional-locks`, Git's trust model for `core.fsmonitor`/filters).
- Tab strip: hosted SwiftUI `GlassEffectContainer` in an **unbordered** toolbar item (the toolbar's own platter
  would otherwise nest glass); equal-width tabs; glass identity by position.
- Security: repository-configured executables during `status` follow Git's trust model (`docs/security.md`).

## Deviations from plan
- **Branch base:** `phase/00-foundation`, not `main` (Phase 0 unmerged; owner's request). Docs updated: yes.
- **UI tests:** no XCUITest target. The agent environment has no Accessibility automation permission (System
  Events keystrokes are refused), so `TabBarUITests`/`NewTabUITests`/`ThemeUITests`/`ProfilesUITests`/
  `MenuUITests` were replaced by model-level app tests (`AppModelTests`, `MenuStateTests` against the real window
  controller's validation, `TabOrderingTests`) plus documented real-input checks. Docs updated: yes.
- **AppKit lifecycle** instead of the Phase 0 SwiftUI `App`/`Window` scene: needed for the toolbar item control,
  menu validation and window restore. `FoundationModel`/`FoundationView` removed.
- **Tab widths are equal** (132–232 pt) rather than "ideal fits name": stable drag math and no layout jumps.
- **`JIT_APP_SUPPORT` works in release builds** (release benchmarks need restored-tab states). Docs: security.md.
- **Spike:** the AppKit `NSGlassEffectContainerView` variant was not built; the SwiftUI container was chosen for
  `glassEffectID` morphs (no AppKit equivalent) and measured idle-clean (`specs/P1.2-tab-bar.md`).
- Opening a subdirectory focuses/opens the top level but shows no "opened from subfolder" note.
- Debug-only screenshot hooks added (`-JitShowDropOverlay`, `-JitShowSettings`, `-JitShowProfilePopover`,
  `-JitShowProfileEditor`).

## Known issues / carry-overs
- **Reduce Transparency / Increase Contrast real captures** — need a person to toggle the setting and run
  `scripts/testing/capture-accessibility.sh reducetransparency|increasecontrast`. Code paths are implemented
  (opaque `surface.chromeOpaque` tabs, accent edges). Medium; owner, before Phase 2 review.
- **VoiceOver pass and Reduce Motion** checked only by code review and labels in tests, not with VoiceOver running.
  Medium; Phase 6 accessibility audit.
- **Framework-internal memory growth** ≈ 16–21 KB per tab open/close (SwiftUI glass container per-identity state,
  AppKit KVO dependency records); no Jit object retained, 0 leaks. Low; Phase 6 (pool workbench controllers).
- **Full-screen mode** and 5K / two-display checks not exercised. Low; Phase 6.
- **Cold launch** and **idle GPU power** — user-run. Low; Phase 6.
- **UI automation suite** (XCUITest) — needs Accessibility automation permission. Medium; Phase 6 visual/UI suite.
- **Churn cost** on very large worktrees (each status ≈ 0.4 s CPU on 50k files) — ignore-aware filtering. Low; Phase 6.
- **Repository paths containing a newline** (Phase 0 carry-over) — still unsupported by discovery. Low; Phase 2.
- **Launch +20 ms vs Phase 0** (AppKit shell, menus, stores) — within budget. Low; Phase 6.

## Self-review findings
A strict review by a separate reviewer (code read only, no shared conclusions) found **no blockers**. Fixed in
`fix: address self-review findings` (each with a test where testable):
- Opening several folders at once (Dock drop, `open -a Jit a b c`, two quick recents) opened only the last —
  opens are now keyed by target; only a newer open of the same target supersedes (`testConcurrentOpensAllComplete`).
- Changes between the first `git status` and the watcher start could be missed — the watcher now starts first
  and events during the load queue a coalesced refresh.
- A debounced write already in flight at ⌘Q wasn't awaited, and an older write could rename over a newer one —
  writes go through a per-file gate ordered by generation; `flush()` waits for it
  (`testFlushAfterInFlightWriteKeepsNewestState`).
- "Fill from Git config" overwrote typed values — fills only empty fields.
- An indeterminate spinner could animate indefinitely while a restored tab waited for the window to reach the
  foreground — the spinner shows only while a load runs; otherwise static text.
- Locate… removed the old recent before the new folder opened — removed only on success
  (`testLocateKeepsRecentWhenNewFolderFails`).
- The status dot said "No local changes" before any status had loaded — now "Not loaded"
  (`testDotIsNotLoadedUntilFirstStatus`).

Logged, not fixed:
- `RecentsStore.noteOpened` resolves up to 20 paths with `realpath` on the main actor, and the watcher's root
  check uses `fileExists` there — a hung network volume could stall the UI. Low; Phase 6 (move off main).
- `.bak-*` backups are unbounded; a crash mid-write can leave a `.tmp-*` file next to the JSON. Low; Phase 6 (prune).
- Benchmark hooks (`JIT_BENCHMARK_*`, `JIT_STRESS_*`) are active in release builds and `JIT_BENCHMARK_OUTPUT`
  appends to a caller-chosen path — env-controlled by whoever launches the process anyway. Low; Phase 7 decides
  whether to compile them out of distributed builds.

Own findings during the phase (all fixed): toolbar wrapped the strip in a second glass platter (nested glass);
overflowing tab glass drew outside the strip; the profile capsule fell into toolbar overflow (strip width from the
wrong leading edge); close-button clicks swallowed by the tab's drag gesture; drop overlay dimmed the toolbar;
email placeholder rendered as a Markdown link; window frame not saved until moved; Settings window "Untitled";
loaded-tab switch 16.7 ms (now 7 ms); churn ran Git back-to-back (now ≤ ~50 % duty); missing-folder discovery
reported a launch failure instead of "This folder no longer exists".

## Next
- Phase 2 (`docs/phases/02-graph-and-navigation`), P2.1. Preconditions: PR #1 and this PR merged (cherry-pick the
  CI fix onto PR #1 or merge this branch's history); optionally the accessibility captures above.
