# ADR-0036: SSH invocation (helper wrapper, strict config, Jit-owned known_hosts, host-key trust)

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §10.3, §13.5, §19

## Context
SSH must use exactly the profile's key (or agent), never another account's `IdentityFile` from
`~/.ssh/config`, never accept host keys silently, never write the user's `~/.ssh` files, and handle key paths
with spaces or quotes safely.

## Decision
- Git gets `GIT_SSH_COMMAND='<quoted helper path>'` and `GIT_SSH_VARIANT=ssh` (deviation from the design's
  `GIT_SSH`: `core.sshCommand` in a user's config outranks `GIT_SSH` but not `GIT_SSH_COMMAND`). The only shell
  word is Jit's own path; keys, known_hosts files and proxy travel in `JIT_SSH_*` variables. The helper
  `execv`s `/usr/bin/ssh` with an argv array.
- Options: strict mode `-F none` (default; the profile can opt into the user's config), key mode
  `-o IdentitiesOnly=yes -i <key>` (+ `IdentityAgent=none` without an agent), agent mode `IdentityFile=none`,
  `StrictHostKeyChecking=yes`, `UpdateHostKeys=no`, `UserKnownHostsFile="<~/.ssh/known_hosts>" "<Jit file>"`,
  `PasswordAuthentication=no`, `KbdInteractiveAuthentication=no`, `BatchMode=no`, `ConnectTimeout=30`.
- Passphrases: the helper sets `SSH_ASKPASS` to itself and `SSH_ASKPASS_REQUIRE=force` **for ssh only** (Git's
  own environment keeps askpass disabled — `ProcessEnvironment.nonInteractive` is applied last). Askpass mode
  refuses yes/no, fingerprint and password prompts and asks the broker only for the expected key. ssh truncates
  long key paths in the prompt, so the broker accepts the expected path or a ≥24-character prefix of it.
  "Remember in Keychain" is off by default.
- Host keys: unknown → failure classified `sshHostKeyUnknown` → trust sheet (`ssh-keyscan -p <port> -t
  ed25519,ecdsa,rsa -- host`, SHA-256 fingerprints computed in Swift, comparison with GitHub's `/meta` for
  github.com; GitLab.com has no machine-readable source, so no comparison). Trust appends a hashed
  (`|1|salt|hmac`) entry to `AppSupport/Jit/known_hosts` (`0600`). A different key for a trusted host is a hard
  error in ssh and in `KnownHostsStore.trust` — there is no override.
- SSH proxies: SOCKS5/CONNECT via `nc -X`, without proxy auth (documented limitation).

## Consequences
- Evidence (rig sshd): unknown host fails without writing anything, trust writes only Jit's file (hashed,
  `0600`) and `~/.ssh` is byte-identical, passphrase via askpass with a key path containing spaces and a
  quote, changed host key is a hard error, strict mode doesn't fall back to `~/.ssh/id_*`.
- `ssh-keyscan` cannot use a ProxyCommand: on proxy-only networks the trust sheet can't read keys (explained).
