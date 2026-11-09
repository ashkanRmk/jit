# Phase 8 — Post-V1: design

> Status: **planned**. Phase 8 is not one linear phase. It is a set of independent **epics** that
> extend V1 (§9.2, §22 Phase 8). Each epic starts only after V1 has shipped (Phase 7 exit gate) and
> runs on its own branch `epic/<name>` with its own progress report. None of this may delay V1.

Requirements: §9.2 (preserved features), §16 (risk classes), §7.4–7.5 (safe patching), §8 (conflicts),
§10 (profiles), §13.5 (process safety), §19 (security). Architecture: [`../../roadmap.md`](../../roadmap.md) §5.

---

## 1. Goal & demo

Turn Jit from an excellent daily-workflow client into a complete power-user tool without giving up the
V1 properties: no data loss, no idle cost, native feel. Every epic must reuse the V1 building blocks
instead of adding parallel mechanisms:

| V1 building block | Built in | Reused by |
|---|---|---|
| Operation framework: risk classes, per-repo serialized writer, revision/snapshot tokens, confirmation sheets, progress, cancellation (ADR-0015) | P4 | every epic |
| Operation state machine (merge / rebase / cherry-pick / revert, continue / abort / skip) | P4 | interactive rebase, commit surgery, stash pop, patch `am`, branch history |
| Three-way conflict resolver with explicit ours/theirs labelling | P4 | interactive rebase, stash apply/pop, patch apply `--3way`, cherry-pick ranges |
| Patch builder + `git apply --check` validation (ADR-0013) | P3 | patches, stash of selected hunks |
| Native diff renderer + syntax highlighting (ADR-0011/0012) | P3 | stash viewer, patch preview, reflog commit view, submodule diffs |
| Graph renderer + lane layout + paginated history (ADR-0009/0010) | P2 | reflog "lost commit" view, filtered history, drag-to-rebase |
| Profile snapshot + per-invocation identity/credentials (ADR-0016) | P1/P5 | signing, tag push, LFS locks, submodule remotes |
| Bundled helper binary `jit-git-helper` (`JitGitHelper` Swift executable target, ADR-0016) | P5 | sequence/message editor subcommands for interactive rebase |

**Demo per epic:** each epic ends with a demonstrable workflow against real repositories, listed in the
epic's "Done when" in `implementation.md`.

## 2. Scope / out of scope

**In scope (epics):**

| ID | Epic | Branch | Suggested order |
|---|---|---|---|
| `stash` | Stash manager — **moved to Phase 4** (P4.15–P4.16) | — | — |
| `reflog` | Reflog explorer & recovery | `epic/reflog` | 2 |
| `reset` | Reset soft / mixed / keep / hard | `epic/reset` | 3 |
| `tags` | Create / delete / push lightweight & annotated tags | `epic/tags` | 4 |
| `rebase-interactive` | Interactive rebase editor | `epic/rebase-interactive` | 5 |
| `commit-surgery` | Drop, reorder/move, edit older messages, squash/fixup as direct graph actions | `epic/commit-surgery` | 6 |
| `history-filters` | Additional history filtering | `epic/history-filters` | 7 |
| `worktrees` | Worktree manager | `epic/worktrees` | 8 |
| `patches` | Create / apply / export patches, native sharing, Cloud Patch extension point | `epic/patches` | 9 |
| `remotes` | Advanced remote management | `epic/remotes` | 10 |
| `branch-history` | Advanced branch history manipulation (move pointer, `--onto`, squash branch, drag-to-rebase, force-with-lease) | `epic/branch-history` | 11 |
| `signing` | Commit/tag signing configuration and verification display | `epic/signing` | 12 |
| `submodules` | Submodule management | `epic/submodules` | 13 |
| `lfs` | Git LFS management | `epic/lfs` | 14 |

**Why this order.** Stash now ships in Phase 4, so every epic here (reset, rebase, checkout with dirty trees)
already has a safe "set my changes aside" path. Reflog first: a recovery surface must exist before Jit offers
history-rewriting tools. Reset and tags are small and high-value. Interactive rebase precedes commit
surgery because surgery is a thin UI over the same engine. Signing, submodules and LFS depend on
external tools and have the largest security surface, so they come last. The order is a
recommendation; dependencies (below, per epic) are hard constraints.

**Out of scope (everywhere, §9.3):** PR/MR management, code review, CI/CD dashboards, hosted
collaboration, AI assistant, IDE features. **Cloud Patch** gets an extension point only — no backend,
no network upload (§9.2).

## 3. User experience

Shared UX rules for every epic:

- **Entry points:** graph context menu, sidebar sections, the Repository/Branch/Git Operations menus,
  and the ⌘K command palette (built in P6). Every action appears only when valid for the selected
  object and repository state (§5.4).
- **Risk presentation (§16.3):** destructive actions use the P4 confirmation sheet: *what changes*,
  *what may be lost*, *recoverable?* (and how: reflog entry, stash SHA, "not recoverable"), *repository
  and branch*. Primary button names the action ("Reset main and discard 3 files"), never "OK".
- **Rewrite warning:** any action that rewrites commits already reachable from a remote-tracking ref
  shows a persistent inline banner: "N of these commits are on origin/main. Others may have them.
  Rewriting requires a force push." The action stays available but is never the default button.
- **States:** each new view defines empty, loading (skeleton rows, no spinner for < 150 ms), normal and
  error states; errors map to the §16.4 taxonomy with a recovery action.
- **Motion:** row insert/remove 120–160 ms, sheet/panel 160–220 ms, drag feedback 80–120 ms; disabled
  under Reduce Motion; no animation during bulk updates (reorder of > 50 rows applies instantly).
- **Themes:** new semantic tokens only (e.g. `stash.node`, `reflog.unreachable`, `rebase.action.drop`);
  each verified in light and dark with screenshots.
- **Glass vs content (ADR-0006):** new sheets, popovers, menus, the rebase preview panel and palette
  entries use the system Liquid Glass chrome (system components or the official glass APIs, grouped in
  a container). New lists and editors — stash rows, reflog entries, rebase todo rows, worktree/remote/
  submodule lists, patch previews — are content: opaque, token-colored, no glass per row. Drag feedback
  for reordering uses the system drag image and an opaque insertion marker, not a glass morph.
- **Accessibility:** every list keyboard navigable; reorderable lists support ⌥⌘↑/⌥⌘↓ as the
  keyboard equivalent of drag; VoiceOver announces action, position and risk.

### 3.1 Stash manager (`stash`) — moved to Phase 4

Moved to Phase 4 (§3.11 there, milestones P4.15–P4.16) at the owner's request (2026-11-09, P3.0 command bar).
Stashing selected hunks (via the patch builder) stays here, in the `patches` epic.

### 3.2 Reflog explorer & recovery (`reflog`)
- **View:** a workbench mode (⌘-mode switch or Repository ▸ Reflog) listing entries for a chosen ref
  (HEAD default; any local branch): action badge (commit, checkout, rebase, reset, merge, amend, pull),
  message, relative time, short SHA. Entries whose commit is unreachable from any ref get an
  "unreachable" marker.
- **Selecting an entry** shows the commit in the graph; if unreachable, the graph adds it as a temporary
  tip lane with a dashed edge style until the selection changes.
- **Recovery actions:** *Create branch here*, *Reset current branch here* (via `reset` epic, with its
  confirmation), *Cherry-pick*, *Copy SHA*, *Compare with current*.
- **Find lost commits:** explicit button running `git fsck --unreachable --no-reflogs` with progress and
  cancel (can be slow on large repos; never automatic). Results list dangling commits including dropped
  stashes ("looks like a stash" heuristic: two/three parents with `index on`/`WIP on` subject).
- **Undo last operation** (also the command bar's Undo/Redo, P3.0): offered only for operations Jit itself ran in this session and recorded
  (commit, amend, reset, rebase, merge, cherry-pick), presented as "Restore main to before ‹op›"
  through the reset confirmation sheet. Never a blind `reset --hard HEAD@{1}`.

### 3.3 Reset (`reset`)
- **Graph context menu:** "Reset ‹current branch› to here ▸ Soft / Mixed / Keep / Hard". Only on
  commits when HEAD is a branch or detached (label adapts).
- Each mode has a one-line plain-language explanation in the menu and sheet:
  Soft — "move branch, keep changes staged"; Mixed — "move branch, keep changes unstaged";
  Keep — "move branch, keep local changes, abort if they conflict" (`--keep`); Hard — "move branch and
  discard all uncommitted changes".
- **Hard reset sheet:** lists uncommitted files that will be lost (from status), commits that become
  unreachable (count + first 5 subjects), states "Commits recoverable via Reflog; uncommitted changes
  are not recoverable", and offers **Stash changes first** (default-on checkbox when `stash` exists).

### 3.4 Tags (`tags`)
- **Create tag** from commit context menu / sidebar "+": name field with live `check-ref-format`
  validation, *Annotated* toggle (message editor; tagger = active profile snapshot), *Sign* (when
  `signing` exists), *Push after creating* (to a chosen remote).
- **Tag rows** in sidebar: annotated vs lightweight icon, tagger/date/message popover, "Push", "Delete
  local", "Delete from ‹remote›" (destructive; affects others).
- Deleting a local tag shows its target SHA for recovery.

### 3.5 Interactive rebase (`rebase-interactive`)
- **Start:** context menu on a commit "Interactive rebase from here…" or Branch ▸ Interactive Rebase
  onto…. Opens a focused editor occupying the main content area.
- **Editor:** a list of commits oldest→newest (Git todo order, labelled clearly), each row: action
  picker (Pick, Reword, Edit, Squash, Fixup, Drop), short SHA, subject, author, mini diffstat. Drag or
  ⌥⌘↑/↓ to reorder; keyboard letters `p r e s f d` set actions (as in Git's todo). Dropped rows are
  struck through but remain visible until confirmed. Reword rows expand an inline message editor;
  squash rows show the combined message preview.
- **Preview panel:** resulting history as a small graph with the new commit count and a
  "conflicts likely" hint when reordering commits that touch the same files.
- **Run:** progress per step; on conflict the P4 resolver opens with labels "Ours = rebased history so
  far (onto ‹base›)" / "Theirs = commit being replayed ‹sha subject›"; on *Edit* stops, the WD panel
  shows "Stopped at ‹commit› for editing — amend, then Continue". Continue / Skip / Abort always visible
  in the operation bar.
- **Unsupported ranges** (contain merge commits, root commit when not supported, rewrites across
  submodule pointer conflicts) are disabled with an explanation, not attempted.

### 3.6 Commit surgery (`commit-surgery`)
Direct graph actions on the current branch's unpublished-or-confirmed history, each executing the
interactive-rebase engine with a generated todo and no editor:
- **Edit message…** (any commit on the current branch) → message sheet → reword.
- **Drop commit** → destructive sheet (recoverable via reflog).
- **Move up / Move down**, or drag a commit row within the branch lane → reorder.
- **Squash into parent / Fixup into…** (pick target).
- **Split commit** is deferred to a later iteration (needs edit-stop UX); listed as Planned.

### 3.7 Additional history filtering (`history-filters`)
- Filter bar extension (⌘F context): author/committer, date range, path(s) (drag files in), message
  regex, content search (`-S` / `-G`, with "may be slow" hint and cancel), first-parent, no-merges /
  merges-only, ancestry path between two selected commits, hide remote branches, simplify by
  decoration.
- Active filters appear as removable tokens; filter state persists per tab. The graph indicates filtered
  mode with a subtle header ("Filtered: 3 conditions · 1,204 commits") and edges that skip hidden
  commits use the dotted "simplified" style.

### 3.8 Worktree manager (`worktrees`)
- **Sidebar section "Worktrees"** (§4.3): path (abbreviated with `~`), branch or detached SHA, locked /
  prunable / dirty badges. The current worktree is marked.
- **Add worktree:** sheet with path chooser (NSSavePanel-style for a new folder), *New branch* /
  *Existing branch* / *Detached at commit*, open-in-new-tab toggle (default on).
- **Actions:** Open in new tab, Reveal in Finder, Open in Terminal, Lock/Unlock (with reason), Remove
  (destructive if dirty or has untracked files; list them), Prune stale entries.
- A branch checked out in another worktree shows a "checked out in ‹path›" badge; checkout of it is
  disabled with that explanation (Git refuses it).

### 3.9 Patches (`patches`)
- **Create:** from selected commits ("Export as patch series…" → `format-patch`), from the working tree
  or index ("Copy as patch", "Save as patch…"), from selected hunks/lines (reuses P3 selection).
  Destinations: Save panel, clipboard, **Share…** (`NSSharingServicePicker`: Mail, Messages, AirDrop).
- **Apply:** File ▸ Apply Patch… or drop a `.patch`/`.diff`/`.mbox` onto the window. Preview sheet:
  files affected, per-file check result from `git apply --check` (green/red with reason), target choice
  (*Working tree*, *Index*, *Both*), *Three-way fallback* toggle, or *Apply as commits* (`git am`) for
  mailbox series. Failures never partially apply silently (`git apply` is atomic by default; `--reject`
  is not offered).
- **Cloud Patch:** not built. The share menu's providers come from a `PatchSharingProvider` protocol
  with only local implementations.

### 3.10 Advanced remote management (`remotes`)
- **Remotes section** in sidebar/repository details: name, fetch URL, push URL (if different),
  protocol badge, last fetch time (from FETCH_HEAD mtime, no network).
- **Actions:** Add remote (URL validation, protocol detection, optional immediate fetch), Rename,
  Edit URLs (fetch/push separately), Remove (destructive: deletes remote-tracking refs; lists how many),
  Prune stale remote-tracking branches (preview list via `git remote prune --dry-run`), Fetch this
  remote, Tag fetching option.
- These write `.git/config` — allowed because the user explicitly requests them (§10.3); the sheet says
  "Changes this repository's configuration".

### 3.11 Advanced branch history manipulation (`branch-history`)
- **Drag a branch label onto a commit** in the graph → popover: *Merge into ‹current›*, *Rebase ‹branch›
  onto here*, *Move ‹branch› pointer here* (destructive if commits become unreachable), *Create branch
  here*.
- **Rebase range onto…** (`git rebase --onto <new> <upstream> <branch>`) from a two-commit selection.
- **Squash branch** into a single commit on top of its merge base (generated interactive todo).
- **Compare branches**: ahead/behind commit lists, patch-equivalent commits marked via `git cherry`.
- **Force push with lease:** the only force push Jit offers. Uses
  `--force-with-lease=<ref>:<expected-sha>` with the SHA Jit last observed, plus `--force-if-includes`
  where supported. Sheet shows remote, branch, commits that will be replaced on the remote.

### 3.12 Signing (`signing`)
- **Profile editor ▸ Signing:** off / GPG / SSH / X.509; key selector (GPG keys via `gpg --list-secret-keys
  --with-colons`, SSH public keys from `~/.ssh/*.pub` or agent), *Sign commits by default*, *Sign tags
  by default*. Stored as references on the profile (§10.1 "commit signing settings for later").
- **Commit composer:** a small signature indicator (seal icon + key short ID) when signing is on.
- **Commit details:** signature status (good / bad / unknown key / expired / none) — computed only on
  selection, never across the whole graph.
- **Failure UX:** missing `gpg`/pinentry, locked key, agent unavailable → actionable error, the commit
  is not created unsigned as a fallback.

### 3.13 Submodules (`submodules`)
- **WD panel:** submodule rows with state from porcelain v2 (`S<c><m><u>`): new commits, modified
  content, untracked content. Diff shows "Submodule ‹path›: a1b2c3 → d4e5f6" with the commit list
  between (if the submodule is initialized).
- **Sidebar section "Submodules":** path, recorded vs checked-out commit, initialized state.
- **Actions:** Initialize & update (explicit; recursive toggle), Update to recorded commit, Open as tab,
  Sync URLs, Add submodule (URL + path), Deinit (destructive if dirty).
- **Clone:** "Also clone submodules" toggle, default **off** with explanation (submodule URLs come from
  the repository and may point to other hosts/accounts).

### 3.14 Git LFS (`lfs`)
- **Detection:** repo uses LFS if `.gitattributes` contains `filter=lfs`; LFS available if a
  `git-lfs` executable is found (bundled or user-installed per ADR-0057).
- **Diff:** LFS pointer files render as an "LFS object" card (oid, size, whether downloaded) instead of
  pointer text; image preview when the object is local.
- **Actions:** Track pattern / Untrack (edits `.gitattributes` via `git lfs track`, shown as a normal WD
  change), Fetch/Pull LFS objects (progress, cancel), Prune, Locks list / Lock / Unlock (uses active
  profile credentials).
- **LFS missing:** banner "This repository uses Git LFS. Without it, large files appear as pointer
  text." with install/enable guidance; Jit never auto-downloads anything.

## 4. Technical design

### 4.1 Common extensions to the V1 core

**Operation kinds and risk classes (extends ADR-0015).** Each epic registers operation kinds in
`GitCore`'s operation registry with a fixed risk class:

| Class | New kinds |
|---|---|
| Read | `ReflogList`, `FsckUnreachable`, `StashList/Show`, `WorktreeList`, `RemoteList`, `TagList/Show`, `SignatureVerify`, `LfsStatus`, `SubmoduleStatus`, filtered history pages |
| Mutating | `StashPush`, `StashApply`, `StashPop`, `TagCreate`, `TagPush`, `ResetSoft/Mixed/Keep`, `InteractiveRebase`, `RebaseOnto`, `WorktreeAdd`, `WorktreeLock`, `PatchApply`, `PatchAm`, `RemoteAdd/Rename/SetUrl`, `SubmoduleUpdate/Init/Sync/Add`, `LfsTrack/Fetch/Lock` |
| Destructive | `StashDrop`, `StashClear`, `ResetHard`, `CommitDrop`, `BranchForceMove`, `ForcePushWithLease`, `TagDeleteLocal/Remote`, `WorktreeRemove/Prune`, `RemoteRemove`, `RemotePrune`, `SubmoduleDeinit`, `LfsPrune` |

Every mutating/destructive request carries the `RepoRevision` token it was prepared against (HEAD
OID + index checksum + refs generation from P4). The writer queue re-validates before running and
returns `StaleState` instead of executing on changed state.

**Operation state machine additions.** P4 detects merge, rebase (non-interactive), cherry-pick, revert.
Phase 8 adds: interactive rebase (`rebase-merge/interactive`), stopped-for-edit, `am` in progress
(`rebase-apply/applying`), multi-commit cherry-pick/revert sequences (`sequencer/todo`). Each state
exposes `continue`, `skip` (where Git supports it), `abort`, and a human summary ("Rebasing feature:
step 3 of 7, stopped for edit at a1b2c3").

**Recovery points (ADR-0050).** Before a rewrite or destructive op, the core records a
`RecoveryPoint { opID, refName, oldOID, newOID, reflogSelector, timestamp }` in the per-session
operation log (memory + the session JSON, bounded to the last 50). Recovery relies on Git's own reflog
and `ORIG_HEAD`; Jit does **not** write extra refs into the user's repository by default. An opt-in
setting "Keep backup refs under refs/jit/backup/" may be evaluated in the ADR.

**Rewrite safety (ADR-0052).** `publishedCommits(in range:) -> [ObjectID]` = the commits of the range minus
`git rev-list <range> --not --remotes` (the unpublished ones), one process per plan. Result drives the rewrite banner and the force-push-with-
lease requirement. Force push is only ever `--force-with-lease=<ref>:<sha>`; plain `--force` is never
emitted.

### 4.2 `GitCore` API sketch (illustrative Swift)

All of this lives in the Foundation-only `GitCore` module (ADR-0002); there is no bridge. Calls are
`async`, run off the main actor, spawn Git via `ProcessRunner`, honor Swift task cancellation
(`killpg` on the child's process group) and report progress through a bounded `AsyncStream` (ADR-0005).
Mutations go through the per-repository actor that serializes writes (P3/P4).

```swift
// GitCore — extensions on the per-repository actor; names illustrative.
extension Repository {
    // stash
    func stashList() async throws(GitError) -> [StashEntry]
    func stashPush(_ req: StashPushRequest, at rev: RepoRevision) async throws(GitError) -> OpOutcome
    func stashApply(index: Int, pop: Bool, at rev: RepoRevision) async throws(GitError) -> OpOutcome // .conflicts(..) possible
    func stashDrop(index: Int, expected: ObjectID, at rev: RepoRevision) async throws(GitError) -> RecoveryPoint

    // reflog / recovery
    func reflogPage(ref: String, cursor: String?, limit: Int) async throws(GitError) -> ReflogPage
    func findUnreachable(progress: ProgressSink) async throws(GitError) -> [DanglingCommit]

    // reset
    func resetPreview(to target: ObjectID, mode: ResetMode) async throws(GitError) -> ResetPreview // files lost, commits unreachable
    func reset(to target: ObjectID, mode: ResetMode, at rev: RepoRevision) async throws(GitError) -> RecoveryPoint

    // interactive rebase
    func rebasePlan(base: ObjectID, headRef: String) async throws(GitError) -> RebasePlan // commits + published flags + unsupported reasons
    func validate(_ plan: RebasePlan) async throws(GitError) -> [PlanIssue]
    func startRebase(_ plan: RebasePlan, identity: IdentitySnapshot, at rev: RepoRevision,
                     progress: ProgressSink) async throws(GitError) -> OpOutcome

    // patches
    func checkPatch(at url: URL, target: ApplyTarget, threeWay: Bool) async throws(GitError) -> PatchCheckReport
    func applyPatch(at url: URL, target: ApplyTarget, threeWay: Bool, at rev: RepoRevision) async throws(GitError) -> OpOutcome
    func formatPatch(_ commits: [ObjectID], into dir: URL) async throws(GitError) -> [URL]
}
```

Feature view models call these through `Services` (`RepositorySession`), which maps `GitError` to the
§16.4 taxonomy for presentation. `ProgressSink` is the bounded `AsyncStream` continuation type from
ADR-0005; `IdentitySnapshot`, `RepoRevision`, `OpOutcome` and `RecoveryPoint` are the P1/P4 value types.

### 4.3 Per-epic technical approach

**Stash.** Moved to Phase 4 §4.15.

**Reflog.** `git reflog show --format=%H%x00%gd%x00%gs%x00%ct -z <ref>` paged with `--skip`/`-n` (reflogs
are short; acceptable). The "unreachable" marker is computed on demand for the visible page only
(≤ 50 entries) with `git for-each-ref --count=1 --contains <oid>`; never for the whole reflog, never a
full `rev-list --all` walk. The spike in §7 measures this. Fsck runs as a cancellable `Read`
operation with process-group kill.

**Reset.** `git reset --soft|--mixed|--keep|--hard <oid>`; preview combines `status` (files lost) and
`git rev-list --count <HEAD> ^<target>` + `--max-count=5` subjects. "Stash first" chains `StashPush`
then `Reset` inside one serialized writer job, aborting the reset if the stash fails.

**Tags.** `git tag [-a -m <msg>] [-s|-u <key>] -- <name> <oid>` (message via `-F <tmpfile>` with 0600
permissions). Annotated tagger identity from the profile snapshot via `GIT_COMMITTER_NAME/EMAIL` env.
Push `git push <remote> refs/tags/<name>`; remote delete `git push <remote> --delete refs/tags/<name>`.

**Interactive rebase (ADR-0051).** Jit generates and validates the todo itself, then drives Git:
1. `rebasePlan` lists `git rev-list --reverse --parents <base>..<head>`; any merge commit → unsupported.
2. The editor UI edits the plan; `validate(_:)` checks: first non-drop action is not squash/fixup, all OIDs
   exist and belong to the range, no duplicates, messages non-empty for reword/squash.
3. Write the todo (Git's own syntax) and the per-step messages to a 0700 temp dir.
4. Run `git rebase -i [--update-refs] <base>` with `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` pointing to
   the bundled `jit-git-helper` (`jit-git-helper sequence-editor` / `jit-git-helper message-editor`,
   subcommands of the `JitGitHelper` Swift target); the helper
   receives the temp dir via an environment variable (no untrusted text in the command string), copies
   the prepared todo over Git's file, and supplies prepared messages in order for reword/squash.
   Alternative to evaluate in the spike: `pick` + `exec git commit --amend -F <file>` lines, or
   `fixup -C` / `amend!` semantics.
5. Progress from parsing `rebase-merge/msgnum` and `end` after each step (read on process events, no
   polling). Conflicts → P4 resolver; edit stops → WD panel state.
6. Identity: committer = profile snapshot (env), authors preserved (Git default).

**Commit surgery.** Pure plan generation over the same engine: `reword(oid, msg)`, `drop(oid)`,
`move(oid, after)`, `squash(oid, into)`. Single-commit reword at HEAD uses `commit --amend` (P3).

**History filters (ADR-0058).** Extends the P2 history reader with `HistoryFilter { authors, committers,
since, until, paths, grep, pickaxe: Pickaxe?, firstParent, merges: MergeFilter, ancestryPath:
(ObjectID, ObjectID)?, branches }` → mapped to `git log` arguments (`--author=`, `--since=`, `--grep=`
with `--regexp-ignore-case`/`-E`, `-S`/`-G`, `--first-parent`, `--no-merges`, `--ancestry-path`,
`--simplify-by-decoration`, `-- <paths>`). Graph edges use the parents Git reports with `--parents`
under history simplification so the filtered graph stays connected; lanes are recomputed per filter
(new layout cache key), never mutated in place. Filter values are passed as separate argv elements.

**Worktrees (ADR-0053).** `git worktree list --porcelain -z`; add/remove/lock/prune via `git worktree`.
A `RepositorySession` is keyed by worktree root; sessions sharing a `commondir` register in a
`CommonDirGroup` so a ref change detected by one session's FSEvents stream invalidates refs/graph caches
in sibling sessions (refs and objects are shared; index/HEAD are per worktree). Mutations remain
serialized per worktree; ref-writing operations additionally take a per-common-dir lock.

**Patches (ADR-0054).** Create: `git format-patch --stdout|-o <dir> <range>` (commits),
`git diff --binary [--cached]` (changes), P3 patch builder (selections). Apply: write incoming patch to
a 0600 temp file, `git apply --check [--cached|--index] [--3way] --verbose` → `PatchCheckReport`, then
the same command without `--check`. Mailbox series → `git am [--3way]` with AM state machine.
Share: `NSSharingServicePicker` with file URLs. Extension point:
`protocol PatchSharingProvider { var id: String; var displayName: String; func share(_ files: [URL]) async throws }`
with `SaveToFileProvider`, `ClipboardProvider`, `SystemShareProvider` only.

**Remotes.** `git remote -v` replaced by `git config --get-regexp -z '^remote\.'` parsing for exact
values; mutations via `git remote add|rename|set-url [--push]|remove`, prune via
`git remote prune [--dry-run] <name>`. URLs validated (scheme allowlist: https, ssh, git@ scp-form,
file only with an explicit confirmation); never accept URLs with embedded credentials — strip and warn.

**Branch history.** `git branch -f <name> <oid>` (destructive if `rev-list <old> ^<new>` non-empty),
`git rebase --onto <new> <upstream> <branch>`, squash = generated todo. Force-with-lease push via P4/P5
push path with lease SHA from the last observed remote-tracking ref.

**Signing (ADR-0055).** Per invocation: `-c commit.gpgsign=true -c tag.gpgSign=true -c gpg.format=<fmt>
-c user.signingkey=<ref> [-c gpg.program=<path>] [-c gpg.ssh.program=<path>]`. Key material is never
read or stored by Jit; only key references. SSH signing passphrases come from ssh-agent; GPG via
pinentry (GUI pinentry required — detect and explain if only curses pinentry is configured, since a
terminal prompt would hang). Verification: `git log -1 --format=%G?%x00%GS%x00%GK <oid>` on selection;
SSH verification needs `gpg.ssh.allowedSignersFile` — offer an app-managed allowed-signers file passed
per invocation, never written to global config.

**Submodules (ADR-0056).** Status from porcelain v2 submodule fields (P3 parser extension);
`git submodule status`, `update --init [--recursive]`, `sync`, `add`, `deinit`. Security: run with
`-c protocol.file.allow=user` (Git default since 2.38.1 — keep it), refuse submodule paths that escape
the worktree or traverse symlinks, require a minimum Git version with known submodule CVE fixes
(record exact version in ADR), never auto-recurse on clone/checkout. Submodule remotes on other hosts
use the active profile; mismatch → P5 mismatch handling.

**LFS (ADR-0057).** Decide bundling (git-lfs is MIT, Go binary, ~10 MB universal) vs detect-only. LFS is
the one named exception to §19's external-filter policy: when present and the repo opts in, Git runs the
`lfs` filter normally; when absent, Jit passes `-c filter.lfs.smudge= -c filter.lfs.process=
-c filter.lfs.required=false` only for read operations that would otherwise fail, and shows pointer files.
Locks: `git lfs locks --json`, `lock`, `unlock` with credentials from the P5 helper.

### 4.4 State ownership

- Per-repository: `StashStore`, `ReflogStore`, `WorktreeStore`, `RemoteStore`, `TagStore` — small
  `@Observable` models owned by `RepositorySession`, loaded lazily when their section/view is first shown,
  invalidated by FSEvents on `refs/stash`, `logs/`, `worktrees/`, `config`, `packed-refs`, `refs/tags`.
- Interactive rebase plan: owned by the editor view model; discarded on cancel; never persisted across
  launches (an in-progress Git rebase is re-detected from `.git` state instead).
- Signing preferences: on the profile (P5 `ProfileStore`); verification results cached per OID in a
  bounded LRU (≤ 500).

### 4.5 Concurrency, cancellation, performance

- All new reads go through the existing read pool (no new threads); fsck, LFS fetch, submodule update and
  `-S/-G` searches are cancellable and kill the process group.
- Nothing in Phase 8 runs in the background without a user action. No periodic fsck, no LFS prefetch,
  no remote polling, no signature verification of the whole graph.
- Lists (reflog, stash, worktrees, dangling commits) are virtualized; reflog is paged.
- Filtered history keeps the P2 page size and memory bound.

### 4.6 Security

- All new commands use argv arrays, `--` before paths/refs where Git accepts it, and the sanitized env.
- Temp files (todo, messages, patches) in a per-operation 0700 directory, removed on completion/abort.
- Helper invocation via `GIT_SEQUENCE_EDITOR`/`GIT_EDITOR` is a fixed, app-controlled path; any data goes
  through files/env, never interpolated into the command string.
- Incoming patches, submodule URLs, remote URLs and LFS endpoints are untrusted input.
- Hooks: rewrites run Git hooks as Git does (ADR-0014); the operation sheet notes "Repository hooks may
  run" when hooks exist.

## 5. Edge cases & failure modes

| Area | Case | Expected behavior |
|---|---|---|
| Stash | `stash@{n}` index shifted by an external stash | Drop/apply validates OID, returns `StaleState`, list refreshes. |
| Stash | Pop conflicts | Stash retained; resolver opens; message says the stash was kept. |
| Stash | Untracked file collides on apply | Git refuses; error explains which file and offers "Apply to a new branch" (`stash branch`). |
| Reset | Hard reset with untracked files | Untracked files are **not** removed by reset; sheet says so (no `clean` implied). |
| Reset | `--keep` aborts due to conflicting local changes | Clear error listing the files; nothing changed. |
| Rebase | Range contains a merge | Disabled with "contains merge commits; preserving merges is not supported yet". |
| Rebase | Commits already pushed | Rewrite banner; completing requires force-with-lease to publish. |
| Rebase | Hook rejects (`pre-rebase`) | Operation fails cleanly; hook output shown sanitized. |
| Rebase | App quits mid-rebase | On relaunch the state machine detects `rebase-merge`, shows Continue/Abort. |
| Rebase | Empty commit after reorder | Surface Git's prompt as "Keep empty / Skip" choice (`--empty` behavior decided in ADR-0051). |
| Rebase | `--update-refs` moves other branches | Plan preview lists other branches that will move. |
| Worktree | Path already exists / not empty | Validation error before running Git. |
| Worktree | Worktree folder deleted externally | Listed as prunable; Prune offered. |
| Worktree | Removing a dirty worktree | Destructive sheet lists files; `--force` only after confirmation. |
| Tags | Tag exists on remote with different target | Push rejected; explain; never force-push tags. |
| Patches | Patch does not apply | Per-file reasons from `--check --verbose`; nothing applied. |
| Patches | Binary patch without full index | Reject with explanation. |
| Remotes | URL with embedded token | Strip credentials, warn, store clean URL only. |
| Signing | Key locked / pinentry unavailable | Commit not created; actionable error; never fall back to unsigned silently. |
| Submodules | Submodule URL on another host / account | P5 mismatch handling; no silent fallback. |
| Submodules | Path traversal / symlinked submodule path | Refuse with security explanation. |
| LFS | git-lfs absent | Pointer files shown; banner; no auto-install. |
| Filters | Pickaxe on 100k commits | Cancellable with progress; partial results shown as they stream. |
| Reflog | Reflog disabled/expired (`core.logAllRefUpdates=false`) | Empty state explains; fsck path still available. |

## 6. ADRs to write

| ADR | Topic | Epic |
|---|---|---|
| 0050 | Recovery points: rely on reflog/ORIG_HEAD + session op log; optional backup refs under `refs/jit/` opt-in only | reflog / reset |
| 0051 | Interactive rebase driving mechanism (helper as sequence/message editor vs `exec` lines), empty-commit policy, `--update-refs` | rebase-interactive |
| 0052 | History rewrite safety: published-commit detection, force-with-lease only, `--force-if-includes` | rebase-interactive / branch-history |
| 0053 | Worktree session model: per-worktree sessions grouped by common dir, shared invalidation, ref-write lock | worktrees |
| 0054 | Patch sharing extension point (`PatchSharingProvider`), no Cloud Patch backend | patches |
| 0055 | Commit/tag signing integration and verification scope | signing |
| 0056 | Submodule security and update policy, minimum Git version | submodules |
| 0057 | Git LFS: bundle vs detect, filter policy exception | lfs |
| 0058 | Filtered history graph semantics (parent rewriting, layout cache keys) | history-filters |

The helper binary gaining editor subcommands amends ADR-0016 (note it there).

## 7. Open questions / spikes

| Question | Spike | Decision criteria |
|---|---|---|
| Helper-as-editor vs `exec` lines for reword/squash messages | Implement both for reword on a 50-commit fixture | Correct messages on every step, no shell interpretation of user text, survives conflicts/continue, simplest code. |
| `--update-refs` default on? | Stacked-branch fixture | Matches user expectation shown in preview; requires Git ≥ 2.38 (check bundled version). |
| Reachability check cost for "unreachable" reflog markers and published-commit detection | Benchmark on 100k-commit repo with 500 remote refs | < 100 ms for a visible page / a 50-commit plan. |
| Bundle git-lfs or detect only | Size, signing, notarization, update cadence | Adds < 15 MB, signs/notarizes cleanly, security updates manageable — else detect-only. |
| Show stashes in the graph by default? | Design review with screenshots | Adds information without clutter in compact density. |
| Backup refs (`refs/jit/backup/*`) | Discuss in ADR-0050 | Only if reflog-based recovery proves insufficient in testing; always opt-in, visible, prunable. |
| Merge-preserving interactive rebase (`--rebase-merges`) | Later iteration | Only after linear editor is stable and resolver handles merge replays. |
