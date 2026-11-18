import AppKit
import DesignSystem

/// Native coordinate-space magnification scales the entire workspace, including AppKit drawing and
/// SwiftUI hosts. Layout uses logical points, so hit targets, row heights, icons and fonts stay aligned.
/// At small window sizes the canvas scrolls rather than squeezing panels below their supported widths.
@MainActor
final class WorkspaceZoomView: NSScrollView {
    private(set) var zoomFactor: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        automaticallyAdjustsContentInsets = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        minMagnification = 0.75
        maxMagnification = 1.5
        // Zoom is changed by the View menu, not an accidental trackpad pinch.
        allowsMagnification = false
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setZoom(_ factor: CGFloat) {
        zoomFactor = min(maxMagnification, max(minMagnification, factor))
        magnification = zoomFactor
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let documentView {
            func updateHosts(_ view: NSView) {
                if let host = view as? any WorkspaceZoomAware {
                    host.canvasZoomDidChange()
                } else {
                    for child in view.subviews { updateHosts(child) }
                }
            }
            updateHosts(documentView)
            layoutSubtreeIfNeeded()
            // NSScrollView normally preserves its centre, which can hide the sidebar when zooming in.
            let top = documentView.isFlipped ? 0 : max(0, documentView.bounds.height - contentView.bounds.height)
            contentView.scroll(to: NSPoint(x: 0, y: top))
            reflectScrolledClipView(contentView)
        }
    }

    override func layout() {
        super.layout()
        guard let documentView else { return }
        // Keep a complete usable workbench at high zoom. Nested graph/diff lists retain their own scroll.
        let size = NSSize(
            width: max(PanelMetrics.windowMinWidth, contentView.bounds.width),
            height: max(PanelMetrics.windowMinHeight, contentView.bounds.height))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        let inheritedTop = documentView.safeAreaInsets.top - documentView.additionalSafeAreaInsets.top
        let extraTop = max(0, safeAreaInsets.top / min(1, zoomFactor) - inheritedTop)
        if abs(documentView.additionalSafeAreaInsets.top - extraTop) > 0.5 {
            documentView.additionalSafeAreaInsets = NSEdgeInsets(top: extraTop, left: 0, bottom: 0, right: 0)
        }
        documentView.layoutSubtreeIfNeeded()
    }
}
