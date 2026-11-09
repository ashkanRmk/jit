# ADR-0045: Entitlements, Hardened Runtime and no App Sandbox for V1

- Status: accepted
- Date: 2026-11-09
- Phase: P7
- Requirements: §19, §20; Phase 7 design §4.4

## Decision
- **Hardened Runtime on every Mach-O**: the app, `jit-git-helper` and every bundled Git binary
  (`--options runtime`; checked per file by `05-sign-app.sh` and `09-validate.sh`).
- **No entitlements at all.** Checked and rejected: `disable-library-validation` (all code is ours, and system
  libcurl is Apple-signed), `allow-jit` / `allow-unsigned-executable-memory` (no JIT), `automation.apple-events`
  (Terminal is opened with `NSWorkspace`, not Apple Events), and network client/server (not sandboxed, so not
  needed). `05-sign-app.sh` fails if the signed app carries any entitlement.
- **App Sandbox off for V1.** Users open arbitrary folders, and Git reads and writes outside them
  (`~/.gitconfig`, `~/.ssh/known_hosts`, worktrees, alternates, submodules, hooks). Git spawns `ssh`, hooks and
  helpers that would inherit the sandbox, and the credential broker uses a Unix socket in `$TMPDIR`.
  Security-scoped bookmarks cover repository folders but not Git's own configuration and SSH ecosystem. A Mac
  App Store variant (Phase 8 parking lot) would need its own design.

## Compensating controls
§19 rules held since Phase 0: argv-only process launches with `--` before paths, a fixed cwd, a scrubbed
environment, `GIT_TERMINAL_PROMPT=0`, secrets only in the Keychain and handed to Git through the
operation-scoped broker (ADR-0016) whose peer must be the bundled helper (path, and the signing team for
Developer ID builds). Also: no idle network, no telemetry, and Hardened Runtime + notarization for distribution.

## Verified
Ad-hoc build with `--options runtime` everywhere, installed in /Applications: the Git graph, line
stage/unstage/discard, merge with conflict resolution and commit, the Git settings pane and the
About/Acknowledgements panels all work (progress.md, §24 B–D). The Phase 5 rig suite (TLS/CA/proxy/SSH/
credential helper) runs against the same bundled Git binary.
