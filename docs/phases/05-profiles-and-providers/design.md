# Phase 5 — Profiles & providers: design

Requirements: §10 (profiles), §11 (GitHub/GitLab), §12 (enterprise networking), §13.5 (process safety),
§19 (security), §24 scenarios E and F. Roadmap: ADR-0016, 0017, 0018; invariants §6.
Amended by ADR-0002 (pure Swift — Git logic in `GitCore`, helpers are Swift executable targets; no Rust,
no FFI) and ADR-0006 (macOS 26+, Liquid Glass on chrome, opaque content).

## 1. Goal & demo

Turn the identity-only profiles from Phase 1 into full global Git profiles that carry authentication
(SSH, PAT, OAuth) and enterprise network configuration, and add native repository discovery for
GitHub.com, GitLab.com and GitLab Self-Managed — without ever modifying global Git/SSH configuration,
leaking a secret, or silently using the wrong account.

**Demo at the end of the phase** (local rig + real services where available)
1. Create three profiles: "Personal GitHub" (OAuth or PAT), "Open-source GitHub" (second account, SSH key),
   "Work GitLab" (self-managed instance on the local enterprise rig with a private CA and proxy).
2. Switch profiles from the toolbar menu; every tab updates; `~/.gitconfig` and `~/.ssh/config` are
   byte-identical before and after (shown with `shasum`).
3. Push to a private GitHub repo with profile A; switch to B and push to the same repo → explained
   mismatch/permission error with a "Switch to 'Personal GitHub' and Retry" action; nothing falls back.
4. Start a long fetch, switch profile mid-flight: the running fetch keeps its original snapshot (shown in
   the activity detail); the next operation uses the new profile.
5. Browse repositories for each account, search, choose SSH vs HTTPS, clone with progress, auto-open.
6. Against the rig: connectivity diagnostics show DNS → TCP → TLS (custom CA) → HTTP → auth passing; remove
   the CA and the TLS step fails with a specific explanation (no bypass offered); turn on the proxy and both
   API browsing and `git fetch` go through it.
7. SSH to an unknown host: the host-key verification sheet shows the SHA-256 fingerprint; accepting writes
   only Jit's own known_hosts file; a changed host key is a hard security error.

## 2. Scope

**In scope**
- Profile model v2 (identity separate from authentication), accounts, provider instances, network configs.
- Profile manager (Settings) and polished global switcher; auth status; snapshot semantics; mismatch UX.
- Keychain service.
- Credential delivery to Git (bundled helper + broker), SSH invocation, host-key verification.
- PAT and OAuth for GitHub and GitLab (incl. self-managed), refresh, logout.
- Provider API clients, remote repository browser, credentialed clone (reusing the Phase 4 clone flow).
- Self-managed server configuration, connectivity diagnostics, custom CA, proxies, offline/VPN handling.
- Web links for self-managed GitLab (extends Phase 4 `WebLink`).
- Opt-in provider avatars (off by default).
- Local enterprise test rig (`TestRig` dev-only Swift executable target + `scripts/testing/enterprise-rig/`).

**Out of scope (and where it lives)**
- Pull/merge request, review, CI, pipeline features — **excluded** (§9.3), never.
- Automatic per-repository profile selection — **excluded in V1** (§10).
- Commit signing configuration (fields reserved only) — **Phase 8**.
- Remote add/edit/remove UI — **Phase 8**.
- Keyboard/command-palette coverage of profile actions — **Phase 6**.
- Signing/notarizing the helper binary inside the bundle — **Phase 7** (dev builds run it unsigned).

## 3. User experience

### 3.1 Global profile switcher (toolbar pill → glass popover)

- **Pill:** a standard toolbar item (rendered by macOS 26 inside the system Liquid Glass toolbar — no
  custom material): profile avatar (circle in the profile's color with initials or chosen SF Symbol;
  provider avatar only if the user opted in) + display name; author email in the tooltip. A small status
  glyph overlays the avatar when the account needs attention (expired, disconnected, rejected).
- **Popover (system popover — Liquid Glass by default; SwiftUI `.popover` / `NSPopover`):**
  - Header: "Active profile" with larger avatar, name, `Author Name <email>`, provider icon +
    `@login on host`, auth method.
  - List of profiles: avatar in profile color, provider glyph, display name, email (secondary), status dot
    (green-muted ok / amber expired / grey not checked / red rejected), check mark on active. Rows are plain
    text on the popover's material using system selection highlight — no per-row glass, no custom blur.
  - Search field appears automatically when there are > 7 profiles.
  - Footer actions ("Add Profile…", "Edit Active Profile…", "Manage Profiles…") as standard buttons in one
    small `GlassEffectContainer` row.
  - The same profiles are also listed in the menu bar (Repository ▸ Profile ▸ …, native `NSMenu`, glass by
    default) so switching works from the keyboard and VoiceOver without the popover.
- **Switching:** one click; popover closes; pill avatar/name crossfade (120 ms; the toolbar capsule may
  resize with the system glass morph; instant with Reduce Motion); a short toast in the activity capsule:
  "Switched to Work GitLab — new operations commit as ada@corp.example".
- **Reduce Transparency / Increase Contrast:** system popover and toolbar adapt automatically; avatar
  colors come from `DesignSystem` profile palette tokens with contrast-checked foregrounds.
- **No profile selected:** pill shows "Choose Profile" in accent color; commit and commit-creating
  operations are blocked with a "Choose Profile…" action (unchanged from Phase 1).
- **Accessibility:** menu rows expose "Profile Work GitLab, ada@corp.example, GitLab, authenticated,
  selected"; switching via keyboard (⌃⌘P suggested to open the menu).

### 3.2 Profile manager (Settings ▸ Profiles / Accounts / Servers & Network)

Settings window styled like macOS System Settings: a SwiftUI `Settings` scene with a
`NavigationSplitView` whose sidebar uses the system sidebar (Liquid Glass) material, and detail panes
built from `Form` with `.formStyle(.grouped)` and standard controls — no custom chrome. Three panes
(Profiles, Accounts, Servers & Network), designed as one cohesive form system.

**Profiles pane** — list of profiles; detail:
- *Identity* group: display name, color/icon, author name, author email, optional committer
  name/email (disclosure), "Signing — Planned" (disabled, labelled).
- *Authentication* group: provider (None / GitHub / GitLab.com / a configured self-managed instance),
  account (picker of accounts for that provider, or "Connect Account…"), preferred transport for clones
  (HTTPS / SSH), SSH identity (picker: "Use ssh-agent", or a key file with fingerprint shown), "Use my
  ~/.ssh/config for this profile" toggle (off by default, with explanation — design §4.6).
- *Network* group (only for self-managed instances): shows the instance's CA and proxy summary with a
  link to Servers & Network.
- Validation inline (email format, missing account for chosen provider); Delete Profile via destructive
  sheet (states that commits are unaffected and that accounts/keys remain).

**Accounts pane** — one row per hosting account: provider icon, `@login`, host, method (PAT / OAuth),
scopes summary, expiry ("Expires in 12 days"), last checked time, status. Actions: Check Now, Replace
Token… (rotation), Reconnect (OAuth), Disconnect… (removes Keychain items; offers revoke where the
provider supports it from a public client — GitLab; for GitHub explains how to revoke in GitHub settings).
Used-by list shows which profiles reference the account.

**Servers & Network pane** — self-managed GitLab instances: name, base URL (scheme, host, HTTPS port,
optional path prefix), SSH host and port, OAuth application ID (optional), custom CA certificates, proxy
mode (System / Manual / Direct), "Test Connection" button with diagnostics panel (§3.6). Also a global
"Proxy" section used for GitHub.com/GitLab.com and as default.

**States:** empty (first-run: "Profiles combine who you commit as with how you sign in to remotes." +
Add Profile), normal, validating (inline spinners, never blocking the window), error (inline under the
field, with fix action).

### 3.3 Connecting an account

Sheet "Connect Account" (standard system sheet — glass treatment by default): provider segmented control
(GitHub · GitLab.com · Self-managed GitLab ▾), then method cards (opaque grouped-form sections, not glass
tiles):
- **Sign in with browser** (OAuth) — visible only when a client ID is configured for that provider/instance;
  otherwise the card reads "Browser sign-in isn't configured for this build/instance" with a Learn More.
- **Personal access token** — secure text field, link to the provider's token page with the exact scopes
  pre-explained (§4.8); "Validate & Save" shows login, avatar initials, scopes, expiry before saving.
- **SSH only** — no API account; profile can still push/pull over SSH; repository browsing unavailable
  (stated).

OAuth flow: system browser via `ASWebAuthenticationSession` (or device-code sheet for GitHub, §4.9) →
progress state "Waiting for browser…" with Cancel → success shows the account; cancellation/denial
returns to the sheet with a neutral message.

### 3.4 Mismatch and authentication-failure UX

When a remote operation fails with an auth-class error, the error view (Phase 4 `PresentableError`)
becomes specific:
- **No credentials for this host:** "The active profile 'Personal GitHub' has no account for
  gitlab.corp.example." Actions: "Switch to 'Work GitLab' and Retry" (one per profile whose account host
  matches the remote; explicit click; retry uses a new snapshot), "Edit Profile…".
- **Credentials rejected / expired:** "GitHub rejected the token for @ada (expired on 3 Nov)." →
  Replace Token… / Reconnect.
- **Authenticated but no access (403/404 'Repository not found'):** "@ada-oss can't access
  acme/private-repo. Another profile may have access." → switch actions as above.
- **SSH key refused:** names the key fingerprint used and the host.
Jit never retries automatically with another profile or with ambient credentials.

### 3.5 SSH passphrase and host-key verification

- Both sheets are standard system sheets attached to the main window (glass by default).
- **Passphrase sheet** (triggered by the askpass path): key file name + fingerprint, secure field,
  "Remember in Keychain" checkbox (off by default), Cancel → operation fails with "Cancelled".
- **Unknown host key sheet:** host, port, key type, SHA-256 fingerprint (SF Mono, large), and for
  github.com/gitlab.com a comparison line: "Matches the fingerprint GitHub publishes" / "Does NOT match"
  (fetched from the provider's documented API/metadata over verified HTTPS). Buttons: Cancel (default),
  "Trust This Host". Trust writes to Jit's own known_hosts. Changed key → non-dismissable warning sheet
  ("This may indicate an attack…") with no trust option; explains how to investigate.

### 3.6 Remote repository browser (new-tab page + File ▸ Browse Remote Repositories…)

- **Chrome vs content (ADR-0006):** the account list is a system sidebar (glass material); the search
  field and filter controls sit in the toolbar (system glass, SwiftUI `.searchable` placement); the
  repository list and detail are **opaque** content surfaces from `DesignSystem` that scroll under the
  toolbar with the system scroll-edge effect. No glass on list rows.
- **Layout:** left: account list (grouped by provider/instance; defaults to the active profile's account);
  top: search field (debounced 250 ms, server-side for GitLab, see §4.10 for GitHub); center: virtualized
  list rows — owner/namespace (secondary) / name (primary), visibility badge (Private/Internal/Public),
  description (one line, truncated), updated relative time; right/bottom: detail with clone URLs
  (segmented HTTPS | SSH, copy buttons), default branch, destination picker (remembered parent folder),
  folder name, Clone button.
- **Pagination:** loads the first page on open; next pages when scrolling near the end (prefetch at 80 %).
- **States:** loading skeleton rows; empty ("No repositories match 'xyz'"); account needs attention (inline
  reconnect); offline ("You're offline — Jit will not retry automatically" + Retry); rate-limited (shows
  reset time); error with diagnostics link for self-managed.
- **Clone:** uses the Phase 4 clone flow with the active profile snapshot. If the browsed account is not
  the active profile's account, the Clone button reads "Clone with 'Work GitLab'…" and asks to switch
  first — never clones under a different account silently.

### 3.7 Connectivity diagnostics panel

An **opaque** vertical step list (content, not chrome — it is read carefully and copied) with status
icons and plain-language results; only the "Test Connection" / "Copy Report" buttons are standard
(glass-styled) controls:
1. Network path (NWPathMonitor: satisfied / constrained / unsatisfied; VPN interface present if detectable)
2. DNS resolution (addresses)
3. Proxy in use (System/PAC result, Manual, Direct) and proxy reachability
4. TCP connect to HTTPS port
5. TLS handshake + trust (chain summary, issuer, expiry, SAN match, which anchor matched: system or custom CA)
6. HTTP reachability of the API (`/api/v4/version` or metadata endpoint; status code)
7. Authentication (`/api/v4/user` with the selected account)
8. SSH: TCP to SSH port, host key fingerprint vs known_hosts
Each failure has a specific explanation and next step (e.g. "Name not found. If this server is on your
company network, connect your VPN and try again."). "Copy Report" copies a sanitized text report.

## 4. Technical design

### 4.1 Data model (ADR-0035)

Non-secret configuration is persisted as JSON in Application Support (`profiles.json`, versioned with a
migration from Phase 1's identity-only format). Secrets live only in the Keychain, referenced by ID.

```swift
struct GitProfile: Codable, Identifiable {
    let id: ProfileID
    var displayName: String
    var appearance: ProfileAppearance            // color / SF Symbol
    var identity: CommitIdentity                  // §10.3 commit identity
    var auth: ProfileAuth?                        // §10.3 remote authentication (nil = identity only)
    var signing: SigningConfig?                   // reserved, Phase 8
}
struct CommitIdentity: Codable { var authorName, authorEmail: String; var committerName, committerEmail: String? }
struct ProfileAuth: Codable {
    var instanceID: ProviderInstanceID            // github.com, gitlab.com, or a self-managed instance
    var accountID: HostingAccountID?              // API/HTTPS account (PAT/OAuth); nil = SSH-only
    var preferredTransport: Transport              // .https / .ssh (for clone URL choice)
    var ssh: SSHIdentity?                          // .agent | .keyFile(path, fingerprint, passphraseInKeychain)
    var useUserSSHConfig: Bool                     // default false
}
struct HostingAccount: Codable, Identifiable {
    let id: HostingAccountID
    let instanceID: ProviderInstanceID
    var login: String; var userID: String
    var method: AuthMethod                         // .pat / .oauth
    var scopes: [String]; var expiresAt: Date?
    var status: AccountStatus                      // .ok / .expired / .rejected / .unknown — last observed
    var lastCheckedAt: Date?
}
struct ProviderInstance: Codable, Identifiable {
    let id: ProviderInstanceID
    var kind: ProviderKind                         // .github / .gitlab
    var webBaseURL: URL                            // scheme+host+port+path prefix
    var apiBaseURL: URL                            // derived, overridable
    var sshHost: String; var sshPort: Int
    var oauthClientID: String?                     // self-managed: user-supplied; SaaS: from build config
    var caCertificateIDs: [CertificateID]
    var proxy: ProxyConfigRef                      // .system / .manual(id) / .direct / .inheritGlobal
}
```

`ProfileStore` (`@Observable`, `@MainActor`) owns profiles, accounts, instances and the active profile ID
(persisted). Views observe only what they display (profile list vs active profile vs one account).

### 4.2 Profile snapshot and resolution

At enqueue, `OperationCenter` asks `ProfileStore` for a `ProfileSnapshot` for the target remote:

```swift
struct ProfileSnapshot: Sendable {
    let profileID: ProfileID
    let identity: CommitIdentity
    let auth: ResolvedAuth          // derived for the operation's remote URL
    let network: ResolvedNetwork    // CA bundle path + proxy URL for that host
}
```

Resolution rules: parse the remote URL (Phase 4 parser) → scheme, host, port. HTTPS: if the profile's
instance matches host/port → `ResolvedAuth.https(accountID, expectedHost)`; otherwise
`.httpsAnonymous(mismatch: .noAccountForHost)` (operation proceeds anonymously so public fetches still
work; an auth failure is then presented as a mismatch). SSH: `.ssh(identity, knownHosts, strictConfig)`;
if the host doesn't match the instance's SSH host, a mismatch hint is attached but the key is still the
profile's (never another profile's). The snapshot is immutable for the operation's lifetime;
`ProfileStore` changes never affect it. Secrets are not in the snapshot — only Keychain references.

The snapshot maps onto Phase 4's `GitCore` `ExecContext` (the enums gain cases; no call site changes):

```swift
public enum AuthPlan: Sendable {
    case nonInteractive
    case https(broker: BrokerEndpoint, expectedHost: String, expectedPort: Int)
    case ssh(keyPath: String?, agent: Bool, knownHosts: [String], strictConfig: Bool,
             proxyCommand: ProxyCommand?, broker: BrokerEndpoint)
}
public enum NetworkPlan: Sendable {
    case systemDefault
    case scoped(urlPrefix: String, caInfo: String?, proxy: String?) // proxy URL never contains credentials
}
```

### 4.3 Keychain service

- `kSecClassGenericPassword`, service `<bundle-id>.account` / `.ssh-passphrase` / `.proxy`, account = the
  Jit ID (account UUID, key fingerprint, proxy config UUID). Label "Jit — GitHub @ada".
- Attributes: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`. Prefer the
  data-protection keychain (`kSecUseDataProtectionKeychain`) when the build is signed with a team ID; fall
  back to the file-based login keychain for unsigned dev builds (record in ADR-0035, verify in Phase 7).
- Values: PAT → token bytes; OAuth → JSON `{access, refresh, expiresAt, tokenType}`; passphrase; proxy
  password. Read into a `SecretBytes` value (a non-copyable `~Copyable` struct, or a final class if
  non-copyable types prove awkward, owning a manually allocated buffer that is wiped with `memset_s` on
  deinit; `description`/`debugDescription` print `<redacted>`). Secrets never become `String` and are
  written straight from that buffer to the broker socket.
- API: `store(_:for:)`, `read(_:)`, `delete(_:)`, `exists(_:)`. All calls off the main actor. Errors
  mapped (`errSecItemNotFound`, `errSecAuthFailed`, `errSecInteractionNotAllowed`).
- Removing an account or profile deletes its Keychain items (after the destructive sheet).

### 4.4 Credential delivery to Git (ADR-0016)

**Helper binary:** new Swift executable target `JitGitHelper` in the `JitKit` package builds
`jit-git-helper`, bundled at `Contents/Helpers/jit-git-helper` (dev: from the build products directory).
It depends only on Foundation/Darwin (not on `GitCore`, AppKit or the Keychain — it holds no secrets at
rest), starts fast, and exits as soon as its single request is answered. Modes by first argument:
`credential <get|store|erase>`, `askpass <prompt>`, `ssh <ssh args…>` (§4.6). Post-V1 (Phase 8) the same
binary gains editor subcommands.

**Per-invocation Git config (HTTPS):**
```
-c credential.helper=                 # clear helpers inherited from system/global/repo config
-c credential.helper=<abs path to jit-git-helper> credential
-c credential.useHttpPath=false
-c credential.interactive=false       # where supported by the Git version
```
*Why clear inherited helpers:* Apple's and Homebrew's Git ship `credential.helper=osxkeychain` in their
system config. Left in place it would (a) answer with whatever account the user last stored for that host
— a silent wrong-account success that violates §10.2 — and (b) receive `store` calls and persist Jit's
token in a Keychain item Jit doesn't control. Clearing applies only to Jit's own invocations; the user's
config files are untouched. (ADR-0016 records this; the empty value reset is a documented Git feature.)

**Broker channel:** the secret travels helper ← broker, never through argv, URLs or a logged environment.
Recommended design (spike in P5.4 decides between the two):
- **A (preferred if it survives Git → shell → helper):** an inherited anonymous socketpair FD whose number
  is passed in `JIT_BROKER_FD`; nothing on disk.
- **B:** a per-operation Unix domain socket in a fresh `0700` directory under the user's `$TMPDIR`, path in
  `JIT_BROKER_SOCKET`, plus a single-use 256-bit nonce in `JIT_BROKER_NONCE`. The broker verifies the peer
  with `LOCAL_PEERTOKEN` (audit token → `SecCode` check that the peer is Jit's bundled helper, signed by the
  same team in release builds), accepts each nonce once, and exists only for the operation's duration.
In both cases the broker (`Services.CredentialBroker` — it lives in `Services`, not `GitCore`, because
peer verification uses the Security framework and secrets come from the Keychain; `GitCore` only carries
the opaque `BrokerEndpoint` value and sets the helper's env) is created per remote operation and torn
down when the child process exits; its socket is serviced by a Dispatch read source — no idle thread,
nothing listening between operations. It receives `{protocol, host, port, username?}` from the helper,
checks it equals the operation's expected host/port (or the configured proxy host for proxy auth), then
asks its `CredentialSource`:

```swift
// Services-internal seam (lets tests substitute a fake source; production reads the Keychain).
public protocol CredentialSource: Sendable {
    func httpsCredential(accountID: HostingAccountID, host: String) async throws(CredentialError) -> SecretPair
    func sshPassphrase(keyFingerprint: String, prompt: String) async throws(CredentialError) -> SecretBytes
    func proxyCredential(proxyID: ProxyConfigID) async throws(CredentialError) -> SecretPair
    func credentialRejected(accountID: HostingAccountID, host: String) async   // from `erase`
}
```

The production source fetches from the Keychain (or shows the passphrase sheet on the main actor) and returns.
`store` is ignored (Jit owns storage); `erase` marks the account `rejected` so the UI can explain.
Requests for unexpected hosts are refused and logged (host only). Secret values are `SecretBytes`
(wiped on deinit, redacted descriptions) end to end.

**Username conventions** (verify at implementation): GitHub PAT/OAuth → username = login (or
`x-access-token`), password = token; GitLab PAT → any username + token; GitLab OAuth → `oauth2` + token.

### 4.5 OAuth token refresh

Just-in-time only: before an API request or a Git operation, if the stored GitLab access token is expired
or expires within 60 s, refresh with the refresh token (single-flight per account), store the new pair,
then proceed. No timers, no background refresh. Refresh failure → account `expired` → mismatch UX.

### 4.6 SSH invocation (ADR-0036)

- Git gets `GIT_SSH=<abs path to jit-git-helper>` and `GIT_SSH_VARIANT=ssh`. Git calls `GIT_SSH` with
  plain ssh arguments (no mode argument), so the helper detects SSH mode via an env marker
  (`JIT_HELPER_MODE=ssh`) and replaces itself with `/usr/bin/ssh` via `execve` and an argv array — no
  shell, so key paths with spaces or metacharacters are safe (unlike `GIT_SSH_COMMAND`, which Git runs
  through a shell).
- Options added by the helper, from `JIT_SSH_*` env (paths and flags only, never secrets):
  `-o IdentitiesOnly=yes` + `-i <key>` (key mode) or agent-only (agent mode);
  `-o StrictHostKeyChecking=yes`;
  `-o UserKnownHostsFile="<~/.ssh/known_hosts> <AppSupport>/Jit/known_hosts"` (user file read, never
  written by Jit; Jit's file written only via the trust sheet) and `-o UpdateHostKeys=no`;
  `-o BatchMode=no` with `SSH_ASKPASS=<helper>`, `SSH_ASKPASS_REQUIRE=force` (askpass mode answers
  passphrase prompts only for the expected key; any yes/no host prompt is refused);
  strict mode (default): `-F none` so another account's `IdentityFile`/`Host` rules in `~/.ssh/config`
  can't make SSH authenticate as a different identity; the instance's SSH host/port come from Jit config.
  `useUserSSHConfig = true` drops `-F none` (needed for aliases/ProxyJump), with a warning in the UI.
- SSH through proxies: SOCKS5 / HTTP CONNECT via `-o ProxyCommand=/usr/bin/nc -X 5|connect -x host:port %h %p`
  (host/port validated as hostname + integer); no proxy auth for SSH (documented limitation).
- `SSH_AUTH_SOCK` from launchd is passed through in agent mode only.
- **Host key flow:** a failure classified as `UnknownHostKey` triggers `ssh-keyscan -p <port> -t
  ed25519,ecdsa,rsa -- <host>` (argv), fingerprints via `ssh-keygen -lf -` (stdin), the trust sheet, and an
  append to Jit's known_hosts (hashed host entries, `0600`). For github.com/gitlab.com, fingerprints are
  compared with the provider's published values fetched over verified HTTPS (GitHub `GET /meta`;
  GitLab.com from its documented source — verify at implementation; never hardcode values that can rotate
  without a fallback). `ChangedHostKey` → security error, no trust path.

### 4.7 Provider clients (ADR-0037)

Swift, `URLSession` (ephemeral configuration, no URL cache on disk, cookies disabled), one session per
instance so trust and proxy policy are scoped.

```swift
protocol HostingProvider: Sendable {
    func currentUser() async throws -> ProviderUser
    func tokenInfo() async throws -> TokenInfo                 // scopes, expiry
    func repositories(page: PageCursor?, query: String?) async throws -> RepositoryPage
    func publishedSSHFingerprints() async throws -> [String]  // github.com / gitlab.com only
}
final class GitHubProvider: HostingProvider { /* api.github.com */ }
final class GitLabProvider: HostingProvider { /* instance.apiBaseURL — GitLab.com and self-managed */ }
```

- GitHub: `GET /user`, scopes from `X-OAuth-Scopes` (classic) / expiry header
  (`github-authentication-token-expiration`), repositories `GET /user/repos?per_page=50&sort=updated
  &affiliation=owner,collaborator,organization_member`, pagination via `Link`. Search: filter loaded pages
  locally first; "Search all accessible repositories" uses `GET /search/repositories` with `user:`/`org:`
  qualifiers for the account and its orgs (bounded, explicit).
- GitLab: `GET /api/v4/user`, `GET /api/v4/personal_access_tokens/self` (scopes, expiry; version-gated),
  `GET /api/v4/projects?membership=true&simple=true&order_by=last_activity_at&per_page=50&search=…`,
  pagination via keyset/`Link`/`X-Next-Page`. Version: `GET /api/v4/version` or `/api/v4/metadata`.
  Minimum supported GitLab version recorded in ADR-0037 (proposal: 15.0+; OAuth PKCE validated per instance).
- Errors: 401 → `rejected/expired`, 403 with rate-limit headers / 429 → rate-limited with reset time (no
  auto-retry loop), 404 on self-managed API root → wrong path prefix hint, TLS/proxy/DNS → diagnostics.
- **Caching:** in-memory per browser window, 5-minute TTL, discarded on close; nothing on disk.
- **Avatars:** off by default; opt-in toggle "Load avatars from providers" in Settings; when on, loaded only
  for visible rows, memory cache bounded (e.g. 200 images), no disk cache.

### 4.8 PAT handling

- Validation on save: `currentUser` + `tokenInfo`; show login, scopes, expiry; refuse to save on 401.
- Scope guidance (explain, don't over-demand):
  - GitHub fine-grained: repository access as needed, **Contents: Read and write**, **Metadata: Read**.
    Classic: `repo` for private repositories (no narrower option), `public_repo` for public-only;
    `read:org` only if org repository listing needs it (verify).
  - GitLab: `read_api` (browsing), `read_repository` (fetch/clone), `write_repository` (push).
- Missing scope detected (e.g. push 403 with scope message) → explain which scope is missing.
- Rotation: Replace Token… validates the new token belongs to the same login (else asks to create a new
  account instead), then atomically replaces the Keychain item.
- Revocation detection: observed on use (401 / `erase`) and on "Check Now" — no background checks.

### 4.9 OAuth (ADR-0017)

- **Public clients only; no client secret in the binary.** Client IDs for GitHub.com/GitLab.com come from a
  build-time, non-secret config (`macos/Resources/OAuthClients.plist`, values supplied by the maintainer).
  Missing ID → OAuth card hidden/explained; report as **blocked on registration**, never fake.
- **GitLab (SaaS and self-managed):** authorization code + PKCE (S256) + `state` (128-bit random, constant-
  time compare) via `ASWebAuthenticationSession`, callback with custom scheme `jit://oauth/gitlab` (GitLab
  supports non-confidential applications with custom-scheme redirect URIs). Scopes: `read_api
  read_repository write_repository` (+ `read_user` if needed). Token refresh (§4.5). Logout: `POST
  /oauth/revoke` with `client_id` + token, then Keychain delete. Self-managed: user enters the Application
  ID; Jit displays the exact redirect URI and scopes for the admin; the instance version and
  `/oauth/authorize` reachability are validated before the browser opens.
- **GitHub:** verify at implementation time whether GitHub OAuth Apps / GitHub Apps allow a public client
  to complete authorization code + PKCE **without** a client secret and accept a custom-scheme or loopback
  redirect. If not, use the **OAuth device flow** (no secret, no redirect; Jit shows the user code, opens
  the verification page in the system browser, and polls the token endpoint at the server-specified
  interval only while the sheet is open — polling stops on success, cancel, or expiry). Revoking a GitHub
  OAuth grant requires the client secret, so Jit deletes local tokens and links the user to GitHub's
  "Authorized OAuth Apps" page. Record the outcome in ADR-0017 (amending its "auth code + PKCE" wording
  for GitHub if device flow is chosen).
- Callback handling: only the in-flight session's `state` is accepted; unexpected callbacks are ignored;
  codes are exchanged once; errors (`access_denied`, cancellation) map to neutral messages.
- Loopback redirects are not used (they require a local listener — §2.4 "no local servers" unless needed).

### 4.10 Enterprise networking (§12, ADR-0018, ADR-0038)

**Custom CA**
- Import PEM/DER/`.cer` via `NSOpenPanel`; parse with `SecCertificateCreateWithData`; show subject, issuer,
  validity, SHA-256 fingerprint; must be a CA (basic constraints) — leaf certificates are rejected with an
  explanation. User confirms association with a specific instance.
- Stored in `AppSupport/Jit/ca/<instance-id>.pem` (directory `0700`, files `0600`; public data, but
  integrity matters). The instance config references certificate IDs.
- URLSession: delegate handles `NSURLAuthenticationMethodServerTrust` **only for the instance's host:port**:
  `SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host))`, `SecTrustSetAnchorCertificates(trust, cas)`,
  `SecTrustSetAnchorCertificatesOnly(trust, false)` (system roots still valid), `SecTrustEvaluateWithError`;
  success → `.useCredential(URLCredential(trust:))`, failure → `.cancelAuthenticationChallenge` with the
  evaluation error mapped to a specific message. All other hosts → `.performDefaultHandling`.
- Git: `-c http.<https://host:port/prefix/>.sslCAInfo=<pem path>` per invocation (URL-scoped so other hosts
  are unaffected). Verify which TLS backend the development Git and the future bundled Git use; if the
  backend replaces rather than augments the default bundle for that URL, that's acceptable (scoped to the
  enterprise host) — document. Never `http.sslVerify=false`, never `GIT_SSL_NO_VERIFY`.
- Expiry: computed when settings or diagnostics are shown (warning < 30 days); TLS failures from expiry get
  a specific message. Rotation: add the new CA alongside the old, remove the old later.

**Proxy**
- Modes per instance: inherit global / System / Manual (HTTP, HTTPS, SOCKS5; host, port, optional
  username + Keychain password) / Direct.
- URLSession: System → default behavior (handles PAC); Manual → `connectionProxyDictionary`
  (HTTP/HTTPS/SOCKS keys); Direct → empty dictionary. Proxy auth via `NSURLAuthenticationMethod*Proxy`
  challenges answered from the Keychain.
- Git (does not read macOS proxy settings): resolve per target URL with `CFNetworkCopySystemProxySettings`
  + `CFNetworkCopyProxiesForURL`; PAC (`kCFProxyTypeAutoConfigurationURL` / JavaScript) via
  `CFNetworkExecuteProxyAutoConfigurationURL` (async, run once per operation, result cached for that
  operation only). Result → `-c http.<url>.proxy=http://host:port` or `socks5h://host:port` (DNS through the
  proxy for internal names), honoring exception lists. **No credentials in the proxy URL** (would be argv):
  proxy auth goes through the credential helper (Git requests proxy credentials via the credential
  protocol for the proxy host — verify behavior with the target Git version in P5.11; if unsupported,
  proxy auth for Git is a documented limitation with the API side still working).
- Diagnostics show which proxy was chosen and why (System/PAC/Manual/Direct, exception matched).

**VPN / offline (ADR-0038)**
- `NWPathMonitor` (event-driven, no polling) started while the app is active; `ConnectivityState` model.
- Unsatisfied path → remote operations and provider requests fail immediately with "You're offline";
  provider browser shows the offline state; nothing retries automatically. When the path becomes satisfied
  after an offline failure, show a passive "Back online — Retry" affordance.
- DNS failures for single-label or private-suffix hosts (`.corp`, `.internal`, `.local`, RFC 1918 results)
  add the VPN hint. Timeouts vs refused vs TLS are distinguished.

### 4.11 Security review checklist (run in P5.14)

- [ ] Grep-based test: argv/env builders contain no token, password, passphrase, or `Authorization` value
      (tests inject a sentinel secret and scan every spawned command line and environment).
- [ ] Logs and `PresentableError.technicalDetail` redaction tests with sentinel secrets and token prefixes.
- [ ] No `http.sslVerify`, `GIT_SSL_NO_VERIFY`, `StrictHostKeyChecking=no`, `accept-new`, or trust-all
      URLSession handlers anywhere (CI grep + unit tests).
- [ ] `~/.gitconfig`, `~/.config/git/config`, `~/.ssh/config`, `~/.ssh/known_hosts` untouched: test suite runs
      with a temporary `HOME` and asserts file hashes before/after; manual check on the dev machine.
- [ ] Inherited credential helpers cleared on every Jit Git invocation; helper refuses unexpected hosts.
- [ ] Broker: single-use, operation-scoped, peer verified (design B) or FD-only (design A); directory perms.
- [ ] Keychain attributes (ThisDeviceOnly, non-synchronizable); items deleted on account removal.
- [ ] OAuth: PKCE S256, state validated, no secrets in binary (`strings` scan of the built app), callback
      for unknown state ignored.
- [ ] Remote URLs with embedded credentials are masked in UI and never logged.
- [ ] No network requests at launch or while idle (Little Snitch-style check via `nettop`/Instruments
      Network for 10 minutes idle).
- [ ] Avatars off by default; no provider request without user action.

## 5. Edge cases & failure modes

- Two accounts on the same host (GitHub personal + OSS): credentials are chosen strictly by the profile's
  account ID, never by host lookup.
- Same SSH key registered on two GitHub accounts: GitHub authenticates it as one user — warn when the same
  fingerprint is configured for profiles bound to different GitHub accounts.
- Remote URL uses an SSH alias from `~/.ssh/config` while strict mode is on → resolution fails with an
  explanation and a pointer to the "Use my ~/.ssh/config" toggle or the instance SSH host setting.
- Profile deleted or account disconnected while an operation is running → the broker's Keychain lookup
  fails → operation fails safely with an explanation (snapshot keeps IDs, not secrets).
- Token expires mid-operation (long clone) → Git fails; the account becomes `expired`; Retry after
  reconnect.
- OAuth window closed by user; browser default changed; callback arrives twice → handled by state check.
- Self-managed instance behind a path prefix (`https://host/gitlab/`) → API base and web links include it.
- Self-signed leaf certificate offered as CA → rejected with guidance to import the issuing CA.
- Proxy with PAC that returns `DIRECT; PROXY …` lists → first usable entry per CFNetwork semantics.
- TLS-intercepting corporate proxy → user imports the proxy's CA for the affected instance (or globally for
  GitHub/GitLab.com via the global network section — scoped by host list, never global insecure trust).
- Captive portal / constrained path → treated as offline for automatic decisions; manual Retry allowed.
- Rate limiting on GitHub search → bounded explicit searches, reset time shown.
- Clock skew affecting token expiry → rely on server responses (401) as truth; local expiry is advisory.

## 6. ADRs to write

| ADR | Title |
|---|---|
| 0016 | Credential delivery to Git (helper binary, cleared inherited helpers, broker channel choice) |
| 0017 | OAuth flows per provider (GitLab PKCE + custom scheme; GitHub PKCE-without-secret or device flow) |
| 0018 | Custom CA and proxy application for URLSession and Git |
| 0035 | Profile / account / instance data model, persistence, Keychain layout, migration from Phase 1 |
| 0036 | SSH invocation strategy (`GIT_SSH` wrapper, strict config mode, Jit-owned known_hosts, host-key trust) |
| 0037 | Provider API clients, pagination, search, caching, minimum GitLab version |
| 0038 | Connectivity diagnostics and offline/VPN policy |
| 0039 | Local enterprise test rig (`TestRig` Swift executable: Network.framework TLS front for `git http-backend`, HTTP CONNECT/SOCKS5 proxy with optional auth; throwaway CA via `openssl`/Security; user-level `sshd`; scripts in `scripts/testing/enterprise-rig/`) |

## 7. Open questions / spikes

| Question | Decide in | Criteria |
|---|---|---|
| Broker channel A (inherited FD) vs B (socket + nonce + peer verification) | P5.4 spike | A only if the FD reliably reaches the helper through Git's helper spawning (`sh -c`) on the minimum Git version and the bundled Git (note: `ProcessRunner` must explicitly keep that one FD open across `posix_spawn` via `posix_spawn_file_actions_addinherit_np` while closing all others); otherwise B with audit-token verification. |
| GitHub OAuth: PKCE without secret vs device flow | P5.7 | Verified against current GitHub docs and a real registered app; must need no secret in the binary. |
| Does Git request proxy credentials through the credential protocol for our setup? | P5.11 | Test with the rig's authenticating proxy on min and bundled Git versions. |
| TLS backend of dev Git and future bundled Git (affects `sslCAInfo` semantics) | P5.10, re-check P7 | Rig test: custom-CA host works, public hosts unaffected. |
| Data-protection keychain in unsigned dev builds | P5.2 | If unavailable, file-based keychain in dev, data-protection in signed builds — tested both ways by Phase 7. |
| Profile switcher: popover vs rich `NSMenu` | P5.3 | Popover (system glass) unless keyboard/VoiceOver behavior is worse than a menu after testing; the menu-bar Profile menu exists either way. |
| Published SSH fingerprint source for GitLab.com | P5.6 | Must be fetched over verified HTTPS from an official source; otherwise show fingerprint without comparison. |
| Minimum self-managed GitLab version | P5.9 | Oldest version where `/user`, `/projects?membership`, PKCE and token self-info work as designed. |
