# Phase 5 — Profiles & providers: implementation plan

Design: [`design.md`](design.md). Requirements: §10, §11, §12, §13.5, §19, §24 E/F. Invariants: roadmap §6.
All code is Swift (ADR-0002): `GitCore`, `Services`, `Features`, plus the `JitGitHelper` executable target
and the dev-only `TestRig` executable target in the `JitKit` package. UI follows ADR-0006 (macOS 26+,
Liquid Glass chrome, opaque content).

## 1. Preconditions

- Phase 4 `progress.md` shows its exit gate passed. Required from Phase 4: `OperationCenter` over the single
  `actor RepositoryHandle` writer, `ExecContext(identity:auth: .nonInteractive, network: .systemDefault)`
  with a single `GitEnvironment.remoteCommand` path, `PresentableError`, remote URL parser, `WebLink`,
  clone flow, activity UI (glass toolbar capsule).
- Phase 1 identity-only profiles persisted (format to migrate) and the toolbar profile pill.
- External prerequisites (missing ones do not block the phase, they block specific items — report them):
  - [ ] OAuth app registrations (public clients) for GitHub.com and GitLab.com, client IDs available.
  - [ ] Two GitHub test accounts with a private test repository; one GitLab.com account.
  - [ ] Access to a real GitLab Self-Managed instance (optional; the local rig covers automated tests).
- Tools for the rig: `openssl`, `/usr/sbin/sshd`, `ssh-keygen`, `ssh-keyscan` (all present on macOS).

## 2. Milestones

Each milestone: spec in `specs/P5.k-*.md` → tests → implementation → verification → commit(s).

### P5.1 — Data model v2 and persistence
- [ ] `GitProfile`, `CommitIdentity`, `ProfileAuth`, `HostingAccount`, `ProviderInstance`, proxy configs
      (design §4.1); versioned `profiles.json` with migration from Phase 1 format.
- [ ] `ProfileStore` split into fine-grained observables (active profile, profile list, accounts, instances).
- [ ] `ProfileSnapshot` resolution for a remote URL (design §4.2) — pure, unit-tested.
- Tests: `migrationFromIdentityOnlyV1`, `snapshotHTTPSMatchingInstance`,
  `snapshotHTTPSNoAccountForHostIsAnonymousWithMismatch`, `snapshotSSHUsesProfileKeyOnly`,
  `snapshotImmutableAfterProfileEdit`, `twoAccountsSameHostSelectedByID`.
- Done when: existing Phase 1–4 flows work unchanged on migrated data.

### P5.2 — Keychain service
- [ ] `KeychainStore` (store/read/delete/exists, off-main), attributes per design §4.3; data-protection
      keychain when signed, file-based fallback in dev (ADR-0035).
- [ ] `SecretBytes` (owned buffer wiped with `memset_s` on deinit; non-copyable if practical; redacting
      `description`/`debugDescription`/`Mirror`); secrets never converted to `String`.
- Tests: round-trip, overwrite, delete-on-account-removal, not-found mapping, attributes asserted via
  `SecItemCopyMatching` attribute query; `secretDescriptionIsRedacted`, `secretBufferWipedOnDeinit`
  (inspect the buffer through a test-only hook after release).

### P5.3 — Profile manager and switcher
- [ ] Settings panes in System Settings style: `Settings` scene + `NavigationSplitView` (system glass
      sidebar) + `Form(.grouped)` detail panes for Profiles, Accounts, Servers & Network (validation,
      destructive deletes). No custom chrome.
- [ ] Switcher: standard toolbar item (system glass) with profile avatar (profile-color circle + initials
      or SF Symbol) → system popover (glass) with avatar rows, status dots, search > 7 profiles, footer
      actions in one `GlassEffectContainer`, toast in the activity capsule; plus menu-bar Repository ▸
      Profile submenu for keyboard/VoiceOver. Decide popover vs rich `NSMenu` per design §7.
- [ ] Snapshot semantics wired: `OperationCenter` captures `ProfileSnapshot` at enqueue; activity detail
      shows the profile used.
- Tests: UI tests for add/edit/remove/switch (popover and menu-bar paths); `inflightOperationKeepsSnapshotAfterSwitch`
      (long fetch from a throttled local server); `switchDoesNotModifyGlobalConfig` (temp HOME, file hashes);
      snapshot tests light/dark/Reduce Transparency for switcher, each Settings pane, empty states.

### P5.4 — Credential helper and broker (HTTPS)
- [ ] Spike: broker channel A vs B (design §7); write ADR-0016 with evidence.
- [ ] Swift executable target `JitGitHelper` (binary `jit-git-helper`, Foundation/Darwin only):
      `credential get|store|erase`, `askpass`, SSH mode scaffold; no logging of payloads; exits after one
      request.
- [ ] `Services.CredentialBroker`: per-operation lifetime, Dispatch-source socket handling (no idle
      thread), host/port check, single-use, peer verification (B), asks its `CredentialSource`;
      `GitCore` `AuthPlan.https(broker:expectedHost:expectedPort:)` in `GitEnvironment.remoteCommand`
      (clear helpers, set Jit helper, `credential.interactive=false` when supported).
- [ ] Xcode project (XcodeGen `project.yml`) embeds the helper at `Contents/Helpers/jit-git-helper` via a
      copy-files build phase in dev and release builds.
- Tests: `helperReturnsCredentialForExpectedHost`, `helperRefusesUnexpectedHost`,
      `brokerNonceSingleUse` (B) / `brokerFDNotInheritedByUnrelatedChildren` (A),
      `inheritedOsxkeychainHelperNotConsulted` (system config with a fake helper that records calls),
      `eraseMarksAccountRejected`, `secretNeverInArgvOrEnv` (sentinel scan of every spawned
      process via the ProcessRunner test hook), HTTPS push to the rig's authenticated Git server.

### P5.5 — PAT accounts
- [ ] Connect Account sheet (PAT card), validation (`currentUser`, `tokenInfo`), scope guidance, expiry.
- [ ] Rotation (same-login check), disconnect (Keychain delete), Check Now; status updates on use.
- [ ] GitHub + GitLab (SaaS + instance) provider clients' user/token endpoints (subset of P5.8).
- Tests: provider parsing tests with recorded fixture JSON (`URLProtocol` stubs) for user, scopes headers,
      expiry, 401; rig API stub end-to-end; manual: real GitHub fine-grained + classic token, GitLab.com token.

### P5.6 — SSH
- [ ] `GIT_SSH` wrapper mode in `jit-git-helper` (argv exec of `/usr/bin/ssh`, options from `JIT_SSH_*`).
- [ ] Key picker (fingerprint via `ssh-keygen -lf`), agent mode, strict mode (`-F none`) default with
      opt-in user config, SOCKS/CONNECT ProxyCommand.
- [ ] Askpass passphrase sheet (standard system sheet) with optional Keychain storage; askpass refuses
      non-passphrase prompts.
- [ ] Host-key flow: classify unknown vs changed; `ssh-keyscan` + fingerprint sheet; provider fingerprint
      comparison; Jit-owned known_hosts (`0600`, hashed entries).
- [ ] Same-key-on-two-GitHub-accounts warning.
- Tests (rig sshd on a high port, user-level): `sshKeyAuth`, `sshAgentAuth`,
      `sshPassphraseViaAskpass`, `sshUnknownHostFailsWithoutTrust`, `sshTrustWritesOnlyJitKnownHosts`,
      `sshChangedHostKeyHardError`, `sshStrictModeIgnoresUserIdentityFile`,
      `sshKeyPathWithSpacesAndQuotes`, `askpassRefusesYesNoPrompt`, `userSSHFilesUnchanged`.

### P5.7 — OAuth
- [ ] Verify GitHub capabilities (PKCE without secret vs device flow) against current docs; record in ADR-0017.
- [ ] GitLab: `ASWebAuthenticationSession`, PKCE S256, state, custom scheme `jit://oauth/gitlab`, token
      exchange, JIT refresh (single-flight), revoke on logout.
- [ ] GitHub: chosen flow (device flow sheet with bounded polling while open, or PKCE).
- [ ] `OAuthClients.plist` build config; OAuth hidden/explained when client ID missing; self-managed
      Application ID entry with redirect URI/scopes display and version validation.
- Tests: `pkceChallengeS256Vectors` (RFC 7636 test vector), `stateMismatchRejected`,
      `callbackForUnknownSessionIgnored`, `refreshSingleFlight`, `refreshFailureMarksExpired`,
      `deviceFlowRespectsIntervalAndSlowDown` (stubbed), `noClientSecretInBinary` (`strings` scan
      script); manual: real GitLab.com and GitHub sign-in if client IDs exist — otherwise mark blocked.

### P5.8 — Provider clients and repository browser
- [ ] `GitHubProvider`, `GitLabProvider` (repositories, pagination, search per design §4.7), rate-limit
      handling, 5-minute in-memory cache, ephemeral per-instance sessions.
- [ ] Browser UI (design §3.6): account list in the system (glass) sidebar, debounced search in the
      toolbar (`.searchable`, system glass), virtualized **opaque** list rows and detail (no glass on rows),
      HTTPS/SSH clone URLs, destination, clone via Phase 4 flow, auto-open; account ≠ active profile →
      switch prompt.
- [ ] Opt-in avatars (visible rows only, bounded memory cache).
- Tests: pagination parsing (`Link`, `X-Next-Page`, keyset), search query building, rate-limit mapping,
      cache TTL/eviction, `noRequestsUntilBrowserOpened`, UI snapshot tests for all states (light, dark,
      Reduce Transparency).

### P5.9 — Self-managed instances and diagnostics
- [ ] Server config form (base URL with path prefix, ports, SSH host/port, OAuth app ID), API base derivation,
      version detection, minimum-version check (ADR-0037).
- [ ] Diagnostics runner (design §3.7) rendered as an opaque step list, with sanitized "Copy Report".
- [ ] `WebLink` extension for configured instances (path prefix, ports).
- Tests: URL derivation table tests; diagnostics against rig (each step forced to fail in turn: bad DNS name,
      closed port, wrong CA, 404 prefix, 401); `webLinkSelfManagedPrefix`.

### P5.10 — Custom CA
- [ ] Import/validate CA (reject leaf), store per instance, expiry display, rotation (multiple CAs).
- [ ] URLSession trust delegate scoped to instance host:port; `NetworkPlan.scoped(urlPrefix:caInfo:proxy:)`
      → `-c http.<url>.sslCAInfo`.
- Tests: rig HTTPS with private CA: API + `git ls-remote`/clone succeed with CA, fail without (specific
      error), `otherHostsUseDefaultTrust`, `leafCertRejected`, `expiredCAMessage`,
      `noInsecureTLSSettingsAnywhere` (grep test).

### P5.11 — Proxy
- [ ] Global + per-instance proxy modes; system/PAC resolution for Git; manual HTTP/HTTPS/SOCKS5; proxy
      auth from Keychain (URLSession challenges; Git via credential helper if supported — design §7).
- [ ] SSH via ProxyCommand for SOCKS/CONNECT.
- Tests: rig proxy (CONNECT + SOCKS5, optional basic auth) — API browsing, HTTPS fetch, SSH fetch through
      proxy; `proxyCredentialsNeverInArgv`; exception list honored; PAC file served locally resolves.

### P5.12 — Offline / VPN behavior
- [ ] `ConnectivityState` via `NWPathMonitor`; fast offline failures; "Back online — Retry" affordance;
      VPN hint heuristics; no automatic retries.
- Tests: injected path states (protocol wrapper around the monitor), error wording for DNS/timeout/refused;
      manual: disable Wi-Fi, connect/disconnect VPN against an internal host if available.

### P5.13 — Mismatch and failure UX
- [ ] Auth-failure classification extended (no account for host / rejected / expired / no access / SSH key
      refused); "Switch to '<profile>' and Retry" actions; never auto-switch, never ambient fallback.
- Tests: scenario tests with two rig accounts: `wrongAccountPushFailsAndOffersSwitch`,
  `retryAfterSwitchUsesNewSnapshot`, `noFallbackToOtherProfileCredentials`.

### P5.14 — Test rig, security review, manual validation, docs
- [ ] `scripts/testing/enterprise-rig/` (ADR-0039): generate CA + server cert (`openssl`), start the
      dev-only Swift executable target `TestRig` (never embedded in the app) providing a Network.framework
      TLS listener in front of `git http-backend` (CGI), an authenticating CONNECT/SOCKS5 proxy and a
      GitLab API stub (user, token self, projects with pagination, version); plus a user-level `sshd` with
      its own host keys and `authorized_keys`; `up`/`down` scripts; all bound to 127.0.0.1 and high ports.
      Rig-dependent tests are gated by an environment variable (e.g. `JIT_RIG=1 swift test --filter Rig`)
      and also run from the Xcode integration test plan.
- [ ] Run the security checklist (design §4.11) and fix findings.
- [ ] Manual validation checklist (§3 below) against real services; record results honestly in progress.md.
- [ ] Write ADRs 0016–0018, 0035–0039; update docs (§5 below); finalize `progress.md`.

## 3. Test plan summary

- **Automated (CI-able, no internet):** `swift test` unit tests (helper, broker, exec env, SSH args, model,
  snapshot resolution, providers with `URLProtocol` stubs, Keychain in a test keychain), rig integration
  tests (HTTPS + CA, proxy, sshd, API stub), UI/snapshot tests for every new screen and state in light,
  dark and Reduce Transparency. Every test that spawns Git runs with a temporary `HOME` and asserts the user's
  global Git/SSH files are unchanged.
- **Sentinel-secret tests:** a known fake secret flows through PAT, OAuth, passphrase and proxy paths;
  the test harness captures every spawned argv/env, all log output and all error details and asserts the
  sentinel never appears.
- **Manual validation checklist (record date, account types, results):**
  - Scenario E (§24): two GitHub accounts + one self-managed GitLab; switch globally; commit identity
    follows profile; remote credentials follow profile; `shasum ~/.gitconfig ~/.ssh/config` unchanged;
    wrong-account operation fails visibly.
  - Scenario F (§24): private GitLab with custom CA and proxy; TLS validated; browsing works; HTTPS Git
    uses trust/proxy; SSH works when configured; unreachable host diagnostics are useful.
  - GitHub: fine-grained PAT, classic PAT, OAuth (if registered), SSH key + agent, unknown-host flow.
  - GitLab.com: PAT, OAuth (if registered), SSH.
  - Items that couldn't be validated (no registration, no real instance) are listed as **not validated**.

## 4. Performance checks (release build)

| Check | Target |
|---|---|
| Launch with 10 profiles, 6 accounts | no Keychain reads, no network, launch time unchanged vs Phase 4 |
| Idle CPU / wakeups | unchanged vs Phase 4; `NWPathMonitor` adds no periodic wakeups |
| Idle network (10 min, app active and inactive) | zero bytes |
| Credential delivery overhead per remote op | < 50 ms added (helper spawn + broker round trip) |
| Glass chrome (switcher popover open/closed, toolbar) while idle | no ongoing GPU/CPU work (Instruments) |
| Repo browser first page (stubbed latency 0) | first rows < 100 ms after response; scrolling 60 FPS with 1,000 rows |
| Memory after closing browser | returns to pre-open level (± 3 MB); avatar cache bounded |

## 5. Docs to update

- `docs/security.md`: credential flow, broker, Keychain layout, SSH strict mode and host-key policy, OAuth,
  CA/proxy scoping, sentinel tests, threat model notes.
- `docs/architecture.md`: profile model, snapshot resolution, providers, networking.
- `docs/product.md`: profiles/accounts behavior, supported auth methods per provider, known limitations
  (SSH proxy auth, proxy auth for Git if unsupported, OAuth availability).
- `docs/release.md`: OAuth client registration prerequisites, `jit-git-helper` embedding/signing note for
  Phase 7.
- `docs/design-system.md`: profile avatar palette tokens, switcher popover, Settings form conventions,
  glass vs opaque decisions for the browser and diagnostics.
- `docs/performance.md`: phase measurements. `CLAUDE.md`: rig commands.

## 6. Exit checklist

- [ ] Demo steps 1–7 (design §1) performed; screenshots for every new screen/state in light, dark and
      Reduce Transparency.
- [ ] Glass only on chrome (toolbar, switcher popover, sidebars, sheets); repository list, detail and
      diagnostics opaque.
- [ ] Global profile switch never modifies global Git/SSH config (automated + manual evidence).
- [ ] In-flight operations keep their snapshot; new operations use the new profile.
- [ ] No silent fallback: wrong-account and no-account cases fail visibly with switch actions.
- [ ] Secrets only in the Keychain; sentinel tests pass; security checklist complete.
- [ ] SSH host keys never auto-accepted; changed keys are hard errors.
- [ ] Custom CA scoped per host; no insecure TLS anywhere; proxy applied to both URLSession and Git.
- [ ] No network at launch or while idle; no background refresh.
- [ ] OAuth status reported honestly (working / blocked on registration / not validated on self-managed).
- [ ] Roadmap §9 gate items 1–8 satisfied.
