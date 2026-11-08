# Phase 7 — kickoff prompt

**How to use.** Merge Phase 6 first. Before starting, decide what you can provide — the agent will ask:

- A **Developer ID Application** certificate in your login keychain and your Team ID.
- Notarization credentials stored by you (the agent must not type secrets):
  `xcrun notarytool store-credentials jit-notary --key <AuthKey.p8> --key-id <ID> --issuer <UUID>`
- Final bundle identifier, app name, version, copyright holder.
- A way to run clean macOS VMs (UTM / tart, ~60 GB free) for macOS 26 and the latest macOS, and
  whether you want an Intel build at all (only Intel Macs on macOS 26 could run it) and have an Intel Mac.
- Real accounts for scenarios E/F (two GitHub accounts + one self-managed GitLab), or accept the
  Phase 5 local test rig.

Without signing credentials the phase still runs and ends as **blocked on credentials** with every
local step verified. Open a fresh Claude Code session at the repository root on an up-to-date `main`
and paste the block below.

```text
You are the principal macOS release engineer and security engineer for Jit, a native macOS Git
client written entirely in Swift, macOS 26+, native Liquid Glass design (role and standards:
docs/master-prompt.md §0, §2, §25, §26; ADR-0002 and ADR-0006 amend the master prompt — there is no
Rust core, so the master prompt's Rust build/packaging steps don't apply). You are starting Phase 7 —
Packaging & Release.

Read first, in order:
1. CLAUDE.md
2. docs/roadmap.md (invariants §6, ADR backlog §5 — ADR-0019 and ADR-0020, exit gate §9),
   docs/adr/0002-pure-swift-core.md, docs/adr/0006-platform-baseline-and-liquid-glass.md
3. docs/master-prompt.md §13.4, §19, §20, §21, §23, §24 (scenarios A–G), §22 Phase 7
4. docs/phases/07-packaging-and-release/design.md and implementation.md
5. docs/phases/06-polish-and-performance/progress.md (state you inherit, carry-overs)
6. docs/phases/05-profiles-and-providers/progress.md (jit-git-helper location, test rig for CA/proxy)
7. docs/performance.md, docs/security.md, docs/architecture.md

Preconditions — verify before changing anything; if one fails, stop and tell me exactly what to do:
- Phase 6 progress.md says complete (or carry-overs I accepted).
- main builds Release and all tests pass (run them).
- Full Xcode selected; a trial x86_64 build of the GitCore package target succeeds (unless I choose
  arm64-only).
- Ask me the questions in implementation.md §1 (Developer ID, Team ID, notary keychain profile name,
  bundle ID, version, universal vs arm64-only, VM access, Intel Mac, real accounts vs test rig) and
  record my answers in
  progress.md. Never ask me to paste a private key, password or token into the chat; I store
  credentials myself with `xcrun notarytool store-credentials` and the keychain.

Then create branch `phase/07-packaging-and-release` and work through milestones P7.1 → P7.12 in order.
For each milestone: spec in docs/phases/07-packaging-and-release/specs/ → tests/check scripts →
implement → run → verify → update docs → commit (Conventional Commits, e.g. `build(release): add
inside-out signing script`).

Phase rules and emphases:
- Every §20 step maps to an idempotent script in scripts/release/ (01-build-app … 09-validate, see
  design.md §4.7 — §20 steps 1–3 collapse into one Xcode build because there is no separate core
  build) plus release.sh with --adhoc, --skip-notarize, --from-step. `set -euo pipefail`, no secrets echoed, outputs in build/
  (git-ignored). Credential files and local env files are git-ignored. Never commit signing material.
- Universal: one Xcode Release archive with ARCHS = arm64 x86_64 (set in macos/project.yml) builds the
  app, the local Swift package targets and the JitGitHelper executable (embedded at
  Contents/Helpers/jit-git-helper). A script asserts every Mach-O in the bundle has both slices and
  that dev-only targets (TestRig, JitBench, GitTestKit) are not embedded.
- Bundled Git (ADR-0019): build from a pinned, signature/hash-verified source tarball with
  RUNTIME_PREFIX, universal, pruned by an allowlist proven by running the whole integration suite
  against it (GIT_TRACE to catch missing helpers). Decide system libcurl vs bundled curl with the
  Phase 5 custom-CA/proxy rig on macOS 26 and latest. Replace hardlinks with symlinks. Isolate system
  config (don't inherit Apple's osxkeychain helper) while respecting ~/.gitconfig and repo config.
  Keep system /usr/bin/ssh. Meet GPLv2 obligations (source tarball + build script + written offer,
  license in Acknowledgements).
- The app must never implicitly run /usr/bin/git (xcrun shim) or trigger a CLT install prompt.
  Resolution: custom (validated) → bundled → dev-only fallbacks → onboarding sheet.
- App icon: a layered Liquid Glass icon authored in Icon Composer (verify the format the current Xcode
  expects), checked in default/dark/clear/tinted appearances; DMG background artwork matches it.
- Hardened Runtime on all code; minimal entitlements; no App Sandbox for V1 unless you find a strong
  reason — document the decision and compensating controls (ADR-0045).
- Sign inside-out with `codesign --force --timestamp --options runtime`; never sign with --deep (only
  verify with it). Notarize the signed DMG with `xcrun notarytool submit --wait --keychain-profile`,
  fetch and summarize the log on failure, staple, then validate with `xcrun stapler validate`,
  `spctl --assess` (DMG and app) and `codesign --verify --strict --deep`.
- Clean-machine verification on fresh macOS 26 and latest VMs with no CLT (`xcode-select -p` must fail),
  DMG downloaded so it is quarantined. Run scenarios A–G (§24) and fill the checklist in
  docs/release.md with expected / observed / evidence / pass-fail. Label anything verified only on the
  test rig, only under Rosetta, or not verified. Judge Liquid Glass visuals on real hardware (VMs may
  lack full GPU acceleration).
- Re-run the Phase 6 benchmarks on the app installed from the DMG; regressions beyond Phase 6
  thresholds are release blockers unless explained and accepted by me.
- Updates (ADR-0020): recommend V1 without automatic update checks; no background network.
- Keep all roadmap §6 invariants (data safety, no idle network, no secrets in argv/URLs/logs).

Out of scope (do not build): new features, Mac App Store build, auto-updater implementation, bundled
OpenSSH/LFS/merge tools, publishing anything publicly. Publishing a GitHub Release or uploading the
DMG anywhere is an outward-facing action — prepare it, then ask me for explicit approval first.

Honesty: never claim signing, notarization, stapling or Gatekeeper acceptance that you did not observe
in command output. If the Developer ID certificate or notary credentials are unavailable, complete and
verify every local step with ad-hoc signing, and set progress.md status to
"blocked (Developer ID certificate and notarization credentials)" with the exact remaining commands.
Don't skip failing tests or checks.

Write docs/phases/07-packaging-and-release/progress.md using the template in docs/phases/README.md;
keep it updated and finalize it at the end with artifact SHA-256, signing identity (name only),
notarization submission ID and status, and the A–G results. Update docs/release.md, docs/security.md,
docs/performance.md, docs/architecture.md, README.md (install section), CLAUDE.md Commands, and write
ADRs 0019, 0020, 0045–0049. Run a strict self-review (§25 step 5) before finishing.

When the exit checklist in implementation.md §6 is satisfied (or the blocked path is fully executed),
push the branch and open a PR to main titled "Phase 07 — Packaging & release" whose body links
progress.md. Do not start Phase 8.
```
