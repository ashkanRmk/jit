# ADR-0046: Code-signing procedure

- Status: accepted
- Date: 2026-11-09
- Phase: P7
- Requirements: §20 steps 5–6; Phase 7 design §4.5

## Decision
- **Identity**: "Developer ID Application: <name> (<TEAMID>)" from the login keychain (or a temporary CI
  keychain), named in the git-ignored `scripts/release/release.local.env` (`JIT_SIGN_IDENTITY`, `JIT_TEAM_ID`).
  Nothing that signs is committed (`.gitignore` covers `*.p12 *.cer *.p8 AuthKey_*.p8 *.provisionprofile
  release.local.env notary-*.json`). Without an identity the scripts sign ad-hoc (`-`) and say so everywhere.
- **Inside-out, never `--deep` for signing**: `04-sign-embedded.sh` signs every Mach-O under `Contents/` except
  the main executable, deepest path first (the bundled Git, then `Contents/Helpers/jit-git-helper`), with
  `codesign --force --timestamp --options runtime --prefix com.ashkanrmk.jit.` and no entitlements. Then
  `05-sign-app.sh` signs the bundle. Symlinks are not signed. Git's shell helpers live in `Contents/Resources`
  and are sealed as resources.
- **Verification** (fails the step): `codesign --verify --strict --deep --verbose=2`, the runtime flag on every
  Mach-O, and — for Developer ID — a secure timestamp on every Mach-O, one Team ID across all of them (equal to
  `JIT_TEAM_ID` when set), and no entitlements.
- **Runtime trust**: for Developer ID builds the credential broker also requires the helper peer to satisfy
  `anchor apple generic and certificate leaf[subject.OU] = "<Jit's team>"`, checked by audit token
  (`PeerCodeSignature`). Ad-hoc builds keep the Phase 5 executable-path check.

## Status
Ad-hoc signing is verified end to end (`release.sh --adhoc`). Developer ID signing is implemented but has not
been run: no Developer ID certificate exists on the release machine (progress.md: blocked on credentials).
