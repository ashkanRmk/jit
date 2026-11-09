# ADR-0043: Cache limits and memory-pressure behaviour

- Status: accepted
- Date: 2026-11-09
- Phase: P6
- Requirements: §15.5; design §4.5

## Context
Caches were bounded but their limits were scattered constants, and nothing reacted to memory pressure
except session suspension. The large-diff benchmark found one unbounded cost: a 5 MB single-line file laid out
as one `CTLine` (220 MB of glyph advances, ≈ 400 MB of large allocations, 236 MB of GPU surfaces; footprint
1.2 GB).

## Decision
- `GitCore/Diagnostics/CacheLimits.swift` holds every limit; each cache reads its value from there:
  graph rows (16 windows × 64 rows), graph avatars (1,024), code-line `CTLine`s per view (4,000; oldest quarter
  dropped), rendered line length (10,000 UTF-16 units, the rest shown as "+N characters not shown"), diff size
  (64 MB), highlighting (2 MB / 50,000 lines), word diff (1,000 bytes per line), palette tracked paths
  (100,000) for the 2 most recent repositories, recents (20), reopen stack (10), operation history (20).
- History stays in the compact struct-of-arrays store (≈ 189 B/commit, ADR-0022); graph pages are **not**
  evicted: 100k commits cost 18 MB and the materialized-row cache is already bounded, so eviction would add
  re-fetch latency for no measurable gain.
- Memory pressure posts `CacheLimits.trimNotification`: code views release their line caches (storage too),
  the palette drops its file index, inactive sessions suspend (ADR-0042).

## Consequences
- 5 MB-line diff: 1,218 → 204 MB. Copy, search and line actions still use the full document.
- Changing a limit is a one-line change with a test (`IdleAndCacheTests.codeLineCacheIsBoundedAndTrims`).
