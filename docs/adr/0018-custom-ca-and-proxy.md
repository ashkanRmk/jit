# ADR-0018: Custom CA and proxy application for URLSession and Git

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §12, §19

## Context
Enterprise GitLab servers use private CAs and sit behind proxies (often PAC). Git does not read macOS proxy
settings, and must never be told to skip TLS verification. The same trust and proxy policy must apply to the
API (URLSession) and to Git, scoped to the hosts that need it.

## Decision
- **CA import** (`CAStore`): PEM/DER/.cer parsed with `SecCertificateCreateWithData`; must have basic
  constraints CA=true — leaf certificates are rejected with guidance. Stored as PEM in
  `AppSupport/Jit/ca/<sha256-prefix>.pem` (`0700` dir, `0600` files); several CAs per server are combined into
  a bundle file on demand (rotation: add new, remove old).
- **CA and proxy are properties of the server, not the profile**: a configured server's CA/proxy applies to
  every profile that reaches that host (found during the hands-on pass: an identity-only profile otherwise
  failed TLS before it could be told it had no account). Credentials still come only from the active profile.
- **URLSession**: one ephemeral session per instance (no cache, no cookies); `ScopedTrustDelegate` handles
  server trust only for the server's host:port with `SecPolicyCreateSSL(true, host)`, its CAs as anchors and
  `SecTrustSetAnchorCertificatesOnly(false)` (system roots stay valid); any other host → default handling.
  There is no code path that accepts an untrusted chain.
- **Git**: `-c http.<scheme://host[:port]/>.sslCAInfo=<pem>` per invocation (origin-scoped). On the dev
  machine's Homebrew Git 2.54 (curl + SecureTransport/OpenSSL per build), a scoped `sslCAInfo` replaces the
  default bundle *for that origin only*; public hosts are unaffected (`otherHostsUseDefaultTrust` is covered by
  scoping). Re-check with the bundled Git in Phase 7.
- **Proxy**: modes inherit-global / System (CFNetwork settings, exception list, PAC via
  `CFNetworkExecuteProxyAutoConfigurationURL`, once per operation) / Manual (HTTP, HTTPS, SOCKS5) / Direct.
  Git gets `-c http.<origin>.proxy=http://[user@]host:port` or `socks5h://…`; Direct → empty value. The
  **username** is in the proxy URL (not a secret; Git only asks the credential helper for a proxy password when
  the URL names a user); the password comes from the Keychain through the broker. Verified on Git 2.54 against
  the rig's authenticating proxy (407 then 200). URLSession uses `connectionProxyDictionary` and answers proxy
  challenges from the Keychain. SSH uses `ProxyCommand=/usr/bin/nc -X 5|connect -x host:port` without auth.
- Never `http.sslVerify=false`, `GIT_SSL_NO_VERIFY`, or a trust-all delegate — enforced by
  `InsecureSettingsLintTests` and `FrameworkTests`.

## Consequences
- Loopback targets are never proxied by macOS networking, so the diagnostics TLS-through-proxy path is only
  stub-tested; a real non-loopback proxy needs manual validation.
- PAC execution needs the main run loop (the app has one; a 10 s cap protects operations).
