import AppKit
import DesignSystem
import SwiftUI

@MainActor
protocol WorkspaceDraggingHandler: AnyObject {
    func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation
    func exitDrag()
    func performDrag(_ sender: any NSDraggingInfo) -> Bool
}

/// SwiftUI must scale its own content and gestures. Counter the canvas transform at the hosting
/// boundary, then apply the same scale inside SwiftUI so drawing and pointer targets stay together.
@MainActor
protocol WorkspaceZoomAware: AnyObject {
    func canvasZoomDidChange()
}

@MainActor
final class WorkspaceHostingView<Content: View>: NSView, WorkspaceZoomAware {
    var rootView: Content {
        didSet { naturalSize = nil; updateRoot(); invalidateIntrinsicContentSize() }
    }
    var sizingOptions: NSHostingSizingOptions = [.intrinsicContentSize] {
        didSet { naturalSize = nil; needsLayout = true; invalidateIntrinsicContentSize() }
    }
    var safeAreaRegions: SafeAreaRegions = [] {
        didSet { hosting.safeAreaRegions = safeAreaRegions }
    }
    var providesIntrinsicWidth = true {
        didSet { invalidateIntrinsicContentSize() }
    }
    /// Optional workbench-specific native input routing. Ordinary hosts retain their responder behavior.
    var keyEventHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { keyEventHandler != nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEventHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyEventHandler?(event) != true { super.keyDown(with: event) }
    }

    weak var draggingHandler: (any WorkspaceDraggingHandler)? {
        didSet {
            if draggingHandler != nil { registerForDraggedTypes([.string]) } else { unregisterDraggedTypes() }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingHandler?.updateDrag(sender) ?? super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingHandler?.updateDrag(sender) ?? super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { draggingHandler?.exitDrag() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingHandler?.updateDrag(sender).contains(.move) ?? false
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingHandler?.performDrag(sender) ?? false
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { draggingHandler?.exitDrag() }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    private var naturalSize: NSSize?
    private var lastWidth: CGFloat = -1
    private var factor: CGFloat = 1
    private let hosting: SwiftUI.NSHostingView<ScaledWorkspaceContent<Content>>

    init(rootView: Content) {
        self.rootView = rootView
        hosting = SwiftUI.NSHostingView(rootView: ScaledWorkspaceContent(content: rootView))
        super.init(frame: .zero)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.safeAreaRegions = []
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    private var canvasFactor: CGFloat {
        var ancestor = superview
        while let view = ancestor {
            if let viewport = view as? WorkspaceZoomView { return viewport.zoomFactor }
            ancestor = view.superview
        }
        return 1
    }

    override var intrinsicContentSize: NSSize {
        guard sizingOptions.contains(.intrinsicContentSize) else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        if let naturalSize {
            return NSSize(
                width: providesIntrinsicWidth ? naturalSize.width : NSView.noIntrinsicMetric, height: naturalSize.height
            )
        }
        let saved = hosting.rootView
        hosting.rootView = ScaledWorkspaceContent(
            content: rootView,
            logicalSize: frame.width > 0 ? NSSize(width: frame.width, height: 0) : nil,
            naturalHeight: true, measuring: true)
        let size = hosting.intrinsicContentSize
        hosting.rootView = saved
        naturalSize = size
        return NSSize(width: providesIntrinsicWidth ? size.width : NSView.noIntrinsicMetric, height: size.height)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    func canvasZoomDidChange() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let nextFactor = canvasFactor
        if factor != nextFactor || lastWidth != frame.width {
            factor = nextFactor
            lastWidth = frame.width
            naturalSize = nil
            invalidateIntrinsicContentSize()
        }
        let physical = NSSize(width: frame.width * factor, height: frame.height * factor)
        if bounds.size != physical { setBoundsSize(physical) }
        hosting.frame = bounds
        updateRoot()
    }

    private func updateRoot() {
        hosting.rootView = ScaledWorkspaceContent(
            content: rootView, logicalSize: frame.size, factor: factor,
            naturalHeight: sizingOptions.contains(.intrinsicContentSize),
            measured: { [weak self] size in
                guard let self, self.naturalSize != size else { return }
                self.naturalSize = size
                self.invalidateIntrinsicContentSize()
            })
    }
}

private struct ScaledWorkspaceContent<Content: View>: View {
    let content: Content
    var logicalSize: NSSize?
    var factor: CGFloat = 1
    var naturalHeight = false
    var measuring = false
    var measured: (NSSize) -> Void = { _ in }

    var body: some View {
        content
            .environment(\.workspaceZoomFactor, factor)
            .frame(width: logicalSize?.width, height: naturalHeight ? nil : logicalSize?.height, alignment: .topLeading)
            .onGeometryChange(for: NSSize.self) {
                $0.size
            } action: {
                measured($0)
            }
            .scaleEffect(factor, anchor: .topLeading)
            .frame(
                width: logicalSize.map { $0.width * factor },
                height: measuring ? nil : logicalSize.map { $0.height * factor },
                alignment: .topLeading)
    }
}

@MainActor
final class WorkspaceHostingController<Content: View>: NSViewController {
    var rootView: Content
    var sizingOptions: NSHostingSizingOptions = []

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let host = WorkspaceHostingView(rootView: rootView)
        host.sizingOptions = sizingOptions
        view = host
    }
}
