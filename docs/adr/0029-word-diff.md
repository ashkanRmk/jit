# ADR-0029: Word-level diff

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6; ADR-0011, ADR-0026

## Context
Within a changed line, showing which words changed makes small edits readable. Git's `--word-diff`
output cannot be combined with the applicable patch Jit parses (ADR-0026), and running Git twice per diff
doubles the cost.

## Decision
Own implementation (`Features/DiffViewer/WordDiff.swift`):
- **Pairing:** inside a hunk, a run of deleted lines followed by a run of added lines is paired line by
  line when the longer run is at most twice the shorter; both lines must be under 1,000 bytes.
- **Tokens:** identifier runs, whitespace runs, and single other characters (UTF-16).
- **Algorithm:** Myers O((N+M)·D) shortest edit script on tokens; tokens outside the common subsequence
  are emphasised (adjacent ones merged). Lines that share no token get no emphasis.
- Computed lazily for visible rows and cached per document; toggle in the diff options menu.

## Consequences
- Pure Swift standard library, no Git invocation; cost bounded by the line-length limit.
- Evidence: `HighlightTests.wordDiffPairsAndLimits`, `myersFindsLongestCommonSubsequence`.
