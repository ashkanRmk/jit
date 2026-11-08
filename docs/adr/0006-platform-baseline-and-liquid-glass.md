# ADR-0006: macOS 26+ baseline and native Liquid Glass design language

- Status: accepted (design direction decided by the project owner; baseline is the consequence), 2026-11-08
- Date: 2026-11-08
- Phase: P0 (pre-decided during planning)
- Requirements: §1 (deployment target "macOS 14 unless a documented compatibility concern justifies a
  different baseline"), §2.1, §3, §15. Amends §3.1's "avoid excessive translucency or blur" by defining
  where translucency is allowed.

## Context
The owner wants Jit to follow the modern macOS design language — Liquid Glass, introduced in macOS 26 —
exactly like a first-party Mac app, and considers design and efficiency equally important. Liquid Glass
APIs (SwiftUI `glassEffect`, `GlassEffectContainer`, `.glass`/`.glassProminent` button styles; AppKit
`NSGlassEffectView`, `NSGlassEffectContainerView`; system toolbar, sidebar and control styling) exist
only on macOS 26+. Supporting macOS 14–15 would require a second, non-glass visual design and fallback
code paths for every chrome surface. The development machine runs macOS 27.2; current Xcode (27.2)
requires macOS 26.6+.

## Decision
- **Deployment target: macOS 26.0.** Apple Silicon first, universal later (Phase 7). Build with the latest
  stable Xcode/SDK so standard controls adopt current system styling automatically.
- **Minimum Git version** remains a Phase 0 capability check (proposal 2.39).
- **Design language: native Liquid Glass, used the way Apple's own apps use it.**
  - Glass belongs to the *control and navigation layer*: window toolbar and its items, the repository tab
    bar, the sidebar (system sidebar material), floating controls, popovers, menus, sheets, the
    profile switcher, the operation/progress capsule, the command palette.
  - The *content layer* stays opaque and calm: the commit graph, diff and code views, conflict resolver
    panes, file lists. Content may extend under glass chrome (scroll-edge effects / background extension)
    but text is never rendered on glass over busy content.
  - Prefer system components and modifiers that render glass for free (toolbars, `NSSplitViewController`
    sidebars, standard buttons/menus/popovers) over custom glass. Custom glass only through the official
    APIs, grouped in a `GlassEffectContainer` / `NSGlassEffectContainerView` — never hand-made blur
    stacks (`NSVisualEffectView` layering, CIFilter blurs, custom shaders).
  - Jit's identity comes from typography, spacing, the graph and diff design, a restrained accent tint and
    lane palette — on top of the system language, not fighting it.
  - Respect Reduce Transparency, Increase Contrast and Reduce Motion (system materials adapt
    automatically; custom surfaces must too).
- **Efficiency rules for glass:** no glass on per-row or per-commit elements; no glass inside scrolling
  content; no continuously animating glass; glass morph/transition animations only on user action and
  short; measure GPU/energy impact of chrome in Phase 6.

## Consequences
- Users on macOS 14–15 cannot run Jit. This is the accepted trade for one coherent native design.
- The design system (Phase 0) defines tokens for the content layer and *usage rules* for glass rather
  than custom translucent surface colors; system semantic colors are preferred where they fit.
- Phase 7 clean-machine tests use macOS 26 and the latest macOS.
- **Revisit if:** a meaningful user segment on macOS 15 is required — that would need a separate
  fallback design and its own ADR.
