# ADR-0051: Updates from GitHub Releases and the change log

- Status: accepted (supersedes ADR-0020)
- Date: 2026-11-11
- Amended: 2026-11-19 for signed updates in 0.1.3
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
so far is published as one. In-app installation requires `Jit-<version>.dmg`, its `.dmg.manifest` and
`.dmg.manifest.sig`. Each URL must match the exact owner, repository, tag and asset name on GitHub.
The release page link is built from the tag.

**When Jit asks.**
- *Update automatically* **off (default)**: Jit requests releases only when the user opens the bell
  with stale or missing notes, chooses Jit ▸ Check for Updates…, or presses Check for Updates in the change log.
- **On**: at most one check per 24 hours, made when Jit starts or becomes the active app. No timer, no
  polling (hard rule). A newer installable release is downloaded and verified in the background and
  installed **when Jit quits**; Jit never restarts by itself. The bell shows a badge and the change log
   offers Restart Now. A failed automatic network check is silent. Verification failures are shown in
   What's New and never stage an installation.
- One ephemeral `URLSession`: no cookies, credentials or cache; redirects must stay on HTTPS. The system
  proxy applies; per-profile proxy/CA settings (ADR-0038) are for Git and provider hosts.
- Tests and tools never reach the network: `UpdateService` requests only through a `fetcher` the app
  delegate installs. Benchmark launches do not start it.

**Installing** (`Services/Updates/DiskImageInstaller`).
1. Require a newer release and a writable, non-translocated app location.
2. Fetch the manifest and its detached Ed25519 signature. Verify the raw signature with the public key
   sealed in the installed app. The canonical payload is UTF-8 `Jit Update Manifest v1`, `version=X.Y.Z`,
   `sha256=<64 lowercase hex digits>`, one line each with a final LF. The version must match the feed.
   Download the DMG into `<Application Support>/Jit/Updates` only after signature and manifest verification.
   Enforce the 1 GB image size limit and compare the DMG SHA-256 before mounting it.
3. `hdiutil attach -nobrowse -readonly -noautoopen -mountpoint <private dir>` (argv array, no shell), copy
   `Jit.app` out, detach.
4. The candidate bundle must match Jit's bundle identifier, release version and pinned public key. Its
   code signature must validate strictly, including nested code and the existing Developer ID team check
   when applicable.
5. At quit — after state is flushed and Git children are gone — the staged bundle is moved beside the
   installed one and swapped with one `renamex_np(RENAME_SWAP)` (two renames with rollback where the volume
   has no atomic swap). Restart Now / Install and Restart then reopen Jit with `/usr/bin/open -n`.
Regular development builds show the change log and link to the release page. The native acceptance test
uses a debug-only file transport, an isolated install and a disposable key.

**UI.** A bell toolbar item at the trailing end of the main window (standard item, system glass; badge
while a newer release is known). It opens *What's New*, a standard sheet: updater state and its one action,
the release notes of the last 20 releases (headings, paragraphs, bullets, inline bold/code/links; the list
  is saved in `Updates/releases.json` and reused for 24 hours), the *Update automatically* switch, Check
for Updates, Done. The same switch is in Settings ▸ General. Jit ▸ Check for Updates… is in the menu and the
command palette.

## Consequences
- **Trust.** GitHub distributes the feed and files. The owner's offline Ed25519 key authorizes the DMG
  bytes and version. Jit rejects unverifiable updates and older or mismatched versions. GitHub still
  controls release discovery, changelog text and availability.
- Existing versions through 0.1.2 install the first signed-update build manually. Starting with 0.1.3,
  publish `SHA256SUMS` for manual checks and omit the standalone `.dmg.sha256` required by the old updater.
  Users verify the manual download with the public key obtained separately from the maintainer. Replacing
  the signing key requires another trusted manual installation.
- The updated app carries no quarantine attribute, so the "Open Anyway" step is not needed after an
  in-app update. macOS may still ask once for Keychain access (ad-hoc builds have no stable identity).
- **The repository must be public** (or releases must move to a public repository): an unauthenticated
  request to a private repository answers 404, and Jit says the releases were not found. On 2026-11-11 the
  repository was private; the feature was verified against the real release data read with `gh`.
- The [release guide](../release.md) covers offline signing, verification, migration and publication.
- Idle cost is unchanged: no timer; one small file read after the first frame.

## Alternatives considered
- **Sparkle**: mature, EdDSA appcast, but a third-party framework with an XPC installer to sign and ship;
  rejected to keep Jit dependency-free.
- **Open the release page only**: no in-app install; rejected, the request was for updating in place.
- **Install while running, restart immediately in automatic mode**: would interrupt work and swap
  resources (bundled Git) under a running process; rejected.
