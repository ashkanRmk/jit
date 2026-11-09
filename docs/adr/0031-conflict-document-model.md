# ADR-0031: Conflict documents from index stages via `git merge-file --zdiff3`

- Status: accepted
- Date: 2026-11-09
- Phase: P4
- Requirements: §8; ADR-0005

## Context
The resolver needs ours / base / theirs per block, byte-exact line endings, and must never be confused by
conflict-marker-like lines that are real content. Scanning the working-tree file depends on the user's
`merge.conflictStyle`, labels Git chose, and any edits already made.

## Decision
- Read stage 1/2/3 blobs (`cat-file blob`), write them to a private 0700 temp dir, run
  `git merge-file -p --zdiff3 --marker-size=<n> -L ours -L base -L theirs` with `n` one longer than any run
  of `<`, `=`, `>`, `|` at a line start in the inputs (minimum 7), and parse into `ConflictSegment` ranges over
  one byte buffer. Opening never touches the index.
- zdiff3 over diff3 (spike on fixtures): common leading/trailing lines move out of the block, so "Both" no
  longer duplicates them; the base section is kept.
- `render(choices)` reproduces Git exactly: all-ours = `merge-file --ours`, all-theirs = `--theirs`,
  ours-then-theirs = `--union --zdiff3` (seeded property test). A final block without a trailing newline is
  trimmed back (merge-file adds one before its markers).
- Saves: hash guard (FNV-1a + length of the file as loaded/saved) → temp file in the same directory with the
  original mode → `fsync` → `rename(2)`. Mark as Resolved re-verifies the hash, then `git add`.
- Non-text (binary, symlink, submodule, > 5 MB, non-UTF-8, modify/delete) uses side choices, each confirmed.

## Consequences
The document never depends on the working-tree file; a file already edited (no markers left) is flagged as
changed and the user chooses Reload from Disk or Keep My Result. Git's own conflict hunks may coalesce
differently from zdiff3's, so the unedited check is "markers present", not a count match.
