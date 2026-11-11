# ADR-0051: Updates from GitHub Releases and the change log

- Status: accepted (supersedes ADR-0020)
- Date: 2026-11-11
- Phase: post-V1 (after 0.0.4)
- Requirements: §19 ("no unintended remote requests"), §26 priorities 1 and 5; amends ADR-0020
  ("V1 ships with no update mechanism")

## Context
The owner asked (2026-11-11) for updates from the project's GitHub Releases, a change log behind a
notification icon at the top right of the window, and one switch: with "update automatically" on, Jit
updates by itself; with it off, the user checks, updates and restarts by hand.

ADR-0020 deferred this to "opt-in Sparkle with an EdDSA-signed appcast". Jit has no third-party packages
(ADR-0002 spirit, dependency audit) and already publishes a DMG and its SHA-256 with every release
(ADR-0049), so the updater is written in Swift on Foundation, CryptoKit and Security.

## Decision
**Source.** `GET https://api.github.com/repos/ashkanRmk/jit/releases?per_page=20`, unauthenticated.
Drafts and tags that are not plain `X.Y.Z` / `vX.Y.Z` versions are ignored. Pre-releases count: every build
so far is published as one. A release is installable by Jit when it has `Jit-<version>.dmg` and
`Jit-<version>.dmg.sha256`, both under `https://github.com/ashkanRmk/jit/releases/download/` — any other
URL in the feed is dropped. The release page link is built from the tag, not read from the feed.

**When Jit asks.**
- *Update automatically* **off (default)**: no request, ever, until the user chooses Jit ▸ Check for
  Updates… or presses Check for Updates in the change log.
- **On**: at most one check per 24 hours, made when Jit starts or becomes the active app. No timer, no
  polling (hard rule). A newer installable release is downloaded and verified in the background and
  installed **when Jit quits**; Jit never restarts by itself. The bell shows a badge and the change log
  offers Restart Now. A failed automatic check is silent.
- One ephemeral `URLSession`: no cookies, credentials or cache; redirects must stay on HTTPS. The system
  proxy applies; per-profile proxy/CA settings (ADR-0038) are for Git and provider hosts.
- Tests and tools never reach the network: `UpdateService` requests only through a `fetcher` the app
  delegate installs. Benchmark launches do not start it.

**Installing** (`Services/Updates/DiskImageInstaller`).
1. Refuse early when Jit cannot be replaced where it is (App Translocation, a folder the user cannot write).
2. Download the `.sha256` and the DMG into `<Application Support>/Jit/Updates`; compare SHA-256; size cap 1 GB.
3. `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <private dir>` (argv array, no shell), copy
   `Jit.app` out, detach.
4. The copy must be Jit: same bundle identifier, exactly the release's version, newer than the running
   one, and a code signature that validates strictly with nested code. When the running Jit is signed with
   a Developer ID team, the new one must satisfy that team's requirement too.
5. At quit — after state is flushed and Git children are gone — the staged bundle is moved beside the
   installed one and swapped with one `renamex_np(RENAME_SWAP)` (two renames with rollback where the volume
   has no atomic swap). Restart Now / Install and Restart then reopen Jit with `/usr/bin/open -n`.
Development (debug) builds have no installer: they show the change log and point at the release page.

**UI.** A bell toolbar item at the trailing end of the main window (standard item, system glass; badge
while a newer release is known). It opens *What's New*, a standard sheet: updater state and its one action,
the release notes of the last 20 releases (headings, paragraphs, bullets, inline bold/code/links; the list
is saved in `Updates/releases.json` and shown without a request), the *Update automatically* switch, Check
for Updates, Done. The same switch is in Settings ▸ General. Jit ▸ Check for Updates… is in the menu and the
command palette.

## Consequences
- **Trust.** Releases are ad-hoc signed (ADR-0049 addendum), so there is no publisher identity to verify.
  The SHA-256 comes from the same release as the DMG: it catches a damaged download, not a malicious
  release. What Jit trusts is GitHub over TLS and whoever can publish releases in the repository — the
  same trust as downloading the DMG by hand, but with automatic updates on it is exercised without a
  person looking. Protect the GitHub account accordingly (2FA, no shared tokens with release scope).
  **Follow-up worth doing:** sign each DMG with an Ed25519 key kept off GitHub and embed the public key in
  Jit (CryptoKit), or move to Developer ID — the team check in step 4 then applies by itself.
- The updated app carries no quarantine attribute, so the "Open Anyway" step is not needed after an
  in-app update. macOS may still ask once for Keychain access (ad-hoc builds have no stable identity).
- **The repository must be public** (or releases must move to a public repository): an unauthenticated
  request to a private repository answers 404, and Jit says the releases were not found. On 2026-11-11 the
  repository was private; the feature was verified against the real release data read with `gh`.
- Release process: the tag must be the version, and `Jit-<v>.dmg` + `.sha256` must be attached under those
  exact names (`docs/release.md`). Release notes are what users read in the app.
- Idle cost is unchanged: no timer; one small file read after the first frame.

## Alternatives considered
- **Sparkle**: mature, EdDSA appcast, but a third-party framework with an XPC installer to sign and ship;
  rejected to keep Jit dependency-free.
- **Open the release page only**: no in-app install; rejected, the request was for updating in place.
- **Install while running, restart immediately in automatic mode**: would interrupt work and swap
  resources (bundled Git) under a running process; rejected.
