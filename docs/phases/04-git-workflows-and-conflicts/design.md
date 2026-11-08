# Phase 4 — Everyday Git workflows & conflicts: design

Requirements: §8 (conflict resolution), §9.1 (V1 operations), §13.5 (process safety), §14 (state and
races), §16 (risk classes, confirmations, error handling). Roadmap: ADR-0015, invariants §6.

## 1. Goal & demo

Make Jit usable for a full day of normal work: sync with remotes, manage branches, integrate work
(merge, rebase, cherry-pick, revert), and resolve conflicts in a native three-way editor — with every
operation classified by risk, serialized per repository, cancellable where safe, and explained when it
fails.

**Demo at the end of the phase**

1. Clone a public HTTPS repository with progress, cancel one clone midway (partial directory removed),
   clone again successfully, and it opens in a new tab.
2. In a repo with a local bare remote: fetch, see ahead/behind update, pull (fast-forward only), make a
   commit, push. Push from a second clone to provoke a rejection; the rejection sheet explains it and
   offers pull / pull with rebase / force-with-lease (destructive confirmation).
3. Create, switch, rename and delete branches from the navigator and graph context menus; switching with
   a conflicting dirty tree shows exactly which files block the switch.
4. Merge a branch that conflicts → persistent "Merging" banner → open the resolver, take ours for one
   block, theirs for another, edit a third by hand, save, mark resolved, continue → merge commit created
   with the active profile's identity.
5. Rebase a branch with a conflict; resolver labels say which side is the upstream and which is "your
   commit abc1234 …"; skip one commit (destructive confirmation), abort another rebase and show that
   refs, index and working tree are byte-identical to before.
6. Copy a GitHub/GitLab web link for a commit.

## 2. Scope

**In scope**
- `OperationCenter`: lifting the Phase 3 per-repo mutation queue into an app-wide operation framework.
- Operation status UI, recent-operation history, destructive confirmation sheet, error presentation.
- Fetch, pull, push, ahead/behind refresh, remotes inspector (read-only), clone from URL.
- Branch create / switch / detach / rename / delete local / delete remote / create tracking / set upstream.
- Merge, non-interactive rebase onto a target, cherry-pick, revert.
- Repository operation-state detection and banner with continue / skip / abort.
- Conflict model and the visual three-way resolver, plus fallbacks for non-text conflicts.
- Enabling the write actions deferred from Phase 2 (navigator checkout, graph context menu).
- Copy remote commit/branch link for github.com and gitlab.com remotes.

**Out of scope (and where it lives)**
- Stored credentials, PAT/OAuth, SSH key selection, passphrase prompts, unknown-host-key acceptance,
  custom CA, proxy → **Phase 5** (plugs into the `AuthPlan`/`NetworkPlan` hook defined here).
- Provider repository browser and credentialed clone → **Phase 5**.
- Web links for self-managed GitLab hosts → **Phase 5** (needs server configs).
- Interactive rebase, reset modes, stash (including "stash and switch"), drop/reorder commits, reflog
  explorer, tag creation, remote add/edit/remove, submodule conflict resolution → **Phase 8**.
- Command palette entries for these operations → **Phase 6** (menus and context menus ship here).

## 3. User experience

### 3.1 Operation activity (toolbar item + popover)

- **Interaction:** a compact activity item on the right side of the toolbar, next to the profile pill.
  Idle: invisible (no reserved empty chrome) or a quiet clock-arrow glyph if recent history exists.
  Running: small determinate ring when progress is known, indeterminate otherwise, plus a one-line label
  ("Fetching origin — 42%"). Click → popover listing the current and last 20 operations of this
  repository: icon, title, target, duration, outcome; failed rows expand to the explained error and a
  sanitized technical detail disclosure; running rows show a Cancel button when cancellation is safe.
- **Hierarchy:** the label is secondary text; only failures use the semantic danger color; success uses a
  brief checkmark that fades (≈160 ms in, 900 ms hold, 200 ms out — no repeating animation).
- **States:** empty (popover says "No operations yet in this session"), running, succeeded, failed,
  cancelled, "needs your attention" (stopped with conflicts → links to the banner).
- **Keyboard / a11y:** popover reachable via the Repository menu ("Show Activity", ⌥⌘A suggested);
  progress exposed as an accessibility value; failures announced with an accessibility notification.
- History is in memory per repository session, bounded (20), never persisted.

### 3.2 Destructive confirmation sheet (shared component)

Used by discard (Phase 3 retrofitted), delete branch, force-unmerged delete, delete remote branch,
force-with-lease push, rebase/cherry-pick skip, abort with recorded resolutions.

Layout (sheet, 440–520 pt wide):
1. **Title naming the action and object:** "Delete branch `feature/login`?" — never "Are you sure?".
2. **Context line:** repository name · current branch (SF Mono for refs and SHAs).
3. **What will change:** one or two plain sentences.
4. **What may be lost:** bullet list with counts ("2 commits not merged into `main`: a1b2c3d Fix …").
5. **Recoverability:** "Recoverable via reflog: tip was `a1b2c3d` (copy)" or "Not recoverable from Jit."
6. **Buttons:** Cancel (default, Escape) and a destructive button whose label repeats the verb
   ("Delete Branch"). Return does not trigger the destructive button. For the highest-risk actions
   (force push, delete remote branch) the destructive button is enabled only after a 600 ms delay — no
   type-to-confirm.

### 3.3 Repository operation banner

Shown above the graph/workbench while the repository is in a merge, rebase, cherry-pick, revert, am or
bisect state, regardless of who started it (Jit or the terminal).

- "Merging `feature/x` into `main` · 3 conflicted files" — [Resolve Next] [Continue] [Abort…]
- "Rebasing `feature` onto `main` · commit 2 of 5: `abc1234` Fix login" — [Resolve Next] [Continue]
  [Skip Commit…] [Abort…]
- "Cherry-picking `abc1234` …" / "Reverting `abc1234` …" — [Continue] [Skip…] [Abort…]
- am / bisect in progress → informational banner: "A `git am` / `git bisect` session is in progress.
  Finish it in Terminal." [Open in Terminal]. Jit does not drive these in V1.
- **Continue** is disabled with a tooltip while unmerged paths remain. Banner tint uses the semantic
  warning surface (subtle, not saturated); appears with a 180 ms height transition (none with Reduce
  Motion).

### 3.4 Remote operations

- **Toolbar:** Fetch, Pull (split button: Pull — fast-forward only (default) / Pull with merge / Pull with
  rebase), Push. Ahead/behind badges (↑2 ↓5) next to the branch name in the toolbar and in the navigator.
- **Fetch menu:** Fetch current remote, Fetch all remotes, "Prune deleted remote branches" toggle — its
  initial value mirrors the repository's effective `fetch.prune`; Jit passes `--prune`/`--no-prune`
  explicitly so the UI never lies about what happened.
- **Pull** is always `fetch` + an explicit integration step (§4.6). If fast-forward is impossible the
  outcome sheet says so and offers merge or rebase; nothing integrates implicitly.
- **Push:** no upstream → "Publish branch" sheet (remote picker, remote branch name prefilled, "Track
  this remote branch" checked). Rejected push → explanation sheet by cause (§5); for non-fast-forward:
  Pull (ff-only), Pull with rebase, Force Push with Lease… (destructive sheet showing the expected remote
  SHA and the commits that would be overwritten on the remote).
- **Plain `--force` is never offered.** Force push is `--force-with-lease=<ref>:<expected-oid>` with
  `--force-if-includes`, only from the rejection sheet or the branch context menu, always via the
  destructive sheet.
- **Remotes inspector** (Repository ▸ Remotes…): table of remotes with fetch/push URLs (credentials in
  URLs masked and flagged with a warning), tracking branches, last-fetched time if known. Read-only in V1.
- **Auth failures in this phase** show an honest message: "This remote needs credentials. Account and SSH
  key setup arrives with profiles & accounts." (wording updated when Phase 5 lands). No prompts.

### 3.5 Clone from URL (new-tab page entry + File ▸ Clone…, ⇧⌘N suggested)

- Sheet: URL field (validated live: https://, ssh://, scp-style `git@host:path`, local path/file://),
  destination parent folder (remembered), folder name (derived from URL, editable, conflict-checked).
- Progress view inside the sheet: phase label (Counting / Compressing / Receiving / Resolving deltas /
  Checking out), determinate bar, transfer rate, Cancel. On success the repo opens in a new tab and the
  sheet dismisses; on failure the explained error stays in the sheet with Retry.
- No `--recurse-submodules` in V1 (submodule support is Phase 8); a post-clone note appears if
  `.gitmodules` exists.

### 3.6 Branch operations

Entry points: navigator context menu, graph commit/ref context menu, Branch menu.

| Action | UI | Behavior |
|---|---|---|
| New branch here… | sheet: name (live `check-ref-format` validation), start point (prefilled), "Switch to it" ✓ | `git branch` / `git switch -c` |
| Switch / checkout | double-click local branch, menu | `git switch <b>`; dirty-tree conflict → "Can't switch: these files have changes that would be overwritten" list + [Cancel] [Discard These Changes…] (destructive). "Stash and switch" is Phase 8. |
| Check out remote branch | double-click `origin/x` | if no local `x`: create tracking branch `x` and switch; if local exists: switch to it and show ahead/behind |
| Check out commit (detached) | graph menu | explanation sheet once per session about detached HEAD, then `git switch --detach <sha>` |
| Rename… | inline edit in navigator or sheet | `git branch -m`; upstream config follows (Git's behavior); remote not renamed (stated) |
| Delete… | destructive sheet | `git branch -d`; if Git reports unmerged → second destructive sheet with unmerged commit list and tip SHA → `-D` |
| Delete remote branch… | destructive sheet (high-risk delay) | `git push <remote> --delete <branch>` |
| Set upstream… / Unset upstream | sheet with remote branch picker | `git branch --set-upstream-to` / `--unset-upstream` |

### 3.7 Merge, rebase, cherry-pick, revert

- **Merge `X` into `current`…** sheet: strategy (Fast-forward when possible (default) / Always create a
  merge commit / Fast-forward only), optional message, identity line ("Commits as Ada Lovelace
  <ada@…> · Personal profile"). Preflight warnings: uncommitted changes present ("Abort may not restore
  them exactly — commit first?"), no active profile (blocking, with "Choose Profile…").
- **Rebase `current` onto `X`…** sheet: shows the N commits that will be replayed, warns when any of them
  exist on the upstream ("This rewrites commits already pushed; a later push will need force-with-lease").
  Requires a clean working tree (Git's rule; Jit does not autostash).
- **Cherry-pick** (one or more selected commits, applied oldest→newest) and **Revert** (single commit):
  merge commits require a mainline choice (sheet listing parents with subjects; default parent 1).
- All four show the identity line; outcome is success, "stopped with conflicts" (banner), or an
  explained error.

### 3.8 Conflict resolver

Opens in the workbench (focused mode by default — §4.5 of the master prompt requires a non-narrow view)
from the banner, the conflicted-files group in the working-directory panel, or ⌘↩ on a conflicted file.

**Layout**
```
┌ header: path · conflict kind · "Merging feature/x into main" · block 2 of 5 · [◀ ▶] ┐
│ ┌ OURS — Current branch main (ours) ┐ ┌ THEIRS — Incoming feature/x (theirs) ┐   │
│ │ read-only, highlighted block       │ │ read-only, highlighted block         │   │
│ └────────────────────────────────────┘ └──────────────────────────────────────┘   │
│ ┌ RESULT — editable ─────────────────────────────────────────────────────────┐   │
│ │ resolved text … [unresolved block: Take Ours | Take Theirs | Both ▾ | Edit] │   │
│ └─────────────────────────────────────────────────────────────────────────────┘   │
│ footer: "2 unresolved blocks" · [Show Base] · [Save] · [Mark as Resolved]          │
└───────────────────────────────────────────────────────────────────────────────────┘
```
- Panes reuse the Phase 3 native text renderer (syntax highlighting, line numbers, search). Ours/theirs
  scroll-sync to the current block. Optional base pane toggles in as a third column above the result.
- **Block actions:** Take Ours, Take Theirs, Both (Ours then Theirs / Theirs then Ours), Edit Manually
  (turns the block into editable text; marked resolved only after the user edits or explicitly
  confirms). Each action is undoable (⌘Z) and animates the block background from conflict tint to
  resolved tint (140 ms).
- **Navigation:** ⌥⌘↓ / ⌥⌘↑ next/previous unresolved block; ⌘S save; ⇧⌘R mark resolved (suggested).
- **Labels (never "local/remote"):**

| Operation | Ours label | Theirs label |
|---|---|---|
| merge | Current branch `main` (ours) | Incoming `feature/x` (theirs) |
| rebase | Upstream being rebased onto: `main` + already-replayed commits (ours) | Your commit `abc1234` "Fix login" (theirs) |
| cherry-pick | Current branch `main` (ours) | Picked commit `abc1234` "…" (theirs) |
| revert | Current branch `main` (ours) | Reverse of `abc1234` "…" (theirs) |

  A one-line info strip under the header explains the rebase inversion the first time per session.
- **Save** writes the result file atomically after a staleness check. **Mark as Resolved** stages the
  saved result (`git add`) — only on explicit click, only when no unresolved blocks remain; if lines that
  look like conflict markers remain, a confirmation explains and asks.
- **States:** loading (skeleton of the three panes), normal, "file changed outside Jit" (banner with
  Reload from Disk / Keep My Result — saving still blocked until resolved), error, all-resolved (footer
  turns calm, Mark as Resolved becomes primary).
- **Fallback views** (no text panes): modify/delete, delete/modify, binary, symlink, submodule,
  non-UTF-8 or oversized text (§3.9 below).

### 3.9 Non-text conflict fallbacks

| Kind | Choices offered | Git effect on confirm |
|---|---|---|
| Modified by one side, deleted by the other | Keep the modified file (shows which side) / Delete the file | `git add -- p` / `git rm -- p` |
| Both added (add/add), text | normal resolver with empty base | as text |
| Binary (any kind) | Use ours / Use theirs (size + type shown, Quick Look preview where possible) | `git checkout --ours|--theirs -- p` then `git add -- p` |
| Symlink | Use ours / Use theirs (targets shown) | same as binary |
| Submodule | Explanation + "Resolve in Terminal" | none (Phase 8) |
| Rename/rename, rename/delete | Presented per resulting path with the paths Git reports; text paths use the resolver | as text / as above |
| Non-UTF-8 or > configured size limit | Use ours / Use theirs / Open in external editor | as binary |

Every fallback choice goes through a confirmation describing the effect on the index and working tree.

### 3.10 Copy remote link

Commit context menu "Copy Link to Commit on GitHub/GitLab", branch context menu "Copy Link to Branch".
Shown only when the commit's remote (upstream's remote, else `origin`) maps to a known web host
(github.com, gitlab.com in this phase). Never fetches anything.

## 4. Technical design

### 4.1 Components

| Layer | Component | Responsibility |
|---|---|---|
| Swift `Services` | `OperationCenter` (app-wide, `@MainActor` facade) | Enqueue requests per repository, capture the profile snapshot at enqueue, hold lifecycle state for UI, route cancellation, keep bounded history. |
| Swift `Services` | `RepositoryOperationState` observer | Exposes the banner model; refreshed by FSEvents invalidation of `.git` state files and after each operation. |
| Swift `Features` | `OperationActivity`, `ConfirmationSheet`, `RemoteSync`, `BranchActions`, `CloneSheet`, `IntegrationSheets`, `ConflictResolver` | UI. |
| Rust `git-core` | `ops::` (`fetch`, `pull`, `push`, `clone`, `branch`, `merge`, `rebase`, `cherry_pick`, `revert`) | Build argv, run through `ProcessRunner`, parse outcomes. |
| Rust `git-core` | `exec::ExecContext`, `exec::env` | Non-interactive environment, identity env, `-c` overrides, protocol policy, hook point for auth/network. |
| Rust `git-core` | `progress::` | Parse `--progress` stderr (CR-separated) into typed phases. |
| Rust `git-core` | `state::` | Detect operation state from `git rev-parse --git-path` resolved files. |
| Rust `git-core` | `conflict::` | Conflict entries, conflict documents, resolution writes. |
| Rust `git-core` | `errors::classify` | Map exit status + C-locale stderr to `GitError` variants. |
| Rust `git-core` | `weblink::` | Remote URL → web URL mapping. |

### 4.2 OperationCenter and serialization (ADR-0015)

- **Authoritative serialization lives in Rust.** Each `RepoHandle` holds a writer lock; every mutating
  call takes it; read calls do not. Even a Swift bug cannot run two mutations on one repository
  concurrently. (If Phase 3 put the queue in Swift, keep the Swift queue for ordering/UI and add the Rust
  lock; record in ADR-0015.)
- **Swift ordering:** `OperationCenter` keeps one FIFO per repository for mutating/destructive requests,
  executed on a background executor; reads bypass the FIFO. A queued request shows as "Waiting for
  'Fetch origin'…".
- **Risk classes** (enum carried on every request): `read`, `mutating`, `destructive`. Destructive
  requests can only be constructed from a confirmed `ConfirmationToken` produced by the sheet — a type
  check, not a convention.
- **Revision tokens:** `RepoRevision { head: Oid|Unborn, head_ref, refs_digest, index_stamp,
  op_state }` captured when a sheet is prepared; the Rust call re-reads and fails with
  `GitError::StaleSnapshot` if it changed (e.g. the user committed in Terminal while the delete sheet was
  open). `refs_digest` = hash of `for-each-ref` output limited to refs the operation touches.
- **Lifecycle:** `queued → running(progress?) → succeeded(outcome) | failed(error) | cancelled |
  stopped(conflicts)`. Terminal states release all resources (process handles, buffers) immediately.
- **Profile snapshot:** captured at enqueue (`ProfileSnapshot` = identity + Phase 5 auth/network plan),
  immutable, passed into the Rust call. Switching profiles never touches queued or running operations.
- **Post-operation invalidation:** each outcome lists what changed (`refs`, `head`, `index`,
  `worktree_paths`, `op_state`) → targeted refresh of navigator, graph head pages, status and banner. No
  full reload.

### 4.3 Execution context and the Phase 5 hook point

```rust
#[derive(uniffi::Record)]
pub struct ExecContext {
    pub identity: Option<IdentitySnapshot>,   // author/committer for commit-creating ops
    pub auth: AuthPlan,                        // Phase 4: always NonInteractive
    pub network: NetworkPlan,                  // Phase 4: Default
}

#[derive(uniffi::Enum)]
pub enum AuthPlan { NonInteractive }          // Phase 5 adds Https{..}, Ssh{..}
#[derive(uniffi::Enum)]
pub enum NetworkPlan { Default }              // Phase 5 adds scoped CA / proxy
```

Every Git invocation that may touch the network goes through `exec::remote_command(ctx, …)`, which
applies, in order:
1. Base env from `ProcessRunner` (Phase 0): sanitized environment, `LC_ALL=C`, `LANGUAGE=` cleared (stable
   stderr for classification; user-facing text is Jit's own), `GIT_TERMINAL_PROMPT=0`,
   `GIT_EDITOR=true`, `GIT_SEQUENCE_EDITOR=true`, `GIT_MERGE_AUTOEDIT=no`, `GCM_INTERACTIVE=never`.
2. Phase 4 non-interactive auth: `GIT_ASKPASS` and `SSH_ASKPASS` point to a path that exits non-zero
   (`/usr/bin/false`), `SSH_ASKPASS_REQUIRE=never`, and
   `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"` (fixed literal, no
   interpolation). ssh-agent keys and public HTTPS work; everything else fails fast and is classified.
3. Protocol policy: `-c protocol.ext.allow=never -c protocol.fd.allow=never`; `GIT_PROTOCOL_FROM_USER=0`
   for submodule-ish indirections; `-c core.hooksPath` is **not** overridden (hooks policy ADR-0014).
4. Identity (commit-creating ops: merge, cherry-pick, revert, rebase, pull-with-merge/rebase):
   `GIT_COMMITTER_NAME/EMAIL` from the snapshot; `GIT_AUTHOR_*` only for new commits (merge commits,
   reverts) — cherry-pick and rebase preserve original authors, as Git does. No profile → the request is
   rejected before running with `GitError::NoActiveProfile`.

Phase 5 replaces step 2 per `AuthPlan` and adds `NetworkPlan` handling; no call site changes.

Process groups: each child runs in its own process group; cancellation sends `SIGTERM` to the group,
then `SIGKILL` after a 2 s grace. Git's own signal handlers clean lockfiles and partial clones on
`SIGTERM`.

### 4.4 Cancellation semantics

| Operation | Cancellable? | On cancel |
|---|---|---|
| fetch | yes, any time | refs updated atomically at the end by Git; Jit re-reads refs and reports "Fetch cancelled — no refs changed" or what changed |
| clone | yes | Git removes its partial directory on SIGTERM; Jit verifies, and removes the destination only if Jit created it (marker recorded before start) |
| push | yes, with warning | remote refs may already be updated; Jit runs `ls-remote` for the pushed ref and reports the actual result |
| pull | during fetch phase only | after fetch completes the integration step is not cancellable; stops → banner |
| merge / rebase / cherry-pick / revert | no (local, short) | button hidden; a stop with conflicts → banner with Abort |
| switch / branch ops / mark resolved | no | — |

### 4.5 Progress

Pass `--progress` (stderr is not a TTY). Parser splits stderr on `\r` and `\n`, recognizes
`<phase>: <pct>% (<n>/<total>)[, <size> | <rate>]` for Counting/Compressing/Receiving/Resolving deltas/
Updating files/Writing objects, and `remote: ` prefixed lines (kept as messages, sanitized). Emitted to
Swift via the Phase 0 progress callback, throttled to ≤ 10 updates/s, coalesced on the Swift side into
one observable property.

### 4.6 Remote operations

- **Fetch:** `git fetch --progress [--prune|--no-prune] <remote>` or `--all`. Tags follow Git defaults.
- **Pull (explicit two-step):** `fetch` the upstream's remote, then one of
  `git merge --ff-only @{upstream}` (default), `git merge --no-edit @{upstream}`, or
  `git rebase --no-autostash --no-update-refs @{upstream}`. `pull.rebase`/`pull.ff` configs do not
  silently change the chosen action; outcomes: `UpToDate`, `FastForwarded{from,to}`, `Merged{commit}`,
  `Rebased{count}`, `NotFastForward` (offer choices), `StoppedWithConflicts`.
- **Push:** `git push --progress --porcelain <remote> <local>:<remote_ref>` (+ `-u` when publishing).
  `--porcelain` output gives per-ref status (`=`, `*`, `+`, `-`, `!`) for precise rejection reasons:
  non-fast-forward / fetch-first, stale info (lease failed), remote hook declined (protected branch —
  show the `remote:` lines), atomic failure.
- **Force with lease:** `--force-with-lease=<remote_ref>:<expected_oid> --force-if-includes`, where
  `expected_oid` is the remote-tracking value shown in the destructive sheet.
- **Ahead/behind:** `git for-each-ref --format=%(refname)%00%(upstream)%00%(upstream:track,nobracket)`
  after any ref change; no network.
- **Clone:** `git clone --progress -- <url> <dest>`; URL must not begin with `-`; scheme allowlist
  `https`, `ssh`, scp-style, `git`, local path/`file` (with explicit note); `http://` allowed only after
  an "insecure transport" confirmation.

### 4.7 Branch operations

Name validation: `git check-ref-format --branch <name>` (run, not reimplemented). Commands: `git branch
[--no-track] <name> <start>`, `git switch [-c <name> [--track <remote>/<b>]] | --detach <oid>`,
`git branch -m <old> <new>`, `git branch -d|-D <name>`, `git push <remote> --delete <ref>`,
`git branch --set-upstream-to=<u> <b>` / `--unset-upstream <b>`. Switch failures are parsed for the
"would be overwritten" path list (C locale). Unmerged-delete detection relies on Git's refusal; the
second sheet lists `git log --oneline <b> --not <upstream-or-HEAD>` (bounded to 50).

### 4.8 Integration operations

- `git merge [--ff | --no-ff | --ff-only] [--no-edit | -m <msg>] -- <commit>`
- `git rebase --no-autostash --no-autosquash --no-update-refs <onto>` (explicit flags so the sheet's
  promise holds regardless of user config — ADR-0030)
- `git cherry-pick [-m <parent>] <oid>…`, `git revert --no-edit [-m <parent>] <oid>`
- `--continue` with `GIT_EDITOR=true` (keeps Git's prepared message), `--skip`, `--abort`, `--quit` never
  used. `merge --continue` is used rather than `commit` so Git validates the state.
- Optional preflight (spike): `git merge-tree --write-tree` (Git ≥ 2.38) to predict conflicts and show
  "This merge will conflict in 3 files" before starting.

### 4.9 Operation-state detection

Resolve paths with `git rev-parse --git-path <name>` (worktree-safe), then classify:
`rebase-merge/` (read `head-name`, `onto`, `msgnum`, `end`, `stopped-sha`) → Rebase;
`rebase-apply/` with `applying` → Am, else Rebase (apply backend); `MERGE_HEAD` → Merge (`MERGE_MSG` for
the source name); `CHERRY_PICK_HEAD` → CherryPick; `REVERT_HEAD` → Revert; `sequencer/todo` without the
above → multi-commit pick/revert between steps; `BISECT_LOG` → Bisect. FSEvents on the git dir
(already watched in Phase 1) triggers re-detection.

```rust
#[derive(uniffi::Enum)]
pub enum RepoOperationState {
    Clean,
    Merging { source: String, conflicted: u32 },
    Rebasing { head_name: String, onto: Oid, step: u32, total: u32, stopped_at: Option<CommitSummary>, conflicted: u32 },
    CherryPicking { commit: CommitSummary, remaining: u32, conflicted: u32 },
    Reverting { commit: CommitSummary, remaining: u32, conflicted: u32 },
    Applying,      // git am — informational only
    Bisecting,     // informational only
}
```

### 4.10 Conflict model

- **Entries:** `git status --porcelain=v2 -z` `u` records give the XY code (UU, AA, DU, UD, AU, UA, DD)
  and stage modes/OIDs; `git ls-files -u -z` cross-checks stages 1/2/3. Kind classification:

| Code | Kind |
|---|---|
| UU | both modified |
| AA | both added |
| UD / DU | modified by us, deleted by them / deleted by us, modified by them |
| AU / UA | added by us / by them (rename-involved cases) |
| DD | both deleted (rename/rename) — resolve by `git rm` or keep paths Git produced |

  Plus attributes: mode `120000` → symlink, `160000` → submodule, binary (NUL in first 8 KB of any
  stage or `-diff`/`binary` attribute via `git check-attr`), size above limit (default 5 MB).
- **Conflict document (ADR-0031):** Rust reads stage blobs via `git cat-file --batch`, writes them to a
  0700 temp dir, runs `git merge-file -p --diff3 -L ours -L base -L theirs ours base theirs`, and parses
  the output (labels are Jit-controlled, so parsing is unambiguous) into segments:
  `Resolved(bytes) | Conflict { ours, base, theirs, ours_range, theirs_range }`. Line endings and
  encoding are preserved as bytes; non-UTF-8 → fallback.
- **Working-tree reconciliation:** the working-tree file (what Git wrote, possibly edited by the user) is
  hashed. If it differs from what the merge produced (user already edited it), the resolver offers
  "Continue from the file on disk" (parse markers in the file; if unparseable, open as plain editable
  result) or "Start from Git's conflict" — never silently discarding either.
- **Saving:** `save_resolution(path, bytes, expected_hash)` → check the current file hash equals
  `expected_hash` (else `StaleSnapshot` → UI shows "changed outside Jit"); write to a temp file in the
  same directory with the original mode; `rename(2)` atomically; return the new hash.
- **Marking resolved:** `mark_resolved(path, expected_hash)` → re-verify hash, then `git add -- <path>`.
  Fallback resolutions use `git checkout --ours|--theirs -- <path>` / `git rm -- <path>` + `git add`.
- **Release:** conflict documents are dropped when the resolver closes; nothing cached across files.

```rust
impl RepoHandle {
    fn operation_state(&self) -> Result<RepoOperationState, GitError>;
    fn conflicts(&self) -> Result<Vec<ConflictEntry>, GitError>;
    fn load_conflict(&self, path: RepoPath) -> Result<ConflictDocument, GitError>;
    fn save_resolution(&self, path: RepoPath, content: Vec<u8>, expected: FileHash) -> Result<FileHash, GitError>;
    fn mark_resolved(&self, path: RepoPath, expected: FileHash) -> Result<(), GitError>;
    fn resolve_with_side(&self, path: RepoPath, side: ConflictSide, token: ConfirmationToken) -> Result<(), GitError>;
    fn continue_operation(&self, ctx: ExecContext) -> Result<IntegrationOutcome, GitError>;
    fn skip_current(&self, ctx: ExecContext, token: ConfirmationToken) -> Result<IntegrationOutcome, GitError>;
    fn abort_operation(&self, token: ConfirmationToken) -> Result<(), GitError>;
    fn fetch(&self, req: FetchRequest, ctx: ExecContext, cancel: Arc<CancelToken>, progress: Box<dyn ProgressSink>) -> Result<FetchOutcome, GitError>;
    fn pull(&self, req: PullRequest, ctx: ExecContext, cancel: Arc<CancelToken>, progress: Box<dyn ProgressSink>) -> Result<PullOutcome, GitError>;
    fn push(&self, req: PushRequest, ctx: ExecContext, cancel: Arc<CancelToken>, progress: Box<dyn ProgressSink>) -> Result<PushOutcome, GitError>;
    fn create_branch(&self, req: CreateBranchRequest, expected: RepoRevision) -> Result<(), GitError>;
    fn switch(&self, req: SwitchRequest, expected: RepoRevision) -> Result<SwitchOutcome, GitError>; // WouldOverwrite { paths }
    fn merge(&self, req: MergeRequest, ctx: ExecContext, expected: RepoRevision) -> Result<IntegrationOutcome, GitError>;
    fn rebase(&self, req: RebaseRequest, ctx: ExecContext, expected: RepoRevision) -> Result<IntegrationOutcome, GitError>;
    // cherry_pick, revert, rename_branch, delete_branch, delete_remote_branch, set_upstream analogous
}
#[uniffi::export] fn clone_repository(req: CloneRequest, ctx: ExecContext, cancel: Arc<CancelToken>, progress: Box<dyn ProgressSink>) -> Result<RepoLocation, GitError>;
```

Swift wraps each in `async throws` methods on `GitCoreBridge.Repository` that run on a background
executor and translate `GitError` into `PresentableError` (§4.11).

### 4.11 Error taxonomy (§16.4)

`errors::classify(exit, stderr_c_locale, context)` → `GitError`; Swift maps each to a
`PresentableError { title, explanation, recoveryActions, technicalDetail (sanitized) }`.

| Case (§16.4) | Detection (examples) | User-facing explanation → recovery actions |
|---|---|---|
| Invalid repository | `not a git repository`, missing path | "This folder is no longer a Git repository." → Locate…, Close Tab |
| Detached HEAD | `HEAD` not a symbolic ref when an op needs a branch | "You're not on a branch." → Create Branch Here…, Switch Branch… |
| Dirty working directory | `would be overwritten`, `Please commit your changes or stash them` | lists files → Cancel, Discard Changes… (destructive), open Working Directory |
| Unmerged index | `you need to resolve your current index first`, unmerged entries | → Resolve Conflicts, Abort… |
| Invalid credentials | `Authentication failed`, HTTP 401/403 | "The remote rejected the credentials." → (Phase 5: Reconnect Account / Switch Profile) |
| Expired token | provider-specific 401 wording (Phase 5 refines) | → Reconnect Account (Phase 5) |
| SSH failure | `Permission denied (publickey)`, `Host key verification failed`, `REMOTE HOST IDENTIFICATION HAS CHANGED` | distinct messages; changed host key is a security warning, never "retry" |
| TLS failure | `SSL certificate problem`, `server certificate verification failed` | → (Phase 5: configure CA); never offer to disable verification |
| Proxy failure | `Failed to connect to proxy`, `Received HTTP code 407 from proxy` | → Network settings (Phase 5) |
| Remote unreachable | `Could not resolve host`, `Connection timed out`, `Connection refused` | DNS vs timeout vs refused worded separately; VPN hint for private-looking hosts → Retry |
| Rejected push | porcelain `!` with reason | §3.4 rejection sheet |
| Merge conflicts | exit 1 + unmerged entries | banner + Resolve |
| Stale diff / snapshot | `StaleSnapshot` from revision/hash checks | "The repository changed since you prepared this action." → Refresh & Review |
| Locked index | `index.lock': File exists` | "Another Git process is using this repository." shows lock age → Retry; Remove Lock… only via destructive sheet stating the risk |
| Missing Git executable | `GitLocator` failure | onboarding/settings link |
| Permission denied | `Permission denied` on paths, EACCES | path shown → Reveal in Finder |
| Disk full | `No space left on device`, ENOSPC | → retry after freeing space; partial clone cleaned |
| Operation cancelled | `CancelToken` | neutral, not an error color |
| Unknown | anything else | generic title + sanitized last 20 stderr lines in disclosure |

Sanitization (shared with Phase 5): strip `user:pass@` from URLs, redact `Authorization`-like headers,
known token prefixes (`ghp_`, `github_pat_`, `glpat-`, `gho_`), and anything matching an in-flight
secret.

### 4.12 Web link mapping

Parse remote URLs (https, `ssh://[user@]host[:port]/path`, scp `user@host:path`), strip `.git`, and map:
- `github.com` → `https://github.com/<owner>/<repo>/commit/<sha>`, `/tree/<branch>`
- `gitlab.com` → `https://gitlab.com/<namespace…>/<repo>/-/commit/<sha>`, `/-/tree/<branch>`
Unknown hosts → no menu item (Phase 5 adds configured self-managed instances, including path prefixes).
Branch names are percent-encoded per path segment.

### 4.13 Performance

- No automatic fetch, ever, in V1 unless the user explicitly enables a future setting (none in V1).
- Progress throttled; activity item stops all drawing when idle; checkmark animation is one-shot.
- Banner detection is event-driven (FSEvents), cheap file stats only.
- Conflict documents load on demand per file; the panes render only visible lines (Phase 3 renderer).
- Post-op refresh is targeted (ref list delta, graph head pages, status of reported paths).

### 4.14 Security

- argv arrays only; `--` before paths and revisions where Git supports it; refs and remote names
  validated (`check-ref-format`, `git remote` list membership) before use.
- Protocol policy (`ext`, `fd` disabled); `http://` requires explicit confirmation; no
  `--upload-pack`/`--receive-pack`/`-c` values derived from user input.
- Temp files for conflict stages in a per-operation 0700 directory, removed on completion.
- No credential prompts can appear in this phase; nothing is written to `~/.gitconfig`.

## 5. Edge cases & failure modes

- Operation started in Terminal while Jit has a sheet open → `StaleSnapshot` on confirm.
- Index locked by an editor/IDE integration → explained error; no auto-delete of `index.lock`.
- Unborn branch (no commits): pull/merge/rebase disabled with explanation; push of first commit works.
- Branch name collisions with remote-tracking names or tags (`refs/heads/x` vs `refs/tags/x`) — always pass
  fully qualified refs to plumbing where ambiguity is possible.
- Upstream gone (`[gone]`) → badge and "Unset upstream" suggestion.
- Push to a remote with a pre-receive hook rejection → show `remote:` lines verbatim (sanitized).
- Local hooks (`pre-commit`, `pre-push`, `post-checkout`) run per ADR-0014; their output appears in the
  activity detail; a failing hook is presented as "Blocked by the repository's <hook> hook".
- Rebase with empty commits after resolution (`--continue` reports "nothing to commit") → offer Skip.
- Conflicted file deleted from disk by the user during resolution → treated as stale; offer fallback.
- Conflict markers already present in the source file historically (false positives) → the document comes
  from stages, not from scanning the file, so they are just content.
- CRLF files, files without trailing newline, Unicode paths, paths with spaces — all in the test matrix.
- Clone into a non-empty existing folder → blocked before running; into iCloud-synced folders → warning.
- Very long-running fetch on a slow VPN → cancellable; no timeout kills a progressing operation; a stall
  detector (no stderr bytes for 120 s) offers Cancel but does not auto-cancel.
- Linked worktrees: state detection via `--git-path`; switching to a branch checked out in another
  worktree → Git refuses; message names the worktree path.
- App quit during an operation → quit confirmation lists running operations; on confirm, cancel-safe ones
  are cancelled, unsafe ones are allowed to finish (bounded wait) before quitting.

## 6. ADRs to write

| ADR | Title |
|---|---|
| 0015 | Operation framework: risk classes, Rust writer lock + Swift FIFO, revision tokens, lifecycle |
| 0030 | Pull strategy (explicit fetch + integrate, ff-only default) and force-push policy (lease-only, never plain force) |
| 0031 | Conflict document model (stage blobs + `git merge-file --diff3`, byte-preserving segments, hash-guarded saves) |
| 0032 | Non-interactive remote execution environment and protocol policy (the Phase 5 hook point) |
| 0033 | Ours/theirs labelling per operation |
| 0034 | Remote URL → web URL mapping |

## 7. Open questions / spikes

| Question | Decide by | Criteria |
|---|---|---|
| `diff3` vs `zdiff3` for conflict documents | P4.11 spike on fixture conflicts | Fewer redundant lines in blocks without losing base information; zdiff3 needs Git ≥ 2.35 (check ADR-0006 minimum). |
| Use `git merge-tree --write-tree` for conflict prediction | P4.9 | Accurate on fixture matrix, < 300 ms on 10k-commit repo, Git version available. Optional — ship without if not clean. |
| Default for "Prune" toggle when config unset | P4.4 | Follow Git default (off) unless user feedback says otherwise. |
| Stall detector threshold | P4.1 | Measured on slow-link simulation (`networkQuality`/Network Link Conditioner). |
| Whether "Discard These Changes…" on blocked switch is worth shipping before stash exists | P4.8 review | If it tests safely (path-scoped `git restore`), keep; otherwise cancel-only. |
