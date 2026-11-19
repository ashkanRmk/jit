import AppKit
import DesignSystem
import SwiftUI

/// An explicit native drag source avoids gesture arbitration between the row's selection tap, its
/// controls and SwiftUI's drag recognizer. The editor's native host handles destinations.
struct RebaseDragHandle: NSViewRepresentable {
    let model: RebaseEditorModel
    let oid: String
    let position: Int
    var focusList: () -> Void

    func makeNSView(context: Context) -> RebaseDragHandleView { RebaseDragHandleView() }
    func updateNSView(_ view: RebaseDragHandleView, context: Context) {
        view.model = model
        view.oid = oid
        view.focusList = focusList
        view.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Reorder commit")
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: IconSize.sm, weight: .regular)
        view.contentTintColor = ColorToken.textTertiary.nsColor
        view.setAccessibilityLabel("Drag commit \(position) to reorder; keyboard alternative Option-Command-Up or Down")
        view.setAccessibilityIdentifier("rebase-drag-\(oid)")
        view.toolTip = "Drag to reorder this commit"
    }
}

@MainActor
final class RebaseDragHandleView: NSImageView, NSDraggingSource {
    weak var model: RebaseEditorModel?
    var oid = ""
    var focusList: () -> Void = {}
    private var mouseDownEvent: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        model.selection = oid
        focusList()
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let image, let mouseDownEvent else { return }
        self.mouseDownEvent = nil
        model.draggedCommit = oid
        let item = NSDraggingItem(pasteboardWriter: oid as NSString)
        item.setDraggingFrame(bounds, contents: image)
        // Start only after movement, and retain the initiating mouse-down event for AppKit.
        beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        return context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        // A successful destination moves the commit and clears state synchronously.
        if operation.isEmpty, model?.draggedCommit == oid {
            model?.draggedCommit = nil
            model?.dropTarget = nil
        }
    }
}
