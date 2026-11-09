# ADR-0017: OAuth flows per provider

- Status: accepted (GitHub device-flow choice to be re-confirmed against live GitHub docs and a registered app)
- Date: 2026-11-09
- Phase: P5
- Requirements: §10, §12, §26 (priority 1); design `docs/phases/05-profiles-and-providers/design.md` §3.3, §4.5, §4.9

## Context
Jit is a native app distributed as a binary: anything compiled in is public, so it can only be an OAuth
**public client** — no client secret may ship. It also may not run a local server (no loopback redirect
listener), poll in the background, or keep tokens outside the Keychain. Two providers, two different
capability sets:

- **GitLab** (gitlab.com and self-managed) supports non-confidential applications using authorization code
  + PKCE with a custom-scheme redirect URI and no secret at the token endpoint. Self-managed admins register
  their own application; Jit asks for its Application ID.
- **GitHub**: OAuth Apps (and GitHub Apps' user tokens) accept PKCE parameters, but — to the best of our
  knowledge as of this decision — the token exchange for the web flow still **requires `client_secret`**;
  PKCE is an addition, not a replacement for the secret. GitHub's **device flow** (RFC 8628) needs only the
  `client_id`, no redirect URI, and is designed for exactly this case. Revoking a GitHub grant through the
  API (`DELETE /applications/{client_id}/grant`) also needs the secret. This was decided from documentation
  knowledge, **not** verified against a live registered app (no client ID is registered yet).

## Decision
**General**
- Client IDs only, from `OAuthClients.plist` (`GitHubClientID`, `GitLabClientID`); empty/missing/invalid
  characters → `nil` → the OAuth card is hidden and explained, never faked (`OAuthClients`). Self-managed
  GitLab uses the instance's configured Application ID. No secret is ever read or sent.
- OAuth requests are form-encoded POSTs with `Accept: application/json`, `User-Agent: Jit`, no cookies, no
  `Authorization` header. Secret values (refresh tokens, device codes, tokens being revoked) are
  percent-encoded byte by byte into the request body without becoming `String`s (`FormBody`). Token
  responses are read with a small flat-JSON reader that yields string values as bytes → `SecretBytes`
  (`FlatJSON`), so access/refresh tokens never pass through `String` in Jit's code (the `URLSession` body
  buffer is outside our control). The only `String` form of a token is the per-request `Authorization`/
  `PRIVATE-TOKEN` header value, built inside one function call and dropped after.
- Keychain format for an OAuth account: one item holding JSON `{"v":1,"token_type","expires_at","scope",
  "access":<base64>,"refresh":<base64>}`, built and parsed as bytes (`OAuthTokens.keychainData()` /
  `init(keychainData:)`), wrapped in `SecretBytes`.
- Errors (`OAuthError`) are plain language and carry only sanitized OAuth error codes (`[a-z0-9_.-]`, ≤ 64);
  never codes, verifiers, tokens or response bodies. Descriptions of token types are redacted.

**GitLab — authorization code + PKCE (S256) + state**
- `PKCE`: verifier = base64url(32 CSPRNG bytes) = 43 chars; challenge = base64url(SHA-256(verifier))
  (RFC 7636 Appendix B vector tested). `OAuthState`: 128 random bits, constant-time comparison.
- Authorize URL: `<web base>/oauth/authorize?client_id&redirect_uri=jit://oauth/gitlab&response_type=code
  &state&scope=read_api read_repository write_repository&code_challenge&code_challenge_method=S256`.
- The browser step is a seam, `OAuthBrowserSession.authenticate(url:callbackScheme:)`, implemented in
  Features with `ASWebAuthenticationSession` (callback scheme `jit`). Services does not import
  AuthenticationServices (its presentation anchor is AppKit).
- Callback (`GitLabOAuthClient.handleCallback`): only `jit://oauth/gitlab` with the in-flight session's
  `state` counts; wrong scheme/path, missing/unknown state, or a second callback → `.ignored`. A code is
  handed out once per `GitLabAuthorization`. `error=access_denied` → neutral `.cancelled`.
- Exchange: `POST <web base>/oauth/token` `grant_type=authorization_code, client_id, code, redirect_uri,
  code_verifier` — no secret. Refresh: `grant_type=refresh_token, client_id, refresh_token, redirect_uri`;
  GitLab rotates refresh tokens, so the caller stores the returned pair. Logout: `POST /oauth/revoke`
  `client_id, token` (best effort), then Keychain delete.
- **Just-in-time refresh** (`OAuthRefresher` actor): when a token is needed and it expires within 60 s,
  refresh once per account even with N concurrent callers (single-flight `Task` per account ID). A rejected
  refresh, or an expired token with no refresh token → `OAuthError.refreshFailed` → caller marks the account
  `expired`. Transport failures (offline, DNS, TLS, proxy) pass through unchanged — offline is not expiry.
  No timers, no background refresh; the refresher holds no tokens (load/store closures hit the Keychain).

**GitHub — device flow (amends the "auth code + PKCE" wording for GitHub)**
- `POST https://github.com/login/device/code` `client_id, scope=repo read:org` → user code + verification
  URL (must be `https://github.com/...`, else refused), then `poll`: sleep `interval`, `POST
  /login/oauth/access_token` `client_id, device_code, grant_type=urn:ietf:params:oauth:grant-type:device_code`.
  `authorization_pending` → wait; `slow_down` → interval + 5 s (or the server's new interval if larger);
  `expired_token` or local expiry → `.expired`; `access_denied` → `.cancelled`; other codes (e.g.
  `device_flow_disabled`) → `.provider(code:)`.
- This is Jit's only polling. It runs inside the caller's `Task` while the sign-in sheet is open and stops on
  success, expiry, denial or cancellation (`Task.sleep` throws on cancel; the sleeper is injectable for tests).
- The device code is held as `SecretBytes` and never displayed.
- Logout deletes local tokens and links to `https://github.com/settings/applications` (revocation through
  the API requires the secret Jit doesn't have).
- Git-over-HTTPS username for GitHub OAuth tokens: `x-access-token`; GitLab OAuth: `oauth2`
  (`gitCredentialUsername`).
- The maintainer must tick "Enable Device Flow" in the GitHub OAuth App settings; otherwise GitHub answers
  `device_flow_disabled`, shown as such.

## Consequences
- No secret in the binary; `noClientSecretInBinary` (P5.7 `strings` scan) stays meaningful.
- GitHub sign-in requires the user to type/confirm an 8-character code in the browser — one extra step
  versus a redirect, accepted for the no-secret guarantee.
- GitHub OAuth App tokens don't expire, so no GitHub refresh path is implemented. If Jit moves to a GitHub
  App with expiring user tokens, refresh (which GitHub documents as needing the client secret) must be
  re-evaluated — revisit this ADR then.
- Revisit the GitHub choice if GitHub documents secret-less PKCE for public clients with custom-scheme
  redirects; re-verify against current docs and a real registered app before Phase 5 sign-off (P5.7).
- Not verified live: GitLab.com and GitHub endpoints were exercised only through recorded-fixture stubs; real
  sign-in is blocked on client-ID registration.
