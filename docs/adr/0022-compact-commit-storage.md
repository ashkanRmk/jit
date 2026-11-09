# ADR-0022: Compact commit storage & memory budget

- Status: accepted
- Date: 2026-11-09
- Phase: P2
- Requirements: §14, §15; ADR-0002, ADR-0005

## Context
The graph must hold 100k+ commits in Swift without ARC traffic or per-commit heap objects. Budget
(implementation.md §4): `CommitStore` ≤ 25 MB for 100k commits including subjects and the author
table; design §4.1 aimed for ≤ 120 bytes/commit excluding subjects.

## Decision
- **Chunked, append-only, columnar store** (`GitCore/History/CommitStore.swift`): 4,096 rows per
  `final class CommitChunk: Sendable` (one object per chunk). Columns are `ContiguousArray`s of trivial
  types: object ids, parent end offsets + flat parent ids, author index, author time, subject end
  offsets + a UTF-8 byte arena, node lane/colour/flags, row width, segment end offsets + flat
  4-byte `EdgeSegment`s (13-bit lanes, 3-bit colour, 2-bit half), and a `UInt16` permutation sorted by
  object id for lookup.
- **One object-id layout**: inline 32-byte `ObjectID` (4 × `UInt64`) for SHA-1 and SHA-256 alike;
  the snapshot carries the format. Monomorphic columns beat generic stores; SHA-1 pays 12 bytes/commit.
- **Parents are stored as ids**, not row indices: in topo order parents arrive after their children,
  and sealed chunks are immutable, so indices could only be resolved through a side table that grows
  with history. Row lookup is a binary search per chunk (`row(for:)`) — no global hash map
  (≈ 60 bytes/entry saved).
- **Authors interned** (64-bit FNV-1a of name/email bytes → index; scan on collision); author
  `String`s exist once per distinct author. Bodies are not stored (fetched lazily per selection).
- `HistorySnapshot` = `[CommitChunk]` + count: publishing a page copies the chunk-reference array and
  an exactly sized copy of the partial tail chunk only. Sealed chunks are shrunk to exact capacity
  (`ChunkBuilder.exactCopy` — `ContiguousArray(array)` would keep the over-allocated buffer).
- `String`s are materialized only for visible rows (`CommitRow.subject`, UI row cache).

## Measured (100k fixture, `CommitStoreMemoryTests`, sum of column capacity × stride)
**189 bytes/commit → 18.1 MB** for 100,000 commits (budget 25 MB). Breakdown per commit: segments 43
(10.0 segments/row — this fixture keeps ~9 lanes alive), object ids 36, parent ids 36, subjects 31
(arena incl. offsets: 28 B text), times 11, lane columns 7, offsets 12, author index 4, sort index 2.
Excluding subjects: 160 B/commit — above design §4.1's 120 B aim because of 32-byte inline ids, parent
ids, and wide lane sets; within the 25 MB total budget. Live heap blocks retained by a loaded 100k
snapshot: 385 for 25 chunks (`noPerCommitHeapObjects`).

## Consequences
- Memory scales with commits × active lanes; a repository with hundreds of concurrent lanes stores
  more segments (4 bytes each). Revisit with a run-length "pass-through" encoding if a real repository
  exceeds the budget.
- Lookups by id are O(chunks × log 4096) — fine for selection, navigation and refresh decisions, not
  meant for per-row hot loops.
- Allocation-heavy APIs (`String` per field, class per commit) are forbidden in the history path.
