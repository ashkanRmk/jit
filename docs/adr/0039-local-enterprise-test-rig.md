# ADR-0039: Local enterprise test rig

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §12 (enterprise networking: custom CA, proxies), §26 (correct Git behaviour, protect data);
  design §4.10, implementation P5.14

## Context
Phase 5 adds custom CAs, manual HTTP/SOCKS5 proxies with authentication, self-managed GitLab (including path
prefixes), PAT-over-HTTPS and SSH key/passphrase handling. These paths cannot be tested against real
services in CI (no internet, no secrets) and must not be tested by mocking Git output (CLAUDE.md: real
repositories). We need real TLS with a private root, real `git http-backend`, real proxies that can prove
traffic went through them, a GitLab-shaped API and a real `sshd` — all local and disposable.

Options considered:
- **Docker (GitLab CE, squid, dante):** heavy (GitLab CE needs GBs of RAM and minutes to boot), needs a
  daemon, not available on every dev Mac or CI runner; rejected.
- **Python/Node helper servers:** extra toolchains outside the project's Swift-only rule (ADR-0002) and
  hard to keep consistent with the Network.framework/Security behaviour the app relies on; rejected.
- **A small dev-only Swift executable + system tools:** Network.framework (`NWListener`) for HTTP/1.1, TLS
  and proxies, `SecPKCS12Import` + `sec_identity_create` for the TLS identity, Git's own
  `git http-backend` as CGI, `/usr/bin/openssl` (LibreSSL) for certificates, macOS `/usr/sbin/sshd` run as
  the user. No third-party dependencies, no daemon.

## Decision
- `TestRig` is a SwiftPM executable target in JitKit (`Sources/TestRig`, Foundation/Darwin/Network/Security
  only). It is **dev-only and never embedded in the app** bundle or linked by any app target.
- `TestRig git-server` serves HTTP or TLS (PKCS#12 imported with `kSecImportToMemoryOnly`, so the login
  keychain is never touched): `/git/…` → CGI `git http-backend` (`GIT_PROJECT_ROOT`, `http.receivepack`
  via `GIT_CONFIG_COUNT`, chunked and gzip request bodies passed through, `Git-Protocol` forwarded),
  Basic auth from a `username:token` file (`--any-username` for GitLab-style PATs, `--deny-user` → 403),
  a deterministic GitLab v4 stub (`version`, `user`, `personal_access_tokens/self`, 120 `projects` with
  search and `X-*`/`Link` pagination), `--path-prefix`, `--throttle-kbps` (KiB/s) and a request log that
  records only method, path and status.
- `TestRig proxy` provides an HTTP proxy (CONNECT + absolute-URI forwarding) and optional SOCKS5 (CONNECT;
  no-auth or RFC 1929), optional Basic/username-password auth (407 with `Proxy-Authenticate`), and a log
  of each target `host:port` — never credentials. Targets are restricted to loopback unless
  `--allow-remote`.
- Every listener binds `127.0.0.1` only (port 0 → OS-chosen high port) and prints `READY <port> <role>`.
  I/O is event-driven (Network/Dispatch callbacks, `DispatchIO` for the CGI pipes; no polling); SIGTERM and
  SIGINT stop listeners and CGI children via `DispatchSource` signal handlers.
- `scripts/testing/enterprise-rig/{up,down,status}.sh` manage a state directory
  (`${JIT_RIG_DIR:-~/Library/Caches/jit-rig}`): throwaway root CA, an unrelated CA, a server certificate
  (SAN `localhost`, `127.0.0.1`, 397 days), a self-signed leaf (CA:FALSE), `server.p12` (3DES/SHA-1, since
  LibreSSL has no `-legacy`), seeded bare repositories (fixed identity, `GIT_CONFIG_GLOBAL=/dev/null`),
  `users.txt`, ed25519 client keys (with and without passphrase), and a user-level `sshd` with its own
  host key, `authorized_keys`, `UsePAM no`, `StrictModes no`. The running rig is described in `rig.env`
  (`JIT_RIG_*`) and `rig.json`. The scripts never modify `~/.ssh`, `~/.gitconfig` or the login keychain.
- Rig-dependent tests are opt-in (environment-gated) and read their endpoints from `rig.env`/`rig.json`
  or start `TestRig` themselves with the options they need.

## Consequences
- Enterprise paths (custom CA accept/reject, proxy auth and routing, path prefixes, 401/403 handling,
  SSH host keys and passphrases, slow transfers and cancellation) are testable offline and repeatably.
- The rig is test infrastructure, not a product surface: it may use `@unchecked Sendable` with
  per-connection serial queues, buffers CGI output before responding, and its stub API covers only the
  endpoints Jit calls. When Jit starts calling more GitLab endpoints, the stub grows with them.
- The rig contains throwaway secrets (tokens, proxy password, p12 password) in its state directory and
  `rig.env`; these are test values and must never be reused for anything real.
- Revisit if CI runners cannot run a user-level `sshd`, if Apple removes the PKCS#12 algorithms LibreSSL
  emits, or if GitHub Enterprise coverage needs a second API stub.
