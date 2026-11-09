# Design system

Direction: **"Quiet Instrument, under glass"** (`docs/phases/00-foundation/design.md` §3.3). System
Liquid Glass chrome floats above a calm, opaque, mineral content layer; color is reserved for meaning
(lanes, diff, status). Code: `macos/Packages/JitKit/Sources/DesignSystem`. Live reference: Debug ▸
Design System (⌥⌘D, debug builds). Renders: `docs/phases/00-foundation/screenshots/`.

Views never hardcode colors, fonts, blurs or glass — enforced by `StylingLintTests` and
`scripts/build/lint.sh`.

## Liquid Glass usage rules (normative)

| Rule | Detail |
|---|---|
| Where | Window toolbar and its items, the tab strip, sidebar, floating controls, popovers, menus, sheets, profile switcher, command palette. |
| Never | Rows/cells (graph, file, diff lines), anything inside scrolling content, cards, text blocks over busy content, behind code. |
| How | System components first: `.toolbar`, `NavigationSplitView` / `NSSplitViewController` sidebars, `.buttonStyle(.glass)` (`secondaryGlassButton()`), `.buttonStyle(.glassProminent)` + `accent.tint` (`primaryGlassButton()`), popovers, sheets. Custom glass only through `DesignSystem` helpers — `jitGlass(in:interactive:)` and the tab strip's `GlassTabStrip` / `glassTab(isSelected:isHovered:id:in:)` are the only call sites of `glassEffect(_:in:)` — grouped with `GlassControlGroup` / `GlassTabStrip` (`GlassEffectContainer`); `FloatingGlassCapsule` for floating controls; `glassEffectID(_:in:)` for morphs. Content under chrome uses `scrollEdgeEffectStyle(.soft, for: .top)`. |
| Grouping | Neighbouring custom glass shares one container. No glass in glass. No `NSVisualEffectView` stacks, CIFilter or `.blur` (lint-enforced). |
| Tint | Untinted by default; `accent.tint` only on the single primary action of a surface and (at 38 %) on the selected tab. Never lane colors on glass. One status exception: the "No Profile" toolbar capsule uses the system prominent toolbar-item style tinted `status.warning`, because it is a state the user must act on before committing. |
| Accessibility | Reduce Transparency: system components go opaque by themselves; `jitGlass` switches to `surface.chromeOpaque` + hairline `border.strong`. Increase Contrast: tokens switch to their high-contrast values. Reduce Motion: glass morphs and rises become opacity-only. |
| Efficiency | Static when idle; morphs only on user action, ≤ 240 ms. |

Verified API names (MacOSX27.2.sdk, all macOS 26.0+): see ADR-0006 Phase 0 addendum.
`NSGlassEffectView.effectIsInteractive` is macOS 27 only — not used.

## Color tokens (content layer)

Defined as data (`ColorSpec`: light / dark / light-HC / dark-HC), resolved through dynamic
`NSColor(name:dynamicProvider:)`. High-contrast values apply when the appearance or
`accessibilityDisplayShouldIncreaseContrast` says so. "—" = same as regular.

| Token | Light | Dark | Light HC | Dark HC |
|---|---|---|---|---|
| `surface.canvas` | `#F5F4F1` | `#161719` | — | — |
| `surface.panel` | `#FAF9F7` | `#1B1C1F` | — | — |
| `surface.raised` | `#FFFFFF` | `#222327` | — | — |
| `surface.sunken` | `#EEECE8` | `#111214` | — | — |
| `surface.chromeOpaque` | `#ECEAE6` | `#232428` | — | — |
| `border.subtle` | `#E3E0DA` | `#2B2D31` | `#B5B1A9` | `#4A4D54` |
| `border.strong` | `#CDC9C1` | `#3A3C42` | `#8E8A82` | `#6A6D74` |
| `text.primary` | `#1D2023` | `#E7E5E0` | `#0F1113` | `#F4F2EE` |
| `text.secondary` | `#545A60` | `#A8A6A1` | `#3F444A` | `#C4C2BD` |
| `text.tertiary` | **`#7A7F85`** | `#76756F` | `#5C6167` | `#9E9C96` |
| `text.disabled` | `#B3B6BA` | `#4E4E4B` | — | — |
| `accent.base` | `#21707A` | `#67B5BA` | `#175A63` | `#86CACE` |
| `accent.tint` | `#21707A` | `#4FA3A9` | — | — |
| `accent.muted` | `#21707A` 12 % | `#67B5BA` 16 % | — | — |
| `accent.onAccent` | `#FFFFFF` | `#0E1A1C` | — | — |
| `state.hover` / `state.pressed` | `#1D2023` 4 % / 8 % | `#E7E5E0` 5 % / 9 % | — | — |
| `status.success` / `warning` / `danger` / `info` | `#2F7A4A` / `#A3670F` / `#AE3932` / `#3D6394` | `#71BE8A` / `#E0A651` / `#E57A70` / `#86A8D6` | — | — |
| `diff.add.bg` / `diff.add.mark` | `#E5F1E7` / `#2F7A4A` | `#1A2A20` / `#71BE8A` | — | — |
| `diff.del.bg` / `diff.del.mark` | `#F7E5E3` / `#AE3932` | `#2D1C1B` / `#E57A70` | — | — |

Changed from the draft: `text.tertiary` light `#878C92` → `#7A7F85` (the contrast test measured 2.87:1
on `surface.sunken`; now 3.42:1). High-contrast columns are new.

**Selection and focus follow the user's system accent** (`Selection.fill` = `controlAccentColor` at
16 % light / 24 % dark, `Selection.edge` = `controlAccentColor`; focus ring = system
`keyboardFocusIndicatorColor`). Tidewater (`accent.tint`) is the tint of primary glass actions only.
Reason: rendered side by side, Tidewater at 12 % read as grey selection; the system accent reads as
selection and matches other Mac apps.

### Lane palette (graph, Phase 2)
slate `#4C6B9F`/`#8EA7D1`, tidewater `#2B8580`/`#6FC0B9`, moss `#6F8435`/`#A9BE72`, ochre
`#A9782A`/`#D9AD62`, clay `#AD5A43`/`#DD9079`, heather `#82599A`/`#B897CF`, rosewood
`#A8577A`/`#D891B0`, steel `#5D7380`/`#9BB0BC` (light/dark). All ≥ 3:1 on `surface.canvas` (tested).

Slot 0 (slate) is HEAD's lane; other lanes take `StableHash(branch name) % 7 + 1`, skipping an
adjacent lane's colour (ADR-0021).

### Graph (Phase 2 — `GraphMetrics`, `GraphColorTable`, `GraphTypography`)
| Token | Compact | Comfortable |
|---|---|---|
| row height | 24 | 30 |
| lane spacing (compressed past 12 lanes) | 14 (6) | 16 (6) |
| leading inset | 10 | 12 |
| node / merge ring radius | 3.5 / 4 | 4 / 4.5 |
| HEAD ring gap / width | 2.5 / 1.25 | 3 / 1.25 |
| edge width | 1.5 | 1.75 |
| pill height | 16 | 18 |
| avatar | 16 | 18 |

- Nodes: filled disc with a 1 pt canvas-coloured ring; merges a hollow ring one step larger; HEAD an outer
  ring in the system accent. Edges: straight per row, S-curves (control points at 50 %) confined to a half
  row; butt caps; vertical lines snapped to the device pixel grid. No gradients, glow or neon.
- Ref pills (opaque, never glass, radius `radius.xs`): local = lane colour at 14 % (light) / 22 % (dark)
  with lane-colour text; current = + 6 pt dot and semibold; local + upstream at the same commit = one pill
  `main ⇄ origin`; remote = 1 pt outline at 60 %, remote prefix dimmed; tag = neutral fill + `tag` symbol;
  detached `HEAD` = neutral fill with `status.warning` outline; more than 3 → `+N`.
- WIP row: dashed hollow node on HEAD's lane, dashed edge into HEAD's row, counts in `text.tertiary`.
- Rows: hover `state.hover` (100 ms in / 140 ms out, off during live scroll, instant with Reduce Motion);
  selection = system accent 16 %/24 % + 2 pt leading accent bar; search matches tinted with the system
  find-highlight colour.
- Glass placement: the scope menu, search capsule, match controls and chips (`Solo: x ✕`,
  `History: path ✕`) float above the opaque table in one `GlassEffectContainer`; the navigator sits on the
  system sidebar material (source-list outline); the inspector content is opaque `surface.panel`.
- Density: View ▸ Graph Density (Compact / Comfortable), default Comfortable (Q2: compact rows read
  cramped next to 13 pt subjects at the default window size).

### Syntax colours (Phase 3 — `SyntaxColor`, `syntax.*`)
keyword `#8A1F84` / `#F07CC0` · type, tag `#0B5577` / `#6FC9E8` · function `#2F6067` / `#7CC4B4` · string `#9A2A17` /
`#F0937D` · number `#3B2CA8` / `#D6C477` · comment `#56606A` / `#98A3AD` · constant `#5E2F99` / `#B896EE` ·
operator, punctuation `#3D4245` / `#C9CCCF` · property, variable `#255F86` / `#8DB9DA` · attribute `#725A12` /
`#D9AE6C` · macro `#7A3E12` / `#F2A25E` (light / dark; Increase Contrast uses the same values).

### Diff and code view (Phase 3 — `CodeLinesView`, ADR-0011)
Opaque content: `surface.canvas` body; `diff.add.bg` / `diff.del.bg` row backgrounds; 3 pt change bar in
`diff.*.mark` at the gutter edge; hunk headers, collapsed-context rows and side-by-side fillers on
`surface.sunken`; line numbers `text.tertiary` in SF Mono (`type.mono.body`); selection = system accent at 28 %
with a 2 pt accent bar; search matches `findHighlightColor` (current match opaque); word-diff emphasis =
the side's mark colour at 28 %. Glass only on the floating capsules over the body (title, layout, change
navigator, find, options, focus; selection actions at the bottom), each a separate hosting view sized to its
content so the body keeps every click. Blame: 240 pt `surface.sunken` gutter, initials avatar in a lane colour,
age ramp = `accent.base` at 15–90 % opacity on the gutter edge.

### Phase 4 — operations, banner, resolver
- **Activity:** a standard toolbar item (system glass) present only while the active tab has activity; ring +
  one-line label while running, one-shot checkmark on finish (160 ms in, ~900 ms hold, 200 ms out), quiet
  clock glyph otherwise; popover rows are plain text on the popover material.
- **Operation banner:** one floating capsule under the command bar, `tintedGlassBar(tint: .statusWarning)`
  (glass tinted at 22 %; opaque `conflict.bg` with a hairline under Reduce Transparency); its buttons share one
  `GlassControlGroup`, Resolve Next is the single `primaryGlassButton`.
- **Sheets:** standard window-modal sheets; destructive buttons use the destructive role with
  `status.danger` text, Cancel is the default; high-risk actions enable after 600 ms.
- **Resolver:** chrome = one floating glass control group (navigator, Show Base, Save, Mark as Resolved —
  prominent only when everything is resolved, Close). Content = opaque `CodeLinesView` panes on
  `surface.canvas` with `surface.panel` pane headers; conflict rows `conflict.bg` with a `conflict.mark` bar,
  resolved rows `resolved.bg` with an `accent.base` bar, the current block in the system selection colour. Block
  actions are plain bordered buttons on `surface.panel` (never glass).
- **Tokens added:** `conflict.bg`, `conflict.mark`, `resolved.bg`.

### Contrast guarantees (unit-tested, all four variants)
Primary/secondary text ≥ 4.5:1 on canvas, panel, raised, sunken; tertiary text, accent, status and diff
marks ≥ 3:1; lanes ≥ 3:1 on canvas; text on diff backgrounds and on accent ≥ 4.5:1; line numbers and
change bars ≥ 3:1 on both diff backgrounds and `surface.sunken`; every `syntax.*` colour ≥ 4.5:1 on the
canvas and both diff backgrounds; text, syntax, line numbers and marks on `conflict.bg` / `resolved.bg`
(Phase 4); Increase Contrast values strictly stronger than regular for
secondary/tertiary text and borders.

## Typography (SF Pro / SF Mono — `TypeToken`, applied with `.typeStyle(_:)`)

| Token | Size / line | Weight |
|---|---|---|
| `type.display` | 20 / 26 | Semibold |
| `type.title` | 15 / 20 | Semibold |
| `type.headline` | 13 / 18 | Semibold |
| `type.body` | 13 / 18 | Regular |
| `type.callout` | 12 / 16 | Regular |
| `type.caption` | 11 / 14 | Medium |
| `type.micro` | 10 / 12 | Semibold, +2 % tracking, uppercase |
| `type.mono.body` | 12 / 18 | Regular (SF Mono) |
| `type.mono.caption` | 11 / 14 | Regular (SF Mono) |

Chrome text uses the system's fonts. Counts use `.monospacedDigit()`. SF Symbols are sized with
`symbolSize(_:)` and `IconSize` (12 / 16 / 20 / hero 40).

## Metrics
- Spacing (`Space`): 2, 4, 6, 8, 12, 16, 20, 24, 32, 40.
- Radii (`Radius`, continuous): xs 4, sm 6, md 10 (cards), lg 14; nested shapes use
  `Radius.concentric(outer:inset:)`. Glass uses capsules or system shapes, not these values.
- Borders: hairline 0.5 pt, emphasis 1 pt. Glass gets no custom borders.
- Shadows: `level1` (y 1, blur 3, 6 %), `level2` (y 4, blur 12, 10 %) — content, light appearance only.
- Panels: window min 960×600; sidebar 200 / 248 / 380; inspector 340 / 360 / 560; content column max 520.
- **Inspector visibility:** opens when something is selected (a commit, two commits, the WIP row) and closes
  when the selection becomes empty; a new tab starts closed. Esc in the graph leaves search / solo / file
  history / compare first, then clears the selection (closing the inspector); with nothing selected, Esc
  closes an inspector opened by the toolbar button or ⌥⌘0, which keeps working as a manual toggle. It always
  opens at the shared inspector width.
- Density: compact 22 pt rows, comfortable 26 pt (default).

## Motion (`MotionToken`)
hover 100 ms ease-out · press 60 ms ease-out · select 150 ms cubic(0.2, 0, 0, 1) · panel 200 ms
cubic(0.2, 0, 0, 1) · glassMorph 220 ms smooth · feedback 180 ms in / 120 ms out. Reveal = fade + 4 pt
rise; Reduce Motion → fade only. Nothing loops.

## Phase 1 chrome and content patterns

Renders (real screen captures): `docs/phases/01-shell-and-tabs/screenshots/`.

- **Toolbar** (unified `NSToolbar`, system glass): `[sidebar toggle] [sidebar tracking separator] [tab strip]
  [⌄ all tabs] [inspector toggle] [profile capsule]`. The sidebar toggle sits beside the window controls over
  the sidebar (macOS standard); an `NSTrackingSeparatorToolbarItem` follows the active tab's sidebar divider so
  the strip starts at the sidebar's edge. Tabs without a sidebar (new tab) drop the separator. Visual window title hidden (the strip names the repository); title and
  subtitle stay set for Mission Control, the Window menu and VoiceOver.
- **Glass tab strip:** an unbordered toolbar item (otherwise AppKit wraps a custom view in its own glass
  platter → nested glass) hosting one `GlassTabStrip`. Capsule tabs 28 pt tall, equal width 132–232 pt,
  4 pt apart; 6 pt status dot (none = clean, hollow `text.tertiary` = not loaded, `accent.base` = changes,
  `status.warning` = operation, `status.danger` = conflicts/error), system body font, primary/secondary
  label color for selected/other, close button on hover or selection. Selected capsule: `accent.tint` at
  38 % (`GlassTint.selectedOpacity`); hover: interactive glass. Selection morphs with `glassEffectID`
  (`motion.glassMorph`); neighbors slide with `motion.select` while dragging. In overflow the container
  sits inside the horizontal scroll content so glass clips with it; the new-tab `+` is its own small
  container next to it (siblings, never nested).
- **Reduce Transparency:** tabs become `surface.chromeOpaque` capsules with `border.strong` hairlines,
  selected `accent.muted` with an accent edge. **Increase Contrast:** the selected capsule gains an
  accent edge. **Reduce Motion:** no morph or slide; a short linear cross-fade.
- **Profile capsule:** content only (18 pt avatar with initials, display name above 1100 pt window width);
  the toolbar item's system platter supplies the glass. Profile swatches (`ProfileColor`): indigo, lagoon,
  fern, amber, coral, violet, orchid, graphite — neighbors of the lane palette, never lane-identical.
- **Profile switcher:** system `NSPopover` (system glass, no custom radius/shadow), 320 pt, rows with a
  28 pt avatar, `type.headline` name, `type.callout` `name <email>`, accent checkmark.
- **New-tab page:** opaque `surface.canvas`, 640 pt column; `type.title` wordmark in `text.tertiary`, one
  `primaryGlassButton` (extra-large), recents in one opaque `contentCard` (no glass cards).
- **Drop overlay:** opaque `surface.canvas` at 92 % + dashed 2 pt `accent.base` outline at `radius.md` —
  covers content, so never glass.
- **Workbench:** system glass sidebar (system list styling, no custom fills); main `surface.canvas` with the
  header (`type.display` name, `type.callout` branch/upstream with monospaced digits, warning chip for
  operations) and four opaque stat cards; inspector `surface.panel`. Loading placeholder appears after
  150 ms, static (no shimmer).

## Open items
- Reduce Transparency is verified by real captures (`docs/phases/01-shell-and-tabs/screenshots/*-reducetransparency-*`).
  Increase Contrast captures still need the system setting toggled by a person
  (`scripts/testing/capture-accessibility.sh increasecontrast`).

## Phase 5 additions
- `TypeToken.monoTitle` (15 pt medium SF Mono) for fingerprints and device codes compared character by character.
- Settings follow System Settings: system sidebar (glass by the system) + grouped forms; no custom chrome.
- Profile switcher: system popover, plain rows with hover state, `AccountStatusDot` (success/warning/danger/
  tertiary tokens), footer buttons in one `GlassControlGroup` with `secondaryGlassButton()`.
- Repository browser list/detail and the diagnostics step list are opaque content (no glass on rows).
