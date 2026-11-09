# ADR-0035: Profile / account / instance data model, persistence and Keychain layout

- Status: accepted
- Date: 2026-11-09
- Phase: P5
- Requirements: §10, §19

## Context
Phase 1 profiles were identity-only (`profiles.json` v1). Phase 5 adds authentication that must stay separate
from identity, never auto-switch, never store secrets outside the Keychain, and never change for an operation
already enqueued.

## Decision
- `profiles.json` **version 2** (`ProfileStore`): profiles (identity + optional `ProfileAuth` with instance ID,
  account ID, preferred transport, SSH identity, `useUserSSHConfig`), hosting accounts (login, user ID, method,
  scopes, expiry, last observed status), self-managed provider instances (base URL with path prefix, SSH host
  and port, OAuth application ID, CA IDs, proxy mode) and the global network config. GitHub.com and GitLab.com
  are built-in instances with fixed IDs. v1 decodes as v2 (new fields optional) and is rewritten as v2 on load;
  unknown versions are backed up, never silently dropped.
- `ProfileSnapshot` captured at enqueue copies identity, auth config, the account record, the instance, the
  global network config and every configured server's network settings — references only, no secrets. Edits,
  switches, deletions afterwards never affect it; a removed account makes the broker's Keychain read fail safely.
- Keychain: generic passwords, service `<bundle id>.account | .ssh-passphrase | .proxy`, account = Jit ID
  (account UUID, key fingerprint, proxy UUID), label "Jit — <server> @<login>",
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`. The data-protection
  keychain is used when the process has an application identifier entitlement; unsigned dev builds use the
  file-based login keychain (which ignores the accessibility class). OAuth tokens are stored as JSON built from
  bytes (`OAuthTokens.keychainData`).
- Deleting an account deletes its Keychain item first (after the destructive sheet), then detaches profiles
  (they keep identity and SSH settings). Deleting a profile never deletes accounts or keys.

## Consequences
- Dev-build caveat (observed): every rebuild of the ad-hoc-signed app is a new code identity, so the file-based
  keychain asks for the login password before releasing an item created by a previous build. Denying fails the
  operation safely. Signed builds with the data-protection keychain avoid this (verify in Phase 7).
- Evidence: `ProfilesV2Tests` (migration, round trip, immutability, two accounts on one host by ID),
  `KeychainStoreTests` (real keychain round trip/overwrite/delete, attributes), `SecretTests`.
