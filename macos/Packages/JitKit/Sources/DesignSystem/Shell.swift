import SwiftUI

/// Window chrome metrics (Phase 1 shell, design §3.1).
public enum TabMetrics {
    public static let minWidth: CGFloat = 132
    public static let maxWidth: CGFloat = 232
    public static let height: CGFloat = 28
    public static let spacing: CGFloat = Space.s2
    public static let statusDot: CGFloat = 6
    public static let closeButton: CGFloat = 16
    public static let newTabButton: CGFloat = 28
    public static let horizontalPadding: CGFloat = Space.s4
}

/// Profile capsule metrics (design §3.1).
public enum ProfileMetrics {
    public static let avatar: CGFloat = 18
    /// Below this window width the capsule shows only the avatar.
    public static let nameHiddenBelowWindowWidth: CGFloat = 1100
    public static let largeAvatar: CGFloat = 28
}

/// Content-overlay values.
public enum OverlayMetrics {
    /// Opacity of `surface.canvas` under the folder drop overlay (opaque content, not glass).
    public static let dropCanvasOpacity: Double = 0.92
    public static let dropDash: [CGFloat] = [8, 5]
    public static let dropLineWidth: CGFloat = 2
    /// Loading placeholders appear only after this delay, so fast loads never flash.
    public static let loadingPlaceholderDelay: Duration = .milliseconds(150)
}

/// Profile identity colors: neighbors of the lane palette (never lane-identical, so a profile is never
/// mistaken for a graph lane).
public enum ProfileColor: Int, CaseIterable, Sendable {
    case indigo, lagoon, fern, amber, coral, violet, orchid, graphite

    public var name: String {
        switch self {
        case .indigo: "Indigo"
        case .lagoon: "Lagoon"
        case .fern: "Fern"
        case .amber: "Amber"
        case .coral: "Coral"
        case .violet: "Violet"
        case .orchid: "Orchid"
        case .graphite: "Graphite"
        }
    }

    public var spec: ColorSpec {
        switch self {
        case .indigo: ColorSpec(light: RGBA(0x5157B8), dark: RGBA(0x9DA1EE))
        case .lagoon: ColorSpec(light: RGBA(0x1C7C8F), dark: RGBA(0x6CC6D6))
        case .fern: ColorSpec(light: RGBA(0x467E3A), dark: RGBA(0x93C985))
        case .amber: ColorSpec(light: RGBA(0xA35C1E), dark: RGBA(0xEEA56B))
        case .coral: ColorSpec(light: RGBA(0xB23F45), dark: RGBA(0xEE8C8F))
        case .violet: ColorSpec(light: RGBA(0x7F48A8), dark: RGBA(0xC59BE3))
        case .orchid: ColorSpec(light: RGBA(0xB0467F), dark: RGBA(0xEE97C4))
        case .graphite: ColorSpec(light: RGBA(0x59616B), dark: RGBA(0xA7AEB8))
        }
    }

    /// Initials drawn on the swatch.
    public static let initials = ColorSpec(light: RGBA(0xFFFFFF), dark: RGBA(0x121316))

    public static func at(_ index: Int) -> ProfileColor {
        ProfileColor(rawValue: ((index % allCases.count) + allCases.count) % allCases.count) ?? .indigo
    }
}

extension ProfileColor {
    @MainActor public var color: Color { Color(nsColor: spec.dynamicColor(named: "jit.profile.\(rawValue)")) }
    @MainActor public static var initialsColor: Color {
        Color(nsColor: initials.dynamicColor(named: "jit.profile.initials"))
    }
}

// MARK: - Glass tab strip

/// The one glass container of the tab strip: every tab capsule lives in it, so the strip reads as one
/// glass surface and selection can morph between tabs. Nothing inside a tab is glass (no nesting).
public struct GlassTabStrip<Content: View>: View {
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if reduceTransparency {
            HStack(spacing: TabMetrics.spacing) { content }
        } else {
            GlassEffectContainer(spacing: TabMetrics.spacing) {
                HStack(spacing: TabMetrics.spacing) { content }
            }
        }
    }
}

/// A tab capsule in the glass strip. The selected tab carries the `accent.tint` selection tint; the
/// `glassEffectID` lets the glass morph when selection or order changes (only on user action).
/// With Reduce Transparency, tabs become opaque `surface.chromeOpaque` capsules.
public struct GlassTab<ID: Hashable & Sendable>: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let id: ID
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    isSelected ? ColorToken.accentMuted.color : ColorToken.surfaceChromeOpaque.color, in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Selection.edge : ColorToken.borderStrong.color,
                        lineWidth: isSelected ? Border.emphasis : Border.hairline))
        } else {
            content
                .glassEffect(glass, in: Capsule())
                .glassEffectID(id, in: namespace)
                .overlay {
                    // Increase Contrast: an explicit edge on the selected capsule.
                    if contrast == .increased, isSelected {
                        Capsule().strokeBorder(Selection.edge, lineWidth: Border.emphasis)
                    }
                }
        }
    }

    private var glass: Glass {
        if isSelected {
            return .regular.tint(ColorToken.accentTint.color.opacity(GlassTint.selectedOpacity)).interactive()
        }
        return isHovered ? .regular.interactive() : .regular
    }
}

/// Tint strengths for glass (glass tint policy, docs/design-system.md).
public enum GlassTint {
    /// Selected tab: a subtle `accent.tint`.
    public static let selectedOpacity: Double = 0.38
}

extension View {
    public func glassTab<ID: Hashable & Sendable>(
        isSelected: Bool, isHovered: Bool, id: ID, in namespace: Namespace.ID
    ) -> some View {
        modifier(GlassTab(isSelected: isSelected, isHovered: isHovered, id: id, namespace: namespace))
    }
}
