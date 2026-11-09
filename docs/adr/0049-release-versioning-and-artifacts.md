# ADR-0049: Release versioning, architectures and artifacts

- Status: accepted
- Date: 2026-11-09
- Phase: P7
- Requirements: §20, §21; Phase 7 design §4.1, §4.7

## Decision
- **Identity** (owner, 2026-11-09): bundle ID `com.ashkanrmk.jit`, name Jit, version **1.0.0**, build 1,
  "© 2026 Ashkan Rahmani".
- **Single source**: `macos/App/Config/Version.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`, `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`, `JIT_COPYRIGHT`), included by `Base.xcconfig` and read by `scripts/release/lib.sh`.
  `release.sh --version X` must equal it; `01-build-app.sh` asserts the built Info.plist matches and stamps
  `JitSourceCommit` (shown in About, `-dirty` when the tree differs).
- **Semver** `MAJOR.MINOR.PATCH`; `CURRENT_PROJECT_VERSION` increases for every distributed build; tag
  `vX.Y.Z` on the commit that produced the artifact.
- **Architectures: arm64 only** (owner decision 2026-11-09). macOS 26 supports only a few Intel Macs and
  there is no Intel hardware to test on. `JIT_ARCHS` in `release.env` is the switch (`"arm64 x86_64"`
  builds a universal app and lipo-merges the Git slices); `03-verify-archs.sh` asserts exactly the chosen
  slices on every Mach-O.
- **Artifacts per release** (`build/release/<version>/`): `Jit-<version>.dmg`, its SHA-256, `validation.txt`,
  the notary JSON/log, private `dSYMs/` (never in the DMG), and for publication the Git source tarball
  (`build/git-src/git-<v>.tar.xz`), `build-git.sh` and `git-version.env` (GPLv2 corresponding source,
  ADR-0019).

## Addendum 2026-11-10 — free ad-hoc distribution (owner decision)
The owner chose not to join the paid Apple Developer Program. 1.0.0 is distributed free as the **ad-hoc-signed,
non-notarized** DMG (Hardened Runtime still on). Consequences, documented in the README and release notes:
first launch needs Privacy & Security → Open Anyway (or removing the quarantine attribute) once per version;
SHA-256 checksums are published with every release for users to verify; after an update macOS may ask once
for Keychain access because ad-hoc builds have no stable signing identity; the broker's Developer ID team check
(ADR-0046) is inactive and only the executable-path check applies. §24 G "correct signing and notarization"
is knowingly not met. The Developer ID steps (07–08) stay in the pipeline for a later switch.
Release assets: DMG, `.sha256`, `SHA256SUMS`, `git-<v>.tar.xz`, `jit-git-build-scripts-<v>.tar.gz`
(prepared in `build/release/<v>/publish/`), notes in `docs/releases/v<v>.md`.
