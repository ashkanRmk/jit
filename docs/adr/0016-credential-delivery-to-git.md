# ADR-0016: Credential delivery to Git (helper binary, cleared helpers, operation-scoped broker)

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §10.2, §10.3, §13.5, §19

## Context
Git needs HTTPS credentials (and SSH key passphrases, and proxy passwords) without prompts, without the
secret ever appearing in argv, URLs, a logged environment or a file, and without silently using another
account. Apple's and Homebrew's Git ship `credential.helper=osxkeychain` in system config: left in place it
would answer with whatever account the user last stored for a host (a silent wrong-account success) and
receive `store` calls that persist Jit's token in a Keychain item Jit doesn't control.

Two broker channels were considered (design §7): (A) an inherited anonymous socketpair FD, (B) a per-operation
Unix socket plus nonce. `ProcessRunner` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT`, Git runs helpers through
`sh -c`, and an inherited FD would have to survive Git → shell → helper for every Git version we support,
plus not leak into hooks and unrelated children. B has no such dependency and is testable in isolation.

## Decision
- One Swift executable, `jit-git-helper` (target `JitGitHelper`, Foundation/Darwin only), embedded at
  `Contents/Helpers/jit-git-helper` (XcodeGen `tool` target copied into the wrapper). Modes:
  `credential get|store|erase`, askpass (`JIT_HELPER_MODE=askpass`), and the `GIT_SSH_COMMAND` target
  (ADR-0036). It holds no secrets at rest, logs nothing and exits after one request.
- Every remote Git invocation gets `-c credential.helper=` (clears every inherited helper, including
  URL-scoped ones read from config files before `-c`). With an account (or proxy auth) it then gets
  `-c credential.helper=!'<helper>' credential`, `credential.useHttpPath=false`, `credential.interactive=false`.
  The `!` form is required: a quoted absolute path would be read as `git credential-<name>`.
- Channel **B**: `Services.CredentialBroker` per remote operation — `mkdtemp` directory (`0700`) under
  `$TMPDIR`, socket `0600`, 256-bit nonce, both passed only in that invocation's environment
  (`JIT_BROKER_SOCKET`/`JIT_BROKER_NONCE` — not secrets by themselves). The peer is verified with
  `LOCAL_PEERPID` → `proc_pidpath` == the bundled helper's resolved path (release builds should add an
  audit-token/`SecCode` team check — Phase 7). Answers only for the policy's HTTPS host:port, proxy host:port
  or expected SSH key; refuses and logs (host only) anything else. Serviced by Dispatch read sources on one
  serial queue (no idle thread); torn down when GitCore releases the lease after Git exits.
- Deviation from "single-use nonce": the nonce is **operation-scoped** with a hard cap of 16 requests,
  because Git legitimately calls the helper several times per operation (get + store/erase, several remotes
  for `fetch --all`, proxy auth). Replay outside the operation is impossible (the socket is gone).
- Secrets are `SecretBytes` end to end (wiped with `memset_s`, redacted descriptions) and are written from
  that buffer to the socket as a length-prefixed raw block; the helper writes them to Git's stdout and wipes.
- `store` → account status ok; `erase` → account `rejected` (shown in Settings ▸ Accounts / error sheets).

## Consequences
- Users who relied on `osxkeychain` for Jit's remotes must connect an account; this is intended (§10.2).
- Evidence: `BrokerHelperTests` (real `git credential fill` with a recording repo helper that must not run,
  unexpected host/port refused, forged nonce and foreign peer refused, erase → rejected, askpass only for the
  expected key, sentinel never in argv/env), `RigIntegrationTests` (HTTPS clone+push through the rig).
- Revisit if Git adds a supported FD-based credential channel, or if peer verification needs SecCode checks
  for distribution builds (Phase 7).
