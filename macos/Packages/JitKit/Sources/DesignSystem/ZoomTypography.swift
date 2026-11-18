import SwiftUI

private struct WorkspaceZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct ZoomFontLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The workspace's visual scale. Fonts render at this point size rather than enlarging cached glyphs.
    public var workspaceZoomFactor: CGFloat {
        get { self[WorkspaceZoomKey.self] }
        set { self[WorkspaceZoomKey.self] = newValue }
    }

    fileprivate var isInsideZoomFontLayout: Bool {
        get { self[ZoomFontLayoutKey.self] }
        set { self[ZoomFontLayoutKey.self] = newValue }
    }
}

/// A larger native font keeps the same logical layout space. The inverse transform cancels the
/// enclosing workspace transform, so the final glyph is drawn at its actual display size.
struct ZoomFontLayout: Layout {
    let scale: CGFloat

    private func expanded(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 * scale }, height: proposal.height.map { $0 * scale })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(expanded(proposal))
        return CGSize(width: size.width / scale, height: size.height / scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: expanded(ProposedViewSize(bounds.size)))
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline, let child = subviews.first else { return nil }
        return child.dimensions(in: expanded(ProposedViewSize(bounds.size)))[guide] / scale
    }
}

private struct ZoomFontModifier: ViewModifier {
    let font: Font
    @Environment(\.workspaceZoomFactor) private var zoom
    @Environment(\.isInsideZoomFontLayout) private var nested

    func body(content: Content) -> some View {
        let scale = nested ? 1 : zoom
        ZoomFontLayout(scale: scale) {
            content
                .font(font.scaled(by: zoom))
                .environment(\.isInsideZoomFontLayout, true)
                .scaleEffect(1 / scale, anchor: .topLeading)
        }
    }
}

struct ZoomTypeStyle: ViewModifier {
    let token: TypeToken
    @Environment(\.workspaceZoomFactor) private var zoom

    func body(content: Content) -> some View {
        content
            .lineSpacing(max(0, token.lineHeight - token.naturalLineHeight) * zoom)
            .tracking(token.tracking * zoom)
            .textCase(token.isUppercase ? .uppercase : nil)
            .scaledFont(token.font)
    }
}

extension View {
    /// Render text and font-based symbols at the workspace's destination size without resizing their layout.
    public func scaledFont(_ font: Font) -> some View { modifier(ZoomFontModifier(font: font)) }
}
