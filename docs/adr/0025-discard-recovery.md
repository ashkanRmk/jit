# ADR-0025: Discard recovery store

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §16.3, §26 (priority 1); ADR-0027

## Context
Discarding working-tree changes is the one Phase 3 action that destroys user data Git never stored.
Git has no undo for it. A confirmation alone does not help after a wrong click or a file edited between
reading the sheet and pressing Discard.

## Decision
- **File-level token.** When the confirmation sheet opens, Jit records per path the `git ls-files -s -z`
  record and a working-tree fingerprint (`lstat` type, size, inode, mtime ns, plus a stable 64-bit hash
  of the bytes, the link target, or a directory's entry list). Inside the write gate, `discard` re-reads
  every token before touching anything; any difference → `staleSnapshot`, nothing changed, and the user
  must reopen the sheet (no Retry).
- **Order inside the gate:** validate all tokens → copy every tracked file that exists into the recovery
  store → move untracked paths to the Trash → `git restore --worktree` (literal pathspecs on stdin). A
  failed copy stops the discard before any change. Staged changes are kept (restore from the index).
- **Untracked** files and folders go to the Trash (`FileManager.trashItem`), never deleted.
- **Store:** `<App Support>/Jit/Recovery/<repo-id>/<yyyyMMdd-HHmmss>-<n>/` with `meta.json` (repository,
  branch, path, operation, time, size — no secrets) and the file as it was (symlinks stay links).
  `repo-id` is a stable hash of the top-level path. Directories `0700`, files `0600`.
- **Retention:** 7 days, then oldest-first down to 500 MB; pruned once at launch off the main thread.
  Entries with unreadable metadata are never removed by guesswork.
- **Access:** Repository ▸ Recently Discarded lists the active repository's copies (reveal in Finder) and
  Show Recovery Folder. Restoring is a manual copy in V1.
- GitCore stays free of app locations: `discard` takes `DiscardHooks` (preserve, trash); Services supplies
  them from `RecoveryStore`.

## Consequences
- Evidence: `DiscardTests` (`discardTrackedKeepsStagedChanges`, `discardWritesRecoveryCopyFirst`,
  `discardUntrackedMovesToTrash`, `discardStaleTokenRefused`, `discardUnrelatedFilesByteIdentical`,
  literal paths, preview), `RecoveryStoreTests`, `WorkingDirectoryTests` discard flow.
- Fingerprinting reads the whole file (and walks an untracked folder) when the sheet opens and again at
  discard: fine for source files, slower for very large binaries.
- Line-level discard (P3.4+) reuses the store with the full snapshot token of ADR-0013.
