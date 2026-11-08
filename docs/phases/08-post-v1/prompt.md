# Phase 8 — Post-V1: kickoff prompt (one epic at a time)

## How to use / before you start

- Phase 8 is a backlog of independent epics. Start **one epic per session**. Replace every `<EPIC>` in
  the block below with one ID from this table before pasting:

  | `<EPIC>` | Epic | Hard dependencies |
  |---|---|---|
  | `stash` | Stash manager | — |
  | `reflog` | Reflog explorer & recovery | — |
  | `reset` | Reset soft/mixed/keep/hard | `reflog` recommended |
  | `tags` | Tag management | — |
  | `rebase-interactive` | Interactive rebase | `reflog` |
  | `commit-surgery` | Drop / reorder / edit older messages / squash | `rebase-interactive` |
  | `history-filters` | Additional history filtering | — |
  | `worktrees` | Worktree manager | — |
  | `patches` | Patch create/apply/export, native sharing | — |
  | `remotes` | Advanced remote management | — |
  | `branch-history` | Advanced branch manipulation, force-with-lease | `rebase-interactive`, `reflog` |
  | `signing` | Commit/tag signing | — |
  | `submodules` | Submodule management | — |
  | `lfs` | Git LFS | — |

- Suggested order: stash → reflog → reset → tags → rebase-interactive → commit-surgery →
  history-filters → worktrees → patches → remotes → branch-history → signing → submodules → lfs.
- V1 must be released first (Phase 7 exit gate). Make sure `main` is up to date and the working tree is
  clean. Signing tests need `gpg` and/or `ssh-keygen`; LFS tests need `git-lfs` or the spike's decision.

```text
You are the principal macOS / Swift / Git engineer for Jit — a 100% Swift, macOS 26+ Git client with the native Liquid Glass design language — working as described in docs/master-prompt.md §0 and §25 (ADR-0002 and ADR-0006 amend the master prompt: there is no Rust). You are implementing ONE post-V1 epic: <EPIC>.

1. Read, in this order:
   - CLAUDE.md (hard rules — they override convenience).
   - docs/roadmap.md (§5 architecture and ADR backlog, §6 invariants, §9 exit gate).
   - docs/master-prompt.md §9.2, §16, §7.4–7.5, §8, §10, §13.5, §19, §23, §26.
   - docs/phases/08-post-v1/design.md — the shared rules in §1–§4.1, the <EPIC> sections in §3 and §4.3, edge cases in §5, ADRs in §6, spikes in §7.
   - docs/phases/08-post-v1/implementation.md — §1 preconditions and the "Epic `<EPIC>`" milestones.
   - docs/phases/07-packaging-and-release/progress.md and every existing docs/phases/08-post-v1/progress-*.md.
   - The ADRs this epic touches in docs/adr/ (always 0002, 0005, 0006; plus 0013, 0014, 0015, 0016 where relevant).

2. Verify preconditions before writing code. Check: V1 exit gate passed in the Phase 7 report; the operation framework, writer queue, RepoRevision tokens, confirmation sheet and conflict resolver exist (find them in the code, don't assume); the epic's hard dependencies (implementation.md §1 table) have finished progress-<dep>.md reports; the bundled Git version supports every Git feature this epic uses (record the version check). If anything is missing, STOP and report exactly what is missing and what has to happen first. Do not build substitutes for missing V1 infrastructure.

3. Run `git status` and `git log -1`, then create branch `epic/<EPIC>` from up-to-date main. Create docs/phases/08-post-v1/progress-<EPIC>.md from the template in docs/phases/README.md (status: in progress) and update it as you go.

4. Work the epic's milestones in order (P8.<EPIC>.1, .2, …). For each one:
   a. Write a short spec at docs/phases/08-post-v1/specs/P8.<EPIC>.<k>-<slug>.md: observable behavior, risk class of every operation, failure/edge cases (start from design.md §5), tests.
   b. Write the named tests first (GitCore integration tests with Swift Testing on real temporary repositories via GitTestKit, run with `swift test`; local bare remotes for push/fetch cases). Destructive and rewrite tests must assert that unrelated files, index entries and refs are byte-identical afterwards.
   c. Implement through the existing layers: GitCore (Foundation-only, per-repository actor) → Services (RepositorySession / OperationCenter) → feature module. Reuse the operation framework, state machine, conflict resolver, patch builder, diff renderer and graph — do not add parallel mechanisms.
   d. Build, run all tests (`swift test` for GitCore/Services, Xcode unit and UI tests), exercise the real workflow in the app, and take light and dark screenshots (plus Reduce Transparency for screens with glass chrome) of every new screen and state into docs/phases/08-post-v1/screenshots/<EPIC>/.
   e. Commit with Conventional Commits (e.g. feat(stash): …, test(core): …, docs(adr): …). Each commit leaves the build green.
   If a milestone starts with a spike, do the spike, write the ADR with the evidence, then continue.

5. Epic-wide emphases:
   - Every mutating/destructive request carries the RepoRevision it was prepared against and fails with StaleState instead of running on changed state.
   - Destructive operations use the §16.3 confirmation sheet (what changes, what may be lost, recoverable and how, which repo/branch) with a specific primary button label, and record a RecoveryPoint (ADR-0050).
   - Rewrites of commits reachable from remote-tracking refs show the published-commits warning; the only force push is --force-with-lease with an explicit expected SHA. Never emit plain --force.
   - Git runs with argv arrays, fixed cwd, `--` separators, GIT_TERMINAL_PROMPT=0 and the sanitized environment. Editor/sequence-editor/askpass hooks point to the bundled jit-git-helper (JitGitHelper Swift target) with data passed via files/env, never interpolated into a command string. Temp files live in a per-operation 0700 directory and are removed afterwards.
   - Identity (committer, tagger, signing key reference) comes from the profile snapshot taken at operation start. Never modify ~/.gitconfig or ~/.ssh/config.
   - Nothing runs without a user action: no polling, no timers, no background fsck/LFS/remote work. Long operations are cancellable and kill the process group.
   - New colors/spacing/motion come only from DesignSystem tokens; respect Reduce Motion; keyboard equivalents for every drag; VoiceOver labels.
   - Follow the ADR-0006 glass/content split: new sheets, popovers, panels and palette entries use system Liquid Glass chrome (system components or official glass APIs in a container); new lists and editors (stash, reflog, rebase todo, worktree/remote/submodule rows, patch previews) stay opaque — no glass per row, no hand-made blur.
   - GitCore stays Foundation-only with compact value types and byte-level parsing (ADR-0005); no class per row.
   - In-progress Git states created by this epic are re-detected after relaunch and offer Continue/Skip/Abort.

6. Out of scope: any other epic (note discoveries in progress-<EPIC>.md under carry-overs instead); PR/MR management, code review, CI dashboards, hosted collaboration, AI features (§9.3); a Cloud Patch backend or any upload of repository content; changing V1 behavior beyond what this epic needs (if a V1 bug blocks you, fix it in a separate, clearly labelled commit and report it).

7. Verification and honesty: run the commands, read their output, and report what actually happened. Never fabricate test results, benchmarks or screenshots. Never mark a test skipped without a recorded reason. If something cannot be verified in this environment (e.g. no gpg, no LFS server), say so explicitly and keep the feature labelled accordingly. Measure the epic's performance checks (implementation.md §4) on a release build and record machine, macOS, Git version and method.

8. Before finishing, do a strict self-review (master-prompt §25 step 5): data-loss risks, stale-state races, main-thread blocking, background CPU, unbounded caches, security of new inputs, UX and visual consistency, outdated docs. Fix or log every finding.

9. Finish: complete the epic exit checklist (implementation.md §6), update the docs listed in implementation.md §5 (mark the epic's status in docs/roadmap.md), finalize progress-<EPIC>.md (status, evidence, performance table, deviations, carry-overs, next), push `epic/<EPIC>` and open a PR to main titled "Epic — <EPIC>" whose body links the progress report. Then stop. Do not start another epic.
```
