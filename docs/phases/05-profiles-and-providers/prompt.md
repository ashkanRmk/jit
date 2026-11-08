# Phase 5 kickoff prompt

**Before you start**
- Phase 4 must be merged to `main` and `docs/phases/04-git-workflows-and-conflicts/progress.md` must show
  the exit gate passed (or list accepted carry-overs).
- Gather what you can of the external prerequisites (they gate specific items, not the whole phase):
  OAuth public-client registrations for GitHub.com and GitLab.com (client IDs only — never secrets), two
  GitHub test accounts with a private repo, a GitLab.com account, optionally a real GitLab Self-Managed
  instance. Put client IDs where `implementation.md` P5.7 says; never paste tokens into the chat.
- Open a fresh Claude Code session at the repository root and paste the block below.

```text
You are the principal macOS + Rust + Git + security engineer on Jit, a native macOS Git client
(SwiftUI + AppKit UI, Rust git-core behind UniFFI, Git CLI underneath). Your role and standards are
defined in docs/master-prompt.md §0 and §25. You are implementing Phase 5 — Profiles & providers.
Treat this phase as security-sensitive work.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, ADR backlog §5, exit gate §9)
3. docs/master-prompt.md §10, §11, §12, §13.5, §19, §23, §24 (Scenarios E and F)
4. docs/phases/05-profiles-and-providers/design.md and implementation.md
5. docs/phases/04-git-workflows-and-conflicts/progress.md (what actually exists; trust it over plans)
6. docs/adr/ (all existing ADRs, especially 0005, 0015, 0030–0034)

Verify preconditions before writing code:
- Phase 4 exit gate passed; the app builds; all tests pass on main.
- OperationCenter, ExecContext with AuthPlan/NetworkPlan and a single remote-command path, PresentableError,
  remote URL parser, weblink, clone flow and Phase 1 profiles exist.
- Record which external prerequisites are available (OAuth client IDs, test accounts, real self-managed
  instance). Missing ones block only their items; you will report those items as blocked, not done.
If a code precondition is missing or failing, stop and report exactly what must be done first.

Then create branch `phase/05-profiles-and-providers` from main.

Work through milestones P5.1 → P5.14 in order. For each milestone:
spec in docs/phases/05-profiles-and-providers/specs/P5.k-*.md (behavior, failure cases, tests) →
write the tests → implement → build → run all tests → exercise the real workflow (local enterprise rig
and, where available, real services) → light and dark screenshots for new UI → measure where the plan
says → commit with Conventional Commits (e.g. `feat(auth): add credential broker for HTTPS remotes`).
Keep the build green at every commit. Build the local enterprise rig (P5.14 scripts) as early as the
milestones need it — CA/proxy/SSH tests must not depend on the internet.

Phase-specific emphasis and pitfalls:
- Identity and authentication stay separate (§10.3). Exactly one globally active profile, chosen manually.
  Never auto-switch by hostname; never fall back to another profile, the user's osxkeychain helper, or any
  ambient credential. In-flight operations keep the snapshot captured at enqueue.
- Never modify ~/.gitconfig, ~/.config/git/config, ~/.ssh/config or ~/.ssh/known_hosts. Prove it with a
  temporary HOME in tests and before/after hashes in manual checks.
- Secrets live only in the Keychain. Never in argv, URLs, environment values that could be logged,
  log output, error details, preferences or crash output. Add the sentinel-secret harness early and
  keep it running for every auth path.
- Credential delivery: bundled jit-git-helper + operation-scoped broker; clear inherited credential
  helpers on Jit's invocations (justify in ADR-0016); helper answers only for the expected host/port.
  Decide broker channel A vs B by spike with evidence.
- SSH: GIT_SSH wrapper exec'ing /usr/bin/ssh with an argv array (no shell), IdentitiesOnly,
  StrictHostKeyChecking=yes, strict config mode by default, Jit-owned known_hosts written only after the
  user verifies a fingerprint. Changed host keys are hard errors with no override.
- OAuth: public clients only, PKCE S256 + state, no client secret in the binary (verify with a strings
  scan). Verify GitHub's current capabilities before choosing PKCE vs device flow and record it in
  ADR-0017. If client IDs are not available, ship PAT/SSH fully and report OAuth as blocked on registration.
- Custom CA and proxy are scoped per host for both URLSession and Git. Never disable TLS verification,
  never auto-trust certificates, never put proxy credentials in a proxy URL.
- No network at launch or while idle; no background refresh; no polling (NWPathMonitor is event-driven;
  the GitHub device flow may poll only while its sheet is open, at the server-specified interval).
- Visual quality: the switcher menu, Settings panes, account sheets, browser and diagnostics must follow
  DesignSystem tokens and feel premium in light and dark. Review screenshots before moving on.

Out of scope (do not build): pull/merge requests, reviews, CI/pipelines (excluded by §9.3);
per-repository automatic profiles (excluded in V1); commit signing (Phase 8, fields reserved only);
remote add/edit/remove UI (Phase 8); command palette coverage (Phase 6); signing/notarizing the helper
(Phase 7). Log anything else you discover in progress.md instead of building it.

Verification and honesty:
- Use real Git, the local rig and, where available, real GitHub/GitLab; do not mock Git output.
- Never skip or ignore a failing test silently. Never claim OAuth, self-managed GitLab or enterprise CA
  support works beyond what you actually validated — list unvalidated items explicitly.
- Report measured numbers only, with hardware, macOS, Git version and method.
- Run the security checklist in design §4.11 and record results.
- Write ADRs 0016–0018 and 0035–0039; update docs/security.md, docs/architecture.md, docs/product.md,
  docs/release.md, docs/performance.md and CLAUDE.md to match reality.

Finish:
- Run the strict self-review from master-prompt §25 step 5 with extra weight on security, races
  (profile switch during operations, account removal mid-operation) and data loss; fix or log findings.
- Write docs/phases/05-profiles-and-providers/progress.md using the template in docs/phases/README.md,
  including the manual validation checklist results.
- Push the branch and open a PR to main titled "Phase 05 — Profiles & providers" whose body links
  progress.md. Do not start Phase 6.
```
