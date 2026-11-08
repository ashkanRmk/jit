# Phase 0 — Foundation & Design: design

Sources: §0–§3, §13, §15.1, §19, §21, §22 (Phase 0), §25 steps 1–3. Plan context: [`../../roadmap.md`](../../roadmap.md).

## 1. Goal & demo

Establish a buildable, measured foundation: a native macOS window that calls a real Rust Git core
through UniFFI, a first version of the design system, the build pipeline, and the first ADRs.

**Demo at the end of the phase**

1. `scripts/build/build-all.sh` builds the Rust core, generates Swift bindings, generates the Xcode
   project and builds `Jit.app` from a clean checkout.
2. Launching `Jit.app` shows a polished (not placeholder-looking) empty window within the target time.
3. "Open Repository…" (⌘O) → pick a folder → the window shows what the Rust core discovered: repository
   kind (regular / bare / linked worktree), top-level path, git dir, current branch or detached/unborn
   state, and the Git executable + version in use. Picking a non-repository shows a designed error state.
4. A debug-only "Design Tokens" window renders every token in light and dark.
5. `docs/performance.md` contains the first measured baseline (launch, idle CPU, wakeups, memory).

## 2. Scope / out of scope

**In scope:** environment verification, repository scaffold, Rust workspace (`git-core`, `git-ffi`,
`git-testkit`, `uniffi-bindgen` tool crate), process execution and Git location, repository discovery,
UniFFI bridge with cancellation/progress/error primitives, build scripts, XcodeGen project, CI, design
direction and token set v1, token gallery, baseline benchmarks, initial docs and ADRs 0001–0006.

**Out of scope** (and where it lives):

| Not in Phase 0 | Lives in |
|---|---|
| Tabs, new-tab page, recents, layout regions, menus beyond the minimum | Phase 1 |
| Status parsing, file watching, profiles, persistence | Phase 1 |
| History, graph, branch navigator | Phase 2 |
| Diff, staging, commit | Phase 3 |
| Remote operations, conflicts | Phase 4 |
| Authentication, providers, networking | Phase 5 |
| Universal binary, signing, notarization, bundled Git | Phase 7 (feasibility notes only here) |

## 3. User experience

Phase 0 has two small screens, but they set the visual tone. Treat them as product UI.

### 3.1 Foundation window

- **Interaction:** app launches into one window. Empty state invites opening a repository (button +
  ⌘O + drag a folder onto the window). After selection, a repository card replaces the empty state.
  "Open Another…" re-runs the panel. No other controls.
- **Visual hierarchy:** window background `surface.canvas`; centered content column max 520 pt.
  Empty state: SF Symbol (`folder.badge.gearshape` or a custom mark) at 40 pt in `text.tertiary`,
  title (`type.title`), one line of `text.secondary` copy, a primary button.
  Repository card: name (`type.display`), path (`type.mono.caption`, middle-truncated, selectable),
  a key/value grid (`type.callout` labels in `text.tertiary`, values in `text.primary`, SHAs in mono).
- **States:**
  - Empty: as above.
  - Loading: discovery normally completes in < 50 ms; show nothing for the first 150 ms, then a small
    `ProgressView` in place of the card (avoids flicker).
  - Normal: repository card.
  - Error: inline message block with `status.danger` icon, human sentence ("This folder isn't a Git
    repository."), the path, and "Choose Another Folder…". Distinct copy for: not a repo, permission
    denied, Git not found (with a short how-to: install Xcode Command Line Tools or Homebrew Git; the
    bundled runtime arrives in Phase 7), Git too old (found vs required).
- **Light/dark:** verify both; the card uses `surface.raised` + `border.subtle` + `shadow.1` in light,
  luminance step + `border.subtle` and no shadow in dark.
- **Micro-interactions:** card appears with a 160 ms opacity + 4 pt rise (`motion.panel` curve);
  Reduce Motion → opacity only. Button hover/press per tokens.
- **Keyboard:** ⌘O opens panel; Return activates the primary button; ⌘W closes window; ⌘Q quits.
- **Accessibility:** card is an accessibility group with label "Repository <name>"; values are
  readable by VoiceOver in order; error block announced via `AccessibilityNotification.Announcement`.

### 3.2 Token gallery (debug builds only)

Menu `Debug ▸ Design Tokens` (compiled only with `#if DEBUG`). A scrollable window with sections:
surfaces (swatches stacked to show hierarchy), text colors on each surface, accents and status colors,
diff colors with sample lines, lane palette as a mini graph, typography scale with sample strings
(SF Pro + SF Mono incl. a 40-char SHA), spacing ruler, radii, borders, shadows, focus ring, interactive
states (rest/hover/pressed/selected/disabled for a row and a button), motion demo buttons. A segmented
control forces Light / Dark / System for the gallery window only. This window is how design reviews and
screenshots happen until real screens exist.

### 3.3 Design direction — "Quiet Instrument"

The app should feel like a precision instrument resting on a calm desk: mineral surfaces, ink-dark
typography, one cool accent used sparingly, color reserved for meaning (branch lanes, diff, status).
Depth comes from luminance steps and hairlines, not from blur, glow, or heavy shadows.

Principles:

1. **Hierarchy by luminance, not borders.** Panels differ by 2–4 % luminance; hairline borders only
   where two surfaces of equal luminance meet.
2. **One accent.** "Tidewater" (a deep teal-ink) marks focus, selection and the primary action. It never
   colors large areas.
3. **Color means something.** Lanes, diff, and status own the saturated colors; chrome stays neutral.
4. **Density with air.** Compact rows, generous section spacing; align to a 4 pt grid.
5. **Motion is confirmation, not decoration.** Short, damped, never looping.

Light and dark are designed separately: light is warm mineral white with graphite ink; dark is
graphite with soft warm-white text — not an inversion.

#### Color tokens — starting values (to be refined with screenshots in P0.6)

| Token | Light | Dark | Use |
|---|---|---|---|
| `surface.canvas` | `#F5F4F1` | `#161719` | window background, graph area |
| `surface.panel` | `#FAF9F7` | `#1B1C1F` | sidebar, inspector |
| `surface.raised` | `#FFFFFF` | `#222327` | cards, popovers, sheets |
| `surface.sunken` | `#EEECE8` | `#111214` | inputs, code wells |
| `surface.overlay` | `#FFFFFF` @ 96 % | `#2A2B30` @ 96 % | menus, HUD |
| `border.subtle` | `#E3E0DA` | `#2B2D31` | hairlines |
| `border.strong` | `#CDC9C1` | `#3A3C42` | input outlines, dividers under emphasis |
| `text.primary` | `#1D2023` | `#E7E5E0` | body |
| `text.secondary` | `#545A60` | `#A8A6A1` | metadata |
| `text.tertiary` | `#878C92` | `#76756F` | labels, placeholders |
| `text.disabled` | `#B3B6BA` | `#4E4E4B` | disabled |
| `accent.base` | `#21707A` | `#67B5BA` | focus, primary button, selection edge |
| `accent.muted` (selection fill) | `#21707A` @ 12 % | `#67B5BA` @ 16 % | selected rows |
| `accent.onAccent` | `#FFFFFF` | `#0E1A1C` | text on accent |
| `state.hover` | `#1D2023` @ 4 % | `#E7E5E0` @ 5 % | hover overlay |
| `state.pressed` | `#1D2023` @ 8 % | `#E7E5E0` @ 9 % | pressed overlay |
| `focus.ring` | `accent.base` @ 55 %, 3 pt | `accent.base` @ 60 %, 3 pt | keyboard focus |
| `status.success` | `#2F7A4A` | `#71BE8A` | success |
| `status.warning` | `#A3670F` | `#E0A651` | warning, "no profile" |
| `status.danger` | `#AE3932` | `#E57A70` | errors, destructive |
| `status.info` | `#3D6394` | `#86A8D6` | info |
| `diff.add.bg` / `diff.add.mark` | `#E5F1E7` / `#2F7A4A` | `#1A2A20` / `#71BE8A` | added lines / gutter & word marks |
| `diff.del.bg` / `diff.del.mark` | `#F7E5E3` / `#AE3932` | `#2D1C1B` / `#E57A70` | deleted lines |

**Lane palette (draft, 8 hues).** Muted, equal perceived lightness within a theme, distinguishable for
common color-vision deficiencies when paired with lane position. Validate contrast against
`surface.canvas` (≥ 3:1 for lines) in P0.6 and refine in Phase 2.

| Lane | Light | Dark |
|---|---|---|
| `lane.0` slate | `#4C6B9F` | `#8EA7D1` |
| `lane.1` tidewater | `#2B8580` | `#6FC0B9` |
| `lane.2` moss | `#6F8435` | `#A9BE72` |
| `lane.3` ochre | `#A9782A` | `#D9AD62` |
| `lane.4` clay | `#AD5A43` | `#DD9079` |
| `lane.5` heather | `#82599A` | `#B897CF` |
| `lane.6` rosewood | `#A8577A` | `#D891B0` |
| `lane.7` steel | `#5D7380` | `#9BB0BC` |

Also provide Increase Contrast variants (`NSAppearance` high-contrast names): borders +1 step, text
secondary/tertiary darkened/lightened, lane lines 1.5× width (graph applies this in Phase 2).

#### Typography (SF Pro / SF Mono)

| Token | Font | Size / line | Weight | Use |
|---|---|---|---|---|
| `type.display` | SF Pro | 20 / 26 | Semibold | page titles, repo name |
| `type.title` | SF Pro | 15 / 20 | Semibold | section titles, sheet titles |
| `type.headline` | SF Pro | 13 / 18 | Semibold | row titles, group headers |
| `type.body` | SF Pro | 13 / 18 | Regular | default |
| `type.callout` | SF Pro | 12 / 16 | Regular | metadata |
| `type.caption` | SF Pro | 11 / 14 | Medium | labels, badges |
| `type.micro` | SF Pro | 10 / 12 | Semibold, +2 % tracking, uppercase | section eyebrows |
| `type.mono.body` | SF Mono | 12 / 18 | Regular | code, diff |
| `type.mono.caption` | SF Mono | 11 / 14 | Regular | SHAs, paths |

Numbers in tables/counters use monospaced digits (`.monospacedDigit()`). Dynamic Type isn't native on
macOS; expose a text-size preference (−1 / default / +1 / +2) that scales the table in Phase 6.

#### Spacing, radii, borders, shadows

- Spacing (4 pt base): `space.1`=2, `space.2`=4, `space.3`=6, `space.4`=8, `space.5`=12, `space.6`=16,
  `space.7`=20, `space.8`=24, `space.9`=32, `space.10`=40.
- Radii: `radius.xs`=3 (badges), `radius.sm`=5 (buttons, inputs, rows), `radius.md`=7 (cards),
  `radius.lg`=10 (popovers), `radius.xl`=12 (sheets/new-tab tiles). Use continuous corners.
- Borders: hairline = 1 px (0.5 pt on Retina) `border.subtle`; emphasis = 1 pt `border.strong`.
- Shadows (light only, dark uses luminance): `shadow.1` y1 blur3 6 %, `shadow.2` y4 blur12 10 %
  (popovers), `shadow.3` y12 blur32 16 % (sheets). Never animate shadows.

#### Motion

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motion.hover` | 100 ms | ease-out | hover fills |
| `motion.press` | 60 ms | ease-out | pressed state |
| `motion.select` | 150 ms | `cubic(0.2, 0, 0, 1)` | row/tab selection |
| `motion.panel` | 200 ms | `cubic(0.2, 0, 0, 1)` | sidebar/inspector, card reveal |
| `motion.feedback` | 180 ms in / 120 ms out | ease-out / ease-in | success ticks, toasts |

Reduce Motion: positional/scale animations become opacity-only at the same duration, or instant for
panel resizes. All animations are one-shot; nothing loops except determinate/indeterminate progress
that is visible and tied to a running operation.

#### Sizes and density

- Icons: `icon.sm`=12, `icon.md`=16, `icon.lg`=20 (SF Symbols, `.medium` weight in chrome).
- Panels: tab bar 36 pt incl. titlebar; sidebar min 200 / default 248 / max 380; inspector min 340 /
  default 440 / max 60 % of window; window min 960×600.
- Density: `compact` row 22 pt, `comfortable` row 26 pt (graph and lists). Default comfortable.

## 4. Technical design

### 4.1 Components

**Rust (`rust/`)**

- `git-core` — pure Rust, no UniFFI dependency.
  - `locator`: finds Git. Order: (1) `JIT_GIT_PATH` env (dev override, debug builds only),
    (2) bundled path inside the app bundle (wired in Phase 7; checked now, absent), (3) user override
    from preferences (Phase 6), (4) `/opt/homebrew/bin/git`, `/usr/local/bin/git`, (5) `/usr/bin/git`
    **only if** the developer directory actually contains Git (check for
    `/Library/Developer/CommandLineTools/usr/bin/git` or the selected Xcode's `usr/bin/git` by file
    existence). Never execute `/usr/bin/git` or `xcrun` blindly: on a machine without CLT the shim pops
    the "install command line developer tools" dialog. Result: `GitExecutable { path, version, source }`.
  - `version`: parse `git version 2.54.0`, `git version 2.39.5 (Apple Git-154)`, `.windows.`-style
    suffixes; compare against `MIN_GIT_VERSION` (ADR-0006).
  - `process`: `ProcessRunner::run(GitCommand) -> Result<Output, CoreError>`.
    - argv only (`std::process::Command`), explicit `current_dir`.
    - `env_clear()` then an allowlist: `HOME`, `PATH` (minimal, includes the Git exec dir),
      `TMPDIR`, `USER`, `LANG`/`LC_ALL=C` for parse-stable output, `GIT_TERMINAL_PROMPT=0`,
      `GIT_ASKPASS` / `SSH_ASKPASS` pointing to a non-interactive "deny" path until Phase 5,
      `GIT_OPTIONAL_LOCKS=0` for read commands, `GIT_EDITOR=true` / `GIT_SEQUENCE_EDITOR=true` /
      `GIT_MERGE_AUTOEDIT=no` so no command ever waits on an editor (operations that need a message
      pass it explicitly). `SSH_AUTH_SOCK` passes through (agent support).
    - Always prepend `-c core.quotepath=false` and `--no-pager`/`-c color.ui=false` as needed.
    - New process group (`CommandExt::process_group(0)`); cancellation sends `SIGTERM` to the group,
      then `SIGKILL` after a 2 s grace; same path for timeouts.
    - stdout read on the calling thread with a byte cap (configurable per command); stderr drained on
      a scoped helper thread with a smaller cap (keep the last 64 KiB). Threads exist only for the
      lifetime of a command — no pools when idle.
    - stdin closed unless the command needs input (`Stdio::null`).
  - `discovery`: `discover(path) -> RepositoryInfo` using one call:
    `git -C <path> rev-parse --path-format=absolute --show-toplevel --absolute-git-dir --git-common-dir --is-bare-repository --is-inside-work-tree`
    (bare repos have no toplevel; handle by running a reduced arg list), plus
    `git symbolic-ref -q --short HEAD` / `rev-parse -q --verify HEAD` for branch, detached, unborn.
    Linked worktree = git dir ≠ common dir. Classify errors from exit code + stderr patterns into typed
    errors (not a repo, permission denied, dubious ownership/`safe.directory`).
  - `error`: `CoreError` (`thiserror`), every variant carries a user-presentable summary; raw stderr
    kept separately as `detail` after sanitization (strip anything URL-credential-shaped).
- `git-testkit` (dev-dependency) — builds real temp repos via the Git CLI with fixed author/committer
  dates and identity (`GIT_AUTHOR_DATE`, etc.) for determinism. API: `TestRepo::new()`, `.write(path,
  bytes)`, `.commit(msg)`, `.branch()`, `.worktree_add()`, `.bare_clone()`; isolated `HOME` and
  `GIT_CONFIG_GLOBAL=/dev/null`-equivalent so the developer's config never leaks into tests.
- `git-ffi` — thin UniFFI layer (proc-macro mode, no UDL). Converts core types to FFI records. Builds
  `staticlib` (and `cdylib` only if bindgen library mode requires it on the host).
- `uniffi-bindgen` — tiny tool crate exposing the bindgen CLI pinned to the workspace UniFFI version.

**Swift (`macos/`)**

- `App/` (XcodeGen target `Jit`): `@main` SwiftUI `App`, `AppDelegate` adaptor, the foundation window,
  debug menu.
- `Packages/JitKit` targets (ADR-0004):
  - `JitCoreFFI` — binary target wrapping the generated XCFramework.
  - `GitCoreBridge` — generated Swift bindings (gitignored, regenerated) + hand-written wrapper.
  - `DesignSystem` — tokens, fonts, reusable styles (button styles, row background, focus ring).
  - `Features` — `FoundationView` (Phase 0 screen), token gallery (`#if DEBUG`).
  - `Services` — created when first needed (Phase 1).

### 4.2 Bridge API sketch (illustrative)

```rust
// git-ffi
#[derive(uniffi::Object)]
pub struct CancelToken { /* AtomicBool + registered process-group ids */ }
#[uniffi::export]
impl CancelToken {
    #[uniffi::constructor] pub fn new() -> Arc<Self>;
    pub fn cancel(&self);            // idempotent; kills registered process groups
    pub fn is_cancelled(&self) -> bool;
}

#[uniffi::export(with_foreign)]
pub trait ProgressSink: Send + Sync {
    fn on_progress(&self, update: ProgressUpdate);   // throttled by core to <= 10 Hz
}

#[derive(uniffi::Record)] pub struct ProgressUpdate { pub phase: String, pub completed: u64, pub total: Option<u64> }

#[derive(uniffi::Error, Debug)]
pub enum CoreError {
    GitNotFound, GitTooOld { found: String, required: String },
    NotARepository { path: String }, PermissionDenied { path: String },
    UnsafeRepository { path: String },               // safe.directory / dubious ownership
    Cancelled, TimedOut { seconds: u32 },
    ProcessFailed { exit_code: i32, summary: String, detail: String },
    Io { summary: String }, Internal { summary: String },
}

#[derive(uniffi::Object)] pub struct GitEngine { /* GitExecutable, config */ }
#[uniffi::export]
impl GitEngine {
    #[uniffi::constructor] pub fn new(config: EngineConfig) -> Result<Arc<Self>, CoreError>;
    pub fn git_info(&self) -> GitInfo;                                  // path, version, source
    pub fn discover_repository(&self, path: String, cancel: Arc<CancelToken>) -> Result<RepositoryInfo, CoreError>;
}
#[uniffi::export] pub fn core_version() -> String;
```

```swift
// GitCoreBridge (hand-written)
public final class GitCore: Sendable {
    public static func make() async throws -> GitCore          // constructs GitEngine off-main
    public func discover(at url: URL) async throws -> RepositoryInfo
}
```

The wrapper runs every Rust call on a dedicated serial-or-concurrent `DispatchQueue` (not the Swift
cooperative pool — the calls block on subprocesses), bridges with `withCheckedThrowingContinuation`,
and wires `withTaskCancellationHandler { token.cancel() }`. Errors map to a Swift `GitCoreError` with
`LocalizedError` copy owned by the Swift layer.

### 4.3 State ownership, concurrency, caching

- Phase 0 state is a single `@MainActor @Observable FoundationModel` (`idle | loading | loaded(info) |
  failed(error)`). Phase 1 replaces it with the real architecture.
- `GitEngine` is created once at launch, off the main thread, lazily on first use (not before the
  window is visible). Git version check runs then; the result is cached for the process lifetime.
- No caches beyond that in Phase 0.

### 4.4 Build pipeline

1. `scripts/build/build-rust.sh [debug|release]` — `cargo build -p git-ffi --target aarch64-apple-darwin`,
   run `uniffi-bindgen generate --library <lib> --language swift --out-dir <tmp>`, place the `.swift`
   file in `macos/Packages/JitKit/Sources/GitCoreBridge/Generated/`, build
   `JitCoreFFI.xcframework` with `xcodebuild -create-xcframework -library <.a> -headers <hdr dir with
   modulemap>` into `macos/Packages/JitKit/Frameworks/` (gitignored). Idempotent; skips work when
   inputs are unchanged (compare a hash of `Cargo.lock` + crate sources).
2. `scripts/build/gen-xcodeproj.sh` — `xcodegen generate --spec macos/project.yml`.
3. `scripts/build/build-app.sh [debug|release]` — `xcodebuild -scheme Jit -configuration … build`.
4. `scripts/build/build-all.sh` — 1 → 2 → 3; fails fast with readable messages.
5. An Xcode pre-build script phase calls `build-rust.sh` so building in Xcode stays one step.

SPM local binary targets must resolve within the package directory — verify in P0.4 and adjust paths
if not. Generated files are never committed.

CI (`.github/workflows/ci.yml`): macOS runner, `rustup` pinned toolchain, `cargo fmt --check`,
`cargo clippy -D warnings`, `cargo test`, `build-all.sh debug`, `xcodebuild test` for JitKit. Install
XcodeGen via Homebrew in CI. No secrets.

### 4.5 Performance approach

- First window comes from SwiftUI `WindowGroup`/`Window` with no work in `init`; `GitEngine` creation is
  deferred to the first user action or a post-first-frame task at `.utility` priority.
- Avoid loading fonts manually (system fonts), avoid large asset catalogs.
- Measure, don't assume (see implementation P0.7).

### 4.6 Security

- App Sandbox **off** (Developer ID distribution; the client must run Git and read arbitrary repos and
  `~/.ssh`). Hardened Runtime on from day one in all configurations so surprises appear early.
- Process safety rules from §13.5 enforced inside `ProcessRunner` — there is no API to run a shell.
- Initial threat model in `docs/security.md`: untrusted repository content (hooks, filters, `core.*`
  config keys such as `core.fsmonitor`/`core.sshCommand`, crafted paths), untrusted remotes, secrets,
  local IPC (Phase 5). Phase 0 records the policy; enforcement lands with each feature.
- Note for later phases: read-only commands should neutralize repo-configured executables where Git
  allows (`-c core.fsmonitor=false` for status reads is under evaluation — it changes performance for
  users who rely on fsmonitor; decide in Phase 1 with ADR-0008).

## 5. Edge cases & failure modes

- No Git found → designed error state; app remains usable (Phase 0 has nothing else to do).
- `/usr/bin/git` present but CLT missing → locator must not execute it (test with an injected probe).
- Git older than minimum → `GitTooOld` with versions.
- Folder is a subdirectory of a repo → discover the enclosing repo and show the top level.
- Bare repository, linked worktree, repository with unborn branch, detached HEAD.
- `safe.directory` / dubious ownership refusal → `UnsafeRepository` with explanation; never add a
  `safe.directory` entry automatically.
- Paths with spaces, Unicode (NFD from Finder vs NFC), symlinked folders.
- Folder on a slow or unmounted network volume → discovery honors cancellation and a 15 s timeout.
- Bindings out of date relative to the Rust library → UniFFI checksum mismatch at startup; build script
  must regenerate both together; CI catches drift.

## 6. ADRs to write

- **ADR-0001** Record architecture decisions (template + process).
- **ADR-0002** Git backend: Git CLI orchestrated by Rust; `gix` only for profiled read bottlenecks.
- **ADR-0003** XcodeGen-generated project (alternative: checked-in `.xcodeproj`).
- **ADR-0004** Thin app target + local Swift package `JitKit`.
- **ADR-0005** FFI concurrency: synchronous Rust, no idle threads, Swift dispatch queues, `CancelToken`,
  `ProgressSink` callback.
- **ADR-0006** Baselines: macOS 14+, Apple Silicon first, minimum Git version + capability check,
  App Sandbox off / Hardened Runtime on.
- Feasibility note (not an ADR yet) for **ADR-0019** bundled Git: build-from-source vs vendor binaries,
  relocatability (`RUNTIME_PREFIX`), `libexec/git-core` helpers, dependencies (curl/openssl/pcre,
  `git-remote-https`), GPLv2 source obligations, signing every Mach-O. Record findings in
  `docs/release.md` "Bundled Git feasibility".

## 7. Open questions / spikes

| Question | Spike | Decide by |
|---|---|---|
| UniFFI version and exact proc-macro syntax for objects, foreign traits, errors | Read current UniFFI docs/changelog; build a 3-function bridge | It builds, the Swift test calls all three, cancellation works |
| Can the SPM binary target live under `Packages/JitKit/Frameworks`? | Try it in P0.4 | `xcodebuild` resolves without absolute paths |
| Minimum Git version | List flags used in Phases 1–4 (`--path-format`, porcelain v2 headers, `switch`/`restore`, `merge-tree --write-tree`?) and the version each needs | ADR-0006 lists each feature → version |
| Tokens in code vs asset catalog | Implement code-defined dynamic `NSColor(name:dynamicProvider:)` | Light/dark/high-contrast switch live, no view hardcodes colors |
| `LC_ALL=C` vs localized Git messages | Keep `C` for parsing; user-facing text comes from our mapping, raw stderr only in "Details" | Confirmed in ADR-0002 |
