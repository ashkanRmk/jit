# Phase 1 — Native Shell & Repository Tabs: design

Sources: §4.1, §4.2, §4.3 (skeleton), §4.5 (skeleton), §4.6, §6.2 (identity prerequisite), §10.1–10.2
(identity subset), §14, §15.2–§15.4, §17. Roadmap §3 moves identity-only profiles into this phase.

## 1. Goal & demo

Turn the foundation window into the real application shell: repository tabs, a new-tab page, the
three-region workbench skeleton, live repository status driven by FSEvents, persisted themes and
layout, identity-only Git profiles with a global switcher, and native menus — all with idle CPU ≈ 0.

**Demo**

1. Launch: the window appears immediately with previously open tabs restored (titles and order
   from the session file); only the active tab loads Git data.
2. ⌘T opens the new-tab page; open a repository via button, recents, or by dragging a folder in.
3. Tabs: reorder by drag, close by button / middle-click / ⌘W, switch with ⌃Tab and ⌘⇧[ / ⌘⇧].
   Many tabs overflow gracefully.
4. Each repository tab shows current branch, upstream ahead/behind, change counts, and an operation
   state badge (merging/rebasing/…) in an honest skeleton workbench; editing a file in another app
   updates the counts within ~0.5 s while the tab is visible.
5. Settings: Light / Dark / System persists. Profiles: create "Personal" and "Work" identities, switch
   from the tab-bar profile indicator; every tab reflects the active profile.
6. Activity Monitor shows ~0 % CPU when idle with 5 tabs open; no network activity.

## 2. Scope / out of scope

**In scope:** app state architecture, persistence, tab bar, new-tab page, workbench skeleton with
persisted split widths, Rust status parsing (summary exposed now, full entries parsed and cached for
Phase 3), repository operation-state detection, FSEvents watching, theme setting, identity-only
profiles + switcher + indicator, menus/shortcuts, Settings window (General, Profiles), lazy tab restore,
measurements.

| Not in Phase 1 | Lives in |
|---|---|
| Graph, branch lists in sidebar, commit details | Phase 2 |
| File lists, diff, staging, commit composer | Phase 3 |
| Clone from URL, fetch/pull/push, checkout | Phase 4 |
| Provider browsing (GitHub/GitLab), auth, SSH/PAT/OAuth fields on profiles | Phase 5 |
| Command palette (⌘K), density setting UI, text-size preference | Phase 6 |
| Multiple main windows | Open question (§7); V1 assumes one main window |

The new-tab page shows only actions that work: Open Local Repository, Recents, drag-and-drop. "Clone
from URL" appears in Phase 4 and provider browsing in Phase 5.

## 3. User experience

### 3.1 Window and tab bar

- **Structure:** single main window, full-size content view, transparent titlebar. The tab bar lives in
  the titlebar row (36 pt) to the right of the traffic lights: `[● ● ●] [tab][tab][tab] [+] ··· [⌄] [profile]`.
  Empty space in the bar remains a window drag region; double-click on empty space zooms (respect the
  system "double-click title bar" setting).
- **Tab anatomy:** status dot (6 pt) · repository name (`type.headline`, truncated tail) · close button
  (appears on hover or when active; always reachable by keyboard). Width: min 132, ideal fits name, max
  232 pt. Tooltip: full path + branch.
- **Status dot semantics:** none = clean or not yet loaded · `text.tertiary` hollow = not loaded yet ·
  `accent.base` = local changes · `status.warning` = merge/rebase/cherry-pick/revert in progress ·
  `status.danger` = conflicts or repository error. Color is never the only signal: tooltip and VoiceOver
  label carry the meaning.
- **Active tab:** `surface.canvas` fill that visually merges into the content below (the bar itself is
  `surface.panel`), 1 px top hairline in light theme, text `text.primary`; inactive tabs `text.secondary`
  with hover fill `state.hover`. Selection transition `motion.select` (150 ms) on fill/text color only.
- **Reorder:** drag a tab; neighbors slide (`motion.select`); dropping outside the bar does nothing in V1
  (no tear-off). Reduce Motion → instant reflow.
- **Close:** button, middle-click, ⌘W. Closing the active tab activates the tab to its right, else left.
  Closing the last tab shows the new-tab page (the window stays). ⌘⇧T reopens the last closed tab
  (in-memory stack of 10, not persisted).
- **Overflow:** tabs compress to min width, then the strip scrolls horizontally (trackpad/scroll wheel)
  with soft edge fades; the `⌄` button lists all tabs in a menu with status and path.
- **Profile indicator (right edge):** 18 pt colored circle with initials + display name (hidden below
  1100 pt window width; circle only). Click → profile switcher popover (§3.5). No profile → warning-tinted
  "No Profile" pill.
- **Keyboard:** ⌃Tab / ⌃⇧Tab and ⌘⇧] / ⌘⇧[ cycle tabs; ⌘T new tab; ⌘W close; ⌘⇧T reopen. ⌘1–⌘3 are
  reserved for workbench modes (§17) and must not switch tabs.
- **Accessibility:** tab bar is an `AXTabGroup`; each tab an `AXRadioButton`-like element with label
  "<name>, <status>, tab n of m"; close buttons labelled "Close <name>"; reorder available via
  accessibility actions "Move left/right" (and Window menu items "Move Tab Left/Right").

### 3.2 New-tab page

- **Hierarchy:** centered column (max 640 pt) on `surface.canvas`. Top: product wordmark small and quiet
  (`type.title`, `text.tertiary`). Primary action tile row: "Open Repository…" (⌘O) tile (`surface.raised`,
  `radius.xl`, icon + title + one-line hint). Below: "Recent" list (up to 12) — name (`type.headline`),
  path (`type.mono.caption`, middle-truncated, `text.tertiary`), branch at last open (`type.callout`),
  relative last-opened time right-aligned. Hover reveals "Reveal in Finder" and "Remove from Recents".
- **Drop target:** dragging a folder anywhere over the window shows a full-content overlay with a dashed
  `accent.base` outline at `radius.xl` and "Open as Repository" label; non-repositories show the error
  inline after drop.
- **States:** empty recents → a single sentence and the open tile, no illustration. Missing recent path
  → row in `text.disabled` with "Not found — Locate… / Remove". Loading not needed (recents are local).
- **Keyboard:** arrow keys move through recents, Return opens, ⌫ removes (with undo via ⌘Z).
- **Accessibility:** recents are a list with row labels "<name>, <path>, opened <time>".

### 3.3 Repository workbench skeleton

- **Layout:** `NSSplitView`-backed three regions: sidebar (left), main (center), inspector (right). Widths
  persist per window (global, not per tab — fewer surprises) with per-tab collapse state. Sidebar toggle
  ⌃⌘S, inspector toggle ⌥⌘0, animated `motion.panel` (instant with Reduce Motion).
- **Repository header (top of main):** name, branch (or "Detached at <short sha>", or "No commits yet"),
  upstream with ahead/behind arrows and counts (`type.callout`, monospaced digits), operation state chip
  ("Merging", "Rebasing 3/7" if available, "Cherry-picking", "Reverting", "Bisecting").
- **Region content in Phase 1 (honest):**
  - Sidebar: repository summary section (path, kind, worktree/bare badge). Branch lists arrive in Phase 2
    — do not show empty "Branches" headers.
  - Main: status summary block — staged / unstaged / untracked / conflicted counts with small glyphs.
    "History graph" does not appear until Phase 2.
  - Inspector: "Working directory" summary with counts and "Open in Finder / Terminal" actions.
- **States:** loading (skeleton shimmer is NOT used — a static faint placeholder appears only after
  150 ms), normal, error (repository missing / not a repository anymore / permission denied / Git
  missing) with recovery actions: Locate…, Remove Tab, Retry.
- **Bare repositories:** no working-directory counts; show "Bare repository — no working tree".

### 3.4 Settings window

SwiftUI `Settings` scene (⌘,): **General** — Appearance (System / Light / Dark segmented, live), "Restore
tabs on launch" toggle (default on). **Profiles** — list + editor (§3.5). Native form styling with
tokens for colors only where the system doesn't already supply them.

### 3.5 Identity-only profiles

- **Model surface in UI:** display name, color (8 swatches from the lane palette's neighbors, not
  lane-identical), author name, author email, optional committer name/email (disclosure, collapsed).
- **Create/edit sheet:** fields with inline validation (name non-empty; email contains one `@` and a dot
  in the domain — warn, don't block, on unusual addresses). "Fill from Git config" button reads
  `git config --global user.name/user.email` read-only and pre-fills. Sheet copy states: "Jit never
  changes your global Git configuration."
- **Switcher popover (from tab-bar indicator):** `radius.lg` popover, `shadow.2` (light). Rows: color
  circle, display name (`type.headline`), `name <email>` (`type.callout`, `text.secondary`), checkmark on
  active. Search field appears when > 6 profiles. Footer: "New Profile…", "Manage Profiles…". One click
  switches; the indicator cross-fades (150 ms). Phase 5 adds provider/auth status to rows.
- **No profile state:** indicator pill `status.warning`; popover explains "Commits need an identity" with
  "Create Profile…" and "Fill from Git config".
- **Accessibility:** popover rows are buttons labelled "<display name>, <email>, active/inactive".

### 3.6 Menus

Only menus with at least one implemented item are shown. Phase 1:

| Menu | Items |
|---|---|
| Jit | About, Settings… ⌘,, Hide/Quit (standard) |
| File | New Tab ⌘T, Open Repository… ⌘O, Open Recent ▸ (with Clear Menu), Close Tab ⌘W, Reopen Closed Tab ⌘⇧T, Close Window ⌘⇧W |
| Edit | standard |
| View | Show/Hide Sidebar ⌃⌘S, Show/Hide Inspector ⌥⌘0, Appearance ▸ System/Light/Dark, Enter Full Screen |
| Repository | Refresh ⌘R, Reveal in Finder ⌥⌘R, Open in Terminal ⌥⌘T, Copy Repository Path ⌥⌘C |
| Window | standard + Select Next/Previous Tab, Move Tab Left/Right, list of tabs |
| Help | Jit Help (links to bundled docs page or GitHub README — no network fetch by the app itself) |

Branch and Git Operations menus appear in Phases 2/4 when they have items. Keyboard equivalents must not
collide with standard macOS shortcuts; verify against Apple's HIG list.

## 4. Technical design

### 4.1 State architecture (ADR-0007)

All UI state types are `@MainActor`; Rust work happens off-main through `GitCoreBridge`.

| Type | Kind | Owns | Observed by |
|---|---|---|---|
| `AppModel` | `@Observable` | `tabs: [TabID]`, `activeTabID`, `recentlyClosed`, reference to stores | tab bar, window |
| `TabModel` | `@Observable` per tab | `id`, `kind (.newTab / .repository(RepositoryRef))`, `title`, `statusDot` | its tab view only |
| `RepositorySession` | `@Observable` per repository tab | lifecycle, `RepositoryInfo`, `StatusSummary`, `OperationState`, error | workbench views of that tab |
| `PreferencesStore` | `@Observable` | theme, restore-tabs flag (UserDefaults) | settings, app |
| `SessionStore` | plain class | read/write `session.json` | `AppModel` |
| `RecentsStore` | `@Observable` | recents list (JSON) | new-tab page, Open Recent menu |
| `ProfileStore` | `@Observable` | profiles, `activeProfileID` | indicator, popover, settings |
| `LayoutState` | `@Observable` | split widths, collapse flags | split view controller |

Rules: no type publishes a whole repository struct when one field changes; the tab bar observes only
`TabModel` fields; `RepositorySession` splits frequently changing values (`statusSummary`) from stable
ones (`info`) into separate properties so Observation invalidates narrowly.

**RepositorySession lifecycle**

```
unloaded ──(tab shown)──▶ loading ──▶ active ──(tab hidden / app inactive)──▶ inactive
   ▲                                    ▲                                         │
   │                                    └──(tab shown / app active: 1 revalidation)┘
   └──(memory pressure: drop caches, keep TabModel)── suspended ◀── inactive
closed: watcher stopped, Rust handle released, tasks cancelled
```

- `unloaded`: restored tab never shown. No Rust handle, no watcher. Title comes from `session.json`.
- `active`: FSEvents stream running; refreshes happen in response to events.
- `inactive`: watcher stopped, in-flight work cancelled, last state kept for instant re-display.
  Re-activation triggers exactly one revalidation (status refresh).
- `suspended`: on `DispatchSource.makeMemoryPressureSource(.warning)` (event-driven, no timer), inactive
  sessions release caches in Rust and Swift.

### 4.2 Persistence

- `~/Library/Application Support/Jit/session.json` — `{ version, windowFrame, layout { sidebarWidth,
  inspectorWidth }, tabs: [{ id, kind, path?, titleCache, branchCache, sidebarCollapsed,
  inspectorCollapsed, ui }], activeTabID }`. `ui` is a per-tab dictionary keyed by feature
  (`graph`, `navigator`, `diff`, `composer`, …) that later phases fill with their own small, versioned
  state (scroll anchor, selected commit, pinned refs, expanded groups, diff mode, composer draft);
  Phase 1 stores and round-trips it without interpreting it. Versioned; unknown versions → back up the file as
  `session.json.bak-<date>` and start fresh.
- `recents.json` — `[{ path, name, lastOpened, lastBranch }]`, max 20, de-duplicated by resolved path.
- `profiles.json` — `{ version, profiles: [Profile] }`, `activeProfileID` in the same file. No secrets
  in this phase or any phase (Phase 5 stores only Keychain references).
- Writes: atomic (`Data.write(options: .atomic)`), `0600` permissions, off-main on a utility queue,
  debounced with a one-shot `DispatchWorkItem` (cancel + reschedule, 500 ms) — never a repeating timer —
  and flushed synchronously-but-fast in `applicationWillTerminate`.
- Paths are stored as standardized absolute paths (Unicode-normalized to the form returned by
  `URL.standardizedFileURL`). No security-scoped bookmarks (App Sandbox off — ADR-0006).

### 4.3 Rust: status and operation state

```rust
// git-core
pub struct StatusSnapshot {
    pub revision: u64,                       // per-repository generation counter
    pub branch: BranchHeader,                // oid, head name | detached | unborn, upstream, ahead, behind
    pub entries: Vec<StatusEntry>,           // full parse kept in Rust for Phase 3
    pub summary: StatusSummary,              // staged, unstaged, untracked, conflicted, ignored_skipped
}
pub enum OperationState { None, Merging, Rebasing { step: Option<u32>, total: Option<u32> },
                          CherryPicking, Reverting, Bisecting, ApplyingMailbox }
```

- Command: `git --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=normal`
  (exact flags confirmed against the minimum Git version, ADR-0006). `--no-optional-locks` /
  `GIT_OPTIONAL_LOCKS=0` is essential: without it `status` may rewrite `.git/index`, which fires
  FSEvents, which triggers another status — a feedback loop that burns CPU.
- Parser handles: headers `# branch.oid|head|upstream|ab`; entries `1` (ordinary), `2` (rename/copy —
  the `-z` form has an extra NUL-separated original path), `u` (unmerged), `?`, `!`; Unicode and
  unusual paths (no quoting with `-z`); submodule state field.
- `OperationState` detection reads the git dir: `MERGE_HEAD`, `rebase-merge/` (`msgnum`, `end`),
  `rebase-apply/` (`next`, `last`, `applying`), `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG`.
- Cache: one `RepositoryState` per open handle holds the last `StatusSnapshot`. `invalidate(kind)`
  bumps the generation; `status_summary()` recomputes only when invalidated. Concurrent refresh
  requests coalesce: one in flight + at most one queued; stale results (older revision) are discarded.

**Bridge sketch**

```rust
#[uniffi::export]
impl GitEngine {
    pub fn open_repository(&self, path: String, cancel: Arc<CancelToken>) -> Result<Arc<RepositoryHandle>, CoreError>;
}
#[derive(uniffi::Object)] pub struct RepositoryHandle { /* id, paths, Mutex<RepositoryState> */ }
#[uniffi::export]
impl RepositoryHandle {
    pub fn info(&self) -> RepositoryInfo;
    pub fn status_summary(&self, cancel: Arc<CancelToken>) -> Result<StatusSummaryRecord, CoreError>; // includes revision, branch header, operation state
    pub fn invalidate(&self, kinds: Vec<InvalidationKind>);   // Worktree, Index, Refs, Head, Config
    pub fn release_caches(&self);
}
#[derive(uniffi::Enum)] pub enum InvalidationKind { Worktree, Index, Refs, Head, Config, OperationState }
```

```swift
@MainActor final class RepositorySession {
    func activate()          // start watcher, revalidate
    func deactivate()        // stop watcher, cancel tasks
    func refresh(reason: RefreshReason) async
}
```

Status summaries are small records; full entries stay in Rust until Phase 3 asks for them in pages.

### 4.4 File watching (ADR-0008)

- `RepositoryWatcher` (Swift, `Services`) wraps one `FSEventStream` per **active** session, scheduled on
  a private serial dispatch queue (`FSEventStreamSetDispatchQueue`), latency 0.2 s (FSEvents' own
  coalescing — no timers of ours), flags `kFSEventStreamCreateFlagUseCFTypes |
  kFSEventStreamCreateFlagWatchRoot` (directory-level events; *not* per-file events).
- Watched roots: worktree top level, plus absolute git dir and common dir when they are outside the
  worktree (linked worktrees, `--separate-git-dir`). Bare repos: git dir only.
- Classification (pure function, unit tested): paths under `.git/objects/`, `*.lock`, `.git/logs/` →
  ignore; `.git/index` → `Index`; `.git/HEAD` → `Head`; `.git/refs/**`, `.git/packed-refs` → `Refs`;
  `.git/config` → `Config`; `MERGE_HEAD` etc. → `OperationState`; anything in the worktree → `Worktree`.
  `kFSEventStreamEventFlagMustScanSubDirs` / `RootChanged` → full revalidation (or repository-moved error).
- Per batch: compute the set of kinds, call `handle.invalidate(kinds)`, then one `refresh`. Refreshes
  coalesce as described in §4.3.
- Lifecycle: stream runs only while the app is active **and** the tab is visible and the window is not
  miniaturized/occluded (`NSWindow.occlusionState`). On app activation: one revalidation of the visible
  tab; no stream while backgrounded. This gives zero idle work in the background.
- Heavy churn (e.g. a build writing thousands of ignored files) still triggers coalesced status runs;
  measure in P1.10 and note mitigation options (ignore-aware filtering) as Phase 6 follow-ups.
- Respect user `core.fsmonitor` configuration as Git does; Jit doesn't enable or disable it.

### 4.5 Tab bar implementation

- AppKit `NSView` subclass hierarchy (`TabStripView` with lightweight `TabItemView`s, CALayer-backed,
  no per-frame work) placed in the titlebar via the window's full-size content view with a
  `NSTitlebarAccessoryViewController` or a custom container aligned to the traffic lights. Window
  dragging handled through `mouseDownCanMoveWindow` on empty areas.
- Drag reorder uses local mouse tracking (not pasteboard) for smoothness; animations via
  `NSAnimationContext` with token durations; `allowsImplicitAnimation` off during bulk changes.
- SwiftUI hosts the content area per tab (`NSHostingView`), one hosting view per *loaded* tab kept alive
  while inactive (instant switching), released when suspended.

### 4.6 Profiles (identity subset)

```swift
struct GitProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var colorIndex: Int
    var author: GitIdentity                 // name, email
    var committer: GitIdentity?             // optional override
    // Reserved for Phase 5 (absent from JSON until then): providerAccountID, transport, sshIdentityRef,
    // httpsCredentialRef, networkingRef, signing
}
struct ProfileSnapshot: Sendable { let profileID: UUID; let author: GitIdentity; let committer: GitIdentity }
```

- `ProfileStore.snapshot()` returns an immutable `ProfileSnapshot`; Phase 3 operations capture it at
  start (§6.2, §10.2) and Rust receives identity via `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env for that one
  invocation. Phase 1 only builds and tests the snapshot type.
- Reading `git config --global user.*` for pre-fill goes through `GitEngine` (read-only `git config
  --global --get`), never by parsing files directly.

### 4.7 Startup sequence (§15.2)

1. `applicationDidFinishLaunching`: read `session.json` + preferences synchronously (small files,
   < 5 ms), build `TabModel`s from cached titles, show the window.
2. After first frame: create `GitEngine` off-main; activate the active tab's session (open handle,
   status). Other tabs stay `unloaded`.
3. No network, no scans of other repositories, no provider initialization.

### 4.8 Security

- Menu actions launching apps use `NSWorkspace` APIs (Terminal via `open(_:withApplicationAt:)`), never
  shell commands. Paths passed as URLs.
- JSON stores `0600`; Application Support directory created with `0700`.
- Repository paths from drag-and-drop or recents are re-validated by discovery before use.

## 5. Edge cases & failure modes

- Restored repository moved/deleted/unmounted → tab error state with Locate…/Remove; no crash; recents
  marked missing.
- Same repository opened twice → focus the existing tab (compare resolved top-level path).
- Opening a subdirectory → opens the repository top level (show a subtle note).
- Repository deleted while open → FSEvents `RootChanged` → error state.
- Corrupt/partial `session.json` (e.g. power loss) → atomic writes prevent; if unreadable, back up and
  start with the new-tab page.
- `.git/index.lock` left by a crashed Git → status reads still work (`--no-optional-locks`); show nothing
  in Phase 1 (lock handling UI is Phase 4).
- Huge repositories: first status may take seconds → loading placeholder after 150 ms, cancellable on tab
  switch/close.
- Many tabs (50+) → overflow works; only visible/active sessions do work.
- Profile deleted while active → active becomes none → indicator shows "No Profile"; never auto-pick
  another profile silently.
- Theme switching while popovers/sheets open → all surfaces update (dynamic colors).
- Two displays with different scale factors → tab bar hairlines remain crisp (use backing-aligned rects).

## 6. ADRs to write

- **ADR-0007** State management & persistence (Observation granularity, stores, JSON files, single main
  window assumption, lifecycle states).
- **ADR-0008** File watching (FSEvents directory-level streams, classification, active-only policy,
  `--no-optional-locks`, fsmonitor stance).

## 7. Open questions / spikes

| Question | How to decide |
|---|---|
| Custom titlebar tab strip via accessory VC vs. custom container | Spike both for 1 day max: correct traffic-light spacing, full-screen behavior, window dragging, VoiceOver. Pick the one with fewer AppKit hacks. |
| Keep inactive tabs' hosting views alive vs. rebuild on switch | Measure memory per loaded tab and switch latency with 10 tabs; target < 16 ms switch and < 15 MB per idle tab. |
| Multiple main windows in V1 | Default no (ADR-0007). Revisit if users need side-by-side repos; architecture keeps `AppModel` per window possible. |
| Status cost on very large worktrees | Benchmark on a 100k-file repo; if > 1 s, plan ignore-aware event filtering or untracked-files mode tuning for Phase 6. |
| Where to show repository errors that affect a background tab | Status dot `status.danger` + tooltip; no notifications in V1. |
