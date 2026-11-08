# Phase 7 — Packaging & release: design

> Requirements: §13.4 (bundled Git), §19, §20, §21, §23, §24 (scenarios A–G), §22 Phase 7.
> ADRs: 0019 (bundled Git runtime), 0020 (updates), plus 0045–0049 below.

## 1. Goal & demo

Produce a universal (Apple Silicon + Intel), Developer ID–signed, hardened, notarized and stapled DMG
that installs and runs on a clean macOS 26+ machine with **no Xcode, Command Line Tools or Homebrew**,
using a bundled, signed Git runtime — and prove it with a documented clean-VM run of scenarios A–G.
The app is 100% Swift (ADR-0002): the only native code beyond the app is the `jit-git-helper`
executable and the bundled Git. Intel matters only for Intel Macs that run macOS 26 (believed to be
the last macOS release supporting Intel — verify at implementation time; if the user decides Intel is
not worth it, ship arm64-only and record it in ADR-0049).

**Demo at the end of the phase**

1. `scripts/release/release.sh --version 1.0.0` runs all §20 steps (scripts 01–09) end to end and prints a summary
   (artifact path, SHA-256, signing identity, notarization submission ID, staple status).
2. On a fresh macOS 26 VM and a fresh latest-macOS VM (no CLT): open the DMG, drag Jit to Applications,
   launch — no Gatekeeper warning beyond the standard first-open confirmation, no CLT install prompt.
3. In the VM, clone a public repository, browse the graph, stage a line, commit, resolve a conflict.
4. `docs/release.md` has the completed acceptance checklist A–G with evidence; `docs/performance.md`
   has the release-build numbers re-measured with the bundled Git and universal binary.

If Developer ID / notarization credentials are unavailable, the demo is items 1–3 above with ad-hoc/local
signing, and the phase is reported **blocked on credentials** (§20) — see §4.8.

## 2. Scope / out of scope

**In scope**
- Universal builds of the app (including the local Swift package targets) and the `jit-git-helper`
  executable (`JitGitHelper` target).
- Bundled Git runtime: build, layout, relocation, configuration isolation, signing, licensing.
- Git resolution order and onboarding fallback.
- Entitlements, Hardened Runtime, sandbox decision.
- App icon in the current macOS style (layered Liquid Glass icon) and DMG styling.
- Code signing (inside-out), DMG creation, notarization, stapling, verification.
- Idempotent `scripts/release/` steps + orchestrator; secrets handling; `.gitignore` rules.
- Clean-machine verification and scenario A–G acceptance checklist.
- Release checklist, final documentation pass, release-build performance re-measure.
- ADR-0020 decision on updates.

**Out of scope**
- New features or UI changes beyond what packaging needs (brand DMG background, About/Acknowledgements
  window, onboarding fallback screen) → Phase 8 or bug-fix PRs.
- Mac App Store distribution (sandboxing + bundled Git make it a separate project) → Phase 8 parking lot.
- Auto-update implementation unless ADR-0020 approves an opt-in mechanism.
- Bundling OpenSSH (the system `/usr/bin/ssh` is used), Git LFS, or GUI merge tools → Phase 8.
- Continuous delivery publishing to a website/GitHub Releases is optional; the GitHub Release upload,
  if done, is an outward-facing action requiring the user's explicit approval.

## 3. User experience

### 3.1 DMG

- Window ≈ 640×400 pt, background artwork in the app's visual identity, consistent with the macOS 26
  look: a calm, softly lit surface that echoes the app icon's glass material (rendered artwork — the
  DMG window cannot use live glass), subtle brand mark; legible in macOS dark mode because Finder
  shows the image as-is — design for both. App icon on the left, `Applications` alias on the right, a
  thin arrow/guide between. No text clutter.
- Volume name `Jit <version>`, custom volume icon, icon size 128, hidden toolbar/sidebar.
- Background provided at 1× and 2× (`.tiff` multi-resolution via `tiffutil -cathidpicheck`).
- Read-only compressed (`UDZO` or `ULFO`; choose by size/compat — ULFO needs macOS 10.11+, fine).

### 3.2 App icon

- Designed for the current macOS icon system: a layered icon (foreground glyph layers over a
  background) authored in Apple's **Icon Composer** so the system renders the Liquid Glass material and
  the default, dark, clear and tinted appearances. Verify the tooling and the asset format the current
  Xcode expects (e.g. an `.icon` document in the app target) at implementation time; fall back to an
  asset-catalog `AppIcon` only if the toolchain requires it, and record which path was used.
- Glyph: a simple, original mark (e.g. abstract lanes/nodes) — no Git logo, no imitation of other Git
  clients. Readable at 16 pt; tested in Finder, Dock, Launchpad/App library, Spotlight and the DMG.
- Volume icon (`.VolumeIcon.icns`) derived from the same artwork.

### 3.3 First launch & Git runtime onboarding

- Normal case: bundled Git is found and validated silently (version check deferred until the first Git
  operation, per Phase 6 startup rules). No onboarding screen.
- Fallback case (bundled Git missing/corrupt/failing validation, which should only happen if bundling
  is abandoned or the bundle is tampered): a calm, native onboarding sheet on the new-tab page:
  - Title: "Git is required"
  - Body explains what was checked and found (e.g. "The bundled Git could not be started: <reason>").
  - Options: "Use Git at…" (file picker, validated), "Install Command Line Tools" (runs
    `xcode-select --install` only on explicit click), "Learn more" (local help page).
  - Never triggers the CLT install prompt implicitly — the app must not exec `/usr/bin/git` (an
    `xcrun` shim) unless the user chose it or CLT is detected as installed (`xcode-select -p` succeeds
    and the path exists).
- Settings → Advanced → Git: shows the Git in use (path, version, "bundled"/"custom"), lets the user
  switch to a custom Git (validated), and reset to bundled.

States: normal (silent), loading (validation in progress — inline spinner in the sheet only),
error (sheet above), custom-Git-invalid (inline error under the picker with the failing check).
Light/dark: standard system sheet (glass per ADR-0006 — no custom styling). Accessibility: sheet fully
keyboard operable, buttons labelled.

### 3.4 About & Acknowledgements

- About window: app name, version + build, short SHA, copyright, links to Acknowledgements and license.
- Acknowledgements: bundled third-party components with licenses — Git (GPLv2) with the written source
  offer / link to the corresponding source archive, and every Swift package dependency license
  (generated from `Package.resolved` and each package's LICENSE, reviewed; tree-sitter and grammars
  if Phase 3 adopted them).

## 4. Technical design

### 4.1 Universal build

- **Everything is built by Xcode.** Release configuration: `ARCHS = arm64 x86_64`,
  `ONLY_ACTIVE_ARCH = NO`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, set in `macos/project.yml` (XcodeGen) so
  the app target and the local Swift package targets it links (`GitCore`, `DesignSystem`, `Services`,
  `Features`) are compiled for both architectures in one build. No separate core build, no `lipo` step
  for our own code.
- **jit-git-helper:** the `JitGitHelper` executable target built in the same archive with the same
  `ARCHS`, embedded at `Jit.app/Contents/Helpers/jit-git-helper` (path fixed in Phase 5) via a
  copy-files build phase.
- **Archive/export:** `xcodebuild archive` then export with the Developer ID method, or a manual copy
  + our own signing script — choose the one that keeps inside-out signing under our control
  (recommended: archive, then our own signing script).
- Dev-only targets (`TestRig`, `JitBench`, `GitTestKit`) are never embedded in the shipped app —
  `03-verify-archs.sh` also asserts their absence.
- **Verification:** `lipo -archs` on every Mach-O in the bundle prints `x86_64 arm64`
  (script: walk the bundle, `file`-detect Mach-O, assert). Intel runtime testing: an Intel Mac if
  available; otherwise Rosetta (`arch -x86_64`) launch on Apple Silicon as partial evidence, clearly
  labelled as such.

### 4.2 Bundled Git runtime (ADR-0019)

**Options**

| Option | Pros | Cons |
|---|---|---|
| A. Build Git from source, universal, `RUNTIME_PREFIX=YesPlease` | Full control of version, features, dependencies; reproducible; relocatable | Build maintenance; must handle curl/TLS/pcre/expat/zlib; security patching is ours |
| B. Repackage a vetted prebuilt distribution (e.g. from a reputable project's universal build) | Less build work | Provenance/trust, relocation/rpath fixes, may include unneeded parts, signing third-party binaries, license obligations still ours |

**Recommendation: A**, scripted in `scripts/build/build-git.sh`, pinned version + SHA-256 of the source
tarball, built for arm64 and x86_64 separately then `lipo`'d.

**Build configuration**
- `make prefix=/ RUNTIME_PREFIX=YesPlease NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_PERL=? NO_PYTHON=YesPlease
  NO_INSTALL_HARDLINKS=YesPlease` (exact flags verified against the pinned Git's Makefile; Perl is needed
  only for a few porcelain commands — exclude if none are used by Jit, verify list).
- HTTPS transport: link against the system `libcurl` (`/usr/lib/libcurl.4.dylib`, available on all
  supported macOS 26+ systems, uses Secure Transport/LibreSSL + system trust) to avoid bundling OpenSSL — verify
  that custom CA configuration from Phase 5 (`http.sslCAInfo` scoped per URL) works with system curl's
  backend; if not, the fallback is bundling curl + OpenSSL (document security-update cost).
- `zlib`, `expat`: system libraries. `pcre2`: omit (`NO_PCRE` default) unless `git grep -P` is needed.
- `iconv`: system.

**Bundle layout** (inside `Jit.app/Contents/Resources/git/` or `Contents/SharedSupport/git/` — pick one;
Mach-O in Resources is legal but SharedSupport/Helpers is clearer; decide in ADR):
```
git/
  bin/git
  libexec/git-core/   # git (hardlinks replaced by copies or symlinks), git-remote-http(s), git-http-fetch,
                      # git-http-push?, git-sh-setup & shell helpers needed by rebase/merge,
                      # git-merge-* helpers, git-mergetool--lib excluded unless needed
  share/git-core/templates/   # minimal; NO sample hooks enabled (samples are inert .sample files — keep or drop)
  etc/gitconfig       # bundled "system" config (see isolation)
  LICENSE, VERSION, SOURCE.txt
```
- Prune with an allowlist derived from the Git subcommands Jit actually invokes (grep `git-core`
  invocations + integration tests run against the pruned bundle with `GIT_TRACE` to catch missing helpers).
- Replace hardlinks with symlinks or a single binary + dashed-command symlinks to keep the bundle small
  and code signing sane (each real Mach-O signed once).

**Configuration isolation**
- `RUNTIME_PREFIX` makes Git resolve `libexec`, `share`, and `etc/gitconfig` relative to the binary.
- System config: ship an empty-or-minimal bundled `etc/gitconfig` (e.g. nothing, or `credential.helper=`
  cleared) so we don't inherit Apple's `/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig`
  (`credential.helper=osxkeychain`), which would bypass Jit's credential model. Alternatively set
  `GIT_CONFIG_NOSYSTEM=1` per invocation — decide; both must leave the user's `~/.gitconfig` and repo
  config respected (§10.3).
- Environment for each invocation (from Phase 4/5 ProcessRunner): `GIT_EXEC_PATH` not needed with
  RUNTIME_PREFIX (verify), `GIT_TERMINAL_PROMPT=0`, controlled askpass/credential helper, sanitized
  `PATH` that still contains `/usr/bin` for `ssh`.
- SSH: system `/usr/bin/ssh` via the Phase 5 profile-scoped `core.sshCommand`.

**Version pinning & security updates**
- `scripts/build/git-version.env` pins version + tarball SHA-256 + signature verification (Git release
  tags are signed; verify with the maintainer's key — record fingerprint in docs).
- Process: subscribe to Git security announcements; on a CVE affecting used features, bump, rebuild,
  re-run integration tests against the bundle, release a patch. Documented in `docs/release.md` and
  `docs/security.md`.

**Licensing (GPLv2)**
- Distributing Git binaries requires providing the corresponding source. Options: include the exact
  source tarball on the DMG (simple, increases size ~10 MB) or a written offer valid ≥ 3 years plus a
  public download of the exact tarball and build script. Recommendation: publish the tarball + build
  script alongside each release and include the written offer + license text in Acknowledgements and
  `git/LICENSE`. Jit's own code calls Git as a separate process (no linking), so Jit's license is
  unaffected — note this reasoning in the ADR (not legal advice; flag for the user's own review).

### 4.3 Git resolution order (app)

1. User-configured custom Git (Settings) if set and valid.
2. Bundled Git (release builds).
3. Development only (Debug builds or explicit env `JIT_GIT_PATH`): `$JIT_GIT_PATH`, then
   Homebrew `/opt/homebrew/bin/git`, `/usr/local/bin/git`, then `/usr/bin/git` **only if**
   `xcode-select -p` succeeds and points to an existing directory.
4. Otherwise: onboarding fallback (§3.2).

Validation: `git --version` ≥ ADR-0006 minimum, `git --exec-path` resolves, `git ls-remote --help`-style
smoke not needed — keep it to version + exec-path + one `git rev-parse --git-dir` in a temp repo on
first use. Cached per session; re-validated if the path changes.

### 4.4 Entitlements, Hardened Runtime, sandbox (ADR-0045)

- **Hardened Runtime:** on for the app, `jit-git-helper` and every bundled Git binary
  (`--options runtime`).
- **Entitlements (app):** none beyond defaults is the goal. Candidates to evaluate and reject unless
  needed: `com.apple.security.cs.disable-library-validation` (should not be needed — all code is signed
  by us; system libcurl is Apple-signed), `allow-jit`, `allow-unsigned-executable-memory` (not needed).
  Bundled Git binaries: no entitlements.
- **App Sandbox: not enabled for V1 (recommended).** Reasons: users open arbitrary repository paths
  and Git touches files outside them (`~/.gitconfig`, `~/.ssh/known_hosts`, worktrees, alternates,
  submodules, hooks); Git spawns subprocesses (`ssh`, hooks, helpers) that would inherit sandbox
  restrictions; credential helper IPC; editors launched externally. Security-scoped bookmarks would
  cover repo folders but not Git's own config/SSH ecosystem. Revisit for a Mac App Store variant
  (Phase 8). The ADR documents the threat-model consequences and compensating controls (§19 rules,
  no network by default, hardened runtime, notarization).

### 4.5 Code signing (ADR-0046)

- Identity: "Developer ID Application: <Team> (<TEAMID>)" from the login keychain or a temporary CI
  keychain; never committed.
- Inside-out order: every Mach-O in `git/libexec/git-core` and `git/bin` → `Contents/Helpers/jit-git-helper`
  → any frameworks/dylibs (only if a Swift package is linked dynamically; the plan links them
  statically) → the app bundle. Each with
  `codesign --force --timestamp --options runtime --sign "$IDENTITY" [--entitlements <file>] <path>`.
- **No `--deep`** for signing (it applies one entitlement set to everything and hides ordering
  mistakes); `--deep` is used only in verification.
- Symlinks are not signed; scripts (`git-sh-setup`, shell helpers) are covered by the bundle seal when
  in Resources/SharedSupport — confirm notarization accepts their location.
- Verification: `codesign --verify --strict --deep --verbose=2 Jit.app`,
  `codesign -dv --verbose=4` (check `flags=0x10000(runtime)`, timestamp, Team ID),
  `spctl --assess --type execute --verbose Jit.app` (passes only after notarization/stapling for
  Developer ID).

### 4.6 DMG, notarization, stapling (ADR-0047)

- DMG build: create a read-write temp image (`hdiutil create -srcfolder staging -volname ... -fs APFS`
  or HFS+ — HFS+ has the best Finder layout compatibility; decide), mount, place app + `Applications`
  symlink + `.background/background.tiff`, set Finder layout via AppleScript (or `.DS_Store` generated
  once and committed as a binary asset — avoids AppleScript automation prompts in CI; recommended:
  generate once, commit, document regeneration), set volume icon (`.VolumeIcon.icns` + `SetFile -a C`
  or `xattr` equivalent), unmount, convert to compressed read-only, sign the DMG
  (`codesign --sign "$IDENTITY" --timestamp Jit-x.y.z.dmg`).
- Notarize: `xcrun notarytool submit Jit-x.y.z.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  --output-format json`; on failure fetch `xcrun notarytool log <id>` and fail the script with the log
  path. Credentials stored once with `xcrun notarytool store-credentials` (App Store Connect API key
  preferred over Apple ID + app-specific password).
- Staple: `xcrun stapler staple Jit-x.y.z.dmg` (stapling the DMG covers the app inside for offline
  first launch; also staple the app before DMG creation if notarizing the app zip separately — choose one
  flow: recommended notarize the signed DMG, then staple the DMG).
- Validate: `xcrun stapler validate`, `spctl --assess --type open --context context:primary-signature -v
  Jit-x.y.z.dmg`, mount and `spctl --assess --type execute` the app inside, `codesign --verify --strict
  --deep`. Record SHA-256.

### 4.7 Release scripts (`scripts/release/`)

Each step is a separate idempotent script, runnable alone, reading config from env + a non-secret
`release.env` (version, bundle ID, team ID placeholder), writing into `build/release/<version>/`:

| # (§20) | Script | Output / idempotency key |
|---|---|---|
| 1–3 | `01-build-app.sh` | XcodeGen generate + clean universal Release archive of the app and `jit-git-helper` (§20 steps 1–3: native Swift components, no separate core build, required architectures) |
| 4 | `02-bundle-git.sh` | builds/copies pruned universal Git into the app (§20 step 4: native dependencies) |
| — | `03-verify-archs.sh` | asserts every Mach-O is `arm64 x86_64` (or arm64-only if ADR-0049 says so); no dev-only targets embedded |
| 5 | `04-sign-embedded.sh` | signs nested code inside-out |
| 6 | `05-sign-app.sh` | signs the app bundle, verifies |
| 7 | `06-create-dmg.sh` | styled DMG, signed |
| 8 | `07-notarize.sh` | submission ID + log saved; skips if already accepted for this DMG hash |
| 9 | `08-staple.sh` | stapled DMG |
| 10 | `09-validate.sh` | full verification report (`validation.txt`), SHA-256 |
| — | `release.sh` | orchestrator with `--skip-notarize`, `--adhoc`, `--from-step N` |

Rules: `set -euo pipefail`; no secrets echoed (`set +x` around credential use); fail fast with clear
messages; outputs under `build/` (git-ignored). `.gitignore` adds `build/`, `*.p12`, `*.cer`,
`*.p8`, `AuthKey_*.p8`, `*.provisionprofile`, `release.local.env`, `notary-*.json` logs if they contain
account info.

### 4.8 Credentials-unavailable path

If no Developer ID certificate / notary credentials:
- Run scripts 01–06 with `--adhoc` (`codesign --sign -` with `--options runtime`), verify hardened
  runtime flags and structure with `codesign -dv`, build the DMG, run `03-verify-archs.sh` and the
  structure parts of `09-validate.sh`.
- Run clean-VM verification with the ad-hoc build (user must right-click → Open or remove quarantine —
  documented as *not* representative of Gatekeeper behavior).
- `progress.md` status: **blocked (Developer ID certificate and notarization credentials)** with the
  exact remaining commands. Never describe the release as notarized.

### 4.9 Clean-machine verification (ADR-0048)

- VMs via Virtualization.framework tooling (UTM, `tart`, or Apple's sample app) — macOS 26 (the minimum)
  and the latest macOS, freshly installed, no CLT/Xcode/Homebrew, standard user account, Gatekeeper default.
- Transfer the DMG by download (so it gets the quarantine attribute — e.g. serve over a local HTTP
  server and download in Safari) rather than shared folders that may skip quarantine.
- Checks: `xcode-select -p` fails (proves no CLT); first launch shows only the standard "downloaded from
  the internet" confirmation; no CLT install dialog during any scenario; `ps` shows Git processes running
  from inside the app bundle; Liquid Glass chrome renders correctly in the VM (note: VMs may lack full
  GPU acceleration — judge glass visuals on real hardware and only functional behavior in the VM).
- Run scenarios A–G (§24) with the checklist in `docs/release.md` (each item: expected, observed,
  evidence — screenshot/log path, pass/fail). Scenario E/F need real accounts/servers: if unavailable,
  run against the Phase 5 local test rig and mark "verified against test rig, not production" explicitly.
- Intel: real Intel Mac if available; otherwise state "Intel verified under Rosetta only" or "not verified".

### 4.10 Updates (ADR-0020)

Recommendation: **V1 ships without automatic updates.** Rationale: §19 forbids unintended remote
requests; an updater adds a network endpoint, a signing key and a dependency (Sparkle) whose security
we must own. V1 offers Help → "Check for Updates…" only if it opens the release page in the browser
(no background check). An opt-in Sparkle (EdDSA-signed appcast, no automatic checks unless the user
enables them, no system profiling) can be proposed in Phase 8. ADR records both options and the choice.

### 4.11 Security review for release

- Dependency audit: every entry in `Package.resolved` reviewed for license, maintenance and known
  advisories (GitHub advisory database / package changelogs); pinned exact versions; results in
  `docs/security.md`. Bundled Git version checked against Git security announcements.
- Binary audit: `strings`/grep the bundle for accidental secrets, debug endpoints, test client IDs,
  developer paths; strip debug info from shipped binaries (keep dSYMs privately archived).
- Confirm no telemetry/network at idle on the release build (re-run Phase 6 idle network check).

## 5. Edge cases & failure modes

- Notarization rejects unsigned/ad-hoc nested binary or missing timestamp → `07-notarize.sh` surfaces
  the specific issue from the log; fix in `04-sign-embedded.sh`.
- Notarization service slow/unavailable → `--wait` with timeout; resumable by submission ID.
- Hardlinked Git binaries signed multiple times break the seal → replaced by symlinks before signing.
- System libcurl behavior differs between macOS 26 and the latest macOS (TLS, proxy) → test both VMs;
  fallback plan in ADR-0019.
- App translocation (running from the DMG or Downloads) → app works read-only from translocated path;
  optionally prompt to move to Applications (decide; no auto-move without consent).
- Quarantine attribute on bundled Git after copying → irrelevant once the app is notarized; verify
  Git runs without prompts.
- Rosetta not installed on test Mac → Intel slice untested; report.
- DMG Finder layout broken on dark mode / different macOS → test both VMs, screenshots.
- App icon renders wrong in an appearance (dark/clear/tinted) or at small sizes → check Finder, Dock,
  Spotlight in each appearance; fix layers in Icon Composer.
- Version mismatches between `CFBundleShortVersionString`, `CFBundleVersion`, DMG name and git tag →
  `release.sh` derives all from one `--version` and asserts consistency.
- User has a custom Git configured that is older than the minimum → validation error with reason.

## 6. ADRs to write

- **ADR-0019** Bundled Git runtime (option A vs B, flags, layout, config isolation, licensing, updates).
- **ADR-0020** Updates for V1 (no auto-update; opt-in Sparkle deferred).
- **ADR-0045** Entitlements, Hardened Runtime, no App Sandbox for V1.
- **ADR-0046** Code signing procedure (inside-out, no `--deep`, identities, keychains).
- **ADR-0047** DMG format and notarization flow (notarize DMG, staple DMG, layout method).
- **ADR-0048** Clean-machine verification protocol (VM tooling, OS versions, evidence requirements).
- **ADR-0049** Release versioning and artifacts (semver, build numbers, tag format `v1.0.0`, checksums,
  source-offer artifacts, universal vs arm64-only decision).

## 7. Open questions / spikes

| Question | Spike | Decision criteria |
|---|---|---|
| System libcurl vs bundled curl+OpenSSL for Git HTTPS? | Build Git against system curl; test Phase 5 custom-CA + proxy rig on macOS 26 and latest. | Custom CA scoped per URL and proxy work → system curl; otherwise bundle with documented patch process. |
| Which `libexec/git-core` entries are needed? | Run full integration suite with `GIT_TRACE=1` against a pruned bundle. | All tests pass; no "not a git command" or missing helper errors. |
| Perl/Python needed? | Grep invoked subcommands; check for Perl-based porcelains. | Exclude if unused. |
| Bundle location for Git (Resources vs SharedSupport vs Helpers)? | Sign + notarize a test bundle each way. | Notarization accepted, `codesign --strict` clean, simplest layout. |
| `GIT_CONFIG_NOSYSTEM=1` vs bundled empty system config? | Test with user `~/.gitconfig` + CLT installed. | User/repo config respected, Apple's osxkeychain helper not inherited. |
| HFS+ vs APFS DMG; `.DS_Store` committed vs AppleScript? | Build both. | Layout correct on macOS 26 + latest, CI-friendly, no automation prompts. |
| Intel hardware availability / is Intel worth shipping? | Ask user; confirm which Intel Macs run macOS 26. | Real Intel test, else Rosetta + explicit caveat; or arm64-only by owner decision (ADR-0049). |
| Icon Composer / `.icon` support in the current Xcode? | Build a test app with a layered icon. | Renders in all system appearances; builds from the command line in CI. |
