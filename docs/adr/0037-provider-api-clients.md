# ADR-0037: Provider API clients, pagination, search, caching, minimum GitLab version

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §10, §12, §26; design `docs/phases/05-profiles-and-providers/design.md` §4.7, §4.8, §7

## Context
Jit talks to GitHub.com, GitLab.com and self-managed GitLab to validate tokens, read scopes/expiry, list
repositories for the remote browser and fetch published SSH host-key fingerprints. Constraints: no
background requests or polling, no disk caches, per-instance proxy/trust policy (design §4.10), secrets only
in the Keychain and never in logs/errors, and plain-language failures that feed the diagnostics panel.

## Decision
**Transport.** `HTTPTransport` (`data(for:) async throws -> (Data, HTTPURLResponse)`) is the only network
seam. `URLSessionTransport` wraps one `URLSession` per provider instance, built from a caller-supplied
configuration (default: `.ephemeral`, `urlCache = nil`, no cookie storage/handling, no credential storage,
`reloadIgnoringLocalCacheData`, 30 s request timeout) and optional session delegate (custom-CA trust). A
per-task delegate follows redirects only within the same scheme/host/port, so a token header never follows a
redirect off-host. Tests use a recording stub transport and a `URLProtocol` stub for the real session path.

**Clients.** `HostingProvider` (`currentUser`, `tokenInfo`, `repositories(page:query:)`,
`publishedSSHFingerprints`) with `GitHubProvider` and `GitLabProvider` structs, constructed with a
`ProviderInstance`, a transport, and a `TokenProvider` closure (`@Sendable () async throws -> SecretBytes`)
called once per request so OAuth refresh happens just in time (ADR-0017). Headers: `User-Agent: Jit` only (no
version or user data). GitHub: `Authorization: Bearer`, `Accept: application/vnd.github+json`,
`X-GitHub-Api-Version: 2022-11-28`. GitLab: PAT → `PRIVATE-TOKEN`, OAuth → `Authorization: Bearer`.

- GitHub `tokenInfo`: `GET /user`; scopes from `X-OAuth-Scopes` (absent/empty → fine-grained PAT or GitHub
  App token: `fineGrained = true`, `scopesKnown = false`); expiry from
  `github-authentication-token-expiration` (`YYYY-MM-DD HH:MM:SS UTC|±HHMM|±HH:MM`, ISO 8601 fallback).
- GitLab `tokenInfo`: PAT → `GET /personal_access_tokens/self` (`expires_at` date-only → 00:00 UTC that
  day); OAuth → `GET <web base>/oauth/token/info` (`scope`, `expires_in`). A 404 returns
  `scopesKnown = false` rather than failing.
- **Repositories / pagination.** GitHub `GET /user/repos?per_page=50&sort=updated&affiliation=owner,
  collaborator,organization_member`; next page = the full `Link rel="next"` URL, accepted only if it has the
  same origin as the API base (a foreign next link ends pagination; a foreign cursor is refused without a
  request). GitLab `GET /projects?membership=true&simple=true&order_by=last_activity_at&per_page=50
  [&search=q]`; next from `X-Next-Page`, else `Link` (keyset), same-origin rule. `PageCursor` is opaque.
  GitLab `simple=true` omits visibility → `RemoteRepository.visibility == nil` (UI shows nothing rather
  than guessing).
- **Search.** GitLab passes `search=` server-side. GitHub's list has no server filter: `query` is ignored
  by `repositories`, the UI filters loaded pages, and "Search all accessible repositories" calls
  `searchAll(query:login:orgs:)` → `GET /search/repositories?q=<query> user:<login> org:<org>…&per_page=50`,
  first page only (bounded, explicit). Login/org names failing GitHub syntax are dropped so they can't
  inject qualifiers. All query values are strictly percent-encoded (`+`, `&`, `=` included).
- **Errors** (`ProviderError`): 401 → `.unauthorized`; GitHub 403/429 with `x-ratelimit-remaining: 0`
  (reset from `x-ratelimit-reset`) or `retry-after` → `.rateLimited(resetAt:)`; GitLab 429 →
  `.rateLimited` from `RateLimit-Reset`/`Retry-After`; other 403 → `.forbidden(message)` with the server's
  message single-lined, ≤ 200 chars, and dropped if it contains the token; 404 → `.notFound`; else
  `.server(status)`; undecodable → `.invalidResponse`. Transport failures → `.transport(URLError)` scrubbed
  to code (+ CFNetwork stream code for proxy detection), classified offline/DNS/TLS/timeout/proxy/
  unreachable. No automatic retries. Descriptions never contain tokens (sentinel test over every error path).
- **Self-managed GitLab.** `version()` = `GET /version` (authenticated); 404, HTML (`text/html`) or
  non-JSON → `.wrongPathPrefix` (any GitLab endpoint answering HTML also maps there).
  **Minimum supported GitLab: 15.0** (`GitLabProvider.minimumSupportedGitLab`; `validateServer()` throws
  `.unsupportedVersion`). 15.0 has `/personal_access_tokens/self`, `/projects?membership`, PKCE for
  non-confidential applications and refresh-token rotation. To be confirmed against a real 15.x instance in
  P5.9; the constant is the single place to change.
- **Published SSH fingerprints.** github.com: `GET https://api.github.com/meta` → `ssh_key_fingerprints`
  values prefixed `SHA256:`, fetched **without** the token (public endpoint). GitHub Enterprise/self-hosted:
  `[]`. **GitLab.com publishes its fingerprints only in HTML documentation; there is no official
  machine-readable endpoint**, so `publishedSSHFingerprints()` returns `[]` and the host-key sheet shows the
  fingerprint without comparison for gitlab.com and self-managed (design §7 allows this). Scraping HTML is
  rejected as brittle.
- **Caching.** `RepositoryCache` per browser window: in-memory, 5-minute TTL, ≤ 64 entries (expired first,
  then oldest), keyed by account + normalized query + cursor, injectable clock, `Mutex`-protected; nothing on
  disk; discarded with the window.
- **Git credential usernames** (`gitCredentialUsername`): GitHub OAuth → `x-access-token`; GitHub PAT →
  login (GitHub ignores the username for tokens; both work); GitLab PAT → login (any non-empty username
  works); GitLab OAuth → `oauth2` (required).

## Consequences
- Every request is user-initiated and bounded; rate limits surface with a reset time instead of retry loops.
- GitLab rows lack visibility badges under `simple=true`; switching to the full representation costs much
  larger payloads — revisit only if users ask.
- GitHub search is one page; deeper search would need explicit "more results" paging (not built).
- Not verified live: GitHub.com, GitLab.com and self-managed endpoints were exercised only through
  recorded-fixture stubs (shapes from the providers' public API docs). Real-token checks (fine-grained,
  classic, GitLab.com PAT) remain manual P5.5 steps.
