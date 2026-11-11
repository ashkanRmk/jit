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
| Program-executing display config (gpg via `log.showSignature`, external diff, textconv) | **Enforced (Phase 2, ADR-0023):** history/details/compare reads pass `-c log.showSignature=false`, `--no-show-signature`, `--no-ext-diff`, `--no-textconv`; revisions follow `--end-of-options`, paths `--`; search text is a literal `--grep=`/`--author=` argument (`--fixed-strings`). Jit never writes a commit-graph or any other file under `.git` to speed up reads. |
| Hostile commit messages / ref names (terminal escapes, bidi overrides) | **Enforced (Phase 2):** displayed as plain text; control characters become Unicode control pictures, bidi controls are removed and RTL text is isolated (`DisplayText.sanitize`, `DisplayTextTests`). |
| Diffs executing programs or misleading the patch builder | **Enforced (Phase 3, ADR-0026):** one canonical `git diff` command: `--no-ext-diff --no-textconv`, `-c diff.external=`, fixed `a/`/`b/` prefixes, `--literal-pathspecs`; untracked files are diffed from raw bytes in-process (no `git add -N`). |
| Line actions damaging unrelated content | **Enforced (Phase 3, ADR-0013):** every line action re-checks a snapshot token inside the per-repository write gate, applies a patch built from the parsed bytes only after `git apply --check`, verifies the result against an independently computed expectation and rolls the index entry back on mismatch. Matrix + property tests assert every other file and index entry is byte-identical. |
| Temporary patch files | **Enforced:** written to a fresh `0700` directory as a `0600` file, passed by absolute path, deleted after the operation. |
| Data loss from discards | **Enforced (ADR-0025):** confirmation sheet saying what changes and what is lost; tracked files copied to `~/Library/Application Support/Jit/Recovery/<hash>/…` (`0700`/`0600`, `meta.json` without secrets) before anything changes; untracked files go to the Trash; stale tokens refuse; retention 7 days / 500 MB pruned at launch. |
| Commit hooks | **As Git (ADR-0014):** opening a repository and committing can execute that repository's hooks (pre-commit, commit-msg, …), exactly as `git commit` in Terminal would. `--no-verify` only through an explicit, confirmed "Commit Without Running Hooks…". Cancelling kills the hook's process group. |
| Commit identity leaking into config or argv | **Enforced (ADR-0028):** the profile snapshot is applied through `GIT_AUTHOR_*`/`GIT_COMMITTER_*` of one child process only; never argv (`-c user.name=` would be visible in process listings), never written to `~/.gitconfig` or `.git/config` (`commitDoesNotModifyAnyConfig` hashes both). |
| Remote operations prompting or leaking credentials (Phase 4, ADR-0032) | **Enforced:** remote commands add `-c protocol.ext.allow=never -c protocol.fd.allow=never`, `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"`, `GCM_INTERACTIVE=never` on top of the non-interactive base; unknown or changed host keys fail (never accepted silently; a changed key is a warning without Retry). Remote URLs shown in Jit are masked (`user:password@`, token-shaped strings). |
| Clone URLs as options or command transports | **Enforced:** URLs starting with `-`, `transport::address` (ext, fd, …) and unknown schemes are refused before Git runs; `http://` needs an explicit insecure-transport confirmation; `git clone -- <url> <dest>`; Jit creates the destination folder itself, so cancel/failure cleanup only removes a folder Jit created. |
| Destructive Git operations | **Enforced (ADR-0015, ADR-0030):** delete branch (`-d`, then `-D` after a second sheet listing unmerged commits), delete remote branch (leased to the shown tip), force push (`--force-with-lease=<ref>:<oid> --force-if-includes`, never plain `--force`), skip, abort, drop stash and non-text conflict choices need a `ConfirmationToken` naming the exact action; stale state tokens refuse. |
| Conflict resolution overwriting work | **Enforced (ADR-0031):** the document comes from index stages; a working file that differs from Git's own merge (labels ignored) is flagged and never overwritten silently; saves are hash-guarded, atomic (temp + fsync + rename, mode kept), only for currently conflicted paths inside the work tree (no `.git`, no symlinked parents); Mark as Resolved only on explicit request. Stage blobs go to a `0700` temp folder removed afterwards. |
| Network / telemetry | Network only when the user starts fetch / pull / push / clone (Phase 4), plus author pictures from gravatar.com for commits on screen (0.0.2, ADR-0050: SHA-256 of the email only, once per author, no cookies or credentials, off switch in Settings ▸ General); no background fetch, no telemetry, analytics or crash upload. Before Phase 4: no network code (Phase 1 idle check: no sockets, see `docs/performance.md`). No telemetry, analytics or crash upload. |

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

## Phase 5 — credentials, SSH, TLS and proxies (ADR-0016, 0018, 0035, 0036)
- **Secrets** (tokens, OAuth token JSON, SSH passphrases, proxy passwords) live only in the Keychain:
  generic passwords, service `<bundle id>.account|.ssh-passphrase|.proxy`, account = Jit ID,
  `WhenUnlockedThisDeviceOnly`, never synchronized. In memory they are `SecretBytes` (wiped, redacted).
- **Credential delivery**: every remote Git command gets `-c credential.helper=` (inherited osxkeychain/GCM
  helpers can never answer); with an account, `jit-git-helper` is the only helper. It asks an operation-scoped
  broker (Unix socket in a `0700` temp dir, 256-bit nonce, peer must be the bundled helper, ≤ 16 requests,
  torn down when Git exits) that answers only for the operation's host:port, proxy or SSH key.
- **No fallback**: credentials come strictly from the active profile's account ID; mismatches are explained with
  explicit "Switch to '<profile>' and Retry" actions — never automatic.
- **SSH**: `-F none` by default, the profile's key only (`IdentitiesOnly`), `StrictHostKeyChecking=yes`, user
  known_hosts read-only, Jit's own hashed known_hosts written only through the trust sheet; changed keys are
  hard errors. No password/keyboard-interactive auth; askpass answers only the expected key's passphrase.
- **TLS/proxy**: custom CAs per server (CA certificates only), trust scoped to that host:port, system roots kept;
  no insecure TLS setting anywhere (`InsecureSettingsLintTests`). Proxy passwords never in URLs or argv.
- **Tests**: sentinel-secret scans of every spawned argv/env (`ProcessRunner.spawnObserver` test hook),
  redaction tests, rig integration tests (`JIT_RIG=1`). `~/.gitconfig` and `~/.ssh/*` are never written.

## Phase 7 — release posture (ADR-0019, 0020, 0045–0049)
- **Signing**: Hardened Runtime on every Mach-O (app, `jit-git-helper`, bundled Git), **no entitlements**,
  App Sandbox off (ADR-0045). Inside-out signing, never `--deep` (ADR-0046). Signing identities and notary
  credentials stay in the keychain; `.gitignore` blocks `*.p12 *.cer *.p8 AuthKey_*.p8 *.provisionprofile
  release.local.env notary-*.json`. 1.0.0 is so far signed **ad-hoc only**: no Developer ID, not notarized.
- **Credential broker peer**: in Developer ID builds the helper must also be valid code signed by Jit's team,
  checked by audit token (`PeerCodeSignature`); ad-hoc builds keep the executable-path check.
- **Bundled Git** (ADR-0019): Git 2.56.0 from the kernel.org tarball (SHA-256 pinned; PGP check available but not
  run — gpg isn't installed on the release machine). It links only macOS system libraries (libcurl with Apple's
  trust store, zlib, iconv) and has its own empty system config inside the signed bundle, so it can't inherit
  another Git's `credential.helper`. Pruned to 16 files. Patch process: `docs/release.md`.
- **Git resolution**: never runs the `/usr/bin/git` shim or `xcrun`. A custom Git is validated before use. The
  CLT installer starts only from an explicit button.
- **Updates** (ADR-0051): from the project's GitHub Releases. Off by default — a request is made only on Check for Updates; with "Update Jit automatically" on, at most one check a day (on start or activation, no timer). The DMG is checked against its published SHA-256, the app inside must be Jit (bundle ID, expected and newer version, strict code-signature validation, same Developer ID team when Jit has one) and is swapped in atomically at quit. Ad-hoc releases carry no publisher identity: trust is GitHub over TLS plus the repository's release permissions (see the ADR's follow-up on signing).
- **Dependency audit (2026-11-09)**: JitKit has no third-party Swift packages (no `Package.resolved`); build-time
  tools are Xcode 27.2 and XcodeGen 2.46. The only bundled third-party component is Git 2.56.0 (GPLv2; license,
  source location and written offer in the app). Git 2.56.0 is the newest release on kernel.org as of
  2026-11-09.
- **Binary audit** (`scripts/release/` output, 1.0.0): no development-only targets, Swift modules, dSYMs, key
  files or `.DS_Store` in the app (`03-verify-archs.sh`). The `strings` scan results are in progress.md.
- **OAuth**: no `OAuthClients.plist` is bundled, so GitHub/GitLab OAuth sign-in reports "not configured" in
  1.0.0. Registering the public OAuth clients is an owner action (`docs/release.md`). PAT and SSH work.
