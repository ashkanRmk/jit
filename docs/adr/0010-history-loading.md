# ADR-0010: History loading strategy

- Status: accepted
- Date: 2026-11-09
- Phase: P2 (spike S1, S4)
- Requirements: §4.4, §5, §14, §15; ADR-0002, ADR-0005

## Context
The graph needs the first rows of `--topo-order` history fast, more rows as the user scrolls, zero CPU
while idle, and output identical to `git log --topo-order`. Three sources were measured with
`JitBench history-source` (release build) on a MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2,
Git 2.54.0, against the synthetic fixtures (`docs/performance.md` → Methods) and a clone of
`github.com/git/git` (86,059 commits reachable from all refs):

1. **Long-lived `git log`** with backpressure: one child per history view; stdout read only while rows are
   requested (`ProcessStream`, P2.0), so the child blocks on a full pipe between requests.
2. **Re-query per page**: `git log --skip=N --max-count=M` for each page; no idle process.
3. **Two-stage**: stream `git rev-list --topo-order --parents` for topology, fetch subject/author/time for
   visible windows by id (`git log --no-walk` here; `cat-file --batch` would need a stdin-capable runner).

| Repository | commit-graph | Strategy | First 300 rows | All rows |
|---|---|---|---|---|
| 100k fixture | no | long-lived log | 284–379 ms | 423–506 ms |
| 100k fixture | no | `--skip` re-query | 281 ms | 14,605 ms |
| 100k fixture | no | rev-list + metadata | 288 ms | 340 ms |
| 100k fixture | yes | long-lived log | 32–35 ms | 440 ms |
| 100k fixture | yes | `--skip` re-query | 35 ms | 2,147 ms |
| 100k fixture | yes | rev-list + metadata | 42 ms | 94 ms |
| git/git | no | long-lived log | 360–405 ms | 512–558 ms |
| git/git | no | rev-list + metadata | 363 ms | 410 ms |
| git/git | yes | long-lived log | 43–44 ms | 533 ms |
| git/git | yes | rev-list + metadata | 54 ms | 103 ms |
| 10k fixture | no / yes | long-lived log | 33 / 17 ms | 56 / 74 ms |
| 1k fixture | no / yes | long-lived log | 12 / 10 ms | 15 / 14 ms |

Idle reader (long-lived log, sampled for 2 s starting 1 s after the first page): **0.00 ms CPU** in every
case. Its physical footprint while blocked: 3 MB (1k), 4–7 MB (10k), **16 MB** (100k, commit-graph),
**50 MB** (100k, none), **93 MB** (git/git, none) — Git keeps the walked topology in memory.

**S4 (commit-graph absent):** `--topo-order` must walk all reachable commits before emitting the first
one; first rows take 280–400 ms on ~100k-commit repositories. Every strategy pays this; it is Git's cost,
not the reader's. With a commit-graph file (written by `git gc` by default, `gc.writeCommitGraph=true`)
the first page is 32–44 ms.

## Decision
- **Strategy 1, long-lived `git log --topo-order -z`** read through `ProcessStream` with backpressure,
  implemented by `GitCore.HistoryLoader`. It is the simplest option that meets the first-page target
  where Git can (commit-graph present), returns all display fields in one pass (no second process, no
  extra latency on fast scrolls), and costs zero CPU while idle. Strategy 3's faster full load does not
  matter because rows load on demand; strategy 2's full cost grows quadratically.
- Pages: 300 rows first, then 2,000 when the visible range comes within 500 rows of the end.
- **Readers are killed when their tab becomes inactive** (`HistoryLoader.suspendReader()`): measured
  per-reader footprint (16–93 MB on large repositories) exceeds the 5 MB threshold in design §4.3.
  Loaded rows stay in the store. The next page request restarts the reader with `--skip=<loaded − 1>`
  and verifies that the first record equals the last loaded commit; on mismatch it reports "The history
  changed while it was loading" (ADR-0024 then reloads).
- A cancelled read (the requesting task cancelled) kills the reader the same way; `close()` kills it
  for good (tab closed, scope/mode changed).
- Jit never writes a commit-graph file (that would modify the user's `.git`). Without one, the toolbar
  spinner appears after 150 ms; an explicit "Optimize repository" maintenance action is a Phase 6
  decision.
- The losing prototypes were removed from `JitBench`; `history-source` now measures the chosen loader only.

## Consequences
- One extra child process per *visible* history view, blocked and CPU-free; none for hidden tabs.
- First-page latency on large repositories without a commit-graph misses the 150 ms target
  (280–400 ms on ~100k commits). Revisit if a later Git offers streaming topo order without a full walk,
  or if users report it (then reconsider strategy 3 with a persistent `cat-file --batch`, ADR-0002 still
  forbids an in-process Git library without profiling evidence).
- `--skip` restarts re-walk history in Git (≈ the first-page cost), only after a tab was hidden.
