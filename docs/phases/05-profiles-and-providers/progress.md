# Phase 5 — Profiles & providers: progress report

Status: complete with carry-overs
Branch / PR: `phase/05-profiles-and-providers` (local; not pushed)
Environment: MacBook Pro `Mac17,9` (Apple M5 Pro, 24 GB), macOS 27.2, Xcode 27.2, Swift 6.4.2, Git 2.54.0
(Homebrew), OpenSSH 10.5p1, LibreSSL 3.3.6

External prerequisites: **none available** — no OAuth client IDs, no GitHub/GitLab test accounts, no real
self-managed GitLab. Everything below was validated against real Git and the local enterprise rig (ADR-0039);
items that need real services are listed as **not validated**.

## Implemented
- **P5.1 Model v2** — `GitProfile.auth` (separate from identity), hosting accounts, provider instances, global
  network config; `profiles.json` v1 → v2 migration; immutable `ProfileSnapshot`; pure `AccessResolver`.
  Evidence: `ProfilesV2Tests` (14).
- **P5.2 Keychain** — `KeychainStore` (ThisDeviceOnly, non-synchronizable, data-protection keychain when
  entitled), `SecretBytes` (memset_s wipe, redacted). `KeychainStoreTests`, `SecretTests`.
- **P5.3 Profile manager and switcher** — System Settings–style Settings (`NavigationSplitView` + grouped
  forms): Profiles (with Authentication group), Accounts, Servers & Network; switcher popover with active-profile
  header, provider glyphs, status dots, search > 7, glass footer row; Repository ▸ Profile menu + ⌃⌘P;
  switch toast + VoiceOver announcement; snapshot captured at enqueue for every remote operation and clone.
- **P5.4 Helper + broker** — `jit-git-helper` (credential / askpass / ssh), embedded at `Contents/Helpers/`;
  operation-scoped Unix-socket broker with nonce and peer check; inherited credential helpers always cleared
  (ADR-0016). `BrokerHelperTests` (7) incl. real `git credential fill` and sentinel scan.
- **P5.5 PAT accounts** — Connect Account (validate → shows login/scopes/expiry → save), Replace Token (same
  login), Disconnect (Keychain delete, revocation guidance), Check Now. Provider clients (`GitHubProvider`,
  `GitLabProvider`) with fixture tests (`*ProviderTests`, 59).
- **P5.6 SSH** — `GIT_SSH_COMMAND` wrapper, strict `-F none`, key/agent modes, askpass passphrase sheet,
  host-key trust sheet with GitHub `/meta` comparison, hashed Jit-owned known_hosts, shared-key warning
  (ADR-0036). Rig tests: unknown host, trust, passphrase with spaces/quote in the key path, changed key, strict mode.
- **P5.7 OAuth** — GitLab auth code + PKCE (ASWebAuthenticationSession, `jit://oauth/gitlab`), refresh
  single-flight, revoke; GitHub device flow; `OAuthClients.plist` loading. **Blocked on registration** — no
  client IDs, so the browser card is shown as "isn't configured"; flows are stub-tested only (ADR-0017).
- **P5.8 Repository browser** — window with account sidebar, `.searchable`, opaque list/detail, pagination at
  80 %, debounce, GitHub local filter + explicit "search all", GitLab server search, rate-limit/offline/attention
  states, clone via the Phase 4 flow with "Clone with '<profile>'…" switch prompt. `RepositoryBrowserTests` (17).
- **P5.9 Self-managed + diagnostics** — server form (path prefix, ports, SSH, OAuth app ID with redirect URI and
  scopes), derived API URL, diagnostics runner + opaque step list with sanitized Copy Report
  (`DiagnosticsTests`, 33 incl. 11 rig tests), ADR-0038.
- **P5.10 Custom CA** — import/validate (leaf rejected), per-server storage, expiry display, scoped URLSession
  trust and `http.<origin>.sslCAInfo` (ADR-0018). Rig: clone/push with CA, TLS failure without/with wrong CA.
- **P5.11 Proxy** — global + per-server modes, CFNetwork/PAC resolution, manual HTTP/HTTPS/SOCKS5, password
  through the broker; SSH via `nc -X`. Rig: clone through the authenticating proxy (407 → 200), no secret in argv.
- **P5.12 Offline** — event-driven `NWPathMonitor` state; remote operations fail fast offline without spawning
  Git; "back online" flag after an offline failure; VPN hints for internal names. `ConnectivityTests`.
- **P5.13 Mismatch UX** — `AuthFailureExplainer`: no account for host / rejected or expired / no access / SSH key
  refused / unknown host key; explicit "Switch to '<profile>' and Retry" (new snapshot); never automatic.
- **P5.14 Rig, security, docs** — `TestRig` (TLS git server, CONNECT/SOCKS5 proxy with auth, GitLab API stub)
  and `scripts/testing/enterprise-rig/{up,down,status}.sh` with user-level sshd; ADRs 0016–0018, 0035–0039.

## Verified
- Tests (`swift test`, full package): GitCore 385, Services 200, Features 87, DesignSystem 15. All pass, except
  the load-sensitive timing check `lanesLayout100kUnder150ms`, which failed in two full concurrent runs (load
  average 7–8; the larger Services suite now runs in parallel) and passes when GitCore runs alone (385/385) or in
  isolation; it passed in the pre-phase baseline full run. Lane code is untouched — Phase 6 should isolate perf
  tests (already a Phase 4 carry-over). Rig-gated suites with `JIT_RIG=1`: `RigIntegrationTests` 10/10,
  diagnostics rig tests 11/11. `scripts/build/lint.sh` clean. `scripts/build/test-app.sh` exit 0.
- Real-workflow checks (debug app, isolated `JIT_APP_SUPPORT`, rig on 127.0.0.1), by pointer:
  1. Phase 1 v1 profile migrated; fetch from the rig with no CA → specific TLS sheet, no bypass, "Test Connection…".
  2. Added "Rig GitLab" server; leaf certificate rejected; rig CA imported (subject/issuer/expiry shown).
  3. Connected a PAT: validated through the custom-CA URLSession (login, scopes, expiry), saved; token only in
     the Keychain (`profiles.json` grep clean).
  4. Bound the account to "Work GitLab"; fetch authenticated via the broker (rig log: 401 challenge → 200).
  5. Identity-only "Personal" profile active → "The profile 'Personal' has no account." with
     "Switch to 'Work GitLab' and Retry"; the switch happened explicitly.
  6. `~/.gitconfig`, `~/.ssh/config`, `~/.ssh/known_hosts` modification times predate the session (unchanged).
- Screenshots (`screenshots/`): settings profiles/accounts/network and switcher popover (light + dark), repository
  browser loading state (light), mismatch sheet (light).

## Performance
| Metric | Previous | Now | Method |
|---|---|---|---|
| Idle CPU, repo open, account + CA configured | 0.00 % (P4, release) | 0.0 %, ~1 idle wakeup / 20 s, 64 MB | `top -pid` on the **debug** app |
| Idle network | none | none (no flows) | `nettop -p` |
| Launch: Keychain/network | — | no Keychain reads, no network at launch (`AccountsService` is lazy) | code review + nettop |
Release-build measurements (launch with 10 profiles, credential delivery overhead, browser memory) were not run.

## Decisions
- ADR-0016 — helper + operation-scoped broker (channel B), cleared inherited helpers, `!`-form helper.
- ADR-0017 — GitLab PKCE without secret; GitHub device flow (not validated live).
- ADR-0018 — CA/proxy scoped per origin; **CA and proxy belong to the server and apply to every profile**.
- ADR-0035 — model v2, snapshot, Keychain layout. ADR-0036 — SSH via `GIT_SSH_COMMAND` wrapper.
- ADR-0037 — provider clients. ADR-0038 — diagnostics/offline. ADR-0039 — local rig.

## Deviations from plan
- Broker nonce is operation-scoped with a 16-request cap, not single-use (Git calls the helper several times).
- `GIT_SSH_COMMAND` instead of `GIT_SSH` (outranks `core.sshCommand`); askpass is enabled by the helper for ssh only.
- Proxy URL carries the (non-secret) username so Git asks the helper for the password.
- Settings window is AppKit-hosted SwiftUI with `NavigationSplitView`, not a SwiftUI `Settings` scene.
- Switch toast is a transient popover at the profile item (the activity capsule exists only while busy).

## Bugs found by exercising the app (fixed)
- Profile rows in Settings ignored clicks (single-tap declared before double-tap).
- Profile editor and Connect Account sheets grew past the screen (now fixed height; forms scroll).
- Server CA wasn't applied to profiles without that server's account → TLS failed before the mismatch could be
  explained. Fixed in the resolver (ADR-0018) with a regression test.
- "Unable to get password from user" was an unclassified error → now an auth failure with account-aware text.
- "Checked in 0 seconds" wording.
- SSH passphrase prompt: ssh truncates long key paths → broker matched nothing (rig test caught it).

## Known issues / carry-overs
- **OAuth** (GitHub device flow, GitLab.com/self-managed PKCE): blocked on client registration; stub-tested only.
- **Not validated against real services**: GitHub fine-grained/classic PATs, GitLab.com PAT, real self-managed
  GitLab (minimum version 15.0 unconfirmed), GitHub `/meta` fingerprint comparison, PAC, non-loopback proxies
  (macOS never proxies loopback, so proxy diagnostics are stub-tested), expired-certificate messaging.
- **Dev-build Keychain prompts**: each rebuild of the ad-hoc-signed app is a new code identity, so the
  file-based login keychain asks for the login password; denying fails safely. Because of this the repository
  browser's live list and the switch-and-retry *completion* were not exercised by pointer (unit-tested). Phase 7
  (signed + data-protection keychain).
- Not exercised by pointer: passphrase and host-key sheets (rig-tested in Services), diagnostics panel, account
  disconnect/replace, menu-bar Profile submenu, "back online" affordance (state only; no UI surface yet — P6).
- Not captured: Reduce Transparency/Increase Contrast screenshots, dark screenshot of the browser and mismatch
  sheet, release-build performance table (§4 of the plan), 10-minute idle network check.
- Broker peer check is path-based; distribution builds should add a SecCode/team check (Phase 7).

## Self-review findings
- Global test hook (`ProcessRunner.spawnObserver`) counted spawns from parallel suites → test filtered by URL.
- `OperationsController` remote calls capture `self` strongly inside `Task` (compiler warnings; same pattern as
  Phase 4) — logged for P6 cleanup.
- Security checklist (design §4.11): sentinel argv/env scan ✔, insecure-TLS/host-key grep ✔ (lint test),
  global files untouched ✔ (tests use temp HOME/sandbox; manual mtime check), inherited helpers cleared ✔,
  broker scoped + peer-checked + `0700` ✔, Keychain attributes ✔ (data-protection path unverified in unsigned
  builds), no client secret in the built app (`strings` scan) ✔, URLs masked (`RemoteURL.masked`) ✔,
  no network at launch/idle ✔ (short check), avatars not implemented (off) ✔.

## Next
- Phase 6 (polish & performance). Before it: push this branch and open the PR; register OAuth apps if browser
  sign-in should ship; run the manual checklist against real GitHub/GitLab accounts.
