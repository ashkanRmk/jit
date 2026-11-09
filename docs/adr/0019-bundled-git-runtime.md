# ADR-0019: Bundled Git runtime

- Status: accepted
- Date: 2026-11-09
- Phase: P7
- Requirements: §13.4, §19, §20 step 4; Phase 7 design §4.2

## Context
Jit must run on a Mac with no Xcode, Command Line Tools or Homebrew (§24 G) and must never trigger the CLT
install prompt by running the `/usr/bin/git` shim. It needs a Git it controls: version, features, configuration
isolation and security updates.

## Options
- **A. Build Git from the official source tarball** (pinned, hash-checked), relocatable, against macOS system
  libraries. Full control and provenance; build and security patching are ours.
- B. Repackage a third-party prebuilt Git. Less build work, but provenance, relocation and unneeded parts
  are outside our control; the GPL obligations stay ours.

## Decision
Option A, scripted in `scripts/build/build-git.sh` with `scripts/build/git-version.env`:
- **Version** Git **2.56.0** (latest on kernel.org on 2026-11-09). The tarball's SHA-256 is pinned and checked
  against kernel.org's signed `sha256sums.asc`. The PGP check of `git-<v>.tar.sign` runs when
  `JIT_GIT_VERIFY_SIGNATURE=1` and gpg is installed. gpg isn't installed on the release machine, so that check
  hasn't been run yet (open item).
- **Build** `make prefix=/ RUNTIME_PREFIX=YesPlease NO_HOMEBREW NO_DARWIN_PORTS NO_FINK NO_RUST NO_GETTEXT
  NO_TCLTK NO_PERL NO_PYTHON NO_INSTALL_HARDLINKS INSTALL_SYMLINKS`, `-arch arm64 -mmacosx-version-min=26.0`, the
  Xcode SDK. Without `NO_HOMEBREW`, Git's Makefile links Homebrew's gettext/iconv, and without `NO_RUST` it
  compiles Rust when cargo is present. Both would make the build machine-dependent.
- **Libraries** (verified with `otool -L`): the system `libcurl` (8.7.1, Apple TLS and trust store), `libz`,
  `libiconv`, CoreServices/CoreFoundation, CommonCrypto. No OpenSSL, no pcre2. **System libcurl is chosen**: the
  HTTPS `ls-remote` check and the Phase 5 rig suite pass against it (see progress.md for the rig run).
- **Layout** `Jit.app/Contents/Resources/git/{bin/git, libexec/git-core, share/git-core/templates, etc/gitconfig,
  LICENSE, VERSION, SOURCE.txt}` — 9.9 MB, 16 files, one real `git` binary (every builtin's dashed name and
  `libexec/git-core/git` are symlinks), plus `git-remote-http` (`https` symlink), `git-http-fetch`,
  `git-sh-i18n--envsubst` and the shell helpers merge strategies, rebase and submodule need. Pruned by an
  allowlist; daemon, shell, scalar, imap/send-email, svn/cvs/p4, instaweb, mergetool/difftool, filter-branch,
  completions and sample hooks removed (an empty `hooks/` template folder is kept because hook installers
  expect it).
- **Proof the allowlist is enough**: `scripts/build/test-bundled-git.sh --suite` relocates the runtime to a
  path with a space and runs the whole JitKit suite with `JIT_GIT_PATH` pointing at it and `GIT_TRACE` captured:
  every Git test passes, and the 44,612 trace lines contain no missing-helper message.
- **Configuration isolation**: with `RUNTIME_PREFIX` the system config is `<bundle>/etc/gitconfig`, which ships
  empty (a comment only), inside the signed bundle. The bundled Git therefore never inherits another Git's
  system config (e.g. Apple's `credential.helper=osxkeychain`). `~/.gitconfig` and repository config are
  respected (§10.3). `GIT_CONFIG_NOSYSTEM` is not set: a *custom* Git the user chose keeps its own system
  config, and remote credentials still go only through `jit-git-helper` (ADR-0016). SSH stays `/usr/bin/ssh`.
- **Resolution order** (`GitLocator`): `JIT_GIT_PATH` (debug only) → custom Git (Settings ▸ Git, validated:
  starts, version ≥ 2.39, `--exec-path` exists) → bundled → Homebrew/`/usr/local` (debug only) → Apple's
  real Git inside an *installed* Xcode/CLT (never the shim) → "Jit couldn't find a Git it can use" with a Git
  Settings… button. The CLT installer runs only from an explicit button in Settings ▸ Git.
- **Licensing (GPLv2)**: Jit runs Git as a separate program and does not link it, so Git is aggregated with Jit,
  not combined with it (our reading; not legal advice — owner to confirm). We ship `LICENSE` (Git's
  COPYING) and `SOURCE.txt`, which holds the exact tarball URL and hash, the build flags, and a three-year
  written offer. Help ▸ Acknowledgements shows both. Each release publishes the tarball and build script next
  to the DMG (`docs/release.md`).
- **Security updates**: watch the git-security announcements; on a CVE affecting used features, bump
  `git-version.env`, rebuild, re-run `test-bundled-git.sh --network --suite`, and ship a patch release.

## Consequences
- 9.9 MB added to the app (the whole 1.0.0 DMG is 11 MB).
- We own Git security patching (process in `docs/release.md`).
- Intel would need a second slice (`JIT_ARCHS="arm64 x86_64"` already lipo-merges); not shipped (ADR-0049).
