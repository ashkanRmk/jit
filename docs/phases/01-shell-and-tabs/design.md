# Phase 1 — Native Shell & Repository Tabs: design

Sources: §4.1, §4.2, §4.3 (skeleton), §4.5 (skeleton), §4.6, §6.2 (identity prerequisite), §10.1–10.2
(identity subset), §14, §15.2–§15.4, §17, as amended by [ADR-0002](../../adr/0002-pure-swift-core.md)
(pure Swift) and [ADR-0006](../../adr/0006-platform-baseline-and-liquid-glass.md) (macOS 26+, Liquid
Glass). Roadmap §3 moves identity-only profiles into this phase. Glass usage rules: Phase 0
`design.md` §3.3 and `docs/design-system.md`.

## 1. Goal & demo

Turn the foundation window into the real application shell: repository tabs, a new-tab page, the
three-region workbench skeleton, live repository status driven by FSEvents, persisted themes and
layout, identity-only Git profiles with a global switcher, and native menus — all in native Liquid Glass
chrome over an opaque content layer, with idle CPU ≈ 0.

**Demo**

1. Launch: the window appears immediately with previously open tabs restored (titles and order
   from the session file); only the active tab loads Git data.
2. ⌘T opens the new-tab page; open a repository via button, recents, or by dragging a folder in.
3. Tabs (glass capsules in the toolbar area): reorder by drag, close by button / middle-click / ⌘W,
   switch with ⌃Tab and ⌘⇧[ / ⌘⇧]. Many tabs overflow gracefully.
4. Each repository tab shows current branch, upstream ahead/behind, change counts, and an operation
   state badge (merging/rebasing/…) in an honest skeleton workbench; editing a file in another app
   updates the counts within ~0.5 s while the tab is visible.
5. Settings: Light / Dark / System persists. Profiles: create "Personal" and "Work" identities, switch
   from the toolbar profile capsule; every tab reflects the active profile.
6. Activity Monitor shows ~0 % CPU when idle with 5 tabs open; no network activity; glass chrome adds no
   recurring work.

## 2. Scope / out of scope

**In scope:** app state architecture, persistence, glass tab bar, new-tab page, workbench skeleton with
persisted split widths (system sidebar + inspector), `GitCore` status parsing (summary exposed now, full
entries parsed and cached for Phase 3), repository operation-state detection, FSEvents watching, theme
setting, identity-only profiles + switcher + indicator, menus/shortcuts, Settings window (General,
Profiles), lazy tab restore, measurements. Creates the `Services` target.

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

All chrome in this phase (toolbar, tab bar, sidebar, popovers, sheets) is Liquid Glass via system
components or the `DesignSystem` glass helpers; all content (status blocks, recents list, cards) is
opaque. Content scrolls under the toolbar with the system scroll-edge effect.

### 3.1 Window, toolbar and tab bar

- **Structure:** single main window with the unified system toolbar (`NSToolbar`, `.unified` style) that
  renders as Liquid Glass. Layout of the toolbar row:
  `[● ● ●] [sidebar toggle] ⟨tab strip: (tab)(tab)(tab) (+)⟩ ··· [⌄] [inspector toggle] [profile capsule]`.
  The sidebar and inspector toggles are standard system toolbar items. Empty space in the toolbar remains
  a window drag region; double-click on empty space zooms (respect the system "double-click title bar"
  setting).
- **Tab strip:** one glass container (`GlassEffectContainer` / `NSGlassEffectContainerView` through the
  `DesignSystem` helper) holding capsule-shaped tabs, so the strip reads as one glass surface and tabs can
  morph into each other. No glass is nested inside a tab.
- **Tab anatomy:** status dot (6 pt) · repository name (system toolbar font, truncated tail) · close
  button (appears on hover or when active; always reachable by keyboard). Width: min 132, ideal fits
  name, max 232 pt. Tooltip: full path + branch.
- **Status dot semantics:** none = clean · hollow `text.tertiary` = not loaded yet · `accent.base` = local
  changes · `status.warning` = merge/rebase/cherry-pick/revert in progress · `status.danger` = conflicts
  or repository error. Color is never the only signal: tooltip and VoiceOver label carry the meaning.
  Dots are drawn inside the glass capsule with system vibrancy-aware colors; verify legibility in both
  themes and with Reduce Transparency.
- **Active tab:** the selected capsule carries the selection treatment (subtle `accent.tint` tint per
  the glass tint policy, or the system's selected-glass appearance if the SDK provides one — verify), text
  in the primary label color; inactive tabs untinted with secondary label color and system hover.
  Selection moves with a glass morph (`glassEffectID`, `motion.glassMorph`, ≤ 240 ms, only on user action);
  Reduce Motion → cross-fade.
- **Reorder:** drag a tab; neighbors slide (`motion.select`); dropping outside the bar does nothing in V1
  (no tear-off). Reduce Motion → instant reflow. No glass animation runs after the drop completes.
- **Close:** button, middle-click, ⌘W. Closing the active tab activates the tab to its right, else left.
  Closing the last tab shows the new-tab page (the window stays). ⌘⇧T reopens the last closed tab
  (in-memory stack of 10, not persisted).
- **Overflow:** tabs compress to min width, then the strip scrolls horizontally (trackpad/scroll wheel)
  inside its glass container with system edge treatment; the `⌄` button (system glass toolbar button)
  lists all tabs in a menu with status and path.
- **Window title/subtitle:** the window title is the active repository name and the subtitle its branch
  and ahead/behind (`NSWindow.subtitle`), so Mission Control, the Window menu and VoiceOver get meaningful
  names even though the toolbar shows tabs. Hide the visual title if the tab strip already shows it
  (decide in the P1.2 spike).
- **Profile capsule (trailing toolbar item):** glass capsule button with an 18 pt colored circle +
  initials + display name (name hidden below 1100 pt window width; circle only). Click → profile switcher
  (§3.5). No profile → warning-tinted "No Profile" capsule (the only non-accent tint allowed, because it is
  a status the user must act on — record in `docs/design-system.md`).
- **Keyboard:** ⌃Tab / ⌃⇧Tab and ⌘⇧] / ⌘⇧[ cycle tabs; ⌘T new tab; ⌘W close; ⌘⇧T reopen. ⌘1–⌘3 are
  reserved for workbench modes (§17) and must not switch tabs.
- **Accessibility:** tab strip is an `AXTabGroup`; each tab an `AXRadioButton`-like element with label
  "<name>, <status>, tab n of m"; close buttons labelled "Close <name>"; reorder available via
  accessibility actions "Move left/right" (and Window menu items "Move Tab Left/Right"). Reduce
  Transparency → toolbar and tab strip become opaque (`surface.chromeOpaque` for the custom container).

### 3.2 New-tab page

- **Hierarchy:** centered column (max 640 pt) on opaque `surface.canvas`, scrolling under the glass
  toolbar. Top: product wordmark small and quiet (`type.title`, `text.tertiary`). Primary action: an
  "Open Repository…" (⌘O) prominent glass button (`PrimaryGlassButtonStyle`, the surface's single
  primary action) with a one-line hint beneath. Below: "Recent" list (up to 12) as opaque content rows —
  name (`type.headline`), path (`type.mono.caption`, middle-truncated, `text.tertiary`), branch at last
  open (`type.callout`), relative last-opened time right-aligned. Hover reveals "Reveal in Finder" and
  "Remove from Recents".
- **No glass cards:** recents and any future tiles are opaque (`surface.raised`, `radius.md`), per the
  glass rules (glass belongs to controls, not content cards).
- **Drop target:** dragging a folder anywhere over the window shows a full-content overlay (opaque
  `surface.canvas` at 92 % + dashed `accent.base` outline at `radius.md` and an "Open as Repository"
  label) — not glass, since it covers content; non-repositories show the error inline after drop.
- **States:** empty recents → a single sentence and the open button, no illustration. Missing recent path
  → row in `text.disabled` with "Not found — Locate… / Remove". Loading not needed (recents are local).
- **Keyboard:** arrow keys move through recents, Return opens, ⌫ removes (with undo via ⌘Z).
- **Accessibility:** recents are a list with row labels "<name>, <path>, opened <time>".

### 3.3 Repository workbench skeleton

- **Layout:** `NSSplitViewController` with a **sidebar item** (`NSSplitViewItem(sidebarWithViewController:)`
  — the system renders the macOS 26 glass sidebar), the main content item, and an **inspector item**
  (`NSSplitViewItem(inspectorWithViewController:)`). Sidebar and inspector widths persist per window
  (global, not per tab — fewer surprises) with per-tab collapse state. Sidebar toggle ⌃⌘S, inspector
  toggle ⌥⌘0, using the system's collapse animation (instant with Reduce Motion).
- **Sidebar contents** use system sidebar list styling on glass (system vibrancy/labels); never custom
  opaque fills inside the glass sidebar. The main and inspector areas are opaque content.
- **Repository header (top of main, opaque):** name, branch (or "Detached at <short sha>", or "No commits
  yet"), upstream with ahead/behind arrows and counts (`type.callout`, monospaced digits), operation state
  chip ("Merging", "Rebasing 3/7" if available, "Cherry-picking", "Reverting", "Bisecting"). The same
  identity appears as window title/subtitle (§3.1).
- **Region content in Phase 1 (honest):**
  - Sidebar: repository summary section (path, kind, worktree/bare badge). Branch lists arrive in Phase 2
    — do not show empty "Branches" headers.
  - Main: status summary block — staged / unstaged / untracked / conflicted counts with small glyphs.
    "History graph" does not appear until Phase 2.
  - Inspector: "Working directory" summary with counts and "Open in Finder / Terminal" actions.
- **States:** loading (no shimmer — a static faint placeholder appears only after 150 ms), normal, error
  (repository missing / not a repository anymore / permission denied / Git missing) with recovery
  actions: Locate…, Remove Tab, Retry.
- **Bare repositories:** no working-directory counts; show "Bare repository — no working tree".

### 3.4 Settings window

SwiftUI `Settings` scene (⌘,) with the system's macOS 26 settings styling (glass toolbar/tabs come from
the system): **General** — Appearance (System / Light / Dark segmented, live), "Restore tabs on launch"
toggle (default on). **Profiles** — list + editor (§3.5). Native form styling; tokens only where the
system doesn't already supply a color.

### 3.5 Identity-only profiles

- **Model surface in UI:** display name, color (8 swatches from the lane palette's neighbors, not
  lane-identical), author name, author email, optional committer name/email (disclosure, collapsed).
- **Create/edit sheet:** system sheet (glass on macOS 26) with opaque form content; fields with inline
  validation (name non-empty; email contains one `@` and a dot in the domain — warn, don't block, on
  unusual addresses). "Fill from Git config" button reads `git config --global user.name/user.email`
  read-only and pre-fills. Sheet copy states: "Jit never changes your global Git configuration."
- **Switcher (from the toolbar profile capsule):** a system popover anchored to the capsule (system glass;
  no custom radius/shadow). Rows: color circle, display name (`type.headline`), `name <email>`
  (`type.callout`, secondary label color), checkmark on active. Search field appears when > 6 profiles.
  Footer: "New Profile…", "Manage Profiles…". One click switches; the capsule content cross-fades
  (150 ms) and the capsule morphs only if its width changes. Phase 5 adds provider/auth status to rows.
- **No profile state:** "No Profile" capsule (§3.1); popover explains "Commits need an identity" with
  "Create Profile…" and "Fill from Git config".
- **Accessibility:** popover rows are buttons labelled "<display name>, <email>, active/inactive".

### 3.6 Menus

Only menus with at least one implemented item are shown. Menus get system macOS 26 styling. Phase 1:

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
collide with standard macOS shortcuts; verify against Apple's HIG list and the roadmap shortcut registry.

## 4. Technical design

### 4.1 State architecture (ADR-0007)

All UI state types are `@MainActor`; Git work happens off the main actor inside `GitCore` actors
(`GitEngine`, `RepositoryHandle`). There is no bridge layer: `Services` imports `GitCore` directly and
receives its value types.

| Type | Kind | Owns | Observed by |
|---|---|---|---|
| `AppModel` | `@Observable` | `tabs: [TabID]`, `activeTabID`, `recentlyClosed`, reference to stores | tab bar, window |
| `TabModel` | `@Observable` per tab | `id`, `kind (.newTab / .repository(RepositoryRef))`, `title`, `statusDot` | its tab view only |
| `RepositorySession` | `@Observable` per repository tab (`Services`) | lifecycle, `RepositoryInfo`, `StatusSummary`, `OperationState`, error; holds the `RepositoryHandle` | workbench views of that tab |
| `PreferencesStore` | `@Observable` | theme, restore-tabs flag (UserDefaults) | settings, app |
| `SessionStore` | plain final class | read/write `session.json` | `AppModel` |
| `RecentsStore` | `@Observable` | recents list (JSON) | new-tab page, Open Recent menu |
| `ProfileStore` | `@Observable` | profiles, `activeProfileID` | profile capsule, popover, settings |
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
closed: watcher stopped, RepositoryHandle released, tasks cancelled
```

- `unloaded`: restored tab never shown. No `RepositoryHandle`, no watcher. Title comes from `session.json`.
- `active`: FSEvents stream running; refreshes happen in response to events.
- `inactive`: watcher stopped, in-flight tasks cancelled (which kills their Git process groups), last
  state kept for instant re-display. Re-activation triggers exactly one revalidation (status refresh).
- `suspended`: on `DispatchSource.makeMemoryPressureSource(.warning)` (event-driven, no timer), inactive
  sessions call `handle.releaseCaches()` and drop Swift-side caches.

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
- Writes: atomic (`Data.write(options: .atomic)`), `0600` permissions, off the main actor, debounced with
  a cancellable one-shot `Task` (`try await Task.sleep(for: .milliseconds(500))`, cancelled and replaced on
  each change) — never a repeating timer — and flushed synchronously-but-fast in `applicationWillTerminate`.
- Paths are stored as standardized absolute paths (Unicode-normalized to the form returned by
  `URL.standardizedFileURL`). No security-scoped bookmarks (App Sandbox off — ADR-0006 addendum).

### 4.3 `GitCore`: status and operation state

```swift
// GitCore
public struct StatusSnapshot: Sendable {
    public let revision: UInt64                  // per-repository generation at which this was computed
    public let branch: BranchHeader              // oid, head name | detached | unborn, upstream, ahead, behind
    public let entries: StatusEntries            // compact full parse kept in GitCore for Phase 3
    public let summary: StatusSummary            // staged, unstaged, untracked, conflicted
}

// Compact storage: one contiguous byte buffer for all paths + parallel arrays of small fixed fields.
public struct StatusEntries: Sendable {
    let pathBytes: [UInt8]                       // all paths, NUL-separated, as Git emitted them
    let pathRanges: [Range<Int32>]               // path (and original path for renames) into pathBytes
    let kinds: [EntryKind]                       // ordinary, renamed/copied, unmerged, untracked, ignored
    let xy: [UInt16]                             // XY codes packed
    let modes: [ModeTriple], oids: [OIDPair]     // only what Phase 3 needs; strings materialized on demand
}

public enum OperationState: Sendable, Equatable {
    case none, merging, rebasing(step: Int?, total: Int?), cherryPicking, reverting, bisecting, applyingMailbox
}

public enum InvalidationKind: Sendable { case worktree, index, refs, head, config, operationState }

public actor RepositoryHandle {
    public nonisolated let id: RepositoryID
    public nonisolated let info: RepositoryInfo
    public func statusSummary() async throws(GitCoreError) -> StatusSummaryResult  // revision, branch header, operation state
    public func invalidate(_ kinds: Set<InvalidationKind>)                        // bumps generation
    public func releaseCaches()
}

extension GitEngine {
    public func openRepository(at url: URL) async throws(GitCoreError) -> RepositoryHandle
}
```

- Command: `git --no-optional-locks status --porcelain=v2 -z --branch --untracked-files=normal`
  (exact flags confirmed against the minimum Git version, ADR-0006 addendum). `--no-optional-locks` /
  `GIT_OPTIONAL_LOCKS=0` is essential: without it `status` may rewrite `.git/index`, which fires
  FSEvents, which triggers another status — a feedback loop that burns CPU.
- Parser works on the raw bytes (no intermediate `String` per line) and handles: headers
  `# branch.oid|head|upstream|ab`; entries `1` (ordinary), `2` (rename/copy — the `-z` form has an extra
  NUL-separated original path), `u` (unmerged), `?`, `!`; Unicode and unusual paths (no quoting with
  `-z`); submodule state field.
- `OperationState` detection reads the git dir: `MERGE_HEAD`, `rebase-merge/` (`msgnum`, `end`),
  `rebase-apply/` (`next`, `last`, `applying`), `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG`.
- Cache: the actor holds the last `StatusSnapshot` and a generation counter. `invalidate(_:)` bumps the
  generation; `statusSummary()` recomputes only when invalidated. Concurrent refresh requests coalesce:
  one in flight + at most one queued (the actor keeps the in-flight `Task` and awaits it); results older
  than the current generation are discarded. Mutating operations (Phase 3+) are also serialized by this
  actor — it is the single per-repository serialization point (ADR-0005).

```swift
// Services
@MainActor @Observable final class RepositorySession {
    func activate()          // open handle if needed, start watcher, revalidate
    func deactivate()        // stop watcher, cancel tasks
    func refresh(reason: RefreshReason) async
}
```

Status summaries are small values; full entries stay in `GitCore` until Phase 3 asks for them in pages.

### 4.4 File watching (ADR-0008)

- `RepositoryWatcher` (`Services`) wraps one `FSEventStream` per **active** session, scheduled on a
  private serial dispatch queue (`FSEventStreamSetDispatchQueue`), latency 0.2 s (FSEvents' own
  coalescing — no timers of ours), flags `kFSEventStreamCreateFlagUseCFTypes |
  kFSEventStreamCreateFlagWatchRoot` (directory-level events; *not* per-file events).
- Watched roots: worktree top level, plus absolute git dir and common dir when they are outside the
  worktree (linked worktrees, `--separate-git-dir`). Bare repos: git dir only.
- Classification (pure function, unit tested): paths under `.git/objects/`, `*.lock`, `.git/logs/` →
  ignore; `.git/index` → `index`; `.git/HEAD` → `head`; `.git/refs/**`, `.git/packed-refs` → `refs`;
  `.git/config` → `config`; `MERGE_HEAD` etc. → `operationState`; anything in the worktree → `worktree`.
  `kFSEventStreamEventFlagMustScanSubDirs` / `RootChanged` → full revalidation (or repository-moved error).
- Per batch: compute the set of kinds, `await handle.invalidate(kinds)`, then one `refresh`. Refreshes
  coalesce as described in §4.3.
- Lifecycle: stream runs only while the app is active **and** the tab is visible and the window is not
  miniaturized/occluded (`NSWindow.occlusionState`). On app activation: one revalidation of the visible
  tab; no stream while backgrounded. This gives zero idle work in the background.
- Heavy churn (e.g. a build writing thousands of ignored files) still triggers coalesced status runs;
  measure in P1.10 and note mitigation options (ignore-aware filtering) as Phase 6 follow-ups.
- Respect user `core.fsmonitor` configuration as Git does; Jit doesn't enable or disable it.

### 4.5 Toolbar and tab strip implementation

- The window uses `NSToolbar` (unified) so the system provides glass, item grouping and full-screen
  behavior. The tab strip is either (a) a custom toolbar item view (`NSToolbarItem` with a custom view
  that flexes) or (b) a titlebar accessory / custom container aligned with the toolbar. Spike both
  (§7); prefer the option that keeps system glass grouping, correct traffic-light spacing, full-screen
  toolbar reveal, and window dragging without private API.
- Tab strip view: AppKit `TabStripView` with lightweight `TabItemView`s (layer-backed, no per-frame work)
  inside one `NSGlassEffectContainerView` (or a SwiftUI `GlassEffectContainer` hosted in the item if that
  measures cheaper — verify API availability). Tabs are glass capsules (`NSGlassEffectView` / `glassEffect`
  in a capsule shape) with stable `glassEffectID`s for morphs. Window dragging handled through
  `mouseDownCanMoveWindow` on empty areas.
- Drag reorder uses local mouse tracking (not pasteboard) for smoothness; animations via
  `NSAnimationContext` with token durations; implicit animations off during bulk changes (e.g. session
  restore inserts all tabs without animation).
- SwiftUI hosts the content area per tab (`NSHostingView`), one hosting view per *loaded* tab kept alive
  while inactive (instant switching), released when suspended.
- Reduce Transparency: the custom glass container switches to `surface.chromeOpaque` via the
  `DesignSystem` helper; system toolbar items adapt automatically.

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
  start (§6.2, §10.2) and `GitCore` applies identity via `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env for that
  one invocation. Phase 1 only builds and tests the snapshot type (`GitIdentity` lives in `GitCore` so the
  core can accept it; `GitProfile` lives in `Services`).
- Reading `git config --global user.*` for pre-fill goes through `GitEngine` (read-only `git config
  --global --get`), never by parsing files directly.

### 4.7 Startup sequence (§15.2)

1. `applicationDidFinishLaunching`: read `session.json` + preferences synchronously (small files,
   < 5 ms), build `TabModel`s from cached titles, show the window (toolbar + tab strip restored without
   animation).
2. After first frame: activate the active tab's session (`GitEngine.openRepository`, status) in a
   `Task` at `.userInitiated`. Git location/version probing happens here lazily. Other tabs stay `unloaded`.
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
  switch/close (task cancellation kills the Git process group).
- Many tabs (50+) → overflow works; only visible/active sessions do work; the glass strip stays one
  container (no per-tab container).
- Profile deleted while active → active becomes none → capsule shows "No Profile"; never auto-pick
  another profile silently.
- Theme switching while popovers/sheets open → all surfaces update (dynamic colors; system glass adapts).
- Reduce Transparency / Increase Contrast toggled while running → chrome and content update live.
- Full-screen mode → toolbar auto-hide/reveal keeps the tab strip usable.
- Two displays with different scale factors → status dots and hairlines remain crisp (use
  backing-aligned rects).

## 6. ADRs to write

- **ADR-0007** State management & persistence (Observation granularity, stores, JSON files, single main
  window assumption, lifecycle states).
- **ADR-0008** File watching (FSEvents directory-level streams, classification, active-only policy,
  `--no-optional-locks`, fsmonitor stance).

## 7. Open questions / spikes

| Question | How to decide |
|---|---|
| Tab strip as custom `NSToolbarItem` view vs titlebar accessory / custom container | Spike both for 1 day max: system glass grouping, traffic-light spacing, full-screen toolbar behavior, window dragging, VoiceOver, no private API. Pick the one with fewer AppKit hacks. |
| AppKit `NSGlassEffectContainerView` vs hosted SwiftUI `GlassEffectContainer` for the strip | Build both with 20 tabs; compare reorder smoothness, memory and idle CPU (must be 0). |
| Selected-tab appearance: tinted glass vs system selected glass | Screenshot review in light/dark/Reduce Transparency with several system accent colors. |
| Show window title text when tabs are visible | Screenshot review + VoiceOver check; title/subtitle remain set either way. |
| Keep inactive tabs' hosting views alive vs. rebuild on switch | Measure memory per loaded tab and switch latency with 10 tabs; target < 16 ms switch and < 15 MB per idle tab. |
| Multiple main windows in V1 | Default no (ADR-0007). Revisit if users need side-by-side repos; architecture keeps `AppModel` per window possible. |
| Status cost on very large worktrees | Benchmark on a 100k-file repo; if > 1 s, plan ignore-aware event filtering or untracked-files mode tuning for Phase 6. |
| Where to show repository errors that affect a background tab | Status dot `status.danger` + tooltip; no notifications in V1. |
