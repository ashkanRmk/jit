# ADR-0038: Connectivity diagnostics and offline policy

- Status: accepted
- Date: 2026-11-09
- Phase: P5 (P5.9 diagnostics, P5.12 offline / VPN)
- Requirements: §12 (enterprise networking), §26 (priorities); design 05 §3.7, §4.10

## Context
Enterprise users meet failures that look the same from Git's side ("couldn't connect") but have very different
fixes: no network, VPN not connected (internal names don't resolve), a proxy that is required or broken, a
firewall dropping a port, a TLS-intercepting proxy or a private CA, a base URL missing its path prefix, a
revoked token, an unknown or changed SSH host key. Users need to find out *which* one, in plain language, and
hand a report to their IT department without leaking secrets.

Constraints: no polling, no repeating timers, no background work (CLAUDE.md hard rules); secrets never in
logs or copied text; an untrusted certificate must never be accepted, not even "just to look at it"; the API
traffic already has a transport per instance with proxy and scoped CA trust (ADR-0018, ADR-0037).

Options considered for the TLS step:
1. **URLSession with a recording delegate** — respects proxies and PAC exactly like API requests, but the
   delegate only sees the trust when a challenge arrives and the chain/anchor details are awkward to surface
   for both success and failure.
2. **NWConnection with a TLS verify block** — the verify block receives the server's `sec_trust_t` for every
   handshake; Jit evaluates it with the same function the URLSession delegate uses
   (`ScopedTrustDelegate.evaluate`: instance CAs + system roots, SSL policy with host name) and completes the
   handshake with that honest result. Proxies are supported through Network.framework's
   `ProxyConfiguration` (HTTP CONNECT and SOCKS5, with credentials) in a per-connection `PrivacyContext`.
3. **`openssl s_client` / `nscurl`** — external processes, different trust store, rejected.

## Decision
**Offline policy (ConnectivityState).** `NWPathMonitor` runs event-driven while the app is active. An
unsatisfied path makes remote operations and provider requests fail immediately with "You're offline";
nothing retries automatically. When the path comes back after an offline failure, a passive "Back online —
Retry" affordance appears. DNS failures for single-label names, private suffixes (`.corp`, `.internal`,
`.local`, `.lan`, `.intranet`, `.home.arpa`, `.private`) and RFC 1918 literals add the VPN hint
(`NetworkHints`). Timeouts, refusals and TLS failures are reported separately.

**Diagnostics (`DiagnosticsRunner`, Services; `DiagnosticsView`, Features).** Runs only when the user presses
"Test Connection"; there is no scheduled or automatic run. Eight ordered steps stream status updates
(`pending → running → passed | warning | failed | skipped`), each with a plain-language result, optional detail
lines and a next step:

1. Network path — from the injected `PathSnapshot` (satisfied / constrained / unsatisfied, VPN-like interface).
   Offline stops the run; every later step is skipped.
2. DNS — `getaddrinfo` on a GCD worker (it blocks). "Name not found." plus the VPN hint for internal-looking
   names. When a proxy is in use, a local lookup failure is only a warning (the proxy resolves names).
3. Proxy — the same `ProxyResolving` decision Git and the API use (System / PAC / Manual / Direct / exception
   list); a chosen proxy is checked with a TCP connect. User names never appear in results or the report.
4. TCP to the HTTPS port — `NWConnection`, through the proxy when one applies; refused, timed out (10 s) and
   unreachable are distinct results.
5. TLS — option 2 above. The verify block never accepts a chain that `ScopedTrustDelegate.evaluate` rejects; the
   handshake is aborted and only the explanation differs. Failures are classified by re-evaluating the
   captured chain: validity dates (expired / not yet valid) → same chain without the host-name requirement
   (passes ⇒ host-name mismatch) → otherwise unknown issuer ("import your company's CA in Servers & Network").
   Success shows subject, issuer, expiry, SAN names and whether a macOS root or an imported CA anchored the
   chain; expiry within 30 days is a warning.
6. HTTP — through the instance's own `HTTPTransport` (`AccountsService.transport(for:)`): GitLab `GET
   <api>/version` (200 with a version, or 401/403, counts as reachable; 404 or HTML ⇒ wrong path prefix;
   older than the minimum ⇒ warning), GitHub `GET <api>/meta`. No token is sent in this step.
7. Authentication — only with an account: the provider's `currentUser()`; 401 ⇒ token rejected; a different
   login ⇒ warning.
8. SSH — TCP to `sshHost:sshPort`, then `ssh-keyscan` fingerprints compared with Jit's and the user's
   known_hosts: trusted, not trusted yet ("Jit will ask you to verify it"), or changed (security error).

A step that depends on a failed one is `.skipped` with the reason. Every network piece sits behind
`DiagnosticsProbing` (DNS, TCP, TLS, host-key scan) or the existing `HTTPTransport` / `ProxyResolving` seams so
tests can force each failure without a network. Timeouts are one-shot `asyncAfter` deadlines per connection;
cancelling the run (Stop, leaving the view) cancels in-flight probes.

**Report.** "Copy Report" produces plain text from the step results plus non-secret configuration. It is passed
through `DiagnosticsReport.sanitize`: user info stripped from every URL (`RemoteURL.masked`), header-style
secrets (`Authorization`, `Proxy-Authorization`, `PRIVATE-TOKEN`, `JOB-TOKEN`, `X-API-Key`) and GitLab/GitHub
token formats redacted.

## Consequences
- Users get a specific, actionable answer for each failure class, and support gets a safe report.
- The TLS step and API trust use one evaluation function, so diagnostics can't disagree with real requests.
- macOS (Network.framework and URLSession) never proxies loopback targets; the runner mirrors that and does not
  claim to tunnel to `localhost`/`127.x`. Consequently the proxy tunnel of steps 4–5 cannot be exercised against
  the loopback-only test rig (ADR-0039); the proxy reachability check and the full direct path are. Manual
  validation against a real proxy remains part of P5.14.
- The SSH step connects directly: `ssh-keyscan` has no ProxyCommand. Behind a SOCKS/CONNECT-only network the
  step reports the failure; SSH-through-proxy diagnostics would need Jit's own key exchange — revisit if
  P5.11's SSH ProxyCommand support lands and users ask for it.
- PAC scripts run once per diagnostics run (same as one operation).
- Forbidden: automatic or periodic diagnostics, retry loops, accepting an untrusted certificate in any probe,
  copying tokens or proxy user names into the report.
