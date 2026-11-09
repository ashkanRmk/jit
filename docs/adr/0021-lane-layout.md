# ADR-0021: Lane layout algorithm & colour assignment

- Status: accepted
- Date: 2026-11-09
- Phase: P2
- Requirements: §5; design.md §3.2, §4.4

## Context
The graph must never shift or recolour rows that are already on screen while more history loads, must
be identical on every launch, and must stay readable with many branches. Layout runs in `GitCore` as rows
stream in (ADR-0010), so it has to be incremental and cheap.

## Decision
`GitCore/History/LaneLayouter.swift`, fed in `git log --topo-order` order (parents after children):
- State: slots with `expected` commit id, colour, state (free / active / reserved) and the row each slot
  was freed at.
- Per commit: slots expecting it → the leftmost becomes the node lane; every *drawn* expecting slot emits a
  `top` segment into the node; the others are freed. No slot → a new tip in the lowest usable slot.
  Other active slots emit `full` pass-through segments. First parent continues in the node lane
  (`bottom` segment). Each further parent: an active slot already expecting it gets a `bottom` curve into
  it; otherwise a new slot is allocated, searching only to the right of the node (merges read left→right).
  A root frees its lane.
- **Cooldown:** a freed slot is reusable only after one fully empty row (`freedAt + 1 < row`).
- **Never move a lane sideways**; gaps close only by reuse. Lanes are stored per row (`nodeLane`,
  `width`, `segments`), so rows draw in isolation.
- **Pinned refs** reserve slots 0…p−1 (drawn as nothing) until their tip arrives; a pinned tip reached
  through another lane first releases its reservation.
- **Colours:** 8 palette slots. Slot 0 belongs to HEAD's lane (HEAD's commit as a tip, or HEAD's branch
  name as the key). Others: `StableHash(key) % 7 + 1`, stepping to the next slot while it equals an
  adjacent active lane's colour. Key = most specific ref at the tip (local > remote without the remote
  name > tag), for second-parent lanes the branch named in `Merge branch 'x'` / `Merge remote-tracking
  branch 'origin/x'` / `Merge pull request #N from owner/x`, else the commit id. FNV-1a, never Swift's
  seeded `Hasher`.
- `EdgeSegment` lanes are 13-bit (8,191 lanes); wider graphs clamp (ADR-0022).

Golden format (`Tests/GitCoreTests/Resources/lanes/*.txt`, regenerated with `UPDATE_GOLDEN=1` and reviewed
by hand): `<subject> | <cells> | n<lane>:<colour> <flags> | <segments>` — see `LaneGoldenTests`.

## Consequences
- Prefix stability holds by construction (row k reads only state built from rows < k) and is proven by
  `lanesPrefixStableAnyPageSize` (8 seeded random DAGs × 3 random page/pipe-read schedules) and
  `historyPaginationEquivalence`. Layout of 100k rows: 13 ms release (`lanesLayout100kUnder150ms`).
- Colours are name-stable across sessions but not across adjacency changes (a neighbour may push a
  branch to the next slot) — names, not colours, carry meaning (design §3.8).
- Topo order sometimes puts a long-lived side branch in lane 0 above HEAD's line; HEAD keeps slot 0's
  colour, not lane 0. Pin-left is the user's tool to force HEAD's branch leftmost.
