# Release

Status (1.0.0, 2026-11-10): **distributed free as an ad-hoc-signed, non-notarized DMG** (owner decision,
ADR-0049 addendum). The Developer ID path (steps 07–08) is implemented but unused; clean-VM acceptance pending. See
[`phases/07-packaging-and-release/progress.md`](phases/07-packaging-and-release/progress.md).
Current version: **0.0.3**, a test build ([`releases/v0.0.3.md`](releases/v0.0.3.md); earlier:
[`0.0.2`](releases/v0.0.2.md), [`0.0.1`](releases/v0.0.1.md));
set `MARKETING_VERSION` back to 1.0.0 before the public release.
Decisions: ADR-0019 (bundled Git), 0020 (no updater), 0045 (entitlements/sandbox), 0046 (signing), 0047 (DMG
and notarization), 0048 (clean-machine protocol), 0049 (versioning, arm64-only).

## 1. Prerequisites (release machine)
- macOS 26+ on Apple silicon, **full Xcode 26+** selected, `brew install xcodegen`.
- For a distributable build (owner-only steps; never paste secrets into a chat or commit them):
  1. A **Developer ID Application** certificate (with private key) in the login keychain.
     Check: `security find-identity -v -p codesigning`.
  2. Notary credentials, stored once in the keychain (App Store Connect API key preferred):
     `xcrun notarytool store-credentials jit-notary --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>`
  3. `scripts/release/release.local.env` (git-ignored):
     ```bash
     JIT_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
     JIT_TEAM_ID=<TEAMID>
     ```
  4. Once per machine: allow Finder automation when macOS asks (DMG window layout), or set `JIT_DMG_LAYOUT=0`.
- Optional: `brew install gnupg` and `JIT_GIT_VERIFY_SIGNATURE=1` to also check Git's PGP signature (ADR-0019).
- Before 1.0 ships publicly (owner): register the public OAuth clients (GitHub OAuth app with Device Flow;
  GitLab.com application, redirect `jit://oauth/gitlab`, scopes `read_api read_repository write_repository`) and
  add `macos/Resources/OAuthClients.plist` (`GitHubClientID`, `GitLabClientID`). Without it OAuth sign-in shows
  "not configured"; PAT and SSH work. Jit itself is MIT-licensed (`LICENSE`).

## 2. Building a release
Change the version **only** in `macos/App/Config/Version.xcconfig` (`MARKETING_VERSION`, increase
`CURRENT_PROJECT_VERSION` for every distributed build), commit, then:

```bash
scripts/release/release.sh --version 1.0.0          # Developer ID: steps 01–09
scripts/release/release.sh --version 1.0.0 --adhoc  # no credentials: 01–06 + 09 (not distributable)
scripts/release/release.sh --from-step 07           # resume, e.g. after a notarization failure
```

| Step (§20) | Script | Does | Output |
|---|---|---|---|
| 1–3 | `01-build-app.sh` | XcodeGen, clean Release archive (`JIT_ARCHS`), plist checks, `JitSourceCommit` | `stage/Jit.app`, `dSYMs/`, `Jit.xcarchive`, `xcodebuild.log` |
| 4 | `02-bundle-git.sh` | `build-git.sh` (cached), embed at `Contents/Resources/git`, run check | — |
| — | `03-verify-archs.sh` | every Mach-O has exactly `JIT_ARCHS`; helper and Git present; no dev-only content | — |
| 5 | `04-sign-embedded.sh` | inside-out: Git binaries, helper (runtime, timestamp, no entitlements) | — |
| 6 | `05-sign-app.sh` | sign the app; strict deep verify; runtime/timestamp/Team ID on every Mach-O; no entitlements | — |
| 7 | `06-create-dmg.sh` | styled DMG (background, layout, volume icon), ULFO, signed | `Jit-<v>.dmg` |
| 8 | `07-notarize.sh` | `notarytool submit --wait`; log on failure; skips an already-accepted DMG hash | `notary-<sha>.json`, `notary-log-<id>.json` |
| 9 | `08-staple.sh` | `stapler staple` + `validate` | — |
| 10 | `09-validate.sh` | SHA-256, signatures, ticket, Gatekeeper (DMG + app), runtime, archs, Git in DMG | `validation.txt` |

All outputs are in `build/release/<version>/` (git-ignored). dSYMs stay there, private — never in the DMG.

### Publishing an ad-hoc release (current mode)
1. `scripts/release/release.sh --version X.Y.Z --adhoc` from a clean tree (About shows the commit).
2. Assets in `build/release/X.Y.Z/publish/`: the DMG, `Jit-X.Y.Z.dmg.sha256`, `SHA256SUMS`,
   `git-<v>.tar.xz`, `jit-git-build-scripts-X.Y.Z.tar.gz` (GPLv2 corresponding source for the bundled Git).
3. Notes from `docs/releases/vX.Y.Z.md` (first-launch steps and the DMG SHA-256 must be in them).
4. With the owner's approval: tag `vX.Y.Z` on the build commit, `gh release create` with the notes and assets.
   The repository (or a releases repository) must be public for users to download.

### Publishing (owner approval required)
Tag `vX.Y.Z` on the release commit. Attach to the GitHub Release: the DMG, its SHA-256, and the GPLv2
corresponding source for Git (`build/git-src/git-<v>.tar.xz`, `scripts/build/build-git.sh`,
`scripts/build/git-version.env`). Release notes must call out security fixes, because there is no updater
(ADR-0020). Nothing is uploaded by the scripts.

## 3. Troubleshooting
- **Notarization "Invalid"**: `07` prints the issues from `notary-log-<id>.json`. Typical causes: a nested
  binary not signed with the Developer ID, a missing secure timestamp, or Hardened Runtime missing. Fix the
  signing step, then `release.sh --from-step 04`.
- **`spctl` rejects the app after stapling**: check `codesign -dv --verbose=4` on the app inside the
  mounted DMG (Authority chain, TeamIdentifier), and that the DMG and not just the app was stapled.
- **Finder layout step times out**: macOS is waiting for the Automation permission prompt; answer it, or
  `JIT_DMG_LAYOUT=0`.
- **Finder removes `.VolumeIcon.icns`**: expected; `06` adds the volume icon after the layout pass.
- **Git build pulls Homebrew libraries or Rust**: `build-git.sh` passes `NO_HOMEBREW` and `NO_RUST`; check
  with `test-bundled-git.sh` ("links only system libraries", "built without Rust").

## 4. Bundled Git security updates (ADR-0019)
1. Watch git-security announcements and kernel.org releases.
2. On a fix that affects us: update `GIT_VERSION` and `GIT_TARBALL_SHA256` in `scripts/build/git-version.env`
   (the hash from kernel.org's signed `sha256sums.asc`; with gpg, verify the tarball signature too).
3. `scripts/build/build-git.sh --force && scripts/build/test-bundled-git.sh --network --suite` must pass.
4. Increase `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` patch), release, and publish the new source tarball.

## 5. Clean-machine protocol (ADR-0048)
Fresh macOS 26.0 and latest-macOS VMs, standard user, no Xcode/CLT/Homebrew (`xcode-select -p` must fail).
Download the DMG through a browser (so it is quarantined), drag to Applications, launch, then run the checklist
below and attach evidence (screenshots, `ps` output, logs). Judge glass visuals on real hardware.

## 6. Acceptance checklist (§24) — 1.0.0
Environment for this run: release Mac (MacBook Pro M5 Pro, macOS 27.2, **Xcode and CLT installed**). The
ad-hoc DMG was quarantined by hand, then installed to /Applications. The app ran with an isolated
`JIT_APP_SUPPORT`. **Not** a clean VM, **not** notarized. Evidence paths are relative to
`docs/phases/07-packaging-and-release/`.

| # | Expected | Observed | Evidence | Result |
|---|---|---|---|---|
| A1 | Window appears quickly | see progress.md "Release performance" (warm/cold launch of /Applications/Jit.app) | `benchmarks/results/` run | see progress.md |
| A2 | Premium UI; light/dark correct | Graph, diff, resolver, Settings ▸ Git, DMG in dark; light via `-JitAppearance` snapshot suite | `screenshots/release-*` | pass (dark checked by eye; light covered by the snapshot suite) |
| A3 | No background network | see progress.md (network-idle scenario) | results JSON | see progress.md |
| A4 | Near-zero idle CPU; stable memory | see progress.md (idle 0/1/5 tabs, footprint) | results JSON | see progress.md |
| B | Real repo graph, stable lanes, selection, incremental history, smooth scroll, accurate refs | branchy-10k (10k commits, 201 branches, 100 tags): lanes, merge curves, branch/remote labels; click → inspector (author, SHA, parent, files); 40-notch scroll smooth | `screenshots/release-graph-branchy-dark.png` | pass |
| C | Stage one line, others unstaged, unstage it, discard another, unrelated kept | `git diff --cached` = exactly `+line 3 changed`; U → nothing staged; ⌫ on `line 10 changed` → specific confirmation (exact line, recovery copy, Cancel default) → only that line removed; line 6 change kept | `screenshots/release-line-discard-sheet-dark.png`; git output in progress.md | pass |
| D | Conflict detected, 3-way editor, choose/combine, safe save, resolved only when appropriate, continue | Merge sheet predicted "will conflict in 1 file"; resolver opened; Save/Mark disabled until resolved; Take Theirs → Mark as Resolved → `M  config.yml`, MERGE_HEAD kept; Continue → merge commit as the profile identity | `screenshots/release-conflict-resolver-dark.png` | pass |
| E | Two GitHub + one GitLab account, profile switching, identity/credentials follow profile, no global config change, no silent wrong-account success | **not run with real accounts** (none available). Covered by the Phase 5 rig and integration suites against the bundled Git: see progress.md | rig run | partial (test rig only) |
| F | Enterprise GitLab: custom CA, proxy, SSH, diagnostics | **test rig only** (TLS server with a private CA, HTTP/SOCKS proxies, user sshd, GitLab API stub): see progress.md | rig run | partial (test rig only) |
| G1 | Correct signing and notarization | ad-hoc only; Gatekeeper blocks a quarantined launch ("Apple could not verify…"), as expected | `screenshots/gatekeeper-adhoc-blocked.png`, `build/release/1.0.0/validation.txt` | **blocked (credentials)** |
| G2 | No development toolchain dependency | Git resolved to and ran from `/Applications/Jit.app/Contents/Resources/git/bin/git` (`ps`, Settings ▸ Git: "Bundled with Jit"); `otool -L` shows only system libraries; Homebrew Git ignored in release | `screenshots/release-settings-git-dark.png` | pass on this Mac; **clean VM not run** |
| G3 | Launches normally | launches after quarantine removal (ad-hoc); notarized launch not possible yet | — | blocked (credentials) |
| G4 | Repository operations work | B–D above with the bundled Git | — | pass |
| G5 | Helpers included / prerequisites handled | `jit-git-helper`, Git runtime and helpers verified by `03`/`09`; no-Git path shows "Git Settings…" and an explicit CLT install button | tests `GitLocatorTests`, `GitValidationTests` | pass |
| — | Intel | arm64-only by owner decision (ADR-0049) | — | n/a |
