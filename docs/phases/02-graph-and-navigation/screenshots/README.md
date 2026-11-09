# Phase 2 screenshots

Real window captures (`scripts/testing/screenshot.sh`, debug build, fresh `JIT_APP_SUPPORT`), light and dark.
Debug launch hooks select rows / search without pointer automation (CLAUDE.md). Recaptured 2026-11-09 in the
P2.13 style (avatar nodes, elbow edges, Branch / Tag column).

| File | Shows |
|---|---|
| `graph-normal-*` | This repository, merge commit selected: first-parent files, two parents, refs; WIP row above |
| `graph-compact-*` | Compact density (`-graphDensity compact`) |
| `graph-search-*` | 10k fixture, search `lane`: counter, match navigation, current match selected |
| `graph-onlymatches-*` | `author:patrick`, Show Only Matches (flat list with dots, SHA column visible) |
| `graph-wip-*` | This repository with uncommitted work: dashed WIP node into HEAD, WIP summary in the inspector |
| `graph-compare-*` | 10k fixture, two commits selected (`-JitGraphSelectRow 3 -JitGraphCompareRow 8`) |
| `graph-empty-*` | Unborn repository: "No commits yet", navigator unborn note |
| `graph-fixture100k-*` | 100k fixture, HEAD row selected: current-branch pill, remote outline pill, branch-name colours |

Not captured: loading skeleton (too brief to catch reliably), error banner, Reduce Transparency /
Increase Contrast variants (need the system setting toggled by a person).
