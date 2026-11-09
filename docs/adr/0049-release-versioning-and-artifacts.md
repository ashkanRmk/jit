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
