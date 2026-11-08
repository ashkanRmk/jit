# Phase 2 — Git Graph & Navigation: Implementation Plan

Design: [`design.md`](design.md). Requirements: §4.3, §4.4, §5, §9.1 (tags), §14, §15.

## 1. Preconditions

From Phase 1 `progress.md` (exit gate passed or carry-overs accepted):
- [ ] `RepoHandle` open/close over UniFFI, `ProcessRunner` with argv arrays, `CancelToken` that kills
      the child process group, progress callback interface.
- [ ] `git-testkit` can build fixture repos (commits, branches, merges, tags) in temp dirs.
- [ ] `RepositorySession` per tab, session persistence (tabs, widths, per-repo UI state blob).
- [ ] FSEvents watcher with coalescing delivering `.git/HEAD`, `.git/refs`, `packed-refs`, `index`
      and worktree change classes.
- [ ] Status (porcelain v2) model available (for WIP row counts).
- [ ] Three-pane split layout with sidebar/main/inspector empty states; DesignSystem tokens.
- [ ] Idle CPU baseline recorded for Phase 1.

If any is missing, stop and complete it as `P2.0` before continuing (record in `progress.md`).

## 2. Milestones

### P2.1 Fixtures & benchmark repos
Goal: deterministic repos for tests and perf.
- [ ] `git-testkit`: builder DSL for topologies (`linear(n)`, `branch`, `merge(parents…)`, `octopus`,
      `crisscross`, `orphan`, `tag`, `detach`), producing stable oids (fixed dates/author via env).
- [ ] `scripts/benchmarks/make-history-fixture.sh <commits> <branches> <out>` using `git fast-import`;
      generates 1k / 10k / 100k (+ 50 branches, merge every 20 commits, 200 tags).
- [ ] Document fixture locations (outside the repo, e.g. `~/Library/Caches/jit-bench/`) in `docs/performance.md`.
Files: `rust/crates/git-testkit/src/topology.rs`, `scripts/benchmarks/make-history-fixture.sh`.
Tests: `testkit_topologies_are_deterministic`.
Done when: 100k fixture builds in < 60 s and is reproducible byte-for-byte (same HEAD oid).

### P2.2 Refs model
- [ ] `refs::read(repo)` — single `for-each-ref -z` call; parse local/remote/tags (peeled), HEAD
      (branch / detached / unborn), upstream + track (`[ahead 2, behind 5]`, `[gone]`).
- [ ] `RefSnapshot.refs_rev` hash.
- [ ] UniFFI `RefSnapshot`, Swift mapping.
Files: `git-core/src/refs.rs`, `git-ffi/src/refs.rs`.
Tests: `refs_parse_detached_head`, `refs_parse_unborn`, `refs_upstream_gone`, `refs_annotated_tag_peeled`,
`refs_unicode_branch_names`, `refs_10k_branches_under_100ms`.
Done when: all pass; 10k refs parsed < 100 ms (release).

### P2.3 Spike S1 — history source (ADR-0010)
- [ ] Implement the three candidate readers behind a trait in a throwaway bench (`benches/history_source.rs`).
- [ ] Measure first-300 latency, full-100k time, idle CPU (Activity Monitor/`top -l` + `powermetrics`
      sample), RSS (app + child) on 1k/10k/100k fixtures and the Git source repo; with/without commit-graph.
- [ ] Write ADR-0010 with numbers; delete losing implementations.
Done when: ADR merged; chosen reader passes the golden equality test against `git log --topo-order`.

### P2.4 Commit store & history reader
- [ ] `CommitStore` columnar layout (design §4.1), interned authors, subject arena, oid index,
      SHA-1/SHA-256 variants.
- [ ] `HistoryReader` per ADR-0010; `HistoryQuery` (scope, path, follow, pinned).
- [ ] `HistoryHandle::{ensure_loaded, rows, row_for_oid, close}` over UniFFI; cancel kills reader.
Files: `git-core/src/store.rs`, `git-core/src/history.rs`, `git-ffi/src/history.rs`.
Tests: `history_matches_git_log_topo_order` (all fixtures), `history_pagination_equivalence`,
`history_cancel_kills_process`, `history_reader_exit_maps_error`, `history_shallow_boundary`,
`history_sha256_repo`, `store_memory_100k_under_25mb` (measures `size_of` + arena capacity).
Done when: all pass; ADR-0022 written.

### P2.5 Lane layout (ADR-0021)
- [ ] `LaneLayouter` incremental (design §4.4) incl. pinned seeding, cooldown, octopus, roots,
      lane compression metadata (`width_lanes`).
- [ ] `color_for(branch_key)` with adjacency avoidance; HEAD branch slot 0.
- [ ] Golden-file harness: ASCII + JSON expected outputs under `git-core/tests/lanes/*.txt`;
      `UPDATE_GOLDEN=1` to regenerate (review diffs manually).
Tests (one golden each): `lanes_linear`, `lanes_simple_merge`, `lanes_octopus_3`, `lanes_crisscross`,
`lanes_long_lived_develop`, `lanes_rebased_branch`, `lanes_40_parallel`, `lanes_detached_head`,
`lanes_orphan_root`, `lanes_late_second_parent_10k`; property: `lanes_prefix_stable_any_page_size`
(proptest over random DAGs: layout(all) == concat(layout(pages)) for page sizes 1…2000),
`lanes_deterministic_across_runs`, `lanes_color_stable_for_branch_name`.
Done when: all pass; layout of 100k rows < 150 ms total (release).

### P2.6 Graph renderer (ADR-0009) — visual design pass
- [ ] Add `graph.*` tokens (sizes for compact/comfortable, 8 lane colours per theme, pill styles)
      to DesignSystem; contrast check script for lane colours vs canvas (≥ 3:1).
- [ ] `GraphTableView`, `GraphCellView` (Core Graphics), `RefLabelsView`, text columns, column
      persistence, density switch (View menu: Compact / Comfortable).
- [ ] Prefetch on scroll; `insertRows` append without animation; WIP row (dashed node).
- [ ] Hover/selection styles + durations; Reduce Motion.
- [ ] Spike S2/S3 measurements recorded in ADR-0009.
- [ ] Empty / loading (static skeleton) / error banner / end-of-history footer states.
Files: `macos/.../Features/GitGraph/*`, `DesignSystem/Graph*.swift`.
Tests: unit `LaneGeometryTests` (segment → path points, pixel snapping at 1×/2×),
snapshot tests `graph_simple_merge_{light,dark}_{compact,comfortable}`, `graph_wip_row`,
`graph_ref_pills_overflow`, `graph_detached_head`; UI test `GraphScrollsAndLoadsMore`.
Verification: screenshots in `screenshots/` (`graph-normal-light.png`, `-dark`, compact, empty,
loading, error); Instruments Animation Hitches on 100k fixture fling.
Done when: 60 FPS (no hitches > 1 frame in a 10 s fling) and visual review in both themes done —
iterate on spacing/colour until it reads as calm and original (§5.5); record before/after screenshots.

### P2.7 Commit details inspector
- [ ] `commit_details(oid)` (body, committer, parents, refs) + changed files (`diff-tree -M -z
      --numstat --name-status`, root commits via `--root`), merge commits vs first parent.
- [ ] `CommitDetailsView` hierarchy (design §3.4), copy SHA, parent links (select/load).
- [ ] `ChangedFilesList` (flat/tree), `+/-` mini bars; "Show File History" row action.
- [ ] LRU of 32 details in Rust; cancel on selection change.
Tests: `details_root_commit`, `details_merge_first_parent`, `details_rename_detected`,
`details_binary_numstat_dash`, `details_unicode_paths`, `details_cancelled_on_reselect` (Swift).
Done when: details appear < 50 ms for normal commits (signpost), screenshots in both themes.

### P2.8 Branch navigator
- [ ] `NSOutlineView` sections Local / Remote (per remote) / Tags, hierarchy grouping with single-child
      folder collapse, counts, current branch, ahead/behind badges, `upstream gone`.
- [ ] Filter field (fuzzy subsequence), auto-expand while filtering, restore after.
- [ ] Click → select ref tip in graph (load pages; confirm if beyond 50k rows).
- [ ] Context menus (copy name, copy SHA, pin/unpin, solo, show in graph); annotated tag popover.
- [ ] Keyboard navigation; expand state persistence; VoiceOver labels.
Tests: `NavigatorTreeBuilderTests` (grouping, collapse, sort: natural order, current first),
`NavigatorFilterTests`, UI test `NavigatorKeyboardNavigation`, perf `navigator_10k_branches_build_under_50ms`.
Done when: 10k-branch fixture scrolls smoothly; screenshots both themes.

### P2.9 Search, filter, scope, pin, solo, file history
- [ ] Toolbar scope menu (All / Current / Local / Selected…), persisted per repo.
- [ ] Pin-left (seeds lanes) and solo (scope = one ref) with toolbar chips.
- [ ] `search_loaded` (tokens: text, `sha:`/hex, `author:`, `ref:`), match navigation ⌘G/⇧⌘G, counter.
- [ ] `search_deep` streaming with cancellation; "Show only matches" flat mode.
- [ ] File history mode (`-- path`, `--follow` for single files) with chip + tooltip caveat.
Tests: `search_hex_prefix`, `search_author_case_insensitive`, `search_fixed_string_metachars`,
`search_deep_cancel`, `file_history_follows_rename`, `file_history_directory_no_follow`,
`scope_solo_excludes_other_branches`, `pin_left_assigns_lane_zero`.
Done when: search over 100k loaded rows < 30 ms; deep search cancellable within 100 ms.

### P2.10 Compare
- [ ] Two-commit selection (⌘-click / ⇧↑↓), compare view with swap and `..`/`...` toggle.
- [ ] Commit ↔ working directory (WIP + commit) list.
- [ ] Context menu entries (Compare with Working Directory, Compare with Selected).
Tests: `compare_two_dot_vs_three_dot`, `compare_with_worktree_includes_untracked_flag`
(untracked excluded by default with a visible note), `compare_renames`.
Done when: lists correct vs `git diff --name-status` on fixtures.

### P2.11 Live refresh & context menu audit
- [ ] Refs event handling: in-place label update vs handle swap (ADR-0024), preserving selected and
      anchor oids; inactive tabs mark dirty and refresh on activation.
- [ ] WIP row appears/disappears with status changes.
- [ ] Audit every context menu: only valid actions; no "Copy remote link" (Phase 4), no checkout (Phase 4).
Tests: `refresh_label_move_in_place` (Rust decision function), UI test `ExternalCommitAppearsWithoutFlicker`
(commit via `git` CLI in test → row 0 updates, selection preserved), `inactive_tab_defers_refresh`.
Done when: external commit shows in < 500 ms after FSEvents coalescing; idle CPU unchanged.

### P2.12 Performance & accessibility verification
- [ ] Release-build measurements (table in §4) on 1k/10k/100k fixtures + Git source repo.
- [ ] Memory with 3 tabs open (100k, 10k, Git source).
- [ ] VoiceOver pass: row labels, rotors (branch tips, merges), navigator.
- [ ] Idle check: 5 minutes idle after loading 100k history → CPU ≈ 0, no wakeups from Jit
      (`powermetrics --samplers tasks`), no child process CPU.
- [ ] Write ADR-0023 (read-only invocation policy) and finalize all ADRs.
Done when: numbers recorded honestly in `progress.md` and `docs/performance.md`.

## 3. Test plan summary

| Layer | What | Where |
|---|---|---|
| Rust unit | refs parsing, store, search, lane math, color assignment | `git-core/src/**` `#[cfg(test)]` |
| Rust golden | lane layouts (ASCII/JSON) incl. page boundaries | `git-core/tests/lanes/` |
| Rust property | prefix stability over random DAGs (proptest) | `git-core/tests/lanes_prop.rs` |
| Rust integration | history vs `git log`, cancellation, shallow, SHA-256, file history, compare | `git-core/tests/history.rs` |
| Swift unit | lane geometry/pixel snapping, navigator tree, view models | `JitKit/Tests/GitGraphTests` |
| Snapshot | graph states × themes × density, inspector, navigator | `JitKit/Tests/Snapshots` |
| UI | scroll+load, navigator keyboard, external commit refresh, compare | `macos/UITests` |

## 4. Performance checks (release build; record hardware, macOS, Git, repo)

| Metric | Target | Method |
|---|---|---|
| First 300 rows visible (100k fixture) | < 150 ms | signpost from open_history to first draw |
| Page append main-thread cost | < 16 ms | signpost around `insertRows` |
| Scroll | 60 FPS, 0 hitches > 1 frame / 10 s fling | Instruments Animation Hitches |
| Row draw | ≤ 2 ms p95 | signpost in `GraphCellView.draw` |
| Rust memory for 100k commits | ≤ 25 MB | allocator stats / Allocations |
| App memory, typical repo open | < 200 MB | Activity Monitor "Memory" + `footprint` |
| Search loaded 100k | < 30 ms | Rust bench |
| Idle CPU after load | 0.0–0.2 % | `top -l` sampling 5 min + `powermetrics` |

## 5. Docs to update

- `docs/architecture.md` — history/lanes/store section, bridge API for history.
- `docs/design-system.md` — graph tokens, lane palettes (both themes), pill styles, density.
- `docs/performance.md` — fixtures, measurement method, Phase 2 results.
- `docs/security.md` — read-only invocation policy (ADR-0023), display sanitisation of messages/refs.
- `docs/adr/0009, 0010, 0021–0024`.
- `CLAUDE.md` — new commands (fixture generation, golden update).

## 6. Exit checklist

- [ ] Demo script in `design.md §1` performed on the 100k fixture and the Git source repo.
- [ ] Lane golden + property tests pass; page-boundary equivalence proven.
- [ ] Graph reviewed in light and dark, compact and comfortable; screenshots committed; judged
      original (not resembling reference screenshots) and calm.
- [ ] No SwiftUI view or CALayer per historical commit; rows reused (verified with view debugger).
- [ ] Navigator read-only + copy only; no checkout, no remote links (Phase 4).
- [ ] External ref changes refresh without full reload or flicker; inactive tabs do no work.
- [ ] Performance table filled with measured numbers (or honest misses + bottleneck analysis).
- [ ] Roadmap §9 phase exit gate satisfied.
