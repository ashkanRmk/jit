# Security

Status: threat model v1, updated for Phase 1. Enforcement arrives with each feature; what is already
enforced is marked **enforced**.

## Assets
Source code in the user's repositories, Git credentials (SSH keys via agent, tokens — Phase 5), Git
identity, the user's Git/SSH configuration.

## Threats and policy

| Threat | Policy |
|---|---|
| Shell injection through paths, branch names, remote URLs | **Enforced:** Git runs via `posix_spawn` with an argv array; there is no API that accepts a shell string (unit test `noShellStringAPI`, argv test with shell metacharacters). `--` before paths in every command that takes paths. |
| Git or ssh hanging on a prompt | **Enforced:** `GIT_TERMINAL_PROMPT=0`, askpass → `/usr/bin/false`, `SSH_ASKPASS_REQUIRE=never`, editors → `true`, child in its own session with no controlling terminal (`POSIX_SPAWN_SETSID`), timeouts. |
| Environment leakage (tokens in env, `GIT_DIR` redirection) | **Enforced:** child environment built from an allowlist (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`), minimal `PATH`. |
| Secrets in logs / errors | **Enforced:** stderr shown only as redacted "Details" (`https://user:token@` → `https://***@`, `token=`/`password=` values, `Authorization:` headers, `ghp_…`/`github_pat_…`/`glpat-…` tokens). Secrets live only in the Keychain (Phase 5); never argv, URLs, env dumps, logs or preferences. |
| Untrusted repository config executing code (`core.fsmonitor`, `core.sshCommand`, hooks, filters) | **Decided (Phase 1):** Jit follows Git's trust model — `git status` in Jit runs exactly what `git status` in Terminal would (a configured `core.fsmonitor` hook, clean filters such as Git LFS), only for repositories the user opened, and Git's own ownership check (`safe.directory`) still refuses repositories owned by another user. Neutralizing only `core.fsmonitor` would not stop a repository-defined filter, and neutralizing filters breaks status for LFS repositories. Jit never enables or changes `core.fsmonitor`. Hooks run only as Git runs them (ADR-0014, Phase 3). |
| Repositories owned by other users | **Enforced:** Git's dubious-ownership refusal is surfaced as "unsafe repository"; Jit never adds `safe.directory` (test `dubiousOwnershipMapsToUnsafeRepository`). |
| `/usr/bin/git` shim triggering the CLT installer | **Enforced:** the locator only checks file existence and returns Apple's real Git binary inside the developer tools, never the shim; it never runs `xcrun`. |
| Runaway or orphaned processes | **Enforced:** per-command output caps, process-group kill on cancel/timeout, all live groups killed on quit. |
| Modification of global config | **Enforced:** Jit never writes `~/.gitconfig` or `~/.ssh/config`. Profiles store identities in Jit's own `profiles.json`; "Fill from Git config" only runs `git config --global --get`. Phase 3 applies a `ProfileSnapshot` per invocation via `GIT_AUTHOR_*`/`GIT_COMMITTER_*`. Phase 1 evidence: `~/.gitconfig` SHA-256 identical before/after all profile operations. |
| App state files | **Enforced:** `~/Library/Application Support/Jit` is created `0700`; `session.json`, `recents.json`, `profiles.json` are written `0600`, atomically (temp + `fsync` + `rename`). They hold paths, tab titles, layout and identities (name/email) — never secrets (test `testNoSecretFieldsSerialized`). Unreadable files are backed up, not executed or partially trusted. |
| Launching other apps | **Enforced:** Reveal in Finder / Open in Terminal use `NSWorkspace` (`activateFileViewerSelecting`, `open(_:withApplicationAt:configuration:)`) with file URLs — never shell commands. Help opens a fixed https URL in the browser; the app itself makes no network request. Dropped and recent paths are re-validated by discovery before use. |
| Network / telemetry | No network code exists (Phase 1 idle check: no sockets, see `docs/performance.md`). No telemetry, analytics or crash upload. |

## Platform posture
- App Sandbox **off** (needs to run Git and read arbitrary repositories and `~/.ssh`); Developer ID
  distribution in Phase 7.
- **Hardened Runtime on in every configuration** (ad-hoc builds force `--options=runtime`). No
  entitlements are requested. Debug builds disable Xcode's preview dylib because it fails library
  validation under Hardened Runtime.
- Temporary files: tests use per-run directories under `$TMPDIR`; the app creates only its own atomic-write
  temp files next to its JSON files (renamed or removed immediately).
- `JIT_APP_SUPPORT` (all builds) redirects the state directory for tests and benchmarks; it only changes
  where Jit reads/writes its own files.
- Dependencies: none (no third-party packages). Toolchain: Xcode 27.2, XcodeGen (build-time only).
