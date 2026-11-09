# Phase 07 — Packaging & release: progress report

Status: **complete with carry-overs — distributed ad-hoc (owner decision 2026-11-10: free, no paid Apple
Developer Program; ADR-0049 addendum)**. Every local step is implemented and verified with ad-hoc signing;
notarization is out of scope by that decision; clean-VM acceptance has not been run (no VM tooling; owner chose
local + test rig).
Branch / PR: `phase/07-packaging-and-release` (PR link added when opened)
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2,
XcodeGen 2.46.0; development Git 2.54.0 (Homebrew); **bundled Git 2.56.0**.

## Owner answers (2026-11-09)
| Question | Answer |
|---|---|
| Bundle ID / name / version / copyright | `com.ashkanrmk.jit`, Jit, 1.0.0 (build 1), "© 2026 Ashkan Rahmani" |
| Universal or arm64-only | **arm64-only** (ADR-0049) |
| Developer ID certificate / Team ID | none on this Mac (`security find-identity -v -p codesigning` → 0 identities) → ad-hoc path |
| Notary keychain profile | none (`jit-notary` not found) |
| VMs / Intel Mac | no VM tooling installed; owner chose "local + test rig"; no Intel Mac (n/a, arm64-only) |
| Real accounts for E/F | none → Phase 5 local enterprise rig |
| Finder automation for the DMG layout | allowed by the owner (they clicked Allow themselves) |

## Preconditions
- Phase 6 complete with carry-overs (accepted as the base for Phase 7).
- `main` built Release. `test-core.sh`: 735 run, 731 passed. The 4 failures were stale command-palette
  snapshot references left by the last `main` commit (⇧⌘F "Find in Open Tabs"). The new rendering was checked
  by eye and re-recorded (`66d48b4`).
- Full Xcode 27.2 selected; macOS 27.2 SDK; x86_64 trial not needed (arm64-only).

## Implemented
- **P7.1 Release configuration** — `macos/App/Config/Version.xcconfig` is the single source (bundle ID, version,
  build, copyright). Release strips dead code and symbols and keeps dSYMs; `.gitignore` covers signing material.
  `01-build-app.sh` checks the built Info.plist against it and stamps `JitSourceCommit`. Placeholder
  `com.example.jit` replaced in code (Keychain service prefix, signpost subsystem).
- **P7.2 Architectures** — arm64 via `JIT_ARCHS` (release.env); `03-verify-archs.sh`: 6 Mach-O, all `arm64`;
  helper at `Contents/Helpers`; no TestRig/JitBench/GitTestKit/xctest/swiftmodule/dSYM/keys/.DS_Store.
- **P7.3 Bundled Git (ADR-0019)** — `scripts/build/build-git.sh` + `git-version.env`: Git 2.56.0, SHA-256
  pinned (matches kernel.org `sha256sums.asc`), `RUNTIME_PREFIX`, `NO_HOMEBREW NO_RUST NO_PERL NO_PYTHON
  NO_TCLTK NO_GETTEXT`, system libcurl 8.7.1/zlib/iconv only. Pruned to 16 files and 9.9 MB, one real binary;
  empty bundled system config; LICENSE/VERSION/SOURCE.txt (written offer). Evidence:
  `test-bundled-git.sh --network` (19 checks: relocation into a path with a space, exec-path,
  isolation, merge strategies, rebase, cherry-pick, stash, clones, submodule, HTTPS) and `--suite`: every Git test
  passes against the relocated runtime, and 44,612 `GIT_TRACE` lines have no missing-helper message. Two
  findings fixed: hook installers expect `.git/hooks/` (empty `hooks/` template kept), and the Makefile
  would otherwise link Homebrew gettext and build Rust.
- **P7.4 Git resolution** — `GitLocator`: custom → bundled → (debug: env, Homebrew) → installed Apple developer
  tools, never the shim; `GitEngine.validateGit(at:)`, `setUserGitPath(_:)` (generation guard). **Settings ▸ Git**
  (version/source/path, Choose Git… with validation and inline errors, Use Bundled Git, explicit Install
  Command Line Tools…). Error cards for `gitNotFound`/`gitTooOld` offer "Git Settings…". Tests:
  `GitLocatorTests` (+4), `GitValidationTests` (3). Screenshot `screenshots/release-settings-git-dark.png`
  (release: "Bundled with Jit", `/Applications/Jit.app/Contents/Resources/git/bin/git`).
- **P7.5 Icon, About, licenses** — `macos/App/AppIcon.icon` (Icon Composer document, two glass SVG layers on
  a teal gradient; compiled by actool into Assets.car + AppIcon.icns). About panel with build and commit and
  a credits line. Help ▸ Acknowledgements (Git version, source/offer, full GPLv2; honest text in development
  builds). Dependency audit: no third-party Swift packages.
- **P7.6 Entitlements (ADR-0045)** — none; Hardened Runtime on every Mach-O; sandbox off with documented
  controls. Credential-broker peer now also requires Jit's signing team in Developer ID builds
  (`PeerCodeSignature`, audit token; `PeerCodeSignatureTests`).
- **P7.7–P7.9 Release pipeline (ADR-0046/0047)** — `scripts/release/01…09` + `release.sh` (`--version`,
  `--adhoc`, `--skip-notarize`, `--from-step`). DMG: HFS+→ULFO, generated 1×/2× background, AppleScript layout,
  volume icon (Finder deletes a pre-existing `.VolumeIcon.icns` during layout — now added afterwards), signed.
  Notarize/staple/validate scripts are written; notarize and staple have not been run (no credentials).
- **P7.10 Release re-check** — benchmarks against `/Applications/Jit.app` (below); idle network 0; binary audit
  (`strings`): no developer paths, tokens, keys or test hosts. The only hits are the token-redaction regex and
  the env/argument-gated benchmark hooks (intentional, documented in Phase 6).
- **P7.11 Acceptance** — `docs/release.md` §6 (B, C, D pass on the installed release; E/F test rig only; G
  blocked on credentials, toolchain-independence shown on this Mac only).
- **P7.12 Docs** — release.md (rewritten), security.md, architecture.md, performance.md, README (install),
  CLAUDE.md commands, roadmap, ADRs 0019, 0020, 0045–0049, specs in `specs/`.

## Verified
- Release pipeline: `release.sh --version 1.0.0 --adhoc` → steps 01–06 + 09 pass; `validation.txt` "PASS —
  ad-hoc build, not for distribution". The ad-hoc rejections of `stapler validate` and `spctl` are recorded
  as expected.
- Tests (final run, after all changes): see "Final test run" below.
- Rig (Phase 5, ADR-0039) against the Git **inside /Applications/Jit.app**:
  `JIT_RIG=1 JIT_GIT_PATH=…/Resources/git/bin/git swift test --filter "Rig|Diagnostics|RemoteOperationTests|
  IntegrationTests|FrameworkTests|SafetyRegressionTests"` → 139 passed, 0 skipped. This includes HTTPS
  clone/push with a PAT through a private CA, an authenticating proxy with a brokered password, SSH trust,
  changed-key and askpass checks, and diagnostics. **System libcurl decision confirmed** on macOS 27.2 (not on 26.0).
- Real workflow on the installed app (quarantined DMG → /Applications, isolated `JIT_APP_SUPPORT`):
  - Gatekeeper blocks the ad-hoc app ("Apple could not verify…"), as expected → `screenshots/gatekeeper-adhoc-blocked.png`.
  - Git runs from `/Applications/Jit.app/Contents/Resources/git/bin/git` (`ps`).
  - B: branchy-10k graph, selection → inspector, smooth scroll (`release-graph-branchy-dark.png`).
  - C: line stage (`git diff --cached` = `+line 3 changed`), unstage (U), line discard with its specific
    confirmation (`release-line-discard-sheet-dark.png`); unrelated changes kept.
  - D: merge predicted to conflict → resolver → Take Theirs → Mark as Resolved (`M config.yml`, MERGE_HEAD kept)
    → Continue → merge commit authored as the profile identity `Acceptance Tester <accept@jit.invalid>`
    (`release-conflict-resolver-dark.png`).
  - DMG window in dark Finder (`dmg-window-dark.png`).

## Release performance (installed from the DMG; details in docs/performance.md)
| Metric | Phase 6 final | Release 1.0.0 | Method |
|---|---|---|---|
| Warm / cold launch | 259.3 / 241.0 ms | 270.2 / 256.5 ms | launch-warm / launch-cold |
| Idle CPU 0/1/5 tabs | 0.00 % | 0.00 % (≤ 0.02 ms/s powermetrics) | idle.sh |
| Idle network | 0 | 0 bytes, 0 sockets | network-idle |
| Memory no repo / 1 / 5 tabs | 32 / 72 / 70 MB | 31 / 72 / 69 MB | footprint |
| Graph scroll (100k) | 1.63 / p95 1.92 ms | 1.45 / p95 1.66 ms | graph-scroll |
| Diff switch | 51.9 ms | 47.4 ms | diff-switch |
| Tab switch | 17.4 ms | 13.2–14.2 ms isolated (19.6 in the loaded full run) | multi-tab |
`compare.sh` flagged tab switch and micro diff-parse in the full run. Neither reproduced in isolated reruns
(tab switch equal to the DerivedData build; diff-parse 0.98 vs 0.968 ms).

## Decisions
- ADR-0019 bundled Git (source build, system libcurl, Resources/git, empty system config, GPLv2 offer).
- ADR-0020 no updater in V1.
- ADR-0045 no entitlements, Hardened Runtime everywhere, no sandbox.
- ADR-0046 inside-out signing, team check on the broker peer.
- ADR-0047 ULFO DMG, AppleScript layout, notarize + staple the DMG.
- ADR-0048 clean-machine protocol (executed locally only, labelled).
- ADR-0049 version source, arm64-only, artifacts.

## Deviations from plan
- **arm64-only** instead of universal (owner). The x86_64 trial build and the Rosetta runs were skipped.
- **No separate onboarding sheet**: Settings ▸ Git plus the error card's "Git Settings…" cover the same states;
  there's no "Learn more" link (no local help page exists to link to).
- **Release builds no longer fall back to Homebrew Git** (debug only), per design §4.3.
- **Bundled Git in `Contents/Resources/git`** (design left Resources vs SharedSupport open). Ad-hoc
  `codesign --strict --deep` accepts it; notarization acceptance of this location is still unverified.
- PGP signature check of the Git tarball not run (gpg not installed); SHA-256 pinned against kernel.org's list.
- Clean-VM acceptance not run (owner decision; ADR-0048 says exactly what the local run proves).
- Light-mode Finder screenshot of the DMG not taken: it needs switching the system appearance, which I didn't
  change. Labels were designed for both modes (luminance 0.19 band).
- Docs updated: yes.

## Bugs found and fixed during acceptance
- "Choose Profile…" in operation sheets did nothing when the window was narrow (the toolbar profile item
  sat in the overflow menu, so there was no anchor). It now opens Settings ▸ Profiles in that case.
- Finder deleted `.VolumeIcon.icns` during the layout pass (DMG volume icon missing). It's now added after.

## Known issues / carry-overs
- **Before publishing (owner)**: the GitHub repository is **private** — a release there is only downloadable by
  collaborators; make it (or a releases-only repository) public; approve the
  GitHub Release (notes `docs/releases/v1.0.0.md`, assets `build/release/1.0.0/publish/`).
- **If you later get a Developer ID** (no longer blocking): install a Developer ID Application certificate; run
  `xcrun notarytool store-credentials jit-notary --key <AuthKey.p8> --key-id <ID> --issuer <UUID>`; create
  `scripts/release/release.local.env` with `JIT_SIGN_IDENTITY="Developer ID Application: … (TEAMID)"` and
  `JIT_TEAM_ID`; then run `scripts/release/release.sh --version 1.0.0` (steps 01–09). Expected: `07` prints
  submission ID "Accepted", `08` staples, and `09` reports PASS with Gatekeeper accepting the DMG and the app.
  Then verify the broker team check with a real Developer ID build (credential helper flow against the rig).
- **Clean-VM acceptance** (ADR-0048) on macOS 26.0 and latest, without CLT, with the notarized DMG — release
  blocker for public distribution.
- **OAuth clients** not registered (`OAuthClients.plist` absent → OAuth "not configured"; PAT/SSH work). Owner.
- Jit's source license: **MIT** (owner, 2026-11-10; `LICENSE`).
- Real-account E/F (two GitHub + self-managed GitLab) not run; rig only.
- Phase 6 carry-overs still open: live VoiceOver walkthrough, XCUITest target, Instruments hitches/Metal by
  hand, visual re-review of settings/browser/resolver/clone in Reduce Transparency and Increase Contrast.
- UX: in a short window with a diff open, the inspector's split gives the file list little height (the
  Unstaged section scrolls out of view until the divider is dragged). Phase 8 / polish.
- Light-mode DMG Finder screenshot (needs a system appearance switch).

## Self-review findings
- Validation's `record` helper aborted under `set -e` on the first expected failure — fixed (`&& rc=0 || rc=$?`).
- The bundled-Git test compared a `//`-joined temp path — fixed (real paths).
- An unverified "3.6 MB compressed Git" figure in ADR-0019 — removed.
- The first DMG step attached the image twice (private mount, then /Volumes) and parsed `hdiutil info` wrongly —
  simplified to one attach.
- The Keychain round-trip test failed once in the long bundled-Git suite run after 251 s (a system keychain
  prompt timed out). It passes alone and in the final run — environment, not code.
- Security: no secret passes through any script, credential files are git-ignored, the scripts never echo
  identities beyond the certificate name, and nothing is uploaded or published.

## Final test run (after all changes, commit `d3bd9b836e`)
- `scripts/build/test-core.sh` → **745 passed, 0 failed** (GitCore 396, Services 203, Features 131, DesignSystem 15).
- `scripts/build/test-app.sh` → exit 0. `scripts/build/lint.sh` → clean.
- Rig suites against the bundled Git → 139 passed (see Verified).

## Final artifact (ad-hoc, not distributable)
- `build/release/1.0.0/Jit-1.0.0.dmg`, 11 MB, ULFO, arm64.
- SHA-256 `c33921805fd6510e099ac5d2e51bee7e8b4dbce3d7fb81a01e5ddd75eeba7fb4`.
- Built from `d3bd9b836e` (About: "Version 1.0.0 (1, d3bd9b836e)", `screenshots/release-about-dark.png`).
- Signing identity: **ad-hoc** ("-"); no Developer ID.
- Notarization submission ID / status: **none — not submitted** (no credentials). Stapled: no.
- `validation.txt`: PASS for the ad-hoc structure checks; ticket and Gatekeeper checks rejected, as expected.
- Acknowledgements: `screenshots/release-acknowledgements-dark.png`.
- The installed copy in `/Applications/Jit.app` is this build (left for the owner to try).
- Profile switcher: the popover works live when the profile item is visible; the overflow fallback
  (Settings ▸ Profiles) is verified by code review only — reproducing it needs several tabs plus no profile at
  minimum width.
