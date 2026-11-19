# Release

Jit is **free** and distributed as an ad-hoc-signed DMG. The Apple Developer ID and notarization steps
remain available separately. Starting with **0.1.3**, Jit uses Ed25519 signatures for in-app updates.
[0.1.3 notes](releases/v0.1.3.md) · [0.1.2 notes](releases/v0.1.2.md)

Earlier builds include [`0.1.1`](releases/v0.1.1.md),
[`0.1.0`](releases/v0.1.0.md),
[`0.0.9`](releases/v0.0.9.md),
[`0.0.8`](releases/v0.0.8.md),
[`0.0.7`](releases/v0.0.7.md),
[`0.0.6`](releases/v0.0.6.md),
[`0.0.5`](releases/v0.0.5.md),
[`0.0.4`](releases/v0.0.4.md), [`0.0.3`](releases/v0.0.3.md), [`0.0.2`](releases/v0.0.2.md),
[`0.0.1`](releases/v0.0.1.md).
Decisions: ADR-0019 (bundled Git), 0020 (no updater), 0045 (entitlements/sandbox), 0046 (signing), 0047 (DMG
and notarization), 0048 (clean-machine protocol), 0049 (versioning, arm64-only).

## 1. Prerequisites (release machine)
- macOS 26+ on Apple silicon with full Xcode 26+ selected. For a fresh machine, follow
  [Release from another Mac](release-from-another-mac.md).
- XcodeGen and Python 3.11 or newer. Install the pinned installer tools once per checkout.

  ```bash
  python3 -m venv build/dmg-tools
  build/dmg-tools/bin/python3 -m pip install --require-hashes -r scripts/release/dmg-requirements.txt
  ```
- OpenSSL 3 for offline signing and publish verification. Install the free `openssl@3` formula if needed
  and set `JIT_UPDATE_OPENSSL="$(brew --prefix openssl@3)/bin/openssl"`. Jit uses CryptoKit at runtime.
- The official update signing public key is in `scripts/release/release.env`. An explicit
  `JIT_UPDATE_PUBLIC_KEY` can be used for rehearsals. See [offline signing](#offline-update-signing).
- For optional Apple notarization (keep credentials in Keychain):
  1. A **Developer ID Application** certificate (with private key) in the login keychain.
     Check: `security find-identity -v -p codesigning`.
  2. Notary credentials, stored once in the keychain (App Store Connect API key preferred):
     `xcrun notarytool store-credentials jit-notary --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>`
  3. `scripts/release/release.local.env` (git-ignored):
     ```bash
     JIT_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
     JIT_TEAM_ID="TEAMID"
     ```
- The release script writes Finder layout metadata directly to the image. Packaging can run in a terminal
  without a Finder session or an Automation grant.
- Optional: `brew install gnupg` and `JIT_GIT_VERIFY_SIGNATURE=1` to also check Git's PGP signature (ADR-0019).
- Releases from 0.1.0 bundle the public OAuth client IDs in `macos/App/Resources/OAuthClients.plist`.
  GitHub.com uses Device Flow. GitLab.com uses PKCE with redirect `jit://oauth/gitlab` and scopes
  `read_api read_repository write_repository`. Jit is MIT-licensed (`LICENSE`).

## 2. Building a release
Change the version **only** in `macos/App/Config/Version.xcconfig` (`MARKETING_VERSION`, increase
`CURRENT_PROJECT_VERSION` for every distributed build), commit, then:

```bash
scripts/release/release.sh --version 0.1.3 --adhoc  # free test-build distribution
scripts/release/release.sh --from-step 07           # resume, e.g. after a notarization failure
```

| Step (§20) | Script | Does | Output |
|---|---|---|---|
| 1–3 | `01-build-app.sh` | XcodeGen, clean Release archive, source commit and public update key sealed in the app | `stage/Jit.app`, `dSYMs/`, `Jit.xcarchive`, `xcodebuild.log` |
| 4 | `02-bundle-git.sh` | `build-git.sh` (cached), embed at `Contents/Resources/git`, run check | — |
| — | `03-verify-archs.sh` | every Mach-O has exactly `JIT_ARCHS`; helper and Git present; no dev-only content | — |
| 5 | `04-sign-embedded.sh` | inside-out: Git binaries, helper (runtime, timestamp, no entitlements) | — |
| 6 | `05-sign-app.sh` | sign the app; strict deep verify; runtime/timestamp/Team ID on every Mach-O; no entitlements | — |
| 7 | `06-create-dmg.sh` | Jit wordmark, Retina background, drag-to-Applications layout and volume icon. ULFO and code-signed | `Jit-<v>.dmg` |
| 8 | `07-notarize.sh` | `notarytool submit --wait`; log on failure; skips an already-accepted DMG hash | `notary-<sha>.json`, `notary-log-<id>.json` |
| 9 | `08-staple.sh` | `stapler staple` + `validate` | — |
| 10 | `09-validate.sh` | DMG hash, embedded update key, signatures, ticket, Gatekeeper, runtime, architecture, bundled Git and Finder layout | `validation.txt` |

All outputs are in `build/release/<version>/` (git-ignored). dSYMs stay there, private — never in the DMG.

### Offline update signing

On the offline signing machine, create one passphrase-encrypted Ed25519 key outside the checkout. Back it
up to encrypted offline storage. Keep the private key and passphrase out of GitHub, CI, and the build machine.

```bash
key=/path/to/jit-update-key.pem
(umask 077; set -C; "${JIT_UPDATE_OPENSSL:-openssl}" genpkey -algorithm Ed25519 -aes-256-cbc > "$key")
scripts/release/update-signing.sh public-key "$key"
```

The printed lowercase hex string is the public key. Record the official public key in
`scripts/release/release.env` when establishing the signing identity and use it for each release. If the
private key is lost or must be replaced, distribute a newly verified manual installer with the new pin
and communicate the change through a trusted channel.

After packaging and validation, transfer the **exact final DMG** and the signing script to the offline
machine. Sign only after all packaging, code signing, and any notarization or stapling are complete.

```bash
scripts/release/update-signing.sh sign 0.1.3 /path/to/Jit-0.1.3.dmg /path/to/jit-update-key.pem
```

Return only `Jit-0.1.3.dmg.manifest` and `Jit-0.1.3.dmg.manifest.sig` to the build machine, alongside the
original DMG in `build/release/0.1.3/`. Run `scripts/release/10-prepare-publish.sh`. It checks that the DMG
still matches the validation report and that the manifest and signature match the configured public key.
Tests and local release rehearsals use disposable keys. A public release uses the owner's offline key.

### Publishing (owner approval required)

1. Open the final DMG in Finder and confirm the Jit wordmark, both icons, drag arrow, and labels appear together.
   Run the [signed-update acceptance test](testing.md#signed-in-app-updates) on the release candidate and
   confirm package and app tests pass for the commit you will tag.
2. Tag the exact clean build commit as `X.Y.Z`. Create a GitHub draft prerelease with the notes from
   `docs/releases/vX.Y.Z.md` and all files from `build/release/X.Y.Z/publish/`. The repository must be public.
3. Confirm that the DMG, `.dmg.manifest`, `.dmg.manifest.sig`, `SHA256SUMS`, and bundled Git source and
   build scripts are present and match the locally verified assets. Publish the draft together with all assets.
4. Omit the standalone `.dmg.sha256` asset for 0.1.3 and later. Jit 0.1.2 and earlier will offer the
   release page for manual installation because they require that exact legacy asset for in-app installation.

For the initial manual install, get the public key from the maintainer over a trusted channel and verify
the downloaded DMG and its two manifest files before opening it.

```bash
scripts/release/update-signing.sh verify 0.1.3 /path/to/Jit-0.1.3.dmg "$JIT_UPDATE_PUBLIC_KEY"
```

### Website (mandatory after every release)
Right after the GitHub Release exists, publish the website:

```bash
scripts/site/publish.sh --version X.Y.Z   # --dry-run builds build/site/ without pushing
```

It builds `site/` locally, writes `release.json` and the download links, size and version into the page from
`build/release/X.Y.Z/Jit-X.Y.Z.dmg`, and pushes one commit to the `gh-pages` branch. GitHub Pages serves that
branch as is (Settings ▸ Pages: "Deploy from a branch", `gh-pages`, `/`); nothing runs in GitHub Actions. A
release is not done until the site offers its DMG: check https://ashkanrmk.github.io/jit/ after about a minute.

Jit reads public releases from GitHub and shows their notes in **What's New**. The tag must be `X.Y.Z`
or `vX.Y.Z`. The signed version and `CFBundleShortVersionString` must match the tag's normalized version.

## 3. Troubleshooting
- **Notarization "Invalid"**: `07` prints the issues from `notary-log-<id>.json`. Typical causes: a nested
  binary not signed with the Developer ID, a missing secure timestamp, or Hardened Runtime missing. Fix the
  signing step, then `release.sh --from-step 04`.
- **`spctl` rejects the app after stapling**: check `codesign -dv --verbose=4` on the app inside the
  mounted DMG (Authority chain, TeamIdentifier), and that the DMG and not just the app was stapled.
- If installer tools are missing, recreate `build/dmg-tools` from the pinned requirements in §1.
  If the mounted image fails layout validation, rebuild from step 06 and sign the new final DMG.
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
