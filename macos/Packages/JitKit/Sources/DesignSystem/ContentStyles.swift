import AppKit
import SwiftUI

/// An opaque card on the content layer: `surface.raised`, hairline `border.subtle`, `shadow.1` in
/// light only (dark separates by luminance). Never glass.
public struct ContentCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let padding: CGFloat

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        let shadow = ShadowToken.level1
        content
            .padding(padding)
            .background(ColorToken.surfaceRaised.color, in: shape)
            .overlay(shape.strokeBorder(ColorToken.borderSubtle.color, lineWidth: Border.hairline))
            .shadow(
                color: .black.opacity(colorScheme == .light ? shadow.opacity : 0),
                radius: shadow.blur / 2, y: shadow.y)
    }
}

extension View {
    public func contentCard(padding: CGFloat = Space.s7) -> some View {
        modifier(ContentCard(padding: padding))
    }

    /// One section of a side panel in its own container (0.0.2): a `contentCard` that fills the panel's width.
    public func panelSection(padding: CGFloat = Space.s5) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).contentCard(padding: padding)
    }

    /// The window's content layer background.
    public func canvasBackground() -> some View {
        background(ColorToken.surfaceCanvas.color)
    }
}

/// Interaction state of a content row (file rows, graph rows, list rows).
public enum RowState: String, CaseIterable, Sendable {
    case rest, hover, pressed, selected, disabled
}

/// Selection and focus follow the user's system accent color (native feel; decided in P0.6 from
/// gallery renders — Tidewater at 12 % read as grey). Tidewater stays the tint of primary glass actions.
public enum Selection {
    /// System accent at 16 % (light) / 24 % (dark) — resolved per appearance by `NSColor`.
    public static var fill: Color {
        Color(
            nsColor: NSColor(name: "jit.selection.fill") { appearance in
                let isDark = Variant.resolve(appearance).isDark
                return NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.24 : 0.16)
            })
    }

    public static var edge: Color { Color(nsColor: .controlAccentColor) }
}

/// Content-row background for each state. Selection uses the system accent (`Selection`).
public struct RowBackground: View {
    let state: RowState

    public init(_ state: RowState) { self.state = state }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        switch state {
        case .rest, .disabled: shape.fill(.clear)
        case .hover: shape.fill(ColorToken.stateHover.color)
        case .pressed: shape.fill(ColorToken.statePressed.color)
        case .selected:
            shape.fill(Selection.fill)
                .overlay(alignment: .leading) {
                    Capsule().fill(Selection.edge).frame(width: 2).padding(.vertical, Space.s2)
                }
        }
    }
}

/// Keyboard focus ring for custom content views, in the system focus color.
public struct FocusRing: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-3)
            }
        }
    }
}

extension View {
    public func focusRing(_ isFocused: Bool, cornerRadius: CGFloat = Radius.sm) -> some View {
        modifier(FocusRing(isFocused: isFocused, cornerRadius: cornerRadius + 3))
    }
}
