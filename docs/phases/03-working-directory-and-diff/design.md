# Phase 3 — Working Directory & Diff: Design

> Requirements: §4.5, §6 (entire), §7 (entire), §9.1 Files, §14, §16, §18.2, §19.
> Roadmap moves: blame lands here. Commit identity comes from the identity-only profiles built in
> Phase 1; authentication is Phase 5.

## 1. Goal & demo

This is a flagship phase. At the end:

- The inspector's working-directory panel shows staged, unstaged, untracked and conflicted files with
  counts and `+/-` stats, in flat or tree mode, and supports stage / unstage / discard per file and all.
- A native diff viewer (no WebView) renders unified and side-by-side diffs with syntax highlighting,
  line numbers, hunk headers, collapsible context, word-level highlights, search and change navigation.
- File, hunk and **line** level stage, unstage and discard work and are **proven safe** by integration
  and property tests that assert unrelated lines and files are byte-identical afterwards.
- The commit composer creates commits and amends using the active profile's identity, applied per
  invocation without touching any Git config.
- Blame and commit/compare diffs (from Phase 2's inspector) open in the same renderer.

**Demo script (Scenario C, §24):** edit 6 lines across 2 hunks of a file → stage one line → only that
line moves to Staged → unstage it → discard another line (confirmation shows exactly what is lost) →
other changes intact → stage a hunk → commit with ⌘↩ as "Work profile" → graph shows the new commit with
the profile's author; `git config --global --list` unchanged.

## 2. Scope

**In scope**
- Full status model (porcelain v2): modified, added, deleted, renamed/copied (staged), type changes,
  untracked, ignored (hidden), conflicted (flagged only), partially staged, mode changes, symlinks,
  submodules (read-only display).
- Working-directory panel; file-level stage/unstage/discard; stage all / unstage all; open in editor;
  reveal in Finder.
- Rust diff engine with a byte-exact model and stable hunk/line IDs.
- Diff renderer (ADR-0011) with unified, side-by-side and full-file layouts; staged, unstaged,
  commit, commit↔commit, commit↔working-directory targets; focused diff mode.
- Syntax highlighting (ADR-0012), word-level diff, whitespace handling.
- Partial staging/unstaging/discard (ADR-0013) with snapshot tokens, `git apply --check`, post-apply
  verification, and recovery copies for discards (ADR-0025).
- Blame view.
- Commit composer: commit, amend, validation, identity snapshot, hooks policy (ADR-0014).
- Per-repository write serialization (ADR-0027), designed to be lifted into Phase 4's OperationCenter.

**Out of scope (and where it lives)**
- Conflict resolution UI → Phase 4 (conflicted files are listed with "Resolve conflicts to stage";
  Open in Editor is available).
- Combined diffs for merge commits → Phase 6 polish if cheap, else Phase 8.
- Stash, reset modes, patch export → Phase 8.
- Commit signing configuration → Phase 8 (Git runs configured signing as usual; see §5).
- Push after commit → Phase 4.
- External diff/merge tools → never by default (§19).

## 3. User experience

### 3.1 Working-directory panel (inspector, WIP selected)

Hierarchy, top to bottom:
1. **Header:** branch name, `3 staged · 5 unstaged · 1 untracked`, view toggle (List / Tree), filter
   field (⌘⌥F within panel), sort menu (Path, Name, Status, Size of change).
2. **Conflicts (n)** — only when present, `accent.danger` glyph; rows not stageable, tooltip
   "Resolve the conflict first (conflict resolution arrives in the next phase)".
3. **Staged (n)** with section action `Unstage All`.
4. **Unstaged (n)** (modified + deleted + untracked, untracked marked `U`) with `Stage All`.
5. **Commit composer** pinned at the bottom (§3.6).

File row: status glyph (A M D R C T U, coloured via `status.*` tokens), file-type icon (SF Symbol by
extension, generic `doc`), file name (`type.body`), parent directory dimmed (`text.tertiary`,
middle-truncated), `+12 −3` (SF Mono, `type.caption`), hover reveals a single primary action button
(Stage / Unstage) at the trailing edge — 100 ms fade. Partially staged files appear in both sections
with a half-filled glyph. Renames: `old → new`. Mode change: `+x` badge. Symlink: `arrow.turn.up.right`
badge. Submodule: `shippingbox` badge, "Submodule — new commits" description, file-level stage only.

Interactions:
- Click selects → diff opens in the diff area. ↑/↓ moves; Space toggles stage/unstage of the
  selected file(s); ⌘A selects all in section; drag rows between Staged/Unstaged sections stages/unstages
  with a drop highlight (`fill.dropTarget`, 120 ms).
- Context menu (file): Stage / Unstage, Discard Changes… (worktree), Open in Editor (⌘⇧O), Reveal in
  Finder, Copy Path, Copy Relative Path, Show File History (Phase 2), Blame.
- Tree mode: folders collapse/expand; folder context menu stages/unstages/discards all children.
- Success feedback after staging: the row slides to its new section (160 ms, Reduce Motion: instant)
  and the section count ticks; no toast.

States:
- **Clean:** calm empty state in place of sections — check glyph, "Working tree clean", subtle
  "Last commit: <subject>".
- **Loading:** sections show prior content immediately (cached); a 2pt progress hairline under the
  header appears only if refresh exceeds 150 ms.
- **Error:** inline banner (e.g. "Index is locked by another Git process (.git/index.lock).
  Retry" — Jit never deletes lock files automatically).
- **Huge change sets (> 5,000 entries):** list virtualized; numstat computed lazily for visible rows;
  untracked directories collapsed (`--untracked-files=normal`) with on-demand expansion.

### 3.2 Discard confirmation (file-level and line-level)

Sheet, not alert, because it must explain precisely (§16.3):
- Title: "Discard changes to `src/app.rs`?" (or "Discard 3 selected lines in `src/app.rs`?").
- Body: what changes (working tree only; staged changes are kept), what is lost (count of lines /
  "the untracked file" ), recoverability ("A copy is kept in Jit's recovery folder for 7 days" /
  "The file will be moved to the Trash"), repository and branch.
- A compact preview of the removed/restored lines (first 20, SF Mono, diff colours).
- Buttons: `Cancel` (default, Esc) and destructive `Discard` (never default, no ⌘↩ shortcut).
- "Don't ask again" is **not** offered for discards.

### 3.3 Diff viewer

Placement: the diff area occupies the inspector's lower region or, in **Focused Diff** mode
(View ▸ Focus Diff; shortcut chosen in Q2 to avoid standard bindings; Esc exits), expands across the
graph area with a 200 ms panel transition. Minimum comfortable width for side-by-side: 900pt; below
that, the side-by-side button shows a tooltip "Widen the window or use Focus Diff" and unified is used.

**File header bar:** path (SF Mono, directory dimmed), status, `+12 −3`, badges (CRLF, No newline at
end, Mode 100644 → 100755, Binary, LFS pointer, Large file), layout segmented control
(Unified / Split / Full File), whitespace menu (Show whitespace, Ignore whitespace changes — with note
"Line actions are disabled while ignoring whitespace"), word-diff toggle, and actions: Stage File /
Unstage File, Discard…, Open in Editor, Blame, File History. Header actions reflect the diff target
(staged vs unstaged); commit diffs only show read-only actions.

**Body:**
- Gutters: old and new line numbers (SF Mono, `text.tertiary`), then a 3pt change bar
  (`diff.addedBar` / `diff.removedBar`), then content.
- Line backgrounds: `diff.addedBg`, `diff.removedBg`; word-level highlights `diff.addedWordBg`,
  `diff.removedWordBg` (2pt radius), designed per theme for long-session readability — added/removed
  hues are muted (moss/rosewood family), never saturated green/red; contrast of syntax colours on diff
  backgrounds ≥ 4.5:1.
- Hunk header row: `@@ -12,7 +12,9 @@ fn render()` in `text.secondary` on `surface.sunken`, with
  hunk actions on the right (Stage Hunk / Unstage Hunk / Discard Hunk…). When lines in the hunk are
  selected, the actions become "Stage 3 Lines" / "Discard 3 Lines…".
- Collapsed unchanged regions: a slim row "⋯ 48 unchanged lines" — click expands 20 lines at a time
  or all (⌥-click).
- Side-by-side: old on the left, new on the right, aligned by hunk; blank filler rows (hatched
  `fill.subtle`) where one side has no line. One shared vertical scroll; horizontal scroll per side
  synchronized.
- Full File: the whole new version with changed lines marked and deleted lines shown as inline
  collapsed "−3 lines" markers that expand on click.
- Tabs rendered at configurable width (Settings, default 4); "Show whitespace" draws `·` and `→` in
  `text.quaternary`; trailing whitespace on added lines gets a subtle `diff.trailingWS` underline.
- Long lines: no wrapping by default; horizontal scrolling; optional soft-wrap toggle (line actions
  remain line-based).
- Selected line: `fill.selection` + left accent bar; selection persists across scroll.

**Line selection model:**
- Click a changed line's gutter or content → selects it; drag across lines → range; ⇧-click extends;
  ⌘-click toggles individual lines; clicking a hunk header selects the hunk's changed lines.
- Only changed lines (`+`/`-`) are selectable for actions; context lines are skipped.
- Text selection for copying is separate: ⌥-drag (or drag inside content after a 300 ms press) selects
  characters; ⌘C copies selected text, or selected lines' text if no character selection.

**Actions & labels (§7.3, unambiguous targets).** Every action names its target in the menu subtitle
or help tag:

| Diff target | Action | Modifies | Label |
|---|---|---|---|
| Unstaged | Stage selection | index | "Stage Lines" / "Stage Hunk" / "Stage File" |
| Unstaged | Discard selection | working tree (destructive) | "Discard Lines…" |
| Unstaged | Keep only selection | working tree (destructive): discards the *unselected* changed lines of the file | "Keep Only Selected Lines…" |
| Staged | Unstage selection | index | "Unstage Lines" / "Unstage Hunk" / "Unstage File" |
| Commit / compare | none | — | read-only (Copy, Open file at revision) |

The words "Accept" and "Reject" are not used in the diff viewer; they are reserved for Phase 4's
conflict resolver where they act on the merge result.

**Navigation:** ⌥↓ / ⌥↑ next/previous change (hunk), ↑/↓ line, ⌘F search in diff (matches highlighted
`diff.searchMatch`, current match outlined; ⌘G / ⇧⌘G), ⌘L go to line. Keyboard actions on selection:
S = stage, U = unstage, ⌫ = discard (opens confirmation) — active only when the diff body is first
responder (never steals typing in fields).

**States:** no file selected → "Select a file to see its changes"; loading > 120 ms → spinner in
header (content area keeps previous file dimmed until replaced — no flash); binary → "Binary file
changed (34 KB → 36 KB)" with Open in Editor / Quick Look (QLPreviewPanel) and file-level actions;
empty file → "Empty file"; too large (> 20 MB or > 200k lines) → "Large diff — showing first 10,000
lines" + Open in Editor, line actions disabled with explanation; stale (file changed externally while
viewing) → header banner "File changed on disk — diff updated" and any pending selection is cleared.

### 3.4 Syntax highlighting

Token kinds (keyword, type, function, string, number, comment, constant, operator, punctuation,
property, tag, attribute, variable, macro) map to `syntax.*` DesignSystem tokens designed per theme.
Highlighting appears progressively: rows render plain first, then spans arrive (no layout shift — spans
only change colour). Files over the limits (> 2 MB or > 50k lines) render plain with a small "Syntax
highlighting off for large files" note.

### 3.5 Blame

Opened from file context menu / diff header / ⇧⌘B. Full-window-width code view with a left blame
gutter (240pt): consecutive lines from the same commit form a block showing initials avatar, author,
relative date, subject (truncated); age indicated by a subtle luminance ramp on the gutter edge (newest
brightest). Hover shows SHA + full subject; click selects the commit in the graph (loading history as
needed). Streams in (`--incremental`): lines appear with blank gutters that fill as data arrives.
Toolbar: revision (defaults to HEAD / working copy), "Ignore whitespace" (`-w`), "Detect moves" (`-M`),
`blame.ignoreRevsFile` respected when configured (shown as a note).

### 3.6 Commit composer

Pinned at the bottom of the working-directory panel.
- **Identity line:** profile avatar/colour + "Committing as **Ana Ruiz** <ana@work.com> · Work"
  (click → profile switcher). If the repository's local config sets a different `user.email`, a
  subtle note: "Repository config says ana@personal.com — Jit will use the active profile."
- **Summary** field (single line, placeholder "Summary"), character counter appears past 50, turns
  `accent.warning` past 72 (warning, not a block). **Description** (multi-line, grows to 8 lines).
- **Amend** toggle: loads HEAD's message into the fields (restores the draft when turned off); if HEAD
  is contained in its upstream, a warning row: "This commit is already on origin/main. Amending
  rewrites it; pushing will then require a force push." If HEAD's author differs from the profile, an
  extra checkbox "Reset author to Ana Ruiz" (off by default; committer is always the profile).
- **Commit button:** "Commit 3 Files" (⌘↩), disabled with reason tooltip when: no staged changes (and
  not amend), empty summary, no active profile, conflicts present, operation in progress.
- **No profile:** the identity line becomes a call-to-action "Choose a profile to commit" opening the
  profile switcher / create sheet (Phase 1).
- **Progress:** button shows inline spinner while running; hook output (if any) streams into a
  collapsible "Hook output" disclosure.
- **Success:** fields clear, a brief check glyph on the button (600 ms, then settles; no lingering
  animation), the graph's new commit row receives the selection highlight.
- **Failure:** message stays; error row with mapped reason (e.g. "pre-commit hook failed (exit 1)" +
  output; "Nothing to commit"; "Index locked").
- Draft persistence: summary/description drafts persisted per repo (session state) so tab switches and
  relaunches keep them.

### 3.7 Accessibility & motion

- File rows: label "src/app.rs, modified, 12 additions, 3 deletions, staged".
- Diff rows: label includes line numbers and change type ("Added line 42: …"); rotor for hunks.
- Line selection fully keyboard-operable (⇧↑/⇧↓ extend; Space toggles line selection).
- Reduce Motion: row moves and panel transitions instant.

## 4. Technical design

### 4.1 Components

**Rust `git-core`**
- `status` — extend Phase 1 parser: `git status --porcelain=v2 -z --branch
  --untracked-files=normal --find-renames --ignore-submodules=none` → `StatusSnapshot` (entries with
  XY, sub-state, modes H/I/W, oids, rename source/score, conflict stage info). Numstat via
  `git diff --numstat -z` and `git diff --cached --numstat -z`, computed lazily per visible batch.
- `diff` —
  - `DiffInvocation` builds the canonical argv (see 4.3).
  - `PatchParser` parses bytes (never `String`) into `FilePatch { header, hunks: Vec<Hunk> }`,
    `Hunk { old_start, old_len, new_start, new_len, section, lines: Vec<Line> }`,
    `Line { kind: Context|Add|Del, bytes: Range<usize>, eol: Lf|CrLf|None, no_newline_marker: bool,
    old_no, new_no }`. IDs: `HunkId(u32)` and `LineId { hunk: u32, idx: u32 }`, stable for the
    lifetime of a `DiffDocument`.
  - `DiffDocument` (UniFFI object) owns raw bytes + parsed index, snapshot token, layout tables for
    unified/split/full-file rows, and serves row windows.
  - `wordiff` — token-level Myers on paired `-`/`+` runs within a hunk (pairs only when run lengths
    are within 2× and line length < 1,000 bytes); results cached per hunk.
- `highlight` — tree-sitter: parses pre-image and post-image blobs once per document in the background
  (≤ 2 MB, ≤ 50k lines), queries highlights for requested row ranges; `Vec<Span { line, start_utf16,
  len_utf16, kind: u8 }>`. Initial grammar set (measure binary size): Swift, Rust, C/C++/ObjC,
  JavaScript/TypeScript (incl. JSX/TSX), Python, Go, Java, Kotlin, Ruby, JSON, YAML, TOML, Markdown,
  Shell, HTML, CSS. Language detection: extension map + shebang + `.gitattributes linguist-language`
  ignored (simplicity).
- `patch_builder` — selection → patch (4.4).
- `stage` — file-level (`git add -- <paths>`, `git rm --cached` for unstage of new files /
  `git restore --staged -- <paths>`), line/hunk via `git apply`.
- `discard` — file-level (`git restore --worktree -- <paths>`; untracked → returned to Swift to move
  to Trash), line/hunk via `git apply -R`; recovery copy written before mutation.
- `commit` — `git commit -F -` (message on stdin), `--amend`, `--reset-author`, `--no-verify` only
  when explicitly requested; streams hook output via progress sink.
- `blame` — `git blame --incremental [-w] [-M] <rev> -- <path>` streamed through a sink.
- `writer` — `RepoWriter`: per-repository mutex + monotonic `RepoRevision` counter (ADR-0027).

**Swift**
- `Features/WorkingDirectory`: `WorkingDirectoryViewController` (AppKit outline for virtualization),
  `WorkingDirectoryModel` (@Observable: sections counts, selection, view mode; entries kept in a
  diffable snapshot — not published wholesale).
- `Features/DiffViewer`: `DiffViewController`, `DiffRenderView` (renderer per ADR-0011),
  `DiffHeaderView` (SwiftUI in hosting view), `DiffSelection`, `DiffSearchController`.
- `Features/Blame`: `BlameViewController` reusing the renderer's line drawing + gutter.
- `Features/CommitComposer`: SwiftUI `CommitComposerView` + `CommitComposerModel`.
- `Services/RepositorySession.writer`: a Swift `actor RepositoryWriter` funnelling all mutations, so
  the UI can show "busy" and disable conflicting actions; Phase 4 replaces it with OperationCenter.
- `Services/RecoveryStore`: manages `~/Library/Application Support/Jit/Recovery/`.

### 4.2 Bridge API sketch (illustrative)

```rust
#[derive(uniffi::Enum)] pub enum DiffTarget {
    Unstaged { path: String },                         // index → worktree (untracked: synthesized)
    Staged { path: String },                           // HEAD (or empty tree) → index
    Commit { oid: String, path: Option<String> },      // first parent → commit
    Range { from: String, to: String, path: Option<String>, merge_base: bool },
    CommitToWorktree { oid: String, path: Option<String> },
}
#[derive(uniffi::Record)] pub struct DiffOptions {
    pub context_lines: u32,          // default 3
    pub ignore_whitespace: bool,     // disables line actions
    pub word_diff: bool,
}
#[derive(uniffi::Record)] pub struct SnapshotToken {
    pub path: String,
    pub head_oid: Option<String>,
    pub index_oid: Option<String>, pub index_mode: Option<u32>,
    pub worktree_hash: Option<Vec<u8>>,              // git-blob SHA-1 of raw bytes
    pub worktree_size: u64, pub worktree_mtime_ns: i64,
    pub repo_revision: u64,
}

#[uniffi::export] impl RepoHandle {
    pub fn status(&self, cancel: Arc<CancelToken>) -> Result<StatusSnapshot, GitError>;
    pub fn numstat(&self, paths: Vec<String>, staged: bool, cancel: Arc<CancelToken>) -> Result<Vec<NumStat>, GitError>;
    pub fn open_diff(&self, t: DiffTarget, o: DiffOptions, cancel: Arc<CancelToken>) -> Result<Arc<DiffDocument>, GitError>;

    pub fn stage_paths(&self, paths: Vec<String>) -> Result<RepoRevision, GitError>;
    pub fn unstage_paths(&self, paths: Vec<String>) -> Result<RepoRevision, GitError>;
    pub fn discard_paths(&self, items: Vec<DiscardItem /* path + token */>) -> Result<DiscardOutcome, GitError>;

    pub fn apply_selection(&self, req: SelectionRequest) -> Result<ApplyOutcome, GitError>;
    pub fn commit(&self, req: CommitRequest, sink: Box<dyn ProgressSink>, cancel: Arc<CancelToken>) -> Result<CommitOutcome, GitError>;
    pub fn blame(&self, path: String, rev: Option<String>, o: BlameOptions, sink: Box<dyn BlameSink>, cancel: Arc<CancelToken>) -> Result<(), GitError>;
}

#[derive(uniffi::Record)] pub struct SelectionRequest {
    pub action: SelectionAction,      // Stage | Unstage | Discard | KeepOnly
    pub token: SnapshotToken,         // from the DiffDocument the user selected in
    pub lines: Vec<LineId>,           // or all lines of chosen hunks
}
#[derive(uniffi::Record)] pub struct ApplyOutcome { pub revision: u64, pub recovery_id: Option<String> }
#[derive(uniffi::Record)] pub struct CommitRequest {
    pub message: String, pub amend: bool, pub reset_author: bool, pub no_verify: bool,
    pub identity: IdentitySnapshot,   // captured from the active profile when the user pressed Commit
}

#[uniffi::export] impl DiffDocument {
    pub fn summary(&self) -> DiffSummary;                       // flags, hunks, row counts, token, badges
    pub fn rows(&self, layout: DiffLayout, start: u32, count: u32) -> Vec<DiffRow>;
    pub fn highlights(&self, layout: DiffLayout, start: u32, count: u32) -> Vec<RowSpans>; // may be empty until parsed
    pub fn search(&self, q: String, case_sensitive: bool) -> Vec<RowMatch>;
    pub fn expand_context(&self, gap: u32, lines: u32) -> u32; // returns new row count
    pub fn close(&self);
}
```

`DiffRow` carries kind, line numbers, the line text (UTF-8, lossy for display; original bytes stay in
Rust), `LineId` if changed, word-diff ranges (UTF-16), and `eol`/`no_newline` flags. The bridge never
transfers whole files: only visible windows (≈ 2× viewport), like the graph.

### 4.3 Canonical diff invocation (ADR-0026)

```
git -c core.quotepath=off -c diff.noprefix=false -c diff.mnemonicPrefix=false
    -c diff.relative=false -c color.ui=false
    diff [--cached] --no-color --no-ext-diff --no-textconv --full-index --binary
    --find-renames -U<n> --src-prefix=a/ --dst-prefix=b/ --submodule=short
    [<rev>…] -- <path>
```

(`-z` is used for `--name-status`/`--numstat` listings; patch output is parsed from the `diff --git`
headers.)

- `--no-textconv` and `--no-ext-diff`: the diff must be applicable and must not run external programs.
- `--binary` so binary patches are representable (file-level only, never line-level).
- Repository `diff.algorithm` is respected for display; `--indent-heuristic` default respected.
- Untracked files: Rust synthesizes a "new file" patch from the raw bytes (no `git add -N`, which would
  mutate the index as a side effect).
- Bytes in, bytes out: CRLF and missing final newline are preserved exactly; the parser never
  normalizes. Paths are taken from the `diff --git` header with C-quoting decoded; when ambiguous, the
  path from the request is used.

### 4.4 Partial staging algorithm (ADR-0013) — critical

**Selection semantics.** For a hunk from diff `pre → post` and a set S of selected changed lines:

| Operation | Source diff | Selected `+` | Unselected `+` | Selected `-` | Unselected `-` | Apply |
|---|---|---|---|---|---|---|
| Stage | unstaged (index→worktree) | keep `+` | drop | keep `-` | → context | `git apply --cached` |
| Unstage | staged (HEAD→index) | keep `+` | → context | keep `-` | drop | `git apply --cached -R` |
| Discard | unstaged (index→worktree) | keep `+` | → context | keep `-` | drop | `git apply -R` (worktree) |
| Keep only | unstaged | S' = changed lines not in S, then Discard(S') | | | | `git apply -R` |

Rationale: the forward patch's pre-image must match the target (index for stage); a reverse patch's
post-image must match the target (index for unstage, worktree for discard), so unselected lines that
exist in the target become context and the rest are dropped.

**Steps for every selection operation** (inside `RepoWriter`, so no other mutation interleaves):

1. **Validate token.** Re-read the path's current state: `git ls-files -s -z -- <path>` (index mode +
   oid), worktree `lstat` + git-blob SHA-1 of contents (for stage/discard), `HEAD` oid (for unstage).
   If anything differs from the token → `GitError::StaleDiff` (UI reloads the diff, clears selection,
   explains "The file changed since you selected those lines").
2. **Build the patch** from the `DiffDocument`'s parsed hunks and S using the table above. Hunk headers
   are recounted exactly (no `--recount` reliance). Each emitted hunk keeps all original context lines
   (no context trimming; never `--unidiff-zero`). Hunks with no selected lines are omitted entirely.
   `\ No newline at end of file` markers stay attached to their line; when a converted-to-context line
   carries the marker, the marker is preserved on the context line; if a selection would require
   changing only the final-newline state ambiguously, the operation is refused (see unsupported cases).
   Headers include `diff --git`, `index <old>..<new> <mode>` (full oids), `---`/`+++`.
3. **Compute the expected result independently.** Apply S to the in-memory pre-image lines (Rust
   model) → expected target bytes (index blob content for stage/unstage, worktree bytes for discard).
4. **Check.** Write the patch to a private temp file (`0600`, in an app temp dir, deleted after) and run
   `git apply --check [--cached] [-R] --whitespace=nowarn <absolute-patch-path>` (no `--3way`, no `--reject`,
   no `--unidiff-zero`, no `--recount`). Failure → refuse with the mapped error; nothing changed.
5. **Recovery copy (discard/keep-only only).** Copy the current worktree file into the recovery store
   with metadata (repo, path, time, branch, token) before applying. Record `recovery_id`.
6. **Apply** the same command without `--check`.
7. **Verify.** Read back the actual result: index blob (`git cat-file blob <oid from ls-files>`) or
   worktree bytes. Compare with the expected bytes from step 3. Also assert other index entries are
   unchanged (compare `ls-files -s` output for all paths minus the target, captured in step 1 for the
   affected path set — for performance, capture the full index entry list only for files with ≤ 100k
   entries; otherwise compare the target path plus a checksum of `ls-files -s` output).
   - Mismatch on index → restore the captured entry with
     `git update-index --cacheinfo <mode>,<oid>,<path>` (or `--force-remove` if it didn't exist) and
     report `GitError::VerificationFailed` with diagnostics written to the log (no file contents).
   - Mismatch on worktree → restore from the recovery copy **only if** the worktree still equals the
     applied (unexpected) result; otherwise leave it and tell the user where the recovery copy is.
8. **Bump `RepoRevision`**, emit invalidation for the path (status + diff reload).

**Unsupported → refuse with explanation** (granular action disabled with a help tag; file-level still
available unless noted):
- Binary files (file-level only).
- Symlinks (file-level only: the "content" is the link target).
- Submodules / gitlinks (file-level stage/unstage only; discard not offered in V1).
- Type changes (file ↔ symlink), mode-only changes mixed with content when line-level is attempted on
  the mode: content lines are stageable; the mode change is a separate explicit "Stage mode change"
  item.
- Diff produced with "Ignore whitespace" (patch wouldn't apply) — line actions disabled while on.
- Paths with clean/smudge filters, `text`/`eol` attributes or `core.autocrlf` conversions where
  `git apply --check` fails for the worktree side → refuse with "This file uses line-ending/filter
  conversion; stage the whole file instead." (detected via `git check-attr -z filter text eol --`
  and config). Stage (index side) usually works and is allowed when the check passes and verification
  succeeds.
- Ambiguous final-newline-only selections that the model cannot express.
- Renamed files on the staged side: line-level unstage allowed only if the check + verification pass
  for the rename-aware patch; otherwise file-level only.
- Files larger than the diff limit (line actions disabled when the diff is truncated).

**New / deleted files.**
- Untracked file, stage selected lines → new-file patch containing only selected lines
  (`new file mode`), applied `--cached`; partial selection yields an index blob with the selected lines.
- Deleted file, stage selected `-` lines → modification patch (file stays in index with remaining
  lines); all lines selected → `deleted file mode` patch.
- Unstage on a newly added file with all lines selected → `git rm --cached -- <path>` equivalent via a
  reverse new-file patch; partial → modification.

### 4.5 Discard recovery (ADR-0025)

- Location: `~/Library/Application Support/Jit/Recovery/<repo-id>/<yyyyMMdd-HHmmss>-<n>/` with
  `meta.json` (repo path, branch, path, operation, line counts — no secrets) and the pre-discard file.
  Directory permissions `0700`, files `0600`.
- Untracked files discarded at file level are moved to the Trash (`FileManager.trashItem`), not deleted.
- Retention: 7 days or 500 MB total, pruned once at app launch (no timer). A "Recently Discarded"
  list (Repository menu) can open/reveal the copies; restoring is a manual copy in V1 (Phase 8 may add
  one-click restore).

### 4.6 Commit identity & hooks (ADR-0014, ADR-0028)

- `IdentitySnapshot { author_name, author_email, committer_name, committer_email }` captured from the
  active profile at the moment the user presses Commit (§6.2: profile switches mid-operation don't
  affect it).
- Applied via the child's environment only: `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` (env takes precedence over config; nothing is written).
  Amend without "Reset author" keeps the original author; committer is the profile.
- Message passed on stdin (`-F -`); `commit.cleanup` from config respected; no editor ever opens
  (sanitized env from Phase 0 sets a non-interactive `GIT_EDITOR`).
- Hooks: run as Git runs them (pre-commit, prepare-commit-msg, commit-msg, post-commit). Their combined
  stdout/stderr is streamed to the composer's "Hook output" disclosure. `--no-verify` is offered only
  via an explicit secondary menu item "Commit Without Running Hooks…" with an explanation; not sticky.
  `docs/security.md` documents that opening a repository and committing can execute that repository's
  hooks, as Git does.
- Signing: if `commit.gpgSign`/`gpg.format` are configured, Git performs signing as configured; if it
  fails (e.g. pinentry unavailable) the error is shown verbatim-but-sanitized. Signing configuration UI
  is post-V1.

### 4.7 Concurrency, invalidation & state ownership

- `RepoWriter` (Rust): one mutex per repository held for the full duration of a mutation (token check →
  apply → verify). Reads (status, diff) run concurrently and tag their results with the
  `RepoRevision` they observed; Swift discards results older than the latest known revision.
- Swift `actor RepositoryWriter`: serializes user-initiated mutations, exposes `isBusy` + current
  operation description; queued actions show as pending (disabled UI), never silently dropped.
- FSEvents (Phase 1) → worktree/index change for path set → re-run status (coalesced) and, if the
  current diff's path is affected, reload the `DiffDocument` (keeping scroll position by nearest line
  number; clearing selection if lines changed).
- Ownership: `StatusSnapshot` in `WorkingDirectoryModel` (diffed updates), current `DiffDocument` in
  `DiffViewController` (one active + one previous cached; inactive tabs release both), composer draft
  in session state.

### 4.8 Renderer (ADR-0011) — spike, then decide

Candidates:
1. **TextKit 2** (`NSTextView` + `NSTextLayoutManager`, custom `NSTextLayoutFragment` for backgrounds
   and gutters). Pros: native text selection, find, accessibility. Cons: side-by-side alignment needs
   two synced views with filler paragraphs; per-line backgrounds and gutters are custom anyway; large
   documents need care to avoid full layout.
2. **Custom virtualized row renderer**: an `NSView` inside `NSScrollView` with a fixed row height,
   drawing only visible rows with `CTLine`s cached in an LRU (by row + appearance), gutters and
   backgrounds drawn directly; selection, search and accessibility implemented explicitly
   (`NSAccessibilityElement` per visible row).

Decision criteria (measure on the reference Mac, release build): 60 FPS (0 hitches > 1 frame) scrolling
a 50k-line diff; open-to-first-paint < 50 ms for a 2k-line diff; memory < 30 MB for the 50k-line diff;
correct side-by-side alignment; line-selection model fidelity (§3.3); text copy; VoiceOver navigation.
Expected outcome is (2) for the diff body (row-oriented data, alignment, line selection) with standard
AppKit text for small read-only areas — but the decision must follow the numbers.

The renderer is built as a reusable `CodeLinesView` so Phase 4's conflict resolver can reuse it
(with an editable mode added there — editing is out of scope here).

### 4.9 Performance approach

- Diff switch: open `DiffDocument` off-main; first paint from the first visible window; highlighting
  and word-diff arrive later without relayout.
- Bounded memory: one active + one cached document; documents release raw bytes on `close()`;
  highlight trees dropped when the document closes; CTLine LRU capped (e.g. 2,000 lines).
- Status: porcelain v2 once per coalesced FSEvents burst; numstat lazily for visible rows only.
- No work while idle; no timers (the success check glyph uses a one-shot animation).

### 4.10 Security

- Patches written only to an app-private temp dir with `0600`, removed after use (and at launch).
- All Git calls via argv with `--` before paths. Patch files are passed to `git apply` as absolute
  paths (which can never be parsed as options).
- No external diff/merge tools, textconv or ext-diff (§19).
- Logs never include file contents or commit messages beyond length/hash.

## 5. Edge cases & failure modes

| Case | Expected behaviour |
|---|---|
| File modified externally between selection and action | Token mismatch → `StaleDiff`, diff reloads, nothing changes. |
| File modified externally between check and apply | Inside writer lock; worktree change can still race: post-apply verification detects, index rolls back / recovery copy reported. |
| `index.lock` exists | `IndexLocked` error with Retry; never auto-delete. |
| Partially staged file, stage more lines | Patch built from current unstaged diff (index→worktree) — staged lines untouched; verified. |
| Multiple nearby hunks, select lines in both | One patch with both hunks; context preserved; property-tested. |
| Selected deletion adjacent to unselected addition | Table semantics; golden tests. |
| CRLF file | Bytes preserved; `\r` not shown, "CRLF" badge; tests with mixed line endings. |
| No trailing newline | Marker semantics; dedicated tests; refuse ambiguous cases. |
| Unicode / spaces / leading dash / newline in path | `-z` parsing, quoted path decoding, argv; tests. |
| Executable bit change only | File-level "Stage mode change" item. |
| Symlink | File-level only. |
| Rename (staged) | Shown `old → new`; unstage file-level restores both; line-level per §4.4. |
| Binary | File-level only, size shown, Quick Look. |
| Empty file added | "Empty file"; stage file-level. |
| Large file (> 20 MB) | Truncated view, line actions disabled. |
| Git LFS pointer files | Shown as text pointer with "LFS pointer" badge (LFS management is post-V1). |
| Commit hook hangs | Cancel button on running commit → kills process group; message preserved. |
| Commit with no profile | Disabled + resolution path. |
| Amend on a pushed commit | Warning row; allowed (force push is Phase 4). |
| Amend with nothing staged | Message-only amend allowed and labelled "Amend Message". |
| Unborn branch (first commit) | Staged diff against empty tree; commit creates root. |
| Conflicted files present | Commit disabled ("Resolve conflicts first"); listed in Conflicts. |
| Submodule with dirty content | Shown read-only with "Submodule has changes"; no discard. |
| `.gitattributes` `-diff`/binary | Treated as binary. |

## 6. ADRs to write

- **ADR-0011** Diff renderer (spike numbers, decision, reusable `CodeLinesView`).
- **ADR-0012** Syntax highlighting (tree-sitter grammars, limits, binary size impact, lazy spans).
- **ADR-0013** Partial staging algorithm (selection table, token, check/apply/verify/rollback,
  unsupported list).
- **ADR-0014** Git hooks policy (run as Git does, visible output, explicit no-verify).
- **ADR-0025 (P3)** Discard recovery store (location, retention, Trash for untracked).
- **ADR-0026 (P3)** Canonical diff invocation and byte-exact patch model.
- **ADR-0027 (P3)** Per-repository write serialization and `RepoRevision` (precursor to ADR-0015).
- **ADR-0028 (P3)** Commit identity application (env-only, amend author rules, repo-config override note).
- **ADR-0029 (P3)** Word-level diff algorithm (own Myers on tokens vs `similar` crate) — dependency decision.

## 7. Open questions / spikes

| Spike | Question | Decision criteria |
|---|---|---|
| S1 Renderer | TextKit 2 vs custom row renderer | §4.8 numbers; choose the simplest that meets all criteria. |
| S2 Tree-sitter cost | Binary size per grammar; parse time for a 50k-line file | Total grammar weight ≤ 15 MB (else trim set); parse 50k lines < 300 ms off-main. |
| S3 Filters / autocrlf | Which conversions break worktree-side `git apply` | Fixture matrix (autocrlf true/input, `text eol=crlf`, LFS filter); outcome = allow/refuse table in ADR-0013. |
| S4 Index-verify cost | Cost of full `ls-files -s` snapshot on a 100k-file repo | If > 100 ms, use path-scoped comparison + checksum. |
| Q1 | Should line selection also allow selecting context lines for "Keep only" semantics? | No by default; revisit after usability check. |
| Q2 | Focus Diff shortcut | Pick one that conflicts with no standard macOS binding; document in menus. |
