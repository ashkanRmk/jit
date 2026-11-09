# ADR-0007: State management and persistence

- Status: accepted
- Date: 2026-11-09
- Phase: P1
- Requirements: §4.1–§4.6, §14, §15.2–§15.4; ADR-0002, ADR-0005, ADR-0006

## Context
Phase 1 turns the single foundation window into the application shell: repository tabs, per-tab Git state
that must update live, persisted layout/session/recents/profiles, and a startup that shows the window
before any Git work. Later phases add large per-tab state (graph, diff, composer). Requirements: idle
CPU ≈ 0, no repeating timers, Observation must invalidate narrowly, and nothing on the main actor waits on
Git. Options considered: one big observable app store; Combine publishers; small `@Observable` models per
concern. Persistence: Core Data/SQLite vs `UserDefaults` + small JSON files.

## Decision
- **One main window** with repository tabs in V1 (`AppModel` per window keeps multi-window possible later).
  AppKit lifecycle (`@main` app delegate, `NSWindowController`, code-built `NSMenu`), SwiftUI for content.
- **Small `@Observable` models, `@MainActor`:** `AppModel` (tab order, active tab, reopen stack, stores),
  `TabModel` per tab (title, branch, status dot — all the tab strip observes), `RepositorySession` per
  repository tab in `Services` (lifecycle, `info`, `status`, `error` as separate properties),
  `LayoutState`, `PreferencesStore`, `RecentsStore`, `ProfileStore`. AppKit controllers receive explicit
  change callbacks (or `withObservationTracking`) — no polling, no Combine.
- **Git state lives in `GitCore` actors:** `RepositoryHandle` (one per open repository) is the single
  per-repository serialization point and cache; `Services` imports `GitCore` directly (no bridge layer).
- **Lifecycle:** `unloaded → loading → active ⇄ inactive → suspended`, `closed`. Only the visible tab of a
  foreground window is `active`; memory pressure (dispatch source, event-driven) suspends inactive sessions.
- **Persistence:** `UserDefaults` for preferences; versioned JSON files in `~/Library/Application
  Support/Jit` (`0700`) — `session.json`, `recents.json`, `profiles.json` — written atomically (`0600` temp
  file + `fsync` + `rename`), off the main actor, debounced by one cancellable one-shot task (500 ms), and
  flushed synchronously at termination. Unknown versions and unreadable files are backed up
  (`.bak-<timestamp>`) and reset. Per-tab feature state is an opaque versionable JSON blob (`ui`) that
  Phase 1 round-trips without interpreting. No database; no security-scoped bookmarks (sandbox off).
- `JIT_APP_SUPPORT=<dir>` redirects the store directory (tests, screenshots, benchmarks), in all builds.

## Consequences
- Startup reads three tiny files synchronously (< 5 ms) and shows cached tab titles immediately.
- A status change re-renders one tab and that tab's workbench only.
- Later phases add their per-tab state under `ui[<feature>]` with their own versions, and new stores as
  further small observable models — not fields on `AppModel`.
- Revisit if multiple main windows are required (move session state per window) or if per-tab state grows
  beyond what a single JSON write can carry cheaply.
