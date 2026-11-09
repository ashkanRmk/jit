import SwiftUI

// Liquid Glass usage rules (ADR-0006, docs/design-system.md):
// - Glass only on chrome: toolbar items, sidebar, floating controls, popovers, sheets.
// - System components first (toolbars, NavigationSplitView sidebars, `.glass`/`.glassProminent`
//   button styles render glass and handle Reduce Transparency themselves).
// - Custom glass goes through `jitGlass(in:)` only — the one place in the codebase that calls
//   `glassEffect`. Neighbouring glass shares one `GlassEffectContainer` (`GlassControlGroup`).
// - Untinted by default; `accent.tint` only on the single primary action of a surface.
// - Never on rows, cells, cards or anything inside scrolling content. Never animated while idle.

/// Glass-cost A/B switch (P6.2, design §4.1): `-JitOpaqueChrome YES` replaces Jit's own glass (tab strip,
/// capsules, floating bars) with the Reduce Transparency opaque surfaces, so Instruments can attribute GPU
/// cost to glass. Inert unless the argument is passed; system chrome (toolbar, sidebar, popovers) stays system.
public enum GlassPolicy {
    public static let opaqueChrome: Bool = UserDefaults.standard.bool(forKey: "JitOpaqueChrome")
}

/// Applies Liquid Glass to a custom chrome control, or an opaque chrome surface when Reduce
/// Transparency is on.
public struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        if reduceTransparency || GlassPolicy.opaqueChrome {
            content
                .background(ColorToken.surfaceChromeOpaque.color, in: shape)
                .overlay(shape.stroke(ColorToken.borderStrong.color, lineWidth: Border.hairline))
        } else {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        }
    }
}

extension View {
    /// Custom glass for a chrome control. Prefer system components; see the rules above.
    public func jitGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    /// The single primary action of a surface: system prominent glass button tinted with `accent.tint`.
    public func primaryGlassButton() -> some View {
        buttonStyle(.glassProminent).tint(ColorToken.accentTint.color)
    }

    /// A secondary chrome action: untinted system glass button.
    public func secondaryGlassButton() -> some View {
        buttonStyle(.glass)
    }
}

/// Neighbouring custom glass controls rendered (and morphed) as one surface.
public struct GlassControlGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = Space.s4, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) { content }
        }
    }
}

/// A floating capsule control above content (e.g. the Phase 4 operation/progress capsule).
public struct FloatingGlassCapsule<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, Space.s6)
            .padding(.vertical, Space.s4)
            .jitGlass(in: Capsule(), interactive: false)
    }
}

/// A floating bar with a subtle semantic tint (the Phase 4 operation banner): tinted Liquid Glass, or an
/// opaque tinted surface under Reduce Transparency. Text on it uses primary/secondary label colors only.
public struct TintedGlassBar<S: Shape>: ViewModifier {
    let shape: S
    let tint: ColorToken
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        if reduceTransparency || GlassPolicy.opaqueChrome {
            content
                .background(ColorToken.conflictBackground.color, in: shape)
                .overlay(shape.stroke(tint.color.opacity(0.6), lineWidth: Border.hairline))
        } else {
            content.glassEffect(.regular.tint(tint.color.opacity(0.22)), in: shape)
        }
    }
}

extension View {
    /// Tinted glass for a floating status bar (one per surface, never on rows).
    public func tintedGlassBar<S: Shape>(in shape: S, tint: ColorToken) -> some View {
        modifier(TintedGlassBar(shape: shape, tint: tint))
    }
}
