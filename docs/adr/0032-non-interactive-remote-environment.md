# ADR-0032: Non-interactive remote execution and protocol policy (Phase 5 hook point)

- Status: accepted
- Date: 2026-11-09
- Phase: P4
- Requirements: §13.5, §19; ADR-0016 (Phase 5)

## Context
No Git invocation may ever wait for a prompt. Phase 5 adds credentials and network settings without changing
call sites.

## Decision
- Every command: sanitized env, `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=SSH_ASKPASS=/usr/bin/false`,
  `SSH_ASKPASS_REQUIRE=never`, `GIT_EDITOR=GIT_SEQUENCE_EDITOR=true`, `GIT_MERGE_AUTOEDIT=no`,
  `GCM_INTERACTIVE=never`, no TTY (own session).
- Remote commands (`GitEnvironment.remoteCommand(ExecContext)`): `-c protocol.ext.allow=never
  -c protocol.fd.allow=never`, `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"`, no
  timeout (cancellation is the user's). `ExecContext { identity, auth: .nonInteractive, network:
  .systemDefault }` is the hook Phase 5 extends.
- `GIT_PROTOCOL_FROM_USER=0` is **not** set: it also blocks top-level `file://` remotes (Git's default `file`
  policy is "user"), and Jit never recurses into submodules in V1.
- Clone URLs: https, ssh, scp-like, git, local/file; `http://` only after explicit confirmation; `-…`,
  `transport::address` and unknown schemes refused before Git runs. No user value reaches a `-c` option.

## Consequences
ssh-agent keys and public HTTPS work; anything needing a password fails fast (local HTTP 401: ~50 ms) with an
explanation. Unknown SSH host keys fail (user accepts once in Terminal) — never accepted silently.
