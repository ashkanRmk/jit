# Phase 8 — Reset previews, keep mode and stash-first recovery

Status: merged to main for 0.0.8 (2026-11-18).
Branch: `codex/reset-preview-recovery`, based on clean main `4204448` (0.0.7 released).
Milestones: P8.reset.1 and P8.reset.2. Decision: [ADR-0061](../../adr/0061-reset-preview-and-stash-recovery.md).

## Implemented

- Replaced the string-mode reset API with typed soft/mixed/keep/hard modes and a preview-bound
  confirmation token. Preview shows local loss paths, removed/unreachable/published commit counts,
  five unreachable subjects and the previous HEAD. Other branches/tags/stashes retain reachability.
- Revalidate repository root, refs, HEAD/operation state, logical index/flags, raw status and changed file contents
  inside the existing writer. Descriptor-relative file reads do not follow symlinks; buffers are bounded.
- Hard/keep refuse untracked, ignored and directory obstructions, and hidden index flags. In-progress
  operations/conflicts/unborn HEAD are refused. Reset never recurses into submodules, even when configured.
- Dirty hard resets default to stash-first, including untracked files and the active profile identity.
  Dirty submodules/nested repositories/special files cannot use this chain. Submodule changes remain
  visible despite ignore config and are excluded from the discard list.
- Stash/reset share one writer job. Cancellation before execution changes nothing; once started the
  chain finishes without caller interruption. Stash failure prevents reset. A later failure preserves
  and reports the exact stash SHA; unexpected post-stash state prevents reset.
- Graph and Reflog menus offer all four modes. Sheets support loading/error/retry, blocked confirmation,
  default Cancel, hard-reset arming delay, identity guidance, published-history warning and bounded lists.
  Outcomes expose previous HEAD, saved stash and recovery guidance through the existing operation UI.

## Verification

- Full serial package suite: **897 tests reported, 21 enterprise-rig skips, zero failures**
  (GitCore 443; Features 195; Services 244 including skips; DesignSystem 15). After the final submodule
  guard, repository binding and opaque snapshots, the focused reset suites passed again: **19 core tests and 4 feature/
  snapshot tests**, including parameterized cases and all ten images, on bundled **Git 2.56.0**.
- Real repositories verify all modes, conflicting keep reset, shared/remote reachability, detached HEAD,
  SHA-256, stale refs/index/file bytes/new untracked paths, exact token/repository binding, hidden flags,
  ignored/untracked/directory obstructions, dirty submodules/nested repos, rename/newline/binary/symlink
  preservation, stash identity, exact staged/worktree/untracked stash parents, controlled failures,
  cancellation and writer serialization. Recovery with `stash apply --index` restores the exact original
  index and working tree.
- Debug app built; final app test bundle: **25 passed, zero failures/skips**. Xcode result:
  `Test-Jit-2026.11.18_10-48-50-+0330.xcresult` (local DerivedData; verified summary).
- Ten light/dark/opaque snapshot references reviewed; two subsequent verification runs passed.
  [Screenshot index](screenshots/reset/README.md). Final lint and `git diff --check` passed.
- Native QA used a separately identified debug app with isolated `JIT_APP_SUPPORT`, a disposable repo
  and a synthetic profile. Graph → Hard showed the tracked path, lost commit and checked stash option.
  Return canceled without changing HEAD/index/worktree. Toggling stash updated the destructive warning.
  Stash and Hard Reset succeeded; the success message showed both full recovery SHAs. Reflog → Create
  Branch Here (switch enabled) recovered the old commit, and Stashes → Apply restored working and
  untracked files. CLI assertions verified main at target, recovered branch at previous HEAD, both file
  contents and the original staged content still in the stash's index parent. Existing Apply uses Git's
  default apply semantics; exact staging restoration via `--index` is covered by the core test.

## Performance

Release `JitBench reset-preview <fixture> <out>` is read-only: three warm-ups, 15 measured reads.
100,000-commit fixture, 252 refs, 97 tracked files, no dirty files; target `HEAD~5` removes 26 commits
in its merge history. Apple Git 2.54.0, Mac17,9, macOS 27.2.1. No explicit reset-preview timing budget
is specified; all work remains cancellable and off the UI executor.

| Metric | Median | p90 | Maximum | Evidence |
|---|---:|---:|---:|---|
| Complete hard-reset preview, including double state/content validation | 82.67 ms | 85.76 ms | 89.95 ms | [raw JSON](benchmarks/reset-preview.json) |

## Limits and next work

- Serialization covers Jit writers, not independent external processes; this is not an atomic filesystem
  transaction. The stash remains recoverable on subsequent failure. Git pruning can remove old objects.
- Content hashing scales with dirty file sizes; tree obstruction checks scale with target paths. Large
  dirty trees were not benchmarked. Read outputs and changed-path counts have explicit bounds.
- Hard/keep with hidden index flags and stash-first on dirty submodules/nested repos/special files require
  separate handling. Ordinary untracked files remain unless the user explicitly saves them in the stash.
- No new XCUITest target, live VoiceOver audit, enterprise rig, clean VM or global idle benchmark run.
- Included in 0.0.8. Next planned feature: remaining tag management, then interactive rebase.

## 0.0.8 release verification

The feature was fast-forward merged into main. The release check covered 900 package tests: 21
enterprise-rig skips, 878 passes and one existing process-runner thread-count failure in the full run.
All 17 ProcessRunnerTests passed on an isolated rerun (threads 6 → 30, limit below +32; the full run
measured 5 → 46). No assertion or production code was changed. All 19 reset tests and the ten snapshot
cases passed in the full run.
Release-version app tests: 25 passed; lint and diff checks passed. Xcode result: `Test-Jit-2026.11.18_11-07-41-+0330.xcresult`.
