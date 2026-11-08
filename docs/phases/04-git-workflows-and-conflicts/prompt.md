# Phase 4 kickoff prompt

**Before you start**
- Phase 3 must be merged to `main` and `docs/phases/03-working-directory-and-diff/progress.md` must show
  the exit gate passed (or list accepted carry-overs).
- Have network access for the public-clone demo. No credentials are needed in this phase.
- Open a fresh Claude Code session at the repository root and paste the block below.

```text
You are the principal macOS + Swift + Git engineer on Jit, a native macOS Git client written entirely in
Swift (SwiftUI + AppKit UI in the native Liquid Glass design language, a Foundation-only GitCore module,
Git CLI underneath). Your role and standards are defined in docs/master-prompt.md §0 and §25; ADR-0002
(pure Swift, no Rust/UniFFI — read "Rust core" in the master prompt as GitCore) and ADR-0006 (macOS 26+,
Liquid Glass chrome, opaque content) amend it. You are implementing Phase 4 — Everyday Git workflows &
conflicts.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, ADR backlog §5, exit gate §9)
3. docs/master-prompt.md §8, §9.1, §13.5, §14, §16, §23, §24 (Scenario D)
4. docs/phases/04-git-workflows-and-conflicts/design.md and implementation.md
5. docs/phases/03-working-directory-and-diff/progress.md (what actually exists; trust it over plans)
6. docs/adr/ (all existing ADRs, especially 0002, 0005, 0006, 0013, 0014)

Verify preconditions before writing code:
- Phase 3 exit gate passed; the app builds; `swift test` (GitCore/Services) and the Xcode test suites pass
  on main.
- ProcessRunner (posix_spawn, own process group, Task cancellation → killpg), typed GitError, GitTestKit,
  RepositorySession, FSEvents invalidation, active-profile snapshot, the Phase 3 `actor RepositoryHandle`
  writer with RepoRevision, and the reusable text renderer exist.
- Record the Git version and whether it supports `merge-tree --write-tree` (>= 2.38) and zdiff3 (>= 2.35).
If anything is missing or failing, stop and report exactly what is missing and what must be done first.
Do not paper over a missing precondition with stubs.

Then create branch `phase/04-git-workflows-and-conflicts` from main.

Work through milestones P4.1 → P4.15 in order. For each milestone:
spec in docs/phases/04-git-workflows-and-conflicts/specs/P4.k-*.md (behavior, failure cases, tests) →
write the tests → implement → build → run all tests → exercise the real workflow in the app →
light and dark screenshots for new UI → measure where the plan says → commit with Conventional Commits
(e.g. `feat(ops): add explicit two-step pull`). Keep the build green at every commit.

Phase-specific emphasis:
- P4.1 first and properly: lift the Phase 3 `actor RepositoryHandle` into the operation framework — it
  stays the ONE serialization primitive (strict FIFO even across suspension points; reads nonisolated on
  snapshots). Do not add a second lock or queue. Every mutation goes through OperationCenter → the handle,
  carries a RepoRevision, and destructive calls require a ConfirmationToken that only the confirmation
  flow can mint (Swift access control). Progress is a bounded AsyncStream parsed from `git --progress`
  stderr bytes; cancellation is Task cancellation → killpg on the child's process group.
- Remote operations are strictly non-interactive in this phase: GIT_TERMINAL_PROMPT=0, failing askpass,
  SSH BatchMode=yes and StrictHostKeyChecking=yes, LC_ALL=C for stable stderr. ssh-agent and public HTTPS
  must work; everything else must fail fast and be explained. Build the ExecContext/AuthPlan/NetworkPlan
  hook exactly so Phase 5 can add credentials without touching call sites.
- Pull is explicit fetch + integrate, fast-forward-only by default; never integrate implicitly.
- Never use plain `--force`. Force push is force-with-lease with an explicit expected OID plus
  --force-if-includes, only through the destructive sheet.
- Commit-creating operations (merge, revert, cherry-pick, rebase, pull with merge/rebase) use the
  profile snapshot captured at enqueue; cherry-pick/rebase keep original authors. No active profile =
  blocked with a clear path to choose one.
- The conflict resolver reads real Git state (unmerged index stages), labels ours/theirs per operation
  (rebase inverts them — say so; never "local/remote"), saves atomically behind a file-hash check, and
  marks resolved only on explicit confirmation. Opening a file must never resolve it.
- Every abort/refusal/cancel test asserts a full RepoFingerprint (HEAD, refs, index, working tree,
  state files) is identical before and after. Add the fingerprint helper to GitTestKit first.
- Visual quality (ADR-0006): Liquid Glass only on chrome, using system components and the official APIs
  (verify names against the installed SDK — e.g. SwiftUI glassEffect / GlassEffectContainer /
  glassEffectID / .glass and .glassProminent button styles; AppKit NSGlassEffectView /
  NSGlassEffectContainerView). The activity item is a standard toolbar item (system glass); the
  operation banner is a floating tinted glass bar; confirmation and clone sheets are standard system
  sheets; the resolver's navigator and actions are one floating glass control group. The ours / theirs /
  base / result text panes, file lists and graph stay OPAQUE — no glass or blur behind code, no glass per
  row or per block. Respect Reduce Transparency, Increase Contrast and Reduce Motion. Everything follows
  DesignSystem tokens, looks premium in light and dark, and stops all drawing (CPU and GPU) when idle.
  Review screenshots (light, dark, Reduce Transparency) before moving on.

Out of scope (do not build): stored credentials, PAT/OAuth, SSH key selection or passphrase prompts,
host-key acceptance UI, custom CA, proxy, provider browser (Phase 5); interactive rebase, reset, stash,
drop/reorder commits, reflog explorer, tag creation, remote add/edit/remove, submodule resolution
(Phase 8); command palette (Phase 6). If you see a need for these, log it in progress.md.

Verification and honesty:
- Run everything against real temporary repositories (GitTestKit, `swift test`) and local bare remotes;
  do not mock Git output.
- Never skip or ignore a failing test silently; never claim a feature works without exercising it.
- Report measured numbers only, with hardware, macOS, Git version and method.
- Write ADRs 0015 and 0030–0034 as decisions are made; update docs/architecture.md, docs/security.md,
  docs/product.md, docs/performance.md, docs/design-system.md and CLAUDE.md to match reality.

Finish:
- Run the strict self-review from master-prompt §25 step 5 (data loss, races, main-thread blocking,
  leaks, idle CPU, security, UX consistency) and fix or log findings.
- Write docs/phases/04-git-workflows-and-conflicts/progress.md using the template in
  docs/phases/README.md, with evidence for every claim.
- Push the branch and open a PR to main titled "Phase 04 — Everyday Git workflows & conflicts" whose
  body links progress.md. Do not start Phase 5.
```
