# Phase 7 — Packaging & release: implementation plan

Design: [`design.md`](design.md). Requirements: §13.4, §19, §20, §21, §24. ADRs: 0019, 0020, 0045–0049.

## 1. Preconditions

- [ ] Phase 6 `progress.md` shows exit gate passed (or carry-overs accepted by the user).
- [ ] `main` builds Release (arm64); all tests green; Phase 6 baseline in `scripts/benchmarks/baseline/`.
- [ ] Full Xcode selected; the x86_64 macOS SDK slice builds (`xcodebuild -showsdks`; a trial
      `ARCHS=x86_64` build of `GitCore` succeeds). No Rust toolchain is needed (ADR-0002).
- [ ] Ask the user (record answers in `progress.md`):
  - Developer ID Application certificate available in a keychain? Team ID?
  - Notarization credentials (App Store Connect API key preferred) — stored with
    `xcrun notarytool store-credentials <profile>` by the user, not by the agent typing secrets.
  - Final bundle identifier, app name, version (default `1.0.0`), copyright holder.
  - Ship universal (Intel Macs on macOS 26) or arm64-only? Access to an Intel Mac running macOS 26?
  - Ability to run macOS 26 and latest-macOS VMs (UTM/tart/Virtualization.framework, ≥ 60 GB disk)?
  - Real GitHub/GitLab/self-managed accounts for scenarios E/F, or use the Phase 5 test rig?
- [ ] Missing credentials do not block starting: follow the ad-hoc path (design §4.8).

## 2. Milestones

### P7.1 — Release configuration and versioning
- [ ] ADR-0049; single source of version (`release.env` / `--version`) feeding `CFBundleShortVersionString`,
      `CFBundleVersion`, DMG name, tag `vX.Y.Z`.
- [ ] Release build settings: dead-code stripping, `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`, strip
      installed products, deployment target 26.0, no debug-only code paths (benchmark and
      `-JitOpaqueChrome` hooks inert), dev-only targets (`TestRig`, `JitBench`, `GitTestKit`) excluded.
- [ ] `.gitignore`: `build/`, `*.p12`, `*.cer`, `*.p8`, `AuthKey_*.p8`, `*.provisionprofile`,
      `release.local.env`.
- Tests: `VersionConsistencyTests` (Info.plist values match `release.env` in a Release build; script check).
- Done when: Release build reports correct version everywhere.

### P7.2 — Universal app and helper
- [ ] `macos/project.yml` Release: `ARCHS = arm64 x86_64`, `ONLY_ACTIVE_ARCH = NO`, applied to the app,
      the local package targets and `JitGitHelper` (arm64-only if the user chose so — ADR-0049).
- [ ] `jit-git-helper` built in the same archive and embedded at `Contents/Helpers/` (Phase 5 path).
- [ ] `scripts/release/01-build-app.sh`: XcodeGen generate + clean universal Release archive.
- [ ] `scripts/release/03-verify-archs.sh` walks the bundle and asserts every Mach-O has both slices
      and that no dev-only target is embedded.
- Verification: `03-verify-archs.sh` passes; app launches natively and under `arch -x86_64` (Rosetta).
- Done when: universal app runs on arm64 and (Rosetta or Intel) x86_64.

### P7.3 — Bundled Git runtime build (ADR-0019)
- [ ] Spike: system libcurl vs bundled curl (design §7) — decide and record.
- [ ] `scripts/build/git-version.env` (version, tarball SHA-256, signing key fingerprint);
      `scripts/build/build-git.sh`: download to `build/`, verify signature/hash, build arm64 + x86_64
      with `RUNTIME_PREFIX`, `lipo`, install to staging.
- [ ] Prune `libexec/git-core` by allowlist; replace hardlinks with symlinks; minimal templates;
      bundled `etc/gitconfig` or `GIT_CONFIG_NOSYSTEM` decision.
- [ ] Add `LICENSE`, `VERSION`, `SOURCE.txt` (written offer + URL) into the bundle.
- Tests: `scripts/build/test-bundled-git.sh` — relocate the staged Git to a random path, run
  `git --version`, `git --exec-path`, init/commit/branch/merge/rebase/cherry-pick/clone(file://)/
  `git ls-remote https://…` (public, network-optional flag) and confirm exec-path points inside.
- Verification: run the full `GitCore` integration suite (`swift test`) with `JIT_GIT_PATH` pointing at
  the pruned bundled Git and `GIT_TRACE=1` logs checked for missing helpers.
- Done when: integration suite passes against the bundled Git on arm64 and x86_64 (Rosetta).

### P7.4 — Git resolution and onboarding fallback
- [ ] Resolution order per design §4.3 in `GitLocator` (`GitCore`) + settings binding in Services.
- [ ] Never exec `/usr/bin/git` unless CLT detected or user chose it.
- [ ] Onboarding sheet + Settings → Advanced → Git (path, version, source, custom picker, reset).
- Tests: `GitCoreTests.gitLocatorPrefersCustomThenBundled`, `gitLocatorSkipsXcrunShimWithoutCLT`
  (fake `xcode-select` result injected), `gitLocatorRejectsOldVersion`; Services
  `GitRuntimeSettingsTests`; UI `MissingGitOnboardingUITest` (launch with `JIT_GIT_PATH` invalid in a
  test build).
- Screenshots: onboarding sheet light/dark; settings pane light/dark.
- Done when: all paths tested; no implicit CLT prompt possible.

### P7.5 — App icon, About & Acknowledgements, license compliance
- [ ] Layered Liquid Glass app icon authored in Icon Composer (verify the current Xcode's icon format;
      fallback asset catalog only if required); checked in default/dark/clear/tinted appearances and at
      16–1024 pt in Finder, Dock, Spotlight.
- [ ] About window (version, build, short SHA) — standard system window styling.
- [ ] Generated third-party license list (Swift packages from `Package.resolved` with their LICENSE
      files; tree-sitter/grammars if used; Git GPLv2 + written offer). Reviewed for completeness.
- [ ] Source archive for Git + build script prepared as a release artifact.
- [ ] Dependency audit of `Package.resolved` (license, maintenance, advisories) documented.
- Screenshots: icon in each system appearance; About and Acknowledgements light/dark.
- Done when: every bundled component's license is shown and source obligations are met.

### P7.6 — Entitlements and Hardened Runtime (ADR-0045)
- [ ] Minimal entitlements files (app; none for Git/helper); sandbox decision documented.
- [ ] Verify the app works under Hardened Runtime with Git, ssh, credential helper, external editor
      launch, custom CA, proxy (ad-hoc signed with `--options runtime` first).
- Done when: all Phase 3–5 workflows pass under Hardened Runtime.

### P7.7 — Signing scripts (ADR-0046)
- [ ] `04-sign-embedded.sh` (inside-out over Git binaries, `jit-git-helper`, any dylibs), `05-sign-app.sh`;
      `--adhoc` mode; identity from env/keychain; no `--deep` signing.
- [ ] Verification inside scripts: `codesign --verify --strict --deep --verbose=2`, `codesign -dv
      --verbose=4` checks for runtime flag, timestamp (non-adhoc), Team ID consistency across all Mach-O.
- Done when: ad-hoc and (if available) Developer ID signing pass verification.

### P7.8 — DMG (ADR-0047)
- [ ] Background artwork (1×/2×, multi-resolution TIFF) matching the app icon's glass material and the
      macOS 26 look; volume icon from the icon artwork.
- [ ] `06-create-dmg.sh`: staging, layout (committed `.DS_Store` or scripted — per spike), compression,
      DMG signing.
- Screenshots: mounted DMG window on macOS 26 and latest, light and dark Finder.
- Done when: DMG opens with the intended layout on both OS versions.

### P7.9 — Notarization, stapling, validation
- [ ] `07-notarize.sh` (`notarytool submit --wait --keychain-profile`, JSON output, log fetch on failure,
      skip if already accepted for same SHA-256), `08-staple.sh`, `09-validate.sh`
      (`stapler validate`, `spctl --assess` for DMG and app, `codesign --verify --strict --deep`,
      SHA-256, writes `validation.txt`).
- [ ] `release.sh` orchestrator with `--adhoc`, `--skip-notarize`, `--from-step N` (N = script number
      01–09); prints summary.
- Verification: full run with real credentials; or ad-hoc run + blocked status.
- Done when: notarized + stapled DMG validates, or blocked-on-credentials is reported with exact
  remaining commands.

### P7.10 — Release-build performance and security re-check
- [ ] Re-run Phase 6 benchmark suite on the universal, bundled-Git release build (reference Mac);
      compare with Phase 6 final; explain differences (e.g. Git version/curl backend).
- [ ] Idle network check on release build; binary audit for secrets/dev paths/test client IDs;
      dSYMs archived privately (not in DMG).
- Done when: `docs/performance.md` "Release build" section and `docs/security.md` release audit done.

### P7.11 — Clean-machine verification and acceptance A–G (ADR-0048)
- [ ] Fresh VMs: macOS 26 and latest; no CLT (`xcode-select -p` fails); DMG downloaded to get quarantine.
      Glass visuals judged on real hardware (VMs may lack full GPU acceleration); functional checks in VMs.
- [ ] Execute scenarios A–G (§24) with the checklist in `docs/release.md`: expected / observed /
      evidence / pass-fail. Scenario E/F: real accounts or test rig, labelled accordingly.
- [ ] Intel: real Intel Mac, Rosetta-only, or not verified — stated explicitly.
- Done when: checklist complete with evidence; failures fixed (and DMG rebuilt) or logged as release
  blockers.

### P7.12 — Release checklist and final documentation
- [ ] `docs/release.md`: prerequisites, credential setup (user-run commands), step scripts, troubleshooting
      (notarization log reading), clean-VM protocol, acceptance checklist, Git security-update process,
      ADR-0020 update policy.
- [ ] README: install instructions, system requirements, what's included, license/acknowledgements link.
- [ ] Final pass over all `docs/` for accuracy (nothing unimplemented described as done); roadmap
      status update for Phase 7.
- [ ] Prepare (but do not publish) the GitHub Release draft notes + artifacts list; publishing requires
      the user's explicit approval.
- Done when: docs match reality; release checklist executable by someone else.

## 3. Test plan summary

| Layer | Tests |
|---|---|
| `GitCore` (`swift test`) | GitLocator resolution/validation tests; full integration suite against bundled Git (arm64 + x86_64) |
| App/Services | version consistency, Git runtime settings, onboarding UI test |
| Scripts | arch verification, bundled-Git relocation test, signing verification, DMG validation |
| Manual | clean-VM scenarios A–G on macOS 26 + latest; Intel/Rosetta run; DMG layout and app icon screenshots |

## 4. Performance checks

Re-run Phase 6 scenarios on the shipping artifact (installed from DMG into /Applications, not the
build folder): cold/warm launch, idle CPU/wakeups/network, idle memory, open-repo, graph scroll,
diff switch. Regressions > Phase 6 thresholds are release blockers unless explained and accepted.

## 5. Docs to update

`docs/release.md`, `docs/security.md` (signing, sandbox decision, dependency audit, bundled Git patch
process), `docs/performance.md` (release-build numbers), `docs/architecture.md` (Git resolution,
bundle layout), `README.md`, `CLAUDE.md` Commands (release scripts), ADRs 0019, 0020, 0045–0049,
`docs/roadmap.md` status line.

## 6. Exit checklist

- [ ] Universal app (or arm64-only per ADR-0049); every Mach-O has the chosen slices; `jit-git-helper`
      and Git included; no dev-only targets embedded.
- [ ] Layered Liquid Glass app icon renders correctly in all system appearances.
- [ ] Integration suite passes against the bundled Git; no implicit CLT dependency.
- [ ] Hardened Runtime on all code; entitlements minimal and justified.
- [ ] Either: Developer ID–signed, notarized, stapled DMG passing `09-validate.sh`
      — or: status **blocked on credentials** with all local steps verified and remaining commands listed.
- [ ] Clean-VM acceptance A–G documented with evidence on macOS 26 and latest.
- [ ] GPLv2 obligations for Git met; all third-party licenses shown.
- [ ] No secrets committed; `.gitignore` covers credential files; scripts never echo secrets.
- [ ] Release-build performance report updated.
- [ ] Roadmap §9 exit gate items 1–8 satisfied.
