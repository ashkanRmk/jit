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
| Where | Window toolbar and its items, (Phase 1) tab bar, sidebar, floating controls, popovers, menus, sheets, profile switcher, command palette. |
| Never | Rows/cells (graph, file, diff lines), anything inside scrolling content, cards, text blocks over busy content, behind code. |
| How | System components first: `.toolbar`, `NavigationSplitView` / `NSSplitViewController` sidebars, `.buttonStyle(.glass)` (`secondaryGlassButton()`), `.buttonStyle(.glassProminent)` + `accent.tint` (`primaryGlassButton()`), popovers, sheets. Custom glass only via `jitGlass(in:interactive:)` — the single call site of `glassEffect(_:in:)` — grouped with `GlassControlGroup` (`GlassEffectContainer`); `FloatingGlassCapsule` for floating controls; `glassEffectID(_:in:)` for morphs. Content under chrome uses `scrollEdgeEffectStyle(.soft, for: .top)`. |
| Grouping | Neighbouring custom glass shares one container. No glass in glass. No `NSVisualEffectView` stacks, CIFilter or `.blur` (lint-enforced). |
| Tint | Untinted by default; `accent.tint` only on the single primary action of a surface. Never lane/status colors on glass. |
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

### Contrast guarantees (unit-tested, all four variants)
Primary/secondary text ≥ 4.5:1 on canvas, panel, raised, sunken; tertiary text, accent, status and diff
marks ≥ 3:1; lanes ≥ 3:1 on canvas; text on diff backgrounds and on accent ≥ 4.5:1; Increase Contrast
values strictly stronger than regular for secondary/tertiary text and borders.

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
- Panels: window min 960×600; sidebar 200 / 248 / 380; inspector 340 / 440; content column max 520.
- Density: compact 22 pt rows, comfortable 26 pt (default).

## Motion (`MotionToken`)
hover 100 ms ease-out · press 60 ms ease-out · select 150 ms cubic(0.2, 0, 0, 1) · panel 200 ms
cubic(0.2, 0, 0, 1) · glassMorph 220 ms smooth · feedback 180 ms in / 120 ms out. Reveal = fade + 4 pt
rise; Reduce Motion → fade only. Nothing loops.

## Open items
- Real screen captures of glass chrome, Reduce Transparency and Increase Contrast were not possible in
  the Phase 0 session (see `docs/phases/00-foundation/progress.md`).
