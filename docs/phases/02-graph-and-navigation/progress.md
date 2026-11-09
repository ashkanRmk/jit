# Phase 02 — Git graph & navigation: progress report

Status: **complete with carry-overs** (listed below)
Branch / PR: `phase/02-graph-and-navigation` (from `main` after Phases 0–1 merged), PR: see below
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Xcode 27.2, Swift 6.4.2, Git 2.54.0
(Homebrew), XcodeGen 2.46.0

## Preconditions (P2.0)
Verified against the code: `RepositoryHandle` generation/invalidate, `ProcessRunner` (posix_spawn, argv, own
process group, Dispatch I/O, cancellation → `killpg`), `GitTestKit`, `RepositorySession`, per-tab `ui` blob,
FSEvents classifier with `.refs`/`.head`/`.index`/worktree kinds, status model, three-pane workbench, Phase 1 idle
baseline. **Missing:** a suspendable stream API for backpressure — implemented as P2.0 (`ProcessStream`,
`specs/P2.0-streamed-process.md`, 8 tests).

## Implemented
- **P2.1 Fixtures** — `GitTestKit.Topology` (fast-import DSL: linear, branch, merge/octopus, orphan, tags,
  remote refs, detach), `SyntheticHistory` (1k/10k/100k: 50 branches, merge every 20, 200 tags), `RandomTopology`
  (seeded DAGs), `JitBench make-history`, `scripts/benchmarks/make-history-fixture.sh`. 100k builds in 6.2 s,
  same HEAD every time. Evidence: `TopologyTests` (4).
- **P2.2 Refs** — `RefSnapshot`/`GitRef`, byte-level `for-each-ref` parser (peeled tags, upstream track/gone,
  HEAD, symbolic remote HEADs, non-commit tags), inline 32-byte `ObjectID`, `StableHash` revision. 10k refs: 4 ms.
  Evidence: `RefsTests` (11).
- **P2.3 Spike S1/S4** — three history sources measured; long-lived `git log` with backpressure chosen; readers
  killed when hidden; losing prototypes deleted. ADR-0010.
- **P2.4 Commit store & reader** — chunked columnar `CommitStore`, `LogParser` (memchr, no String per field),
  `HistoryLoader` actor (shared reads, cancellation kills Git, `--skip` restart with drift check), `HistoryQuery`
  scopes/path/follow/pinned. 189 B/commit, 18.1 MB for 100k; 385 live heap blocks for 25 chunks. ADR-0022.
  Evidence: `HistoryLoaderTests` (12), `HistoryReaderSuspensionTests` (2), `CommitStoreMemoryTests` (2).
- **P2.5 Lane layout** — incremental, deterministic, prefix-stable `LaneLayouter` (cooldown, octopus, roots,
  pinned reservations, HEAD slot 0, name-stable colours with adjacency avoidance). 10 golden files reviewed by
  hand, seeded property test over random DAGs × random page and pipe-read sizes. 13 ms for 100k. ADR-0021.
  Evidence: `LaneGoldenTests` (10), `LanePropertyTests` (5, one parameterised × 8 seeds), `LanePerformanceTests`.
- **P2.6 Graph renderer** — view-based `NSTableView`, Core Graphics cells (lanes/nodes, pills+subject in one
  view, initials avatars), per-appearance colour table, pixel snapping, WIP row, footer, skeleton/empty/error
  states, prefetch, hover/selection, density (View ▸ Graph Density), responsive columns, glass bar with scope menu,
  search and chips. ADR-0009. Evidence: `LaneGeometryTests`, `RefLabelTests`, `DisplayTextTests`, screenshots.
- **P2.7 Inspector** — details (subject, reflowed body, identities, dates, SHA copy, parent links, refs), changed
  files (status, ± bars, renames, flat/tree, first-parent for merges, Combined disabled "planned"), WIP summary,
  LRU 32, cancellation on reselect. Evidence: `CommitDetailsTests` (6), `MessageReflowTests`.
- **P2.8 Navigator** — Local/Remote/Tags outline on the system sidebar material, hierarchy with collapsed
  chains, filter with auto-expand/restore, persisted expansion, tracking badges, `upstream gone`, pins, tag
  message popover, copy/solo/pin/show menus, ↩ to show in graph. Evidence: `NavigatorTreeBuilderTests` (6),
  `NavigatorFilterTests`.
- **P2.9 Search/scope/pin/solo/file history** — tokens, in-memory search, match navigation (↩/⇧↩, ⌘G/⇧⌘G,
  Edit ▸ Find), Highlight vs Show Only Matches, deep search (streamed, bounded, cancellable), scope menu +
  branch picker (persisted), pin left, solo chip, file/folder history chip with the `--follow` caveat.
  Evidence: `HistorySearchTests` (8), `historyFileHistoryFollowsRename`, `pinLeftAssignsLaneZero`.
- **P2.10 Compare** — two commits (ordered older → newer, swap, `...` vs direct), commit ↔ working tree with the
  untracked note, row menu entries. Evidence: `CompareTests` (3).
- **P2.11 Live refresh** — `HistoryInvalidation` (unchanged / labels in place / background reload + swap keeping
  selection and scroll anchor), hidden tabs defer, WIP row follows status, context-menu audit. ADR-0024.
  Evidence: `HistoryInvalidationTests` (5), `HistoryControllerTests` (4).
- **P2.12 Verification** — `JIT_BENCHMARK_GRAPH=1` in-app benchmark, idle runs, ADR-0023 read-only policy,
  row accessibility labels.

## Verified
- Tests: `swift test` **218 passed** (GitCoreTests 152, ServicesTests 39, FeaturesTests 15, DesignSystemTests 12);
  `xcodebuild test` (JitAppTests) **23 passed**; skipped: none. Lint clean (`scripts/build/lint.sh`) — but CI's
  swift-format flagged three test force unwraps that local swift-format 6.4.4 accepted; fixed after the PR opened.
- Real workflow (debug and release app, real repositories): git/git clone (86k commits, 1,012 tags), 1k/10k/100k
  fixtures, a dirty copy of the 1k fixture, an empty repository. Exercised through real launches with debug hooks
  (row selection, compare, WIP selection, search, only-matches, density) and screenshots of each; one pointer
  click selected a row before macOS asked to let Claude bypass the screen-capture picker; the owner granted it
  afterwards and a pointer pass on the 10k fixture followed: row click fills the inspector, the parent link jumps
  to the parent row, a navigator folder expands, `author:hana` + Return moves to match 2 of 65, and a 200-tick
  wheel scroll pages more history in (matches grew to 317 without re-searching). External commits /
  label moves verified through `HistoryControllerTests` against real repositories.
- Screenshots: `docs/phases/02-graph-and-navigation/screenshots/` — 8 screens × light/dark (index in its README).
- Visual review: lanes thin and muted with nodes as the only emphasis, hollow merge rings, accent HEAD ring,
  S-curves inside half rows, opaque tinted pills (current dot, `⇄` combined upstream, outlined remotes). Issues
  found and fixed during the review: graph column hogging width (now fitted to visible lanes), columns hidden
  under the floating inspector (safe area), SHA/author not fitting (responsive columns), skeleton not clearing,
  ragged hard-wrapped bodies (reflow), WIP subject truncated by its counts, compare direction.

## Performance (release build)
| Metric | Previous | Now | Method |
|---|---|---|---|
| First 300 rows visible from history start, 100k | — | 143–156 ms with commit-graph; 413–427 ms without | `JIT_BENCHMARK_GRAPH=1` |
| Same, git/git | — | 142–157 ms with; 485–504 ms without | same |
| Page append (main thread) | — | median 0.27–0.30 ms | same |
| Scroll step p95 / max, 400 screens | — | 1.76–1.94 ms / 10.9 ms, none > 16.7 ms | same |
| Row draw p95 | — | 0.012 ms (fixtures), 0.110 ms (git/git) | same |
| CommitStore 100k | — | 18.1 MB, 189 B/commit (git/git 86k: 53.4 MB) | `CommitStoreMemoryTests` |
| App footprint | 31 MB no repo | 61 MB idle after first pages (100k); 86 MB all 100k loaded; 129 MB git/git all loaded | benchmark, `footprint` |
| Search loaded 100k | — | 2.4 ms | benchmark |
| Idle CPU / wakeups, 100k open | 0.0 % | 0.0 %; 1.0/s active, 0.57/s inactive (no-repo baseline 2.0/s) | `idle.sh` |
| External commit → visible | — | 37 ms after the refs event (+ FSEvents 0.2 s) | `HistoryControllerTests` |

Full table and methods: `docs/performance.md`.

## Decisions
- ADR-0009 Graph rendering — NSTableView + Core Graphics cells; sync row materialization (S2/S3).
- ADR-0010 History loading — long-lived `git log` with backpressure; readers killed when hidden; `--skip` restart.
- ADR-0021 Lane layout & colours — prefix-stable incremental layout, cooldown, HEAD slot 0, name-stable colours.
- ADR-0022 Compact commit storage — chunked columnar store, inline 32-byte ids, parents as ids, 189 B/commit.
- ADR-0023 Read-only invocation policy — no signature verification / ext-diff / textconv for display reads.
- ADR-0024 History invalidation — labels in place vs background reload + swap.

## Deviations from plan
- **P2.0 added** (streamed process API was missing). Docs updated: yes.
- **Graph toolbar** is a floating glass bar at the top of the graph pane, not window toolbar items: the window
  toolbar is fully used by the Phase 1 tab strip. Same glass rules (one `GlassEffectContainer`). Docs: design-system.
- **No SwiftUI snapshot / XCUITest suites** (`graph_simple_merge_{…}` snapshots, `GraphScrollsAndLoadsMore`,
  `NavigatorKeyboardNavigation`, `ExternalCommitAppearsWithoutFlicker` UI tests): there is no snapshot-testing
  dependency and the agent environment has no Accessibility automation (as in Phase 1). Replaced by model/controller
  tests against real repositories (`HistoryControllerTests`, `HistoryInvalidationTests`) and real window captures.
- **Commit store 160 B/commit excluding subjects** vs design's 120 B aim (the 25 MB total budget is met); git/git
  needs 53 MB because its graph keeps many lanes alive (ADR-0022).
- **First-page latency** meets 150 ms only with a commit-graph file; without one Git's topo walk dominates
  (ADR-0010). Jit does not write commit-graphs; "Optimize repository" is a Phase 6 decision.
- `EdgeSegment` is 4 bytes with 13-bit lanes (design: 8-bit lanes) to avoid overflow on very wide graphs.
- The graph column width follows the lanes on screen (design: max over loaded rows, which made git/git's column
  hit the 40 % cap and squeeze subjects).
- Changed-files list is SwiftUI `LazyVStack` (design leaned AppKit); fine for normal commits, not measured at 10k+ files.
- `.mailmap` is honoured (`%aN`/`%aE`) like `git log`.
- Debug launch hooks added: `-JitGraphSelectRow`, `-JitGraphCompareRow`, `-JitGraphSearch`, `-JitGraphOnlyMatches`,
  `-JitGraphSelectWIP`; benchmark mode `JIT_BENCHMARK_GRAPH=1`.
- `idle.sh` parser fixed; Phase 1's "0 wakeups" was a misreading of `top` (see performance.md).
- Phase 1 repository header and status cards were removed from the main pane (the graph replaces them); the
  operation state (Merging/Rebasing…) moved into the graph bar as a chip; counts appear on the WIP row.

## Known issues / carry-overs
- **⇧⌘H "File History…" with a typed path** — not built; file/folder history is reachable from the inspector's file
  menu. Low; Phase 3 (with the working-directory file list).
- **VoiceOver rotors** ("Branch tips", "Merge commits") and a VoiceOver pass — rows have spoken labels; rotors not
  built. Medium; Phase 6 accessibility audit.
- **Instruments Animation Hitches fling trace, 3-tab memory, powermetrics** — not run (need interactive Instruments
  / root). Low; Phase 6.
- **Reduce Transparency / Increase Contrast captures of the graph bar** — need the system settings toggled by a
  person (`scripts/testing/capture-accessibility.sh`). Code uses `jitGlass`, which goes opaque. Low; owner.
- **Space toggles inspector focus** (design §3.7) — not built. Low; Phase 6 keyboard audit.
- **Highlight-mode dimming of non-matching rows** (Q1) — matches are tinted; non-matches are not dimmed. Low; Phase 6.
- **First page without commit-graph** 413–504 ms on ~100k commits — Git's cost; Phase 6 "Optimize repository".
- **Phase 1 carry-overs** still open: Increase Contrast captures, VoiceOver pass, XCUITest suite, paths with newlines.

## Self-review findings
A strict review by a separate reviewer (code read only, no shared conclusions) found two high-severity bugs and
several medium ones. Fixed in `fix: address Phase 2 self-review findings`:
- **High:** a background reload while a page was loading left a stale `pageTask` — pagination stopped and
  `loadRows` could spin on the main actor. Page/refresh tasks now carry generation tokens; `replace()` drops the
  old loader's page task; `loadRows` stops when a page makes no progress.
- **High:** "Show Only Matches" + solo/file history could index past the new snapshot and hit a precondition.
  Matches are recomputed before the table reloads; `displayRow` bounds-checks.
- `select(oid:)` could spin when the tab closed mid-load → stops without progress.
- `loadRows` could restart the reader on a hidden tab (defeating ADR-0010) → guarded by `isActive`.
- `refreshTask` / cancelled `pageTask` could clobber their successors → identity tokens.
- "Compare with Selected" never appeared for an unselected row → uses the selection from before the click.
- Sanitization covered subjects only → now also author names/emails, bodies and tag messages (newlines kept),
  file paths and rename sources, ref names in pills, navigator and inspector; C1 controls replaced.
- `ref:` search used the snapshot's refs after label-only updates → uses the controller's current refs.
- A read resolving after `suspendReader` could be parsed by the reset parser → discarded by reader generation.
- File history treated paths as pathspecs (`a[1].txt`) → `--literal-pathspecs` (`fileHistoryPathIsLiteral`).
- Tag message lookup by ref-name pattern → exact object via `git cat-file tag` (`annotatedTagMessageExactObject`).
- A grace-period kill with unread output could look like a clean end of history → reported as an error.

Logged, not changed:
- `compareWithWorkingTree` and status honour a repository's `core.fsmonitor`: deliberate — Jit follows Git's
  trust model for repositories the user opened (Phase 1 decision, `docs/security.md`; ADR-0023 neutralises
  display-only programs). Revisit with the Phase 5/6 security review.
- Deep search does not search bare hex words as text (loaded search matches them as id prefix or text). Low; Phase 6.

Own findings during the phase (fixed): graph column too wide on git/git, columns under the floating inspector,
skeleton not clearing, ragged commit bodies, WIP subject truncation, compare direction, accessibility labels built
but not attached, hardcoded fonts in Features (lint), idle-script parser.

## Next
- Phase 3 (`docs/phases/03-working-directory-and-diff`), P3.1. Preconditions: this PR merged.
