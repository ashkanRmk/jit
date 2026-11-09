# ADR-0023: Read-only Git invocation policy

- Status: accepted
- Date: 2026-11-09
- Phase: P2
- Requirements: §13.5, §19; ADR-0005, ADR-0008

## Context
Displaying history runs `git log`, `git show`, `git diff-tree`, `git diff`, `git for-each-ref` many times.
Some repository/user configuration makes Git execute external programs only to *display* things:
signature verification (`log.showSignature` → gpg/ssh), external diff drivers (`diff.external`,
`GIT_EXTERNAL_DIFF`), textconv filters. A cloned repository cannot set these itself (`.git/config` is
local), but users' global config can, and running gpg for every page of history is slow and surprising.

## Decision
- Read-only display invocations neutralise program-executing *display* options per invocation:
  `-c log.showSignature=false` and `--no-show-signature` for `log`/`show`; `--no-ext-diff` and
  `--no-textconv` for `log`, `diff`; `diff-tree` uses neither by default. (`ReadOnlyPolicy`, `HistoryQuery`,
  `CommitDetails`.)
- Everything else in repository and user configuration is respected (e.g. `.mailmap` via `%aN`/`%aE`,
  `core.abbrev`, replace refs, grafts). `core.fsmonitor` stays the user's choice (ADR-0008).
- Reads set `GIT_OPTIONAL_LOCKS=0` (existing `CommandKind.read`), never write to `.git`, and never write
  a commit-graph file.
- All user strings are argv elements: revisions after `--end-of-options`, paths after `--`, search text
  as `--grep=<text>` / `--author=<text>` with `--fixed-strings` and `--regexp-ignore-case`.
- Repository-controlled text (subjects, ref names, bodies) is displayed as plain text; control characters
  become Unicode control pictures and bidi overrides are removed with the whole string isolated
  (`DisplayText.sanitize`).

## Consequences
- Signature status is not shown in Phase 2 (it would need gpg/ssh runs; a later explicit action).
- Adding a new read command means applying this policy; tests cover the history, details and compare paths.
