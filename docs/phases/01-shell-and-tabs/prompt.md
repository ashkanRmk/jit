# Phase 1 — kickoff prompt

**Before you start**
- Phase 0 must be merged to `main` with `docs/phases/00-foundation/progress.md` marked complete.
- Open a fresh Claude Code session at the repository root and paste the block below.

```text
You are the principal engineer building Jit, a premium, ultra-lightweight native macOS Git client:
100% Swift 6 (SwiftUI + AppKit), native Liquid Glass design on macOS 26+, a Foundation-only GitCore
module driving the Git CLI. Your role and standards: docs/master-prompt.md §0, §25–§26, as amended by
docs/adr/0002-pure-swift-core.md (no Rust/FFI) and docs/adr/0006-platform-baseline-and-liquid-glass.md.
You are implementing, not advising.

This session covers PHASE 1 — NATIVE SHELL & REPOSITORY TABS only.

Read first, in this order:
1. CLAUDE.md
2. docs/roadmap.md (owner decisions at the top; §3: identity-only profiles were moved into this phase;
   invariants §6; gate §9) and docs/adr/0002, 0005, 0006
3. docs/master-prompt.md §4.1–§4.6, §6.2, §10.1–§10.2, §14, §15.2–§15.4, §17
4. docs/phases/00-foundation/progress.md (what actually exists, carry-overs)
5. docs/phases/01-shell-and-tabs/design.md
6. docs/phases/01-shell-and-tabs/implementation.md
7. docs/phases/README.md (workflow + progress.md template)
8. docs/design-system.md (glass usage rules, verified APIs)
9. The existing code: macos/ (App, Packages/JitKit), scripts/, docs/adr/

Preconditions (implementation.md §1): Phase 0 complete, build and tests green on main. If not, STOP
and report what is missing.

Then:
- Create branch `phase/01-shell-and-tabs` from main.
- Work milestones P1.1 → P1.10 in order. For each: spec in docs/phases/01-shell-and-tabs/specs/ →
  tests → implement → build → run tests → exercise against real repositories → screenshots in light
  and dark → commit (Conventional Commits, small commits).

Emphases and pitfalls:
- Idle means idle. Only the visible tab of an active app runs an FSEvents stream; background app and
  inactive tabs do no work. No timers, no polling — debounced writes use one cancellable one-shot task.
- Run status with --no-optional-locks / GIT_OPTIONAL_LOCKS=0, otherwise status rewrites .git/index,
  which triggers FSEvents, which triggers status: a CPU feedback loop. Test for it.
- Observation granularity: the tab bar observes TabModel only; RepositorySession splits stable and
  changing properties. Never publish a whole repository struct for one field change.
- Startup: show the window from cached session data first; open the active tab's RepositoryHandle
  after the first frame; other restored tabs stay unloaded until shown.
- GitCore: one `actor RepositoryHandle` per open repository is the single serialization point (no second
  queue); status parsing is byte-level with compact storage; task cancellation kills Git process groups.
  GitCore never imports AppKit/SwiftUI; Services uses it directly (no bridge layer).
- Liquid Glass chrome, opaque content: unified NSToolbar, glass capsule tab strip in ONE glass
  container (no nested glass), system glass sidebar and inspector via NSSplitViewController, profile
  capsule in the toolbar, system popovers/sheets. The new-tab page, recents, workbench and drop overlay
  are opaque content. Use the DesignSystem glass helpers or system components only — no
  NSVisualEffectView stacks or custom blurs. Glass morphs only on user action (≤ 240 ms); support
  Reduce Transparency, Increase Contrast and Reduce Motion. Verify glass API names in the SDK.
- The tab bar is a flagship piece of chrome: native-feeling drag reorder, overflow, middle-click,
  keyboard cycling (⌃Tab, ⌘⇧[ / ⌘⇧]), VoiceOver, Reduce Motion. ⌘1–⌘3 are reserved for workbench
  modes — don't bind them to tabs.
- Profiles here are identity-only (name/email/optional committer, display name, color). Never write
  ~/.gitconfig; "Fill from Git config" only reads. Build ProfileSnapshot now; Phase 3 uses it.
  Never auto-select a profile when the active one is deleted.
- Honest UI: no Branches header without branches, no Clone/Browse buttons, no Git/Branch menus until
  they have working items.
- All colors, fonts, spacing, radii and motion come from DesignSystem tokens. Extend tokens rather than
  hardcoding.

Out of scope: graph/history/branch lists (Phase 2), file lists/diff/staging/commit (Phase 3),
clone/fetch/pull/push/checkout (Phase 4), provider browsing/auth/SSH/PAT/OAuth (Phase 5), command
palette and density UI (Phase 6), signing/release (Phase 7). Do not add Rust or any FFI layer.

Verification and honesty:
- Measure startup, idle CPU and GPU (active and background, glass chrome visible), tab switching,
  memory over 50 open/close cycles, and idle network with a release build (implementation.md §4). Report real numbers with method and
  hardware. Never fabricate results; never skip failing tests silently.
- Prove ~/.gitconfig is unchanged (checksum before/after).

Finish:
- Update the docs in implementation.md §5; write ADR-0007 and ADR-0008.
- Write docs/phases/01-shell-and-tabs/progress.md from the template in docs/phases/README.md.
- Run a strict self-review (master-prompt §25 step 5); fix blockers, log the rest.
- Push the branch and open a PR to main titled "Phase 01 — Native shell & repository tabs" linking
  progress.md.
- Do not start Phase 2.
```
