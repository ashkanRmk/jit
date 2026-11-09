# Phase 2 screenshots

Real window captures (`scripts/testing/screenshot.sh`, debug build, fresh `JIT_APP_SUPPORT`), light and dark.
Debug launch hooks select rows / search without pointer automation (CLAUDE.md).

| File | Shows |
|---|---|
| `graph-normal-*` | git/git, merge commit selected: first-parent files, parents, reflowed body |
| `graph-compact-*` | Compact density (`-graphDensity compact`) |
| `graph-search-*` | Search `refs`: counter, match navigation, current match selected |
| `graph-onlymatches-*` | `author:patrick`, Show Only Matches (flat list with dots, SHA column visible) |
| `graph-wip-*` | Dirty working tree: dashed WIP node into HEAD, WIP summary in the inspector |
| `graph-compare-*` | Two commits selected: compare older → newer, since common ancestor |
| `graph-empty-*` | Unborn repository: "No commits yet", navigator unborn note |
| `graph-fixture100k-*` | 100k fixture, HEAD row selected: current-branch pill, remote outline pill, branch-name colours |

Not captured: loading skeleton (too brief to catch reliably), error banner, Reduce Transparency /
Increase Contrast variants (need the system setting toggled by a person).
