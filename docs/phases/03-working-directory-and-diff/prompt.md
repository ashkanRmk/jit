# Phase 3 — Kickoff prompt

**How to use:** merge Phase 2 to `main` first. Open a fresh Claude Code session at the repository root
and paste the block below. This is the longest, most safety-critical phase; expect it to span several
sessions. When resuming in a new session, paste the same prompt — it tells the agent to continue from
`progress.md`.

**Before you start:** confirm `docs/phases/02-graph-and-navigation/progress.md` says complete (or lists
accepted carry-overs), that an active identity-only profile can be selected (Phase 1), and that full
Xcode is selected.

```text
You are the principal macOS / Swift / Git engineer, security engineer and product designer described in
docs/master-prompt.md §0, implementing Phase 3 (Working directory & diff) of Jit, a native macOS 26+
Git client written entirely in Swift (SwiftUI + AppKit, Foundation-only GitCore module, Git CLI).
ADR-0002 (pure Swift, no Rust) and ADR-0006 (macOS 26+, Liquid Glass chrome, opaque content) override
the master prompt where they differ — read "Rust core" there as GitCore.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, perf budget §7, exit gate §9)
3. docs/master-prompt.md §3, §4.5, §6, §7 (entire — §7.4 and §7.5 are critical), §9.1 Files, §14,
   §16, §18, §19, §23, §24 Scenario C
4. docs/phases/03-working-directory-and-diff/design.md and implementation.md
5. docs/phases/02-graph-and-navigation/progress.md, and all ADRs in docs/adr/
6. If docs/phases/03-working-directory-and-diff/progress.md already exists, you are resuming:
   continue from the first unfinished milestone.

Preconditions: verify every item in implementation.md §1 against the actual code. Implement anything
missing as milestone P3.0 and record it. If the environment is broken, stop and tell me what to fix.

Work on branch `phase/03-working-directory-and-diff` from main (or continue it if it exists).
Execute milestones P3.1 → P3.11 in order. For each milestone: write a short spec in
docs/phases/03-working-directory-and-diff/specs/ → write tests → implement → build → run all tests →
exercise the real workflow on real repos → screenshots (light and dark) for UI → measure where relevant
→ commit (Conventional Commits, e.g. `feat(diff): …`, `test(apply): …`).

Phase emphases:
- Data safety outranks everything (§26). Build and prove the safety core (P3.3 byte-exact diff model,
  P3.4 patch builder with snapshot token → git apply --check → apply → independent verification →
  rollback) entirely in GitCore, tested with `swift test`, with the full §7.4 matrix and seeded property
  tests BEFORE wiring line actions into the UI. Never use --unidiff-zero, --recount, --reject or --3way; never hand-edit index or
  worktree text as a substitute for patch application.
- Every destructive or partial test must assert that unrelated lines, files and index entries are
  byte-identical afterwards.
- When a granular operation cannot be done safely (binary, symlink, submodule, type change, filter /
  EOL conversion that fails the check, ambiguous final newline, ignore-whitespace view, truncated diff),
  disable it with a clear explanation. No risky workarounds.
- Treat diff bytes as bytes: CRLF, missing final newline and non-UTF-8 content must survive
  parse → patch → apply exactly.
- Labels must state their target: "Stage Lines" (index), "Unstage Lines" (index), "Discard Lines…" and
  "Keep Only Selected Lines…" (working tree, destructive, confirmed). Do not use "Accept"/"Reject" here.
- Discards write a recovery copy first (ADR-0025); untracked files go to the Trash.
- Commits use the active profile's identity snapshot via GIT_AUTHOR_*/GIT_COMMITTER_* env only; prove
  with tests that no config file changes. Hooks run as Git runs them with visible output; no-verify only
  on explicit request (ADR-0014).
- Decide the renderer (ADR-0011) and highlighting (ADR-0012: tree-sitter C runtime vs hand-written Swift
  lexers) by measured spikes. No WebView, Monaco or CodeMirror. Only visible rows are materialized as
  Strings; highlighting is lazy per viewport and never blocks first paint.
- Memory discipline (ADR-0005): DiffDocument is one byte buffer plus flat line/hunk records — no class or
  String per line; inactive tabs release documents.
- All mutations go through the single RepositoryHandle FIFO write gate (ADR-0027) — remember actor
  reentrancy: an await inside an actor method lets other calls in, so the gate must serialize explicitly.
  Phase 4 lifts it into the OperationCenter; do not build a second queue.
- Liquid Glass (ADR-0006): diff body, gutters, file rows and blame are opaque content; glass only for the
  floating layout switcher, change navigator, find bar and selection-action capsule (one glass container),
  the panel header and the composer action bar. Verify API names against the macOS 26 SDK; check Reduce
  Transparency / Increase Contrast.
- The diff viewer is a flagship surface: review screenshots in both themes and refine the diff colours,
  gutters, hunk headers and selection states until they are calm, readable and original.

Out of scope (do NOT build; leave absent or clearly disabled with explanation): conflict resolution
(Phase 4 — list conflicted files only), push/pull/fetch, branch operations, stash/reset/patch export
(Phase 8), signing configuration UI (Phase 8), provider features (Phase 5), external diff/merge tools.

Verification and honesty: use real temporary Git repositories via GitTestKit, never mocked Git output.
Run property tests with at least 50,000 cases locally before declaring P3.4 done and record the count.
Release builds for performance; report measured numbers with hardware, macOS, Git version and repo size,
including misses and their bottlenecks. Never fabricate results; no skipped tests without a reason.

At the end: write docs/phases/03-working-directory-and-diff/progress.md using the template in
docs/phases/README.md, update the docs listed in implementation.md §5, run the strict self-review from
master-prompt §25 step 5 (focus: data-loss risks, races, main-thread blocking, leaks), fix or log the
findings, push the branch and open a PR to main titled "Phase 03 — Working directory & diff" linking
progress.md. Do not start Phase 4.
```
