# ADR-0026: Canonical diff invocation and byte-exact patch model

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6, §7, §14, §16; ADR-0005, ADR-0013

## Context
Line-level staging and discard (P3.4) build patches from what the diff viewer shows. If the diff is
affected by user configuration (external diff, textconv, prefixes, colour, quoting), or if parsing
normalizes line endings or loses the "no newline" state, a patch built from it can stage the wrong bytes.

## Decision
- **One command line** (`DiffInvocation.arguments`): `-c core.quotepath=off -c diff.noprefix=false
  -c diff.mnemonicPrefix=false -c diff.relative=false -c color.ui=false -c diff.external=
  -c diff.suppressBlankEmpty=false --literal-pathspecs diff --no-color --no-ext-diff --no-textconv
  --full-index --binary --find-renames -U<n> --src-prefix=a/ --dst-prefix=b/ --submodule=short`, then the
  target (`--cached`, first parent or the empty tree for a root commit, a range, or commit → worktree),
  `--`, paths. A staged rename passes both paths so Git pairs them.
- **Untracked files** get a new-file patch synthesized from raw bytes in Git's exact format (mode from
  `lstat`, blob id from `hash-object --no-filters --stdin`, Git's quoting and its trailing tab for names
  with spaces). No `git add -N`. Checked byte-equal to Git's own `add -N` output.
- **Single-path diffs are read with the whole file as context.** Display context is a layout choice:
  long unchanged runs become gap rows, and expanding one makes a new document over the same buffer.
- **Parsing on bytes**: one buffer (Git's output) plus flat records. `LineRecord` is 16 bytes (text
  offset, 24-bit length, kind, CRLF flag, no-newline flag, old/new numbers); hunks and files are small
  structs; paths are C-unquoted. Nothing is normalized; display strings are made only for visible rows.
- **Layouts** are packed row tables: unified and full-file at 4 bytes per row, split at 8. Split pairs a
  run of deletions with the following run of additions.
- **Round trip**: `PatchStorage.serialize()` rebuilds the patch from the records (headers verbatim, each
  line from kind + text + ending + marker) and must equal Git's bytes for every fixture.
- **SnapshotToken** per working-tree path: HEAD id, index record, worktree fingerprint and blob id, repo
  revision. Taken before and after Git runs; if they differ the read repeats (three tries).

## Consequences
- Evidence: `DiffEngineTests` — CRLF and mixed endings, missing final newline (old/new/both), staged
  rename with edits, copy header, mode change, symlink, binary, submodule, empty file, Unicode / space /
  quote / backslash / newline / tab / leading-dash paths (content and mode-only), untracked synthesis vs
  `add -N`, split alignment, full-file rows equal pre- and post-image, gaps and expansion, search,
  commit and root-commit diffs, token, memory.
- Measured (debug build, M5 Pro): 100,000 changed lines → 28 B/line beyond Git's own output, about
  0.27 s to read, parse and lay out.
- Whole-file context makes single-file diffs larger than `-U3`; acceptable for files Jit renders
  (highlighting limits in ADR-0012 cap size). Multi-file commit diffs use `-U<n>` and cannot expand.
- Repository `diff.algorithm` and `diff.indentHeuristic` still apply (display only; patches stay valid).
