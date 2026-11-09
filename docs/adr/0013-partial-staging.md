# ADR-0013: Partial staging algorithm

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §7, §16, §18.2, §24 (Scenario C); ADR-0025, ADR-0026, ADR-0027

## Context
Staging, unstaging and discarding selected lines is the riskiest feature of a Git client: a wrong patch
silently stages bytes the user never chose or destroys working-tree edits. It must never touch anything
outside the selected lines of the one file.

## Decision
Selection semantics (design §4.4), for a hunk and a set S of selected changed lines:

| Operation | Source diff | Selected `+` | Unselected `+` | Selected `-` | Unselected `-` | Apply |
|---|---|---|---|---|---|---|
| Stage | unstaged | keep `+` | drop | keep `-` | → context | `git apply --cached` |
| Unstage | staged | keep `+` | → context | keep `-` | drop | `git apply --cached -R` |
| Discard | unstaged | keep `+` | → context | keep `-` | drop | `git apply -R` |
| Keep only | unstaged | discard the complement of S | | | | `git apply -R` |

Every operation runs inside the write gate (ADR-0027):
1. Re-read the `SnapshotToken`; any difference in the fields the operation depends on (HEAD + index for
   unstage; index + working tree for stage/discard) → `staleSnapshot`, nothing changes.
2. `filter` attribute → refused. Read the target's current bytes (index blob or working-tree file).
3. `PatchBuilder` (pure) emits the patch (own headers, all context kept, hunk positions recomputed, no
   `--recount`/`--unidiff-zero`/fuzz) and, separately, the expected target: the target's bytes with each
   hunk's range replaced by the lines the operation keeps. The builder first checks that the target
   holds exactly the lines the diff shows; a mismatch on a file with `text`/`eol`/`core.autocrlf`
   conversion → refused ("stage the whole file instead"), otherwise stale.
4. Patch written to a private `0700` directory as a `0600` file; `git apply --check`; failure → refused.
5. Discard / keep-only: recovery copy (ADR-0025) before touching the file.
6. `git apply`.
7. Verify: index blob (or absence) equals the expected bytes and every other index entry is unchanged;
   for discards the working-tree bytes equal the expected bytes and the index is unchanged. Index
   mismatch → the captured entry is restored with `update-index --index-info` (path on stdin) and
   `verificationFailed` is reported; working-tree mismatch → reported with the recovery copy's location.

Allowed / refused (reason codes → disabled controls with this text): binary, symlink, submodule, type
change, whitespace hidden, filter/line-ending conversion (only when the working-tree side does not match
or a filter is set; the index side is allowed when it verifies), ambiguous final newline (a line without
final newline would have to stop being last), renamed/copied on the staged side (file-level only in V1),
truncated diffs. New files (partial → new-file patch with the selected lines), deleted files (partial →
file kept with the remaining lines; all → deletion), unstaging all lines of a new file (entry removed).

## Consequences
- Evidence: `ApplyTests` (28 cases, §7.4 matrix incl. CRLF, mixed EOL, no final newline ×3, Unicode /
  quote / dash / newline paths, mode change, autocrlf and `eol` attribute matrices, filter refusal,
  stale token, concurrent writer during apply → rollback, index.lock, stage-then-unstage round trip) and
  `ApplyPropertyTests` (seeded random files/edits/partial staging/selections vs a model). A deliberately
  broken builder fails six matrix tests (mutation check).
- Verification costs two extra Git reads per action; acceptable against the 150 ms budget.
- Rename-aware line unstage, and discarding on converted files, stay file-level in V1.
