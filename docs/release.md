# Release

Status: **stub.** Signing, notarization, the DMG and bundled Git are Phase 7. Phase 0 builds are
ad-hoc signed with Hardened Runtime; the development machine has no Developer ID identity.

## Bundled Git feasibility (input to ADR-0019)

Notes from Phase 0 research; nothing here is built or verified yet.

| Topic | Finding / plan |
|---|---|
| Source | Build Git from the official release tarball in a reproducible script (`scripts/release/`), pinned version ≥ 2.39 (ADR-0006 addendum). Vendoring third-party prebuilt binaries is rejected: provenance and signing would be outside our control. |
| Relocatability | Build with `RUNTIME_PREFIX=YesPlease` so Git resolves `libexec/git-core`, templates and `share/` relative to its own binary inside `Jit.app/Contents/Resources/git/`. `GitLocator` already checks the bundled path first in priority order (absent until then). |
| Helpers | `libexec/git-core` contains many executables (`git-remote-https`, `git-upload-pack`, merge helpers). All must be included or Git features silently fail; keep the full set, strip docs/i18n/Perl/Tcl (`NO_PERL`, `NO_TCLTK`, `NO_GETTEXT`, `NO_PYTHON`). |
| Dependencies | HTTPS via `git-remote-https` needs libcurl; macOS ships `libcurl` and `zlib` as system libraries, so link against them instead of vendoring OpenSSL. `pcre2` optional (`NO_PCRE`/USE_LIBPCRE2 decision). `libiconv` from the system. |
| Architectures | Universal (arm64 + x86_64) only if ADR-0049 keeps Intel; build each slice and `lipo`. |
| Signing | Every Mach-O in the bundled tree (git, every `libexec/git-core` binary) signed with the Developer ID, Hardened Runtime, secure timestamp, before the app is signed; notarize the whole app. |
| Licensing | Git is GPLv2. Shipping it unmodified as a separate executable is aggregation; we must provide the exact corresponding source (offer or bundle the tarball) and the license text in the app/DMG. |
| Size | Expect roughly 20–40 MB uncompressed for a stripped build; measure in Phase 7. |
| Fallback | If bundling is blocked, the existing "Git isn't installed" state guides the user to CLT/Homebrew. |
