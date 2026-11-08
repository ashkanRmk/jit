# Phase 5 — Profiles & providers: implementation plan

Design: [`design.md`](design.md). Requirements: §10, §11, §12, §13.5, §19, §24 E/F. Invariants: roadmap §6.

## 1. Preconditions

- Phase 4 `progress.md` shows its exit gate passed. Required from Phase 4: `OperationCenter`,
  `ExecContext { identity, auth: AuthPlan::NonInteractive, network: NetworkPlan::Default }` with a single
  `exec::remote_command` path, `PresentableError`, remote URL parser, `weblink`, clone flow, activity UI.
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
- Tests: `migration_from_identity_only_v1`, `snapshot_https_matching_instance`,
  `snapshot_https_no_account_for_host_is_anonymous_with_mismatch`, `snapshot_ssh_uses_profile_key_only`,
  `snapshot_immutable_after_profile_edit`, `two_accounts_same_host_selected_by_id`.
- Done when: existing Phase 1–4 flows work unchanged on migrated data.

### P5.2 — Keychain service
- [ ] `KeychainStore` (store/read/delete/exists, off-main), attributes per design §4.3; data-protection
      keychain when signed, file-based fallback in dev (ADR-0035).
- [ ] Zeroizing handoff to Rust (`SecretBytes`), redacting `CustomStringConvertible`/`Debug`.
- Tests: round-trip, overwrite, delete-on-account-removal, not-found mapping, attributes asserted via
  `SecItemCopyMatching` attribute query; `secret_debug_is_redacted` (Rust + Swift).

### P5.3 — Profile manager and switcher
- [ ] Settings panes: Profiles, Accounts, Servers & Network (forms, validation, destructive deletes).
- [ ] Switcher menu with custom rows, status dots, search > 7 profiles, add/edit/manage actions, toast.
- [ ] Snapshot semantics wired: `OperationCenter` captures `ProfileSnapshot` at enqueue; activity detail
      shows the profile used.
- Tests: UI tests for add/edit/remove/switch; `inflight_operation_keeps_snapshot_after_switch` (long fetch
      from a throttled local server); `switch_does_not_modify_global_config` (temp HOME, file hashes);
      snapshot tests light/dark for menu, each pane, empty states.

### P5.4 — Credential helper and broker (HTTPS)
- [ ] Spike: broker channel A vs B (design §7); write ADR-0016 with evidence.
- [ ] `rust/crates/credential-helper` (`jit-git-helper`): `credential get|store|erase`, `askpass`, SSH mode
      scaffold; minimal dependencies; no logging of payloads.
- [ ] `git-core::broker`: per-operation lifetime, host/port check, single-use, callback to Swift
      `CredentialSource`; `AuthPlan::Https` in `exec::remote_command` (clear helpers, set Jit helper,
      `credential.interactive=false` when supported).
- [ ] Build scripts copy the helper next to the app in dev (`Contents/Helpers/` layout mirrored).
- Tests: `helper_returns_credential_for_expected_host`, `helper_refuses_unexpected_host`,
      `broker_nonce_single_use` (B) / `broker_fd_not_inherited_by_unrelated_children` (A),
      `inherited_osxkeychain_helper_not_consulted` (system config with a fake helper that records calls),
      `erase_marks_account_rejected`, `secret_never_in_argv_or_env` (sentinel scan of every spawned
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
- [ ] Askpass passphrase sheet with optional Keychain storage; askpass refuses non-passphrase prompts.
- [ ] Host-key flow: classify unknown vs changed; `ssh-keyscan` + fingerprint sheet; provider fingerprint
      comparison; Jit-owned known_hosts (`0600`, hashed entries).
- [ ] Same-key-on-two-GitHub-accounts warning.
- Tests (rig sshd on a high port, user-level): `ssh_key_auth`, `ssh_agent_auth`,
      `ssh_passphrase_via_askpass`, `ssh_unknown_host_fails_without_trust`, `ssh_trust_writes_only_jit_known_hosts`,
      `ssh_changed_host_key_hard_error`, `ssh_strict_mode_ignores_user_identityfile`,
      `ssh_key_path_with_spaces_and_quotes`, `askpass_refuses_yes_no_prompt`, `user_ssh_files_unchanged`.

### P5.7 — OAuth
- [ ] Verify GitHub capabilities (PKCE without secret vs device flow) against current docs; record in ADR-0017.
- [ ] GitLab: `ASWebAuthenticationSession`, PKCE S256, state, custom scheme `jit://oauth/gitlab`, token
      exchange, JIT refresh (single-flight), revoke on logout.
- [ ] GitHub: chosen flow (device flow sheet with bounded polling while open, or PKCE).
- [ ] `OAuthClients.plist` build config; OAuth hidden/explained when client ID missing; self-managed
      Application ID entry with redirect URI/scopes display and version validation.
- Tests: `pkce_challenge_s256_vectors` (RFC 7636 test vector), `state_mismatch_rejected`,
      `callback_for_unknown_session_ignored`, `refresh_single_flight`, `refresh_failure_marks_expired`,
      `device_flow_respects_interval_and_slow_down` (stubbed), `no_client_secret_in_binary` (`strings` scan
      script); manual: real GitLab.com and GitHub sign-in if client IDs exist — otherwise mark blocked.

### P5.8 — Provider clients and repository browser
- [ ] `GitHubProvider`, `GitLabProvider` (repositories, pagination, search per design §4.7), rate-limit
      handling, 5-minute in-memory cache, ephemeral per-instance sessions.
- [ ] Browser UI (design §3.6): account list, debounced search, virtualized rows, detail with HTTPS/SSH
      clone URLs, destination, clone via Phase 4 flow, auto-open; account ≠ active profile → switch prompt.
- [ ] Opt-in avatars (visible rows only, bounded memory cache).
- Tests: pagination parsing (`Link`, `X-Next-Page`, keyset), search query building, rate-limit mapping,
      cache TTL/eviction, `no_requests_until_browser_opened`, UI snapshot tests for all states.

### P5.9 — Self-managed instances and diagnostics
- [ ] Server config form (base URL with path prefix, ports, SSH host/port, OAuth app ID), API base derivation,
      version detection, minimum-version check (ADR-0037).
- [ ] Diagnostics runner (design §3.7) with step results and sanitized "Copy Report".
- [ ] `weblink` extension for configured instances (path prefix, ports).
- Tests: URL derivation table tests; diagnostics against rig (each step forced to fail in turn: bad DNS name,
      closed port, wrong CA, 404 prefix, 401); `weblink_self_managed_prefix`.

### P5.10 — Custom CA
- [ ] Import/validate CA (reject leaf), store per instance, expiry display, rotation (multiple CAs).
- [ ] URLSession trust delegate scoped to instance host:port; `NetworkPlan::Scoped { ca_info }` →
      `-c http.<url>.sslCAInfo`.
- Tests: rig HTTPS with private CA: API + `git ls-remote`/clone succeed with CA, fail without (specific
      error), `other_hosts_use_default_trust`, `leaf_cert_rejected`, `expired_ca_message`,
      `no_insecure_tls_settings_anywhere` (grep test).

### P5.11 — Proxy
- [ ] Global + per-instance proxy modes; system/PAC resolution for Git; manual HTTP/HTTPS/SOCKS5; proxy
      auth from Keychain (URLSession challenges; Git via credential helper if supported — design §7).
- [ ] SSH via ProxyCommand for SOCKS/CONNECT.
- Tests: rig proxy (CONNECT + SOCKS5, optional basic auth) — API browsing, HTTPS fetch, SSH fetch through
      proxy; `proxy_credentials_never_in_argv`; exception list honored; PAC file served locally resolves.

### P5.12 — Offline / VPN behavior
- [ ] `ConnectivityState` via `NWPathMonitor`; fast offline failures; "Back online — Retry" affordance;
      VPN hint heuristics; no automatic retries.
- Tests: injected path states (protocol wrapper around the monitor), error wording for DNS/timeout/refused;
      manual: disable Wi-Fi, connect/disconnect VPN against an internal host if available.

### P5.13 — Mismatch and failure UX
- [ ] Auth-failure classification extended (no account for host / rejected / expired / no access / SSH key
      refused); "Switch to '<profile>' and Retry" actions; never auto-switch, never ambient fallback.
- Tests: scenario tests with two rig accounts: `wrong_account_push_fails_and_offers_switch`,
  `retry_after_switch_uses_new_snapshot`, `no_fallback_to_other_profile_credentials`.

### P5.14 — Test rig, security review, manual validation, docs
- [ ] `scripts/testing/enterprise-rig/` (ADR-0039): generate CA + server cert (`openssl`), start HTTPS Git
      server (`git http-backend` behind a small dev-only Rust test server in a test-only crate, never
      shipped), authenticating CONNECT/SOCKS5 proxy, GitLab API stub (user, token self, projects with
      pagination, version), user-level `sshd` with its own host keys and `authorized_keys`; `up`/`down`
      scripts; all bound to 127.0.0.1 and high ports; used by `cargo test --features rig` and Swift
      integration tests.
- [ ] Run the security checklist (design §4.11) and fix findings.
- [ ] Manual validation checklist (§3 below) against real services; record results honestly in progress.md.
- [ ] Write ADRs 0016–0018, 0035–0039; update docs (§5 below); finalize `progress.md`.

## 3. Test plan summary

- **Automated (CI-able, no internet):** Rust unit tests (helper, broker, exec env, SSH args), Swift unit
  tests (model, snapshot resolution, providers with `URLProtocol` stubs, Keychain in a test keychain), rig
  integration tests (HTTPS + CA, proxy, sshd, API stub), UI/snapshot tests for every new screen and state
  in light and dark. Every test that spawns Git runs with a temporary `HOME` and asserts the user's
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
| Repo browser first page (stubbed latency 0) | first rows < 100 ms after response; scrolling 60 FPS with 1,000 rows |
| Memory after closing browser | returns to pre-open level (± 3 MB); avatar cache bounded |

## 5. Docs to update

- `docs/security.md`: credential flow, broker, Keychain layout, SSH strict mode and host-key policy, OAuth,
  CA/proxy scoping, sentinel tests, threat model notes.
- `docs/architecture.md`: profile model, snapshot resolution, providers, networking.
- `docs/product.md`: profiles/accounts behavior, supported auth methods per provider, known limitations
  (SSH proxy auth, proxy auth for Git if unsupported, OAuth availability).
- `docs/release.md`: OAuth client registration prerequisites, helper binary signing note for Phase 7.
- `docs/performance.md`: phase measurements. `CLAUDE.md`: rig commands.

## 6. Exit checklist

- [ ] Demo steps 1–7 (design §1) performed; screenshots for every new screen/state in light and dark.
- [ ] Global profile switch never modifies global Git/SSH config (automated + manual evidence).
- [ ] In-flight operations keep their snapshot; new operations use the new profile.
- [ ] No silent fallback: wrong-account and no-account cases fail visibly with switch actions.
- [ ] Secrets only in the Keychain; sentinel tests pass; security checklist complete.
- [ ] SSH host keys never auto-accepted; changed keys are hard errors.
- [ ] Custom CA scoped per host; no insecure TLS anywhere; proxy applied to both URLSession and Git.
- [ ] No network at launch or while idle; no background refresh.
- [ ] OAuth status reported honestly (working / blocked on registration / not validated on self-managed).
- [ ] Roadmap §9 gate items 1–8 satisfied.
