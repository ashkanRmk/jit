# Security

Status: threat model v1 (Phase 0). Enforcement arrives with each feature; what Phase 0 already
enforces is marked **enforced**.

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
| Untrusted repository config executing code (`core.fsmonitor`, `core.sshCommand`, hooks, filters) | Phase 0 runs only `rev-parse`/`symbolic-ref`, which execute none of these. Decision on neutralizing repo-configured executables for read commands: Phase 1 (ADR-0008). Hooks run only as Git normally runs them, and the UI will say so. |
| Repositories owned by other users | **Enforced:** Git's dubious-ownership refusal is surfaced as "unsafe repository"; Jit never adds `safe.directory` (test `dubiousOwnershipMapsToUnsafeRepository`). |
| `/usr/bin/git` shim triggering the CLT installer | **Enforced:** the locator only checks file existence and returns Apple's real Git binary inside the developer tools, never the shim; it never runs `xcrun`. |
| Runaway or orphaned processes | **Enforced:** per-command output caps, process-group kill on cancel/timeout, all live groups killed on quit. |
| Modification of global config | **Enforced by construction:** Jit never writes `~/.gitconfig` or `~/.ssh/config`; identity will be applied per invocation (`-c`), Phase 1/3. |
| Network / telemetry | No network code exists. No telemetry, analytics or crash upload. |

## Platform posture
- App Sandbox **off** (needs to run Git and read arbitrary repositories and `~/.ssh`); Developer ID
  distribution in Phase 7.
- **Hardened Runtime on in every configuration** (ad-hoc builds force `--options=runtime`). No
  entitlements are requested. Debug builds disable Xcode's preview dylib because it fails library
  validation under Hardened Runtime.
- Temporary files: tests use per-run directories under `$TMPDIR`; the app creates none in Phase 0.
- Dependencies: none (no third-party packages). Toolchain: Xcode 27.2, XcodeGen (build-time only).
