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

    /// The window's content layer background.
    public func canvasBackground() -> some View {
        background(ColorToken.surfaceCanvas.color)
    }
}

/// Interaction state of a content row (file rows, graph rows, list rows).
public enum RowState: String, CaseIterable, Sendable {
    case rest, hover, pressed, selected, disabled
}

/// Content-row background for each state. Selection uses `accent.muted` with an `accent.base` edge.
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
            shape.fill(ColorToken.accentMuted.color)
                .overlay(alignment: .leading) {
                    Capsule().fill(ColorToken.accentBase.color).frame(width: 2).padding(.vertical, Space.s2)
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
