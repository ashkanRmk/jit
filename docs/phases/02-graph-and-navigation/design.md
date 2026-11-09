# Phase 2 — Git Graph & Navigation: Design

> Requirements: §4.3 (left navigator), §4.4 (main graph), §5 (entire), §9.1 (tags), §14, §15.
> Roadmap moves: file history lands here; the navigator is read-only plus copy actions (checkout and
> all branch mutations are Phase 4); avatars are initials only (no network).

## 1. Goal & demo

The graph is the visual centre of Jit. At the end of this phase:

- Opening a repository with many branches and merges shows a **beautiful, original commit graph**
  that appears in well under a second and scrolls at 60 FPS, including over a 100k-commit fixture.
- History loads incrementally; appending pages never shifts or recolours rows already on screen.
- The left navigator lists local branches, remote branches and tags, grouped by `/` hierarchy,
  filterable, keyboard-navigable, with tracking info.
- Selecting a commit shows its details and changed files in the inspector.
- Search (message, SHA, author, refs), branch filter, pin-left, solo/focus, file history, and
  compare (commit↔commit, commit↔working directory) all work against real repositories.
- Ref changes made outside Jit (e.g. `git commit` in Terminal) update the graph without a full reload.

**Demo script:** open the Git source repository (or the 100k fixture) → scroll to the bottom of the
first page and keep going → select a merge → ⌘F `"refs"` → solo a branch → right-click → Copy SHA →
in Terminal create a commit → graph updates with a WIP/new commit row at the top, no flicker.

## 2. Scope

**In scope**
- Commit + ref data model, compact chunked columnar storage in `GitCore` (Swift), paginated streamed
  history (ADR-0010).
- Deterministic lane layout in `GitCore` with Swift Testing golden tests (incl. page boundaries).
- AppKit virtualized graph renderer (ADR-0009) with an original visual design, compact and comfortable density.
- Ref labels: local branch, remote branch, tag, HEAD, detached HEAD; WIP virtual node.
- Initials avatars (deterministic colour from author email hash; no network).
- Commit details inspector: metadata, message, parents, changed-file list with `+/-` stats.
- Branch navigator (local / remote / tags; worktrees and stashes sections appear only in Phase 8).
- Search, filter, pin-left, solo/focus, file history, compare file lists.
- Copy SHA, copy branch name, copy commit subject; context menus.
- FSEvents-driven ref/HEAD refresh without full reload.

**Out of scope (and where it lives)**
- Opening a file's diff from the details list → Phase 3 (in this phase the file row is selectable
  but the diff pane shows nothing; the row must not pretend — no "Open diff" action until Phase 3).
- Checkout, create/rename/delete branch, merge, rebase, cherry-pick, revert → Phase 4.
- **Copy remote commit/branch link** → Phase 4 (P4 "copy remote commit link" builds web URLs from
  remotes for GitHub/GitLab). Phase 2 does not show this menu item.
- Provider avatars → Phase 5 (opt-in).
- Worktree/stash sections in the navigator → Phase 8.
- Blame → Phase 3.

## 3. User experience

### 3.1 Layout within a repository tab

```
┌ tab bar ───────────────────────────────────────────────────────────────┐
│ Navigator (240pt) │ Graph toolbar: [branch scope ▾] [search ⌘F]  [⋯]   │ Inspector (360pt) │
│  ▸ Local          │ ─────────────────────────────────────────────────  │  Commit details   │
│  ▸ Remote         │  graph | refs + subject            author   date   │  or WIP summary   │
│  ▸ Tags           │  ...virtualized rows...                            │                   │
└───────────────────┴────────────────────────────────────────────────────┴───────────────────┘
```

Graph columns (left→right): graph lanes (dynamic width, clamped), ref labels + subject (flexible),
author (initials avatar + name, 140pt), date (relative, 96pt), short SHA (SF Mono, 64pt, hidden in
narrow layouts). Column widths persist per tab (Phase 1 session state).

**Material layers (ADR-0006).** The graph table, navigator rows and inspector content are the
**opaque content layer** — `surface.canvas` backgrounds, no glass on rows, labels, pills or anything
that scrolls. Liquid Glass appears only in the chrome around them: the window toolbar (branch scope
menu, search field and overflow menu are standard toolbar items, so the system renders them as glass),
the system sidebar material behind the navigator's section list, and small floating glass capsules for
transient chips (`Solo: feature/x ✕`, `History: path ✕`, the "Search all history" progress) grouped in
one `GlassEffectContainer` so they morph instead of stacking. Rows scroll under the toolbar with the
system scroll-edge effect; text is never drawn on glass over busy content. With Reduce Transparency the
system renders these surfaces opaque; custom capsules must follow (verify the exact SwiftUI/AppKit
glass API names against the macOS 26 SDK during P2.4).

### 3.2 Graph — visual design spec

> **Superseded in part by [P2.13](specs/P2.13-graph-visual-style.md)** (owner request, 2026-11-09): avatar
> nodes in a lane-coloured ring, solid merge dots, rounded-elbow lane changes, a lane-tinted row band and a
> separate "Branch / Tag" column with connectors replace the node, curve and in-subject pill rules below.
> Palette, rows, states and budgets here still apply.

Design intent: quiet, precise, "drafting-table" graph. Lanes are thin and calm; nodes are the only
emphasis; colour is muted and used to separate, not decorate.

| Token (DesignSystem) | Compact | Comfortable |
|---|---|---|
| `graph.rowHeight` | 24 pt | 30 pt |
| `graph.laneSpacing` | 14 pt | 16 pt |
| `graph.leadingInset` | 10 pt | 12 pt |
| `graph.nodeRadius` (regular commit) | 3.5 pt | 4.0 pt |
| `graph.mergeNodeRadius` | 4.0 pt | 4.5 pt |
| `graph.headRingRadius` | node + 2.5 pt | node + 3 pt |
| `graph.edgeWidth` | 1.5 pt | 1.75 pt |
| `graph.maxVisibleLanes` before compression | 12 | 12 |

Geometry:
- Nodes sit on the lane centre at the vertical row centre. Regular commits: filled disc with a 1pt
  ring in the surface colour (separates node from edges). Merge commits: hollow ring (edge colour,
  surface fill) one step larger. HEAD: an outer ring in `accent.primary` at `headRingRadius`, 1.25pt.
- Vertical edges: straight lines through row centres, butt-capped so adjacent rows join seamlessly.
- Lane changes (fork/merge): cubic Bézier from `(x0, rowTop)` to `(x1, rowBottom)` with control points
  at 50% vertical offset — `c1 = (x0, top + 0.5h)`, `c2 = (x1, top + 0.5h)` — giving an S-curve
  constrained to a single row. Never draw diagonals spanning multiple rows.
- Edges are drawn per row as segments clipped to the row rect; each segment is fully determined by
  the row's `LaneRow` data, so a row can be drawn in isolation (enables reuse and overscan).
- More than `maxVisibleLanes` active lanes: lanes beyond the limit are drawn at 6pt spacing with
  reduced opacity, and a subtle `+N` indicator appears in the header; graph column never pushes
  subject text off-screen (column width clamp: 40% of graph table width).
- Crisp rendering: snap vertical edge x-coordinates to `round(x * scale) / scale + 0.5/scale` for odd
  pixel widths; use `NSGraphicsContext.current.cgContext` with antialiasing on for curves only.

Lane palette: 8 hues, designed independently for each theme (not inverted), muted, separated in
perceived lightness so adjacent lanes remain distinguishable for common colour-vision deficiencies.

| Slot | Light (on mineral-white) | Dark (on graphite) |
|---|---|---|
| 0 | slate blue | soft periwinkle |
| 1 | teal | sea-glass |
| 2 | ochre | warm sand |
| 3 | plum | heather |
| 4 | moss | sage |
| 5 | terracotta | clay rose |
| 6 | steel | pewter blue |
| 7 | rosewood | dusty pink |

Exact values are defined as `graph.lane[0…7]` tokens in `DesignSystem` during P2.4 and checked for
≥3:1 contrast against `surface.canvas` in both themes. The first-parent line of HEAD's branch always
uses slot 0. No neon, no gradients, no glow.

Ref labels (in the subject column, before the subject) — **opaque tinted pills, never glass**
(legibility at 16pt and zero compositing cost per row):
- Pill height 16pt (compact) / 18pt (comfortable), radius `radius.xs` (4pt), 6pt horizontal padding,
  `type.caption` medium weight.
- Local branch: tinted fill (lane colour at 14% light / 22% dark) + lane-colour text.
- Current branch: same plus a leading 6pt filled dot and semibold text.
- Remote branch: outline only (1pt lane colour at 60%), text `text.secondary`, shows `origin/` prefix
  dimmed. If a local and its upstream point to the same commit, render one combined pill
  `main ⇄ origin` instead of two.
- Tag: `tag` SF Symbol (10pt) + name, neutral fill `fill.subtle`, text `text.secondary`.
- Detached HEAD: neutral pill `HEAD` with `accent.warning` outline.
- Overflow: show up to 3 pills; the rest collapse into `+N` with a popover listing all refs.

WIP virtual node: first row when the working tree or index is dirty. Dashed hollow node (2pt dash) on
HEAD's lane, subject "Uncommitted changes", trailing counts `3 staged · 5 unstaged` in `text.tertiary`.
Selecting it shows a WIP summary in the inspector (the working-directory panel is Phase 3; in Phase 2
the inspector lists changed paths with status letters from the Phase 1 status model).

Rows:
- Hover: `fill.hover` background, 100 ms fade in / 140 ms out (no fade when scrolling — hover tracking
  is suspended during live scroll).
- Selection: `fill.selection` + 2pt leading accent bar, 140 ms. Multi-selection (⌘-click) for compare
  supports exactly two commits; a third replaces the oldest selection.
- Unreachable-by-filter rows (when "highlight" filter mode is used): text at 45% opacity, graph kept.
- Dates: relative for < 7 days ("3h ago"), else `MMM d, yyyy`; tooltip with full ISO timestamp + timezone.

States:
- **Loading (first page):** table with 12 skeleton rows (static, no shimmer — §3.4 no perpetual
  animation); if first page takes > 150 ms a small indeterminate spinner appears in the toolbar.
- **Empty (no commits):** centred message "No commits yet" + "Make the first commit from the working
  directory panel" (Phase 3) — until Phase 3 exists, only the message.
- **Normal:** as above. Appending pages: no visual change except the scroll knob shrinking.
- **Error:** inline banner above the table (`surface.raised`, `accent.danger` icon) with the mapped
  error ("History could not be read: the repository is locked by another process") + Retry.
- **End of history:** a quiet footer row "Beginning of history · 12,483 commits".

### 3.3 Graph toolbar, search and filters

- **Branch scope menu:** `All branches` (default), `Current branch`, `Local branches only`,
  `Selected branches…` (checklist popover with filter field). Persisted per tab.
- **Pin left:** pinned branches get the lowest lane indices (lane 0, 1, …) in the stated order;
  managed from the navigator context menu ("Pin to Left") and shown with a pin glyph in the navigator.
- **Solo / focus:** from navigator or graph label context menu. Shows only commits reachable from the
  branch (`git log <branch>`), other lanes vanish; a toolbar chip `Solo: feature/x ✕` exits it.
- **Search (⌘F):** single field with token prefixes: free text matches subject/body; `sha:` or any
  4–40 hex string matches SHAs; `author:`; `ref:`. Results highlight matching rows and jump to the
  next match with ↩ / ⇧↩; counter `3 of 41`. Search over already-loaded rows is instant (`GitCore`,
  in-memory byte scan); "Search all history" continues into unloaded history in the background, cancellable,
  streaming matches (uses `git log` with `--grep`/`--author`/`-i` and `--fixed-strings` as appropriate).
- **Filter mode toggle:** "Highlight matches" (default, keeps graph topology) vs "Show only matches"
  (flat list, graph column replaced by simple dots — topology is meaningless for a filtered set).
- **File history:** from the inspector file list ("Show File History") or ⇧⌘H with a path. The graph
  switches to a path-filtered list (`git log --follow -- <path>` when a single file, without
  `--follow` for directories). A chip `History: src/app.rs ✕` shows the mode. `--follow` caveat: it
  only works for a single path and can mis-detect renames; the UI shows "Rename tracking is heuristic"
  in the chip's tooltip.

### 3.4 Commit details inspector

Hierarchy, top to bottom:
1. Subject (`type.title3` semibold, selectable), body (`type.body`, preserves blank lines, wraps; URLs
   are not auto-linked in Phase 2).
2. Meta grid: author avatar + name + email; committer (only if different); authored / committed dates
   (only show both if different); SHA (SF Mono, copy button on hover); parents (short SHAs as links that
   select the parent row, loading more history if needed); refs pointing here.
3. Changed files: header "12 files  +340 −122"; rows with status glyph (A/M/D/R/C/T), path (SF Mono,
   middle-truncated, directory dimmed), `+/-` mini bar (8 segments) and numbers. Flat/tree toggle.
   Renames show `old → new`. Merge commits: diff against first parent by default with a segmented
   control `First parent | Combined` disabled with a tooltip until Phase 3 ("Combined diff is planned").

States: nothing selected → the inspector closes (design-system.md, Inspector visibility; opened manually it
shows the quiet placeholder "Select a commit"); loading files > 120 ms → inline spinner
in the files header; error → inline message in the files section only.

Two commits selected → **Compare** view: "Comparing `a1b2c3d` → `e4f5a6b`", swap button, changed-file
list from `git diff --name-status -z --numstat a b` (merge-base toggle: `a...b` vs `a..b`, labelled
"Changes on B since common ancestor" vs "Direct difference"). WIP + commit selected → commit vs
working directory list.

### 3.5 Branch navigator (left sidebar)

- Sections: **Local**, **Remote** (one group per remote), **Tags**. Section headers show counts.
- Hierarchy: names split on `/` into folders (`feature/ui/tabs` → `feature ▸ ui ▸ tabs`); a folder with
  a single child collapses into `feature/ui ▸ tabs`. Expand state persisted per repo.
- Row: branch glyph, name (last path component, full name in tooltip), current branch bold with
  accent dot, ahead/behind badge `↑2 ↓5` in `text.secondary` (from `for-each-ref
  %(upstream:track)`; no network), "gone" upstream shown as `upstream gone` in `accent.warning`.
- Filter field at top (⌘⌥F when sidebar focused): fuzzy subsequence match across all sections;
  matching folders auto-expand while filtering, restore after clearing.
- Click: selects and scrolls the graph to the ref's tip (loading pages if needed, with a toolbar
  spinner; if the tip is beyond 50k commits from the top, ask before loading).
- Double-click: same as click in Phase 2 (checkout is Phase 4 — no double-click checkout yet).
- Context menu (Phase 2): Copy Branch Name, Copy SHA, Pin to Left / Unpin, Solo, Show in Graph.
  Tags: Copy Tag Name, Copy SHA, Show in Graph, show annotated tag message in a popover.
- Keyboard: ↑/↓ move, ←/→ collapse/expand, ↩ show in graph, type-to-select.
- Large collections: `NSOutlineView` (view-based, row reuse) — 10k branches must stay responsive.
- States: no remotes → Remote section hidden; no tags → Tags shows "No tags"; ref read error →
  section-level inline error.

### 3.6 Context menus (graph rows)

Only valid actions appear:
- Commit row: Copy SHA, Copy Short SHA, Copy Subject, Compare with Working Directory, Select for
  Compare / Compare with Selected (when one other selected), Show File History (from file rows), Solo
  branch (when a branch label is under the cursor).
- WIP row: no copy actions; "Compare with HEAD" is implicit (it's what the WIP summary shows).
- Ref label: Copy name, Pin/Unpin, Solo, Show in navigator.

### 3.7 Keyboard

↑/↓ move selection; ⇧↑/⇧↓ extend to a two-commit compare; ⌘↑/⌘↓ top/bottom of loaded history;
Space toggles inspector focus; ⌘F search; ⌘G / ⇧⌘G next/previous match; ⌘C copies SHA of the
selected commit when the graph is first responder; Esc clears search/solo/compare in that order.
⌘1 selects the graph workbench mode (Phase 1 reserves ⌘1/2/3).

### 3.8 Accessibility

- Graph table rows expose `accessibilityLabel` = "Commit a1b2c3d, Fix tab overflow, by Ana Ruiz, 3
  hours ago, branches main and origin/main, merge of 2 parents". The graph drawing itself is
  decorative (`accessibilityHidden` for the cell's drawing view), topology described via the
  "merge"/"parents" text.
- Custom rotor: "Branch tips" and "Merge commits" to jump in VoiceOver.
- Lane colours are never the sole carrier of meaning (labels carry names; HEAD has a ring shape).
- Reduce Motion: selection/hover transitions become instant; scroll-to-commit jumps instead of animating.

## 4. Technical design

### 4.1 Components

**`GitCore` (Swift, Foundation-only — ADR-0002/0005)**
- `Refs` — reads refs with one `git for-each-ref -z --format=…` call (refname, objectname, peeled
  `*objectname`, upstream, `upstream:track`, HEAD flag, symref), parsed as bytes. Produces a
  `RefSnapshot` value with a hash (`refsRevision`) used for invalidation.
- `HistoryReader` (see 4.3) parses `git log -z` output **as bytes** (`UnsafeRawBufferPointer` /
  `Span<UInt8>` over the read buffer; no `String` per field) and appends into a `CommitStore`.
- `CommitStore` — **chunked, append-only, columnar** storage; no class or struct-with-references per
  commit:
  - Rows live in fixed-size chunks of 4,096 rows. A chunk is filled by the reader and then **sealed**
    (immutable `final class CommitChunk: Sendable` — one object per 4k commits, not per commit).
    A `HistorySnapshot` is `{ chunks: [CommitChunk], count }`, so publishing a new snapshot after a
    page append copies only the chunk-reference array, never the column data.
  - Columns inside a chunk (`ContiguousArray` of trivial types):
    `oids: [ObjectID]` where `ObjectID` is an inline 20-byte struct (`(UInt64, UInt64, UInt32)`;
    SHA-256 repos — detected via `extensions.objectformat` — use a 32-byte variant, store generic over
    the ID type); `parentOffsets: [UInt32]` + flat `parentRows: [Int32]` (row indices; parents beyond
    loaded history are negative sentinels resolved through a small side table of pending OIDs);
    `authorIndex: [UInt32]` into an interned author table (name/email bytes, deduplicated);
    `time: [Int64]`; `subjectRanges: [UInt32]` into a per-chunk UTF-8 byte arena. No bodies (fetched
    lazily for the selected commit).
  - `oidIndex: [ObjectID: Int32]` (ObjectID is `Hashable` over its words) for lookup.
  - `String`s are materialized only for visible rows (in `GraphRowCache`, §4.5) and dropped after.
  - Target: ≤ 120 bytes/commit including lane data, excluding subject bytes → 100k commits ≈ 12 MB +
    subjects. Measured with a 100k fixture by allocation tracking (`malloc_size` sums in a test hook)
    and Instruments Allocations in P2.10.
- `LaneLayouter` — incremental top-down layout (4.4); lane rows stored columnar in the same chunks
  (`nodeLane: [UInt16]`, `nodeColor: [UInt8]`, `nodeKind: [UInt8]`, flat `segments: [EdgeSegment]`
  (4-byte packed struct) + `segmentOffsets: [UInt32]`).
- `HistorySearch` — in-memory byte scan over subject arenas, author table, oid hex, refs; streaming
  deep search spawns a separate `git log` with filters.
- `compare` — `git diff --name-status -z` + `--numstat -z` (two calls or `--raw --numstat` combined
  where supported) producing `ChangedFile` lists; commit details `git show -s --format=… -z` for body
  and committer + `git diff-tree --root -r -z --numstat --name-status -M` for files.
- `file_history` — a `HistoryReader` configured with `-- <path>` (+ `--follow` for a single file).

**Swift**
- `Features/GitGraph`: `GraphViewController` (AppKit) hosting `GraphTableView: NSTableView`,
  `GraphCellView` (custom `draw(_:)`), `RefLabelsView`, graph toolbar items (standard
  `NSToolbarItem`s / SwiftUI toolbar content — glass comes from the system), `GraphChipsView`
  (SwiftUI glass capsules in a `GlassEffectContainer`), `GraphViewModel` (`@Observable`, holds row
  count, selection, mode, search state — *not* row data), `GraphRowCache` (main-actor cache of
  materialized visible rows).
- `Features/BranchNavigator`: `NavigatorViewController` with `NSOutlineView`, `NavigatorViewModel`.
- `Features/CommitInspector`: SwiftUI `CommitDetailsView` (bounded content, fine in SwiftUI) +
  `ChangedFilesList` (AppKit `NSTableView` if > 500 files, else SwiftUI `List` — decide in P2.6 by
  measurement; default to AppKit for consistency).
- `Services/RepositorySession` (from Phase 1) gains `history: HistoryController` which owns the
  `GitCore` `HistoryLoader` actor, the current `HistorySnapshot`, and page requests.

### 4.2 `GitCore` API sketch (illustrative Swift)

```swift
// GitCore — Foundation-only. All types are value types or immutable final classes (Sendable).
public struct HistoryQuery: Sendable, Hashable {
    public var scope: HistoryScope        // .all | .current | .local | .refs([RefName]) | .solo(RefName)
    public var path: RepoPath?            // file history (raw bytes preserved)
    public var follow: Bool
    public var pinned: [RefName]          // refs pinned left, in order
}

public actor HistoryLoader {               // one per open graph/file-history view
    public init(repository: RepositoryHandle, query: HistoryQuery) async throws
    /// Ensures rows [0, minRows) are loaded. Suspends (never blocks a thread) while the reader fills.
    /// Task cancellation stops reading; the reader process is killed with its process group.
    public func ensureLoaded(_ minRows: Int) async throws -> HistorySnapshot
    public var snapshot: HistorySnapshot { get }
    public func searchLoaded(_ q: SearchQuery) -> [Int32]                 // row indices, byte scan
    public func searchDeep(_ q: SearchQuery) -> AsyncThrowingStream<ObjectID, Error> // bounded buffer
    public func close()                                                  // kills reader process group
}

public struct HistorySnapshot: Sendable {  // immutable; cheap to pass (array of sealed chunk refs)
    public let count: Int
    public let complete: Bool
    public let refsRevision: UInt64
    public func row(_ index: Int) -> CommitRowRef          // index into chunk columns, no allocation
    public func row(for oid: ObjectID) -> Int?
    public func headLane() -> UInt16?
}

public struct CommitRowRef {                // non-owning view: chunk + local index
    public var oid: ObjectID
    public var time: Int64
    public var isMerge: Bool
    public var lanes: LaneRowRef               // nodeLane, nodeColor, nodeKind, segments (buffer view)
    public func subjectBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R
    public var authorIndex: UInt32             // resolve via snapshot.authors
}

public struct EdgeSegment: Sendable {       // 4 bytes, packed
    public var fromLane: UInt8, toLane: UInt8, color: UInt8
    public var half: SegmentHalf               // .top (row top → centre) | .bottom (centre → row bottom) | .full
}

extension RepositoryHandle {                // actor from Phase 1
    public func refs() async throws -> RefSnapshot
    public func commitDetails(_ oid: ObjectID) async throws -> CommitDetails   // cancellable via Task
    public func compare(_ a: RevSpec, _ b: RevSpec, mode: CompareMode) async throws -> [ChangedFile]
}
```

The UI never receives whole histories: the table asks `GraphRowCache` (main actor) for visible rows +
overscan (≈ 2× visible); the cache materializes `GraphRowDisplay` values (subject `String`, initials,
ref labels) from the current `HistorySnapshot` in windows of 64 rows, keeping at most 16 windows
(≈ 1k rows). Materialization is a direct read of chunk columns — no process call, no copy of the store.

### 4.3 History loading (ADR-0010)

Default design (to be confirmed by spike S1):
- One long-lived `git log` child per open `HistoryHandle`:
  `git -c core.quotepath=off log --topo-order --format=<NUL-separated fields> -z --parents
  --decorate=no <scope revs> [-- path]` with `--no-color --no-ext-diff`.
  The pipe is read through the Phase 0 `ProcessRunner` stream API (Dispatch-source driven, into a
  reusable byte buffer) **only while `ensureLoaded` is asking for more**; otherwise the read source is
  suspended, the pipe fills and Git blocks (backpressure) — **zero CPU while idle**, no thread parked.
- Page size: first page 300 rows (target first rows visible < 150 ms on the 100k fixture), later pages
  2,000 rows, requested when the visible range comes within 500 rows of `loaded_rows`.
- The reader process is killed on tab close, scope/mode change, a refs change that invalidates
  history (§4.7), or app termination. Inactive tabs keep a blocked reader (no CPU; one pipe + small
  RSS). If S1 shows per-reader RSS is material (> 5 MB), kill readers on tab deactivation instead;
  already-loaded rows stay in the `CommitStore`, and the next page request starts a new reader with
  `--skip=<loaded_rows>` (cost measured in S1; topo order is deterministic for unchanged refs, and
  the first re-read rows are checked against the stored oids to detect drift).
- `--topo-order` guarantees parents after children, which top-down lane layout requires.
  Note `--topo-order` must compute the full topology before emitting on some histories (commit-graph
  file makes it fast); the spike measures first-row latency with and without
  `core.commitGraph`/`git commit-graph write` present. **Jit never writes a commit-graph file
  automatically** (that would modify the repo's `.git`); if absent and history is slow, the UI may
  offer it as an explicit maintenance action later (Phase 6 decision).

Alternatives measured by spike S1:
1. Long-lived reader with backpressure (above).
2. Re-query per page with `--skip=N --max-count=M` (simple, O(N) per page, no idle process).
3. Two-stage: stream topology only with `git rev-list --topo-order --parents` (compact, fast with a
   commit-graph) to lay out lanes, and fetch display metadata (subject, author, time) for visible
   windows through one long-lived `git cat-file --batch` (or `git log --no-walk --stdin`) process per
   visible repository. Saves memory for very large histories at the cost of an extra process and
   latency on fast scrolls. (ADR-0002: no in-process Git library unless profiling proves these fail.)

Decision criteria (record numbers in ADR-0010): first-300-rows latency on 1k/10k/100k fixtures and on
the Git source repo; steady-state CPU while idle (must be 0); RSS of the app + children with 3 tabs;
total time to load 100k rows; correctness identical to `git log --topo-order` output (golden compare).

### 4.4 Lane layout algorithm

Input: commits in topo order, each with ordered parents. Output: `LaneRow` per row. Properties:
deterministic, top-down, **row k's layout depends only on rows 0…k** (so pagination never changes
earlier rows), O(rows × active_lanes).

State: `active: Vec<Option<LaneSlot>>`, each slot = `{ expected_oid, color, branch_key }`.

For each commit `c` at row `r`:
1. Find slots expecting `c`. If none → new branch tip: allocate the lowest free slot (pinned refs
   reserve slots 0…p-1 and are seeded at the start), color = `color_for(branch_key(c))`.
   If several slots expect `c` (merge convergence) → node goes in the leftmost; the others emit
   `Top` segments curving into the node lane and are freed.
2. Emit pass-through `Full` segments for every other active slot.
3. Parents: first parent continues in the node's slot (same color). Each additional parent `p`:
   if some active slot already expects `p` → `Bottom` segment curving into that slot; else allocate
   the lowest free slot (prefer slots to the right of the node to keep merges reading left→right) with
   a new color, and emit a `Bottom` segment into it. Octopus merges repeat this per parent.
4. Root commit (no parents) → slot freed after the node (no `Bottom` segment).
5. Free slots are reused only after one full empty row to avoid an edge visually touching a new tip
   ("lane cooldown" of 1 row) — keeps crisscross merges readable.
6. Lane compaction: never move an existing lane sideways (that would re-layout earlier rows); gaps
   close only when a slot is freed and later reused.

Color stability (`color_for`): `branch_key` = the name of the most specific ref whose first-parent
chain contains the tip (computed from `RefSnapshot`: local branch > remote branch > tag), falling back
to the tip oid. `color = hash64(branch_key) % 8`, then if equal to the color of the immediately
adjacent active lane, take the next slot in palette order. HEAD's branch is forced to slot 0. Because
it's derived from names, `main` keeps its color across sessions and page loads.

WIP node: virtual row −1 inserted by the UI layer as row 0 when dirty (`nodeKind = .wip`, lane =
HEAD's lane, `.bottom` dashed segment into HEAD's row). `HistorySnapshot.headLane()` provides the lane
so the UI doesn't recompute. UI row indices are offset by 1 when WIP is present; `CommitStore` is
unaware of WIP.

Detached HEAD: `HEAD` label on the commit; if HEAD is not reachable from any listed ref (e.g. scope
"Local branches"), HEAD is always added to the scope revs so it appears.

Golden tests (Swift Testing, `macos/Packages/JitKit/Tests/GitCoreTests/Lanes/`, golden files in
`Tests/GitCoreTests/Resources/lanes/`): fixtures built with `GitTestKit`; expected output as ASCII art (`*`, `|`, `/`, `\`, `M`) with color slot digits, plus a JSON form. Cases: linear;
two branches merged; three-way octopus; crisscross (A merges B, B merges A); long-lived `develop`
merged repeatedly into `main`; rebased branch (no merge); 40 parallel branches (lane compression);
detached HEAD; orphan root (second root commit); merge where second parent appears much later (lane
held open for 10k rows). **Page-boundary test:** compute layout in one pass vs in pages of 1, 7, 300
and 2000 rows; outputs must be identical.

### 4.5 Rendering (ADR-0009)

- `GraphTableView` is a view-based `NSTableView` with `usesAutomaticRowHeights = false`, fixed
  `rowHeight`, `NSTableViewStyle.plain`, `intercellSpacing = .zero`, row views reused via
  `makeView(withIdentifier:)`. Data source returns `numberOfRows = loadedRows (+1 WIP)`; when loading
  more, call `insertRows(at:withAnimation: [])` at the end — no reload, so the scroll position and
  visible rows don't move.
- `GraphCellView.draw(_:)` draws only its row's segments + node using `CGContext` paths; colors are
  resolved once per appearance change into a `[CGColor]` table (no per-draw `NSColor` resolution).
  `wantsLayer = true`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`, `canDrawSubviewsIntoLayer`
  for the row to flatten text + graph into one layer per row view.
- Text cells use `NSTextField` labels (no attributed string rebuilding on scroll — strings built once
  per row bind). Ref pills are drawn in `RefLabelsView.draw(_:)` (one view, not one view per pill).
- Prefetch: `NSScrollView` bounds-change notification → compute visible range → if within 500 rows of
  end, `Task { try await history.ensureLoaded(...) }` (coalesced; at most one in flight).
- Appearance change → invalidate color table, `reloadData(forRowIndexes: visible, columnIndexes: all)`.
- No animations during insertions/bulk updates (`NSAnimationContext.runAnimationGroup` with duration 0).
- The table's scroll view extends under the glass toolbar (full-size content view); the system
  scroll-edge effect keeps toolbar items legible. The table itself is opaque (`surface.canvas`), so
  scrolling never forces re-sampling of custom glass beyond what the system toolbar already does.

### 4.6 State ownership

| State | Owner | Notes |
|---|---|---|
| Commit store, lane rows, refs snapshot | `GitCore` `HistoryLoader` / `RepositoryHandle` actors | Source of truth; UI reads immutable `HistorySnapshot`s. |
| Visible row cache (materialized `String`s) | `GraphRowCache` (main actor, LRU of windows) | Dropped on tab deactivation (memory). |
| Selection (oids, not row indices), scroll anchor oid | `GraphViewModel` → persisted in Phase 1 session state | Survive reload. |
| Mode (scope, solo, file history, search) | `GraphViewModel` | Persist scope + pinned refs per repo. |
| Navigator expand state, filter | `NavigatorViewModel` | Persist expand state per repo. |
| Commit details | `CommitInspectorModel` | Cached LRU of 32 details in `RepositoryHandle`. |

### 4.7 Concurrency, cancellation, invalidation

- All Git work runs in `GitCore` actors off the main actor. The main actor only reads the latest
  immutable `HistorySnapshot` (sealed chunks are never mutated, so reads need no locks) and
  materializes visible rows in `GraphRowCache`. Materializing 128 rows must measure < 0.2 ms p99
  (spike S3); if not, windows are materialized off-main and cells show a blank row until filled
  (rare due to overscan).
- Requests are Swift `Task`s; selecting another commit cancels the previous details task, which kills
  its Git process group (ADR-0005).
- Phase 1's FSEvents watcher reports `.git/HEAD`, `.git/refs/**`, `.git/packed-refs`, `.git/index`
  changes. Handling:
  - Refs changed → re-read refs (`refs_rev` changes). If only labels moved but all old tips remain
    reachable and no new commits above row 0 (check: new tips' oids already in `oid_index`), update
    labels in place (`reloadData(forRowIndexes:)` for affected rows).
  - New commits (tip oid unknown) → open a new history handle in the background, lay out the first
    page, then swap atomically while keeping the selected oid and scroll anchor oid; old handle closed.
  - Index/worktree changed → only WIP row visibility/counts change (from Phase 1 status).
- Inactive tab: refs events are recorded as "dirty" and processed on activation (no work while inactive).

### 4.8 Performance approach

- Budgets: first page visible < 150 ms (fixture 100k, warm cache); page append < 16 ms on main thread
  (insertRows only); scroll 60 FPS with ≤ 2 ms per row draw; `CommitStore` ≤ 25 MB for 100k commits
  (including subject arenas and author table); `GraphRowCache` ≤ 2 MB.
- Byte-level parsing: no `String`/`Substring` per field while reading `git log -z`; fields are
  located with `memchr`-style scans over the buffer and copied straight into column arrays.
- Signposts (`os_signpost`) around: first page, page append, row draw, details fetch — used in Phase 6.
- 100k fixture generated by `scripts/benchmarks/make-history-fixture.sh` using `git fast-import`
  (fast, deterministic; includes merges every N commits and 50 branches).

### 4.9 Security

- All refnames, paths and search strings passed as argv elements; search text passed to
  `--grep=<text>` with `--fixed-strings` unless the user enables regex; path after `--`.
- `git log` invoked with `--no-ext-diff --no-textconv` and `-c log.showSignature=false` (signature
  verification runs gpg/ssh — not needed for display in Phase 2). **Policy (ADR-0023):** respect
  repository config, except options that execute external programs purely for read-only display
  (`log.showSignature`, textconv, ext-diff), which are neutralised per invocation. `core.fsmonitor`
  is respected (it's the user's configured hook) and listed in `docs/security.md` as a known
  program-executing setting.
- Commit messages and ref names are displayed as plain text (no markup interpretation, control
  characters rendered as `␛`-style replacement glyphs, bidi override characters neutralized).

## 5. Edge cases & failure modes

| Case | Expected behaviour |
|---|---|
| Empty repo / unborn HEAD | Empty state; navigator shows the unborn branch name with "no commits". |
| Shallow clone | Graph ends at the shallow boundary with footer "Shallow history — earlier commits not fetched"; grafted parents not drawn. |
| SHA-256 repository | Store variant handles 32-byte oids; short SHA length from `core.abbrev`/`rev-parse --short`. |
| Replace refs / grafts | Honour Git's default behaviour; document. |
| 10k+ branches | Navigator virtualized; `for-each-ref` single call; graph scope "All" may show many lanes → compression. |
| Very long subjects / emoji / RTL | Truncate tail with ellipsis; bidi isolation; full text in tooltip and inspector. |
| Commit with 30 parents (octopus) | Layout allocates up to N lanes; segments per row capped by data, not by drawing assumptions. |
| History rewritten under us (force-push fetch, rebase in Terminal) | Refs change → new handle; selection kept if oid still exists, else cleared with no error. |
| `index.lock` present | Reads still work; no error. |
| Reader process dies (OOM, killed) | `ensureLoaded` throws `GitError.processExited` → banner + Retry; loaded rows stay visible. |
| Corrupt object | Mapped error for the affected range; loaded rows remain. |
| Path with newline / non-UTF-8 bytes | `-z` parsing; non-UTF-8 displayed with replacement chars, original bytes kept for argv. |
| Search with regex metacharacters | Fixed-string by default. |
| Tag pointing to a tree/blob | Shown in navigator as "non-commit tag", no graph label. |
| Tab closed during load | Load task cancelled, process group killed, `HistoryLoader` released. |

## 6. ADRs to write

- **ADR-0009** Graph rendering approach (NSTableView + Core Graphics cell) — with measured FPS and
  per-row draw time; rejected alternatives (SwiftUI List, NSCollectionView, single custom scrolling
  canvas) and why.
- **ADR-0010** History loading strategy — spike S1 numbers and decision.
- **ADR-0021 (P2)** Lane layout algorithm & colour assignment — invariants (prefix-stability,
  determinism), cooldown, compression; golden-test format.
- **ADR-0022 (P2)** Compact commit storage & memory budget in Swift (chunked append-only columnar store,
  inline `ObjectID`, byte arenas, interned authors, lazy bodies, strings only for visible rows; measured
  bytes/commit).
- **ADR-0023 (P2)** Read-only Git invocation policy (which program-executing config is neutralised for
  display reads: ext-diff, textconv, showSignature; respecting everything else).
- **ADR-0024 (P2)** History invalidation on ref changes (in-place label update vs handle swap).

## 7. Open questions / spikes

| Spike | Question | Decision criteria |
|---|---|---|
| S1 History source | Long-lived `git log` reader with backpressure vs `--skip` re-query vs two-stage `rev-list` topology + `cat-file --batch` metadata | §4.3 criteria; idle CPU must be 0; prefer the simplest that meets first-page < 150 ms on the 100k fixture. |
| S2 Renderer | Does view-based `NSTableView` with flattened row layers hold 60 FPS at 100k rows on the reference Mac? | Instruments Animation Hitches: 0 hitches > 1 frame over a 10 s fling; row draw ≤ 2 ms p95. If not, prototype a single custom `NSView` canvas drawing visible rows directly. |
| S3 Row materialization cost | Can the main-actor data source materialize visible rows synchronously from the snapshot? | p99 < 0.2 ms for 128 rows → sync; else off-main window materialization. |
| S4 Commit-graph absence | How slow is `--topo-order` on a 100k repo without a commit-graph file? | If first row > 500 ms, use `--date-order` for the first page? (No — breaks topo invariant.) Instead document and plan an explicit "Optimize repository" action (Phase 6). |
| Q1 | Should "Highlight matches" dim non-matching rows or only mark matches? | Usability check on 3 real repos; pick the one where matches are findable in < 2 s scanning. |
| Q2 | Default density | Compact for ≥ 14" displays? Decide with screenshots; default "Comfortable" unless screenshots show waste. |
