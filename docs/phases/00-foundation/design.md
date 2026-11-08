# Phase 0 — Foundation & Design: design

Sources: §0–§3, §13, §15.1, §19, §21, §22 (Phase 0), §25 steps 1–3, as amended by
[ADR-0002](../../adr/0002-pure-swift-core.md) (pure Swift, no Rust/UniFFI) and
[ADR-0006](../../adr/0006-platform-baseline-and-liquid-glass.md) (macOS 26+, native Liquid Glass).
Plan context: [`../../roadmap.md`](../../roadmap.md).

## 1. Goal & demo

Establish a buildable, measured foundation: a native macOS 26 window in the Liquid Glass design
language that calls a real Swift Git core (`GitCore`), a first version of the design system, the build
pipeline, and the first ADRs.

**Demo at the end of the phase**

1. `scripts/build/build-all.sh` generates the Xcode project with XcodeGen and builds `Jit.app` from a
   clean checkout. `swift test` in `macos/Packages/JitKit` runs the core tests.
2. Launching `Jit.app` shows a polished (not placeholder-looking) empty window within the target time:
   system glass toolbar over a calm opaque content area.
3. "Open Repository…" (⌘O) → pick a folder → the window shows what `GitCore` discovered: repository
   kind (regular / bare / linked worktree), top-level path, git dir, current branch or detached/unborn
   state, and the Git executable + version in use. Picking a non-repository shows a designed error state.
4. A debug-only "Design System" gallery window renders every token and the glass usage rules in light,
   dark, Increase Contrast and Reduce Transparency.
5. `docs/performance.md` contains the first measured baseline (launch, idle CPU, wakeups, memory, and
   the GPU/energy cost of glass chrome at idle).

## 2. Scope / out of scope

**In scope:** environment verification, repository scaffold, local Swift package `JitKit` (`GitCore`,
`GitTestKit`, `DesignSystem`, `Features`, `JitBench`), process execution and Git location, repository
discovery, async/cancellation/progress/error primitives in `GitCore`, a short `ProcessRunner` spike,
build scripts, XcodeGen project, CI, Liquid-Glass-native design direction and token set v1, design-system
gallery, baseline benchmarks, initial docs, ADRs 0001/0003/0004/0005 and the Phase 0 addendum to ADR-0006.
ADR-0002 and ADR-0006 are already accepted.

**Out of scope** (and where it lives):

| Not in Phase 0 | Lives in |
|---|---|
| Tabs, new-tab page, recents, layout regions, menus beyond the minimum | Phase 1 |
| Status parsing, file watching, profiles, persistence, `Services` target | Phase 1 |
| History, graph, branch navigator | Phase 2 |
| Diff, staging, commit | Phase 3 |
| Remote operations, conflicts | Phase 4 |
| Authentication, providers, networking, `JitGitHelper`, `TestRig` | Phase 5 |
| Universal binary, signing, notarization, bundled Git | Phase 7 (feasibility notes only here) |

## 3. User experience

Phase 0 has two small screens, but they set the visual tone. Treat them as product UI.

### 3.1 Foundation window

- **Interaction:** app launches into one window. Empty state invites opening a repository (button +
  ⌘O + drag a folder onto the window). After selection, a repository card replaces the empty state.
  "Open Another…" re-runs the panel. No other controls.
- **Chrome vs content:** the window uses the unified system toolbar (`.toolbar` / `NSToolbar`) which
  renders Liquid Glass automatically; it holds only the window title area and an "Open…" toolbar button
  (system glass button). Everything below is the opaque content layer (`surface.canvas`) that extends
  under the toolbar with the system scroll-edge effect — no custom blur.
- **Visual hierarchy:** centered content column max 520 pt. Empty state: SF Symbol
  (`folder.badge.gearshape` or a custom mark) at 40 pt in `text.tertiary`, title (`type.title`), one line
  of `text.secondary` copy, a primary button (`.glassProminent` tinted with `accent.tint`, verified against
  the SDK). Repository card: name (`type.display`), path (`type.mono.caption`, middle-truncated,
  selectable), a key/value grid (`type.callout` labels in `text.tertiary`, values in `text.primary`, SHAs
  in mono). The card is **opaque** content (`surface.raised`), not glass.
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
  a luminance step + `border.subtle` and no shadow in dark. Toolbar glass adapts on its own.
- **Micro-interactions:** card appears with a 160 ms opacity + 4 pt rise (`motion.panel` curve);
  Reduce Motion → opacity only. Button hover/press come from the system glass button styles.
- **Keyboard:** ⌘O opens panel; Return activates the primary button; ⌘W closes window; ⌘Q quits.
- **Accessibility:** card is an accessibility group with label "Repository <name>"; values are
  readable by VoiceOver in order; error block announced via `AccessibilityNotification.Announcement`.
  With Reduce Transparency the toolbar becomes opaque (system); nothing else changes.

### 3.2 Design-system gallery (debug builds only)

Menu `Debug ▸ Design System` (compiled only with `#if DEBUG`). A window with a glass toolbar and a
sidebar (system `NSSplitViewController` sidebar, so it gets system glass) listing sections; the detail
area is opaque content that scrolls *under* the toolbar so glass-over-content is visible. Sections:

- Content surfaces (swatches stacked to show hierarchy), text colors on each surface, accent/tint and
  status colors, diff colors with sample lines, lane palette as a mini graph.
- Typography scale with sample strings (SF Pro + SF Mono incl. a 40-char SHA), spacing ruler, radii
  (showing concentric nesting inside a glass capsule), borders, shadows, focus ring.
- Interactive states (rest/hover/pressed/selected/disabled for a list row and a button).
- **Glass rules:** examples of allowed glass (toolbar button group in a `GlassEffectContainer`, a floating
  capsule control, a popover, a sheet) side by side with the matching *forbidden* patterns rendered as
  annotated static images only (glass rows, stacked blurs, text on glass over a busy graph) so reviewers
  learn the rule.
- Motion demo buttons, including a glass morph between two toolbar control states.

A segmented control forces Light / Dark / System for the gallery window only; a note shows whether
Reduce Transparency / Increase Contrast are on (the system settings drive those). This window is how
design reviews and screenshots happen until real screens exist.

### 3.3 Design direction — "Quiet Instrument, under glass"

The app should feel like a precision instrument under a pane of Apple's glass: the system's Liquid Glass
chrome floats above a calm, opaque, mineral content layer with ink-dark typography, one cool accent used
sparingly, and color reserved for meaning (branch lanes, diff, status). Jit looks like it belongs on
macOS 26 next to Finder and Xcode — and is recognizably Jit through typography, spacing, accent tint, the
lane palette and the craft of the graph and diff.

Principles:

1. **System glass for chrome, opaque calm for content.** Toolbar, tab bar, sidebar, popovers, menus,
   sheets and floating controls use Liquid Glass via system components. The graph, diff, code, lists and
   cards are opaque. Text never sits on glass over busy content.
2. **System-first.** Use standard toolbars, `NSSplitViewController` sidebars, standard buttons, menus,
   popovers, sheets and system semantic colors wherever they fit; they get glass, vibrancy, accessibility
   fallbacks and future OS refinements for free. Custom chrome is the exception and must use the official
   glass APIs.
3. **Hierarchy by luminance, not borders, inside content.** Content panels differ by 2–4 % luminance;
   hairline borders only where two equal surfaces meet.
4. **One accent.** "Tidewater" (a deep teal-ink) is the tint for prominent glass buttons and marks
   focus, selection and the primary action. It never colors large areas, and glass is never tinted with
   lane or status colors.
5. **Color means something.** Lanes, diff, and status own the saturated colors; chrome stays neutral.
6. **Density with air.** Compact rows, generous section spacing; align to a 4 pt grid.
7. **Motion is confirmation, not decoration.** Short, damped, never looping. Glass morphs only on user
   action.

Light and dark content colors are designed separately: light is warm mineral white with graphite ink;
dark is graphite with soft warm-white text — not an inversion. Glass itself is system-rendered and
adapts on its own.

#### Liquid Glass usage rules (normative for every phase)

| Rule | Detail |
|---|---|
| Where glass is allowed | Window toolbar and its items; the repository tab bar (titlebar/toolbar area); the sidebar (system sidebar material); floating controls (e.g. operation/progress capsule, focused-diff controls); popovers, menus, sheets, the profile switcher, the command palette. |
| Where glass is forbidden | Rows and cells (graph rows, file rows, diff lines), anything inside scrolling content, cards on the content layer, text blocks over busy content, behind code. |
| How to get glass | System components first. Custom glass only via official APIs: SwiftUI `glassEffect(_:in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)` / `.glassProminent`, `glassEffectID` for morphs; AppKit `NSGlassEffectView` / `NSGlassEffectContainerView`; scroll-edge effects and background extension for content running under chrome. **Verify exact names and availability against the installed macOS SDK in P0.1** and record them in `docs/design-system.md`. |
| Grouping | Neighbouring glass controls share one `GlassEffectContainer` / `NSGlassEffectContainerView` so they render and morph as one surface. Never nest glass inside glass; never stack `NSVisualEffectView`s or custom blurs. |
| Tint policy | Default untinted. `accent.tint` only on the single primary action of a surface (`.glassProminent`) and for the selected tab. No lane/status/brand-colored glass. |
| Shapes | Capsules and concentric rounded rectangles that follow the system's corner geometry (`radius.*` tokens are chosen to nest concentrically inside system glass shapes and window corners). |
| Accessibility | Reduce Transparency → glass becomes opaque (system handles system components; custom glass must check `accessibilityReduceTransparency` / `NSWorkspace.accessibilityDisplayShouldReduceTransparency` and switch to `surface.chromeOpaque`). Increase Contrast → stronger borders/separators per system behavior. Reduce Motion → no glass morphs, cross-fade instead. |
| Efficiency | Glass is static when idle (no animated tints, no animated content behind chrome while idle). No per-row glass. Morph/transition animations ≤ 240 ms and only on user action. P0.7 measures idle GPU/energy with glass chrome visible. |

#### Content-layer color tokens — starting values (to be refined with screenshots in P0.6)

Prefer system semantic colors (`NSColor.labelColor`, `.separatorColor`, `controlAccentColor` where the
user's accent should win) when they match the intent; the tokens below are Jit's content palette and
are defined as dynamic colors with light/dark and Increase Contrast variants.

| Token | Light | Dark | Use |
|---|---|---|---|
| `surface.canvas` | `#F5F4F1` | `#161719` | window content background, graph area |
| `surface.panel` | `#FAF9F7` | `#1B1C1F` | inspector content (sidebar uses system material) |
| `surface.raised` | `#FFFFFF` | `#222327` | opaque cards on the content layer |
| `surface.sunken` | `#EEECE8` | `#111214` | inputs, code wells |
| `surface.chromeOpaque` | `#ECEAE6` | `#232428` | Reduce Transparency fallback for custom glass |
| `border.subtle` | `#E3E0DA` | `#2B2D31` | hairlines |
| `border.strong` | `#CDC9C1` | `#3A3C42` | input outlines, dividers under emphasis |
| `text.primary` | `#1D2023` | `#E7E5E0` | body |
| `text.secondary` | `#545A60` | `#A8A6A1` | metadata |
| `text.tertiary` | `#878C92` | `#76756F` | labels, placeholders |
| `text.disabled` | `#B3B6BA` | `#4E4E4B` | disabled |
| `accent.base` | `#21707A` | `#67B5BA` | focus, selection edge, links |
| `accent.tint` | `#21707A` | `#4FA3A9` | tint for `.glassProminent` primary actions and the selected tab |
| `accent.muted` (selection fill) | `#21707A` @ 12 % | `#67B5BA` @ 16 % | selected rows |
| `accent.onAccent` | `#FFFFFF` | `#0E1A1C` | text on accent fills |
| `state.hover` | `#1D2023` @ 4 % | `#E7E5E0` @ 5 % | hover overlay (content rows) |
| `state.pressed` | `#1D2023` @ 8 % | `#E7E5E0` @ 9 % | pressed overlay (content rows) |
| `focus.ring` | system focus ring color | system focus ring color | keyboard focus (system ring; custom views draw it via `NSFocusRingType`) |
| `status.success` | `#2F7A4A` | `#71BE8A` | success |
| `status.warning` | `#A3670F` | `#E0A651` | warning, "no profile" |
| `status.danger` | `#AE3932` | `#E57A70` | errors, destructive |
| `status.info` | `#3D6394` | `#86A8D6` | info |
| `diff.add.bg` / `diff.add.mark` | `#E5F1E7` / `#2F7A4A` | `#1A2A20` / `#71BE8A` | added lines / gutter & word marks |
| `diff.del.bg` / `diff.del.mark` | `#F7E5E3` / `#AE3932` | `#2D1C1B` / `#E57A70` | deleted lines |

Whether the selection/focus accent follows the user's system accent color or stays Tidewater is a P0.6
decision (recommendation: follow the system accent for focus/selection to feel native; keep Tidewater for
the brand tint of primary glass actions only if it reads well next to arbitrary system accents —
otherwise follow the system accent everywhere). Record it in `docs/design-system.md`.

**Lane palette (draft, 8 hues).** Muted, equal perceived lightness within a theme, distinguishable for
common color-vision deficiencies when paired with lane position. Lane colors only ever appear on the
opaque content layer. Validate contrast against `surface.canvas` (≥ 3:1 for lines) in P0.6 and refine in
Phase 2.

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

Chrome text (toolbar, tab titles, sidebar) uses the system's own fonts and vibrancy on glass rather than
custom colors. Numbers in tables/counters use monospaced digits (`.monospacedDigit()`). Dynamic Type
isn't native on macOS; expose a text-size preference (−1 / default / +1 / +2) that scales the table in
Phase 6.

#### Spacing, radii, borders, shadows

- Spacing (4 pt base): `space.1`=2, `space.2`=4, `space.3`=6, `space.4`=8, `space.5`=12, `space.6`=16,
  `space.7`=20, `space.8`=24, `space.9`=32, `space.10`=40.
- Radii (continuous corners, chosen to nest concentrically inside system glass shapes; verify against the
  macOS 26 window/control corner geometry in P0.6 and adjust): `radius.xs`=4 (badges), `radius.sm`=6
  (inputs, content rows' selection), `radius.md`=10 (opaque cards), `radius.lg`=14 (popover content),
  `radius.capsule` (glass controls, tabs, pills). Prefer system container shapes for glass over fixed radii.
- Borders: hairline = 1 px (0.5 pt on Retina) `border.subtle`; emphasis = 1 pt `border.strong`. Glass
  surfaces get no custom borders.
- Shadows (content layer, light only; dark uses luminance): `shadow.1` y1 blur3 6 %, `shadow.2` y4 blur12
  10 %. Glass provides its own depth — never add shadows to glass. Never animate shadows.

#### Motion

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motion.hover` | 100 ms | ease-out | hover fills (content rows; glass controls use system hover) |
| `motion.press` | 60 ms | ease-out | pressed state |
| `motion.select` | 150 ms | `cubic(0.2, 0, 0, 1)` | row/tab selection |
| `motion.panel` | 200 ms | `cubic(0.2, 0, 0, 1)` | sidebar/inspector, card reveal |
| `motion.glassMorph` | 180–240 ms | system default glass animation | glass control state changes (`glassEffectID` morph) |
| `motion.feedback` | 180 ms in / 120 ms out | ease-out / ease-in | success ticks, toasts |

Reduce Motion: positional/scale animations and glass morphs become opacity-only at the same duration, or
instant for panel resizes. All animations are one-shot; nothing loops except determinate/indeterminate
progress that is visible and tied to a running operation.

#### Sizes and density

- Icons: `icon.sm`=12, `icon.md`=16, `icon.lg`=20 (SF Symbols, system weights in chrome).
- Panels: toolbar/tab bar height follows the system unified toolbar; sidebar min 200 / default 248 /
  max 380; inspector min 340 / default 440 / max 60 % of window; window min 960×600.
- Density: `compact` row 22 pt, `comfortable` row 26 pt (graph and lists). Default comfortable.

## 4. Technical design

### 4.1 Components

All code is Swift 6 (language mode 6, strict concurrency). Deployment target macOS 26.0.

**Local package `macos/Packages/JitKit`** (ADR-0004)

- `GitCore` — imports Foundation, Darwin (and `System` if useful) only; never AppKit/SwiftUI.
  - `GitLocator`: finds Git. Order: (1) `JIT_GIT_PATH` env (dev override, debug builds only),
    (2) bundled path inside the app bundle (wired in Phase 7; checked now, absent), (3) user override
    from preferences (Phase 6), (4) `/opt/homebrew/bin/git`, `/usr/local/bin/git`, (5) `/usr/bin/git`
    **only if** the developer directory actually contains Git (check for
    `/Library/Developer/CommandLineTools/usr/bin/git` or the selected Xcode's `usr/bin/git` by file
    existence). Never execute `/usr/bin/git` or `xcrun` blindly: on a machine without CLT the shim pops
    the "install command line developer tools" dialog. Result: `GitExecutable { path, version, source }`.
    The version probe runs lazily on first Git use (not at launch).
  - `GitVersion`: parse `git version 2.54.0`, `git version 2.39.5 (Apple Git-154)`, `.windows.`-style
    suffixes; compare against `GitVersion.minimum` (ADR-0006 addendum).
  - `ProcessRunner` — thin `posix_spawn` wrapper; `func run(_ command: GitCommand) async throws(GitCoreError) -> ProcessOutput`.
    - argv only (`posix_spawn` with an explicit argv array), explicit working directory
      (`posix_spawn_file_actions_addchdir_np`).
    - Environment built from scratch from an allowlist: `HOME`, `PATH` (minimal, includes the Git exec
      dir), `TMPDIR`, `USER`, `LANG`/`LC_ALL=C` for parse-stable output, `GIT_TERMINAL_PROMPT=0`,
      `GIT_ASKPASS` / `SSH_ASKPASS` pointing to a non-interactive "deny" path until Phase 5,
      `GIT_OPTIONAL_LOCKS=0` for read commands, `GIT_EDITOR=true` / `GIT_SEQUENCE_EDITOR=true` /
      `GIT_MERGE_AUTOEDIT=no` so no command ever waits on an editor (operations that need a message
      pass it explicitly). `SSH_AUTH_SOCK` passes through (agent support).
    - Always prepend `-c core.quotepath=false` and `--no-pager`/`-c color.ui=false` as needed.
    - Own process group via `POSIX_SPAWN_SETPGROUP` (pgid 0). Cancellation (Swift task cancellation via
      `withTaskCancellationHandler`) sends `SIGTERM` to the group (`killpg`), then `SIGKILL` after a 2 s
      grace; the same path handles timeouts.
    - stdout/stderr pipes set non-blocking and read with `DispatchSource.makeReadSource`; process exit
      observed with `DispatchSource.makeProcessSource(.exit)` then `waitpid`. Results resume a checked
      continuation. **No thread blocks** waiting on a child and no cooperative-pool thread is held;
      sources exist only for the lifetime of a command — nothing runs when idle.
    - Bounded capture: stdout byte cap per command (configurable); stderr keeps the last 64 KiB.
      Output is `[UInt8]`/`Data`; parsers work on bytes (`-z` NUL-separated), not `String`s.
    - stdin is `/dev/null` unless the command needs input.
    - Phase 0 spike (P0.3): own wrapper vs the `swift-subprocess` package — criteria: process-group
      creation and group kill, full env control, Swift 6 strict-concurrency fit, non-blocking I/O,
      dependency weight. **Recommendation: own wrapper** unless the package clearly covers process groups
      and env control without extra dependencies. Record the outcome in ADR-0005.
  - `RepositoryDiscovery`: `discover(at:) async throws -> RepositoryInfo` using one call:
    `git -C <path> rev-parse --path-format=absolute --show-toplevel --absolute-git-dir --git-common-dir --is-bare-repository --is-inside-work-tree`
    (bare repos have no toplevel; handle by running a reduced arg list), plus
    `git symbolic-ref -q --short HEAD` / `rev-parse -q --verify HEAD` for branch, detached, unborn.
    Linked worktree = git dir ≠ common dir. Classify errors from exit code + stderr patterns into typed
    errors (not a repo, permission denied, dubious ownership/`safe.directory`).
  - `GitCoreError`: one enum, every case carries a user-presentable summary; raw stderr kept separately
    as `detail` after sanitization (strip anything URL-credential-shaped).
  - `GitEngine`: an `actor` holding the located `GitExecutable` and config; entry point for discovery.
    Phase 1 adds `actor RepositoryHandle` per open repository (ADR-0005).
- `GitTestKit` — test-support library target (used only by test targets and `JitBench`). Builds real temp
  repos via the Git CLI with fixed author/committer dates and identity (`GIT_AUTHOR_DATE`, etc.) for
  determinism. API: `TestRepo()`, `.write(_ path:, _ bytes:)`, `.commit(_ msg:)`, `.branch(_:)`,
  `.addWorktree(_:)`, `.bareClone()`; isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL`
  pointing to an empty temp file so the developer's config never leaks into tests.
- `DesignSystem` — tokens, glass usage helpers, reusable styles (row background, focus ring, content
  card), Reduce Transparency fallbacks. Imports SwiftUI/AppKit.
- `Features` — `FoundationView` (Phase 0 screen), design-system gallery (`#if DEBUG`).
- `JitBench` — dev-only executable target: micro-benchmarks for `GitCore` (process spawn latency,
  discovery, later parsers/lane layout) using `ContinuousClock`, emitting JSON results.
- `Services` — created when first needed (Phase 1).

**App target (`macos/App`, XcodeGen target `Jit`):** `@main` SwiftUI `App`, `AppDelegate` adaptor, the
foundation window, debug menu. Thin: wiring only.

### 4.2 Core API sketch (illustrative)

```swift
// GitCore
public struct GitExecutable: Sendable { public let path: String; public let version: GitVersion; public let source: Source }

public enum GitCoreError: Error, Sendable {
    case gitNotFound
    case gitTooOld(found: GitVersion, required: GitVersion)
    case notARepository(path: String)
    case permissionDenied(path: String)
    case unsafeRepository(path: String)                  // safe.directory / dubious ownership
    case cancelled
    case timedOut(seconds: Int)
    case processFailed(exitCode: Int32, summary: String, detail: String)
    case io(summary: String)
    case internalError(summary: String)
}

public struct ProgressUpdate: Sendable { public let phase: String; public let completed: UInt64; public let total: UInt64? }

public struct GitCommand: Sendable {
    public var arguments: [String]          // argv after the git executable; never a shell string
    public var workingDirectory: URL
    public var timeout: Duration?
    public var stdoutLimit: Int
    public var kind: Kind                    // .read (adds GIT_OPTIONAL_LOCKS=0) / .write
}

public actor GitEngine {
    public init(config: EngineConfig)
    public func gitInfo() async throws(GitCoreError) -> GitExecutable          // lazy locate + version check
    public func discoverRepository(at url: URL) async throws(GitCoreError) -> RepositoryInfo
    // Long-running operations (Phase 4+) return progress through a bounded stream:
    // func fetch(...) -> (progress: AsyncStream<ProgressUpdate>, result: Task<FetchResult, Error>)
}
```

Swift task cancellation is the only cancellation mechanism: callers cancel the `Task`; `ProcessRunner`
kills the process group. Progress streams use `AsyncStream` with `.bufferingNewest(1)` and are throttled
to ≤ 10 Hz. Features never import Darwin process APIs; they call `GitEngine` from `@MainActor` view
models with `Task { }` and never block.

### 4.3 State ownership, concurrency, caching

- Phase 0 state is a single `@MainActor @Observable FoundationModel` (`idle | loading | loaded(info) |
  failed(error)`). Phase 1 replaces it with the real architecture.
- `GitEngine` is created at launch (cheap: no I/O in `init`); Git location and version check happen on
  first use, off the main actor; the result is cached for the process lifetime.
- No caches beyond that in Phase 0. No background threads, timers or long-lived processes.

### 4.4 Build pipeline

1. `scripts/build/gen-xcodeproj.sh` — `xcodegen generate --spec macos/project.yml` (project is generated,
   not committed — ADR-0003).
2. `scripts/build/build-app.sh [debug|release]` — `xcodebuild -project macos/Jit.xcodeproj -scheme Jit
   -configuration … build` with a stable `-derivedDataPath`.
3. `scripts/build/test-core.sh` — `swift test --package-path macos/Packages/JitKit` (GitCore,
   GitTestKit-backed tests; runs without the app).
4. `scripts/build/build-all.sh` — 1 → 2 (→ 3 with `--test`); fails fast with readable messages.

CI (`.github/workflows/ci.yml`): macOS runner image that ships Xcode 26 or newer (select it explicitly
with `xcode-select`; fail clearly if unavailable), install XcodeGen via Homebrew, run `test-core.sh`,
`build-all.sh debug`, and `xcodebuild test` for the app's unit tests. No secrets.

### 4.5 Performance approach

- First window comes from SwiftUI `WindowGroup`/`Window` with no work in `init`; Git location/version
  probing is deferred to the first user action or a post-first-frame task at `.utility` priority.
- System glass chrome is composited by the window server; keep the hierarchy behind it shallow and
  static. No animated content behind the toolbar when idle.
- Avoid loading fonts manually (system fonts), avoid large asset catalogs.
- Measure, don't assume (see implementation P0.7).

### 4.6 Security

- App Sandbox **off** (Developer ID distribution; the client must run Git and read arbitrary repos and
  `~/.ssh`). Hardened Runtime on from day one in all configurations so surprises appear early. Recorded
  as the Phase 0 addendum to ADR-0006.
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
- Git older than minimum → `gitTooOld` with versions.
- Folder is a subdirectory of a repo → discover the enclosing repo and show the top level.
- Bare repository, linked worktree, repository with unborn branch, detached HEAD.
- `safe.directory` / dubious ownership refusal → `unsafeRepository` with explanation; never add a
  `safe.directory` entry automatically.
- Paths with spaces, Unicode (NFD from Finder vs NFC), symlinked folders.
- Folder on a slow or unmounted network volume → discovery honors cancellation and a 15 s timeout.
- Child process ignores `SIGTERM` → `SIGKILL` after grace; grandchildren die with the group.
- Pipe output exceeds cap → command fails with a clear "output too large" error, process group killed.
- Reduce Transparency / Increase Contrast enabled → chrome becomes opaque/high-contrast; content tokens
  switch to their high-contrast variants.

## 6. ADRs to write

ADR-0002 (pure Swift core) and ADR-0006 (macOS 26+, Liquid Glass) are **already accepted** — do not
rewrite them.

- **ADR-0001** Record architecture decisions (template + process).
- **ADR-0003** XcodeGen-generated project (alternative: checked-in `.xcodeproj`).
- **ADR-0004** Thin app target + local Swift package `JitKit` (`GitCore`, `GitTestKit`, `DesignSystem`,
  `Services`, `Features`, `JitBench`, later `JitGitHelper`/`TestRig`).
- **ADR-0005** Concurrency, process & memory model: `async` `GitCore` APIs, `actor` per repository,
  `posix_spawn` + process groups + Dispatch sources, Swift task cancellation → `killpg`, bounded
  `AsyncStream` progress, no idle threads, value-type/struct-of-arrays memory rules; includes the
  `ProcessRunner` vs `swift-subprocess` spike result.
- **ADR-0006 addendum** (append a dated "Phase 0 addendum" section): minimum Git version with the
  feature → version table, App Sandbox off / Hardened Runtime on, bundle ID placeholder, verified Liquid
  Glass API names in the installed SDK.
- Feasibility note (not an ADR yet) for **ADR-0019** bundled Git: build-from-source vs vendor binaries,
  relocatability (`RUNTIME_PREFIX`), `libexec/git-core` helpers, dependencies (curl/openssl/pcre,
  `git-remote-https`), GPLv2 source obligations, signing every Mach-O. Record findings in
  `docs/release.md` "Bundled Git feasibility".

## 7. Open questions / spikes

| Question | Spike | Decide by |
|---|---|---|
| Own `posix_spawn` wrapper vs `swift-subprocess` | Build both minimal versions running `git --version` with process-group kill and env allowlist | Group kill works, env fully controlled, no thread blocked, ≤ 1 extra dependency → ADR-0005 |
| Exact Liquid Glass API names and AppKit equivalents in the installed SDK | Read SDK headers/docs; build the gallery's glass section | Gallery renders allowed patterns in light/dark/Reduce Transparency → `docs/design-system.md` |
| Selection/focus accent: system accent vs Tidewater | Render rows and glass prominent buttons with several system accents | Screenshot review → `docs/design-system.md` |
| Radii that nest concentrically with macOS 26 window/control shapes | Overlay content cards in a window and in popovers at several sizes | Visually concentric at default window corner radius |
| Minimum Git version | List flags used in Phases 1–4 (`--path-format`, porcelain v2 headers, `switch`/`restore`, `merge-tree --write-tree`, `zdiff3`) and the version each needs | ADR-0006 addendum lists each feature → version |
| Tokens in code vs asset catalog | Implement code-defined dynamic `NSColor(name:dynamicProvider:)` | Light/dark/high-contrast switch live, no view hardcodes colors |
| `LC_ALL=C` vs localized Git messages | Keep `C` for parsing; user-facing text comes from our mapping, raw stderr only in "Details" | Confirmed in ADR-0005 |
| Does `swift test` on the CI runner see the same Git as local? | Print `GitLocator` result in a test | Tests use `GitTestKit`'s resolved Git consistently |
