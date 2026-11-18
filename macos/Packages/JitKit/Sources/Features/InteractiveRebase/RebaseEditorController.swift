import AppKit
import GitCore

/// Native responder-chain routing for a workbench hosted in NSHostingView. SwiftUI key equivalents
/// are not sufficient when the graph table was first responder before the editor covered it.
@MainActor
final class RebaseEditorController: NSViewController, WorkspaceDraggingHandler {
    let model: RebaseEditorModel
    unowned let operations: OperationsController

    init(model: RebaseEditorModel, operations: OperationsController) {
        self.model = model
        self.operations = operations
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let host = WorkspaceHostingView(
            rootView: RebaseEditorView(
                model: model, controller: operations, focusList: { [weak self] in self?.focusList() }))
        host.sizingOptions = []
        host.draggingHandler = self
        host.keyEventHandler = { [weak self] in self?.handleKey($0) ?? false }
        view = host
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusList()
    }

    func focusList() { view.window?.makeFirstResponder(view) }

    func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard
            let target = dropTarget(
                source: sender.draggingSource, pasteboard: sender.draggingPasteboard,
                windowLocation: sender.draggingLocation)
        else { model.dropTarget = nil; return [] }
        model.dropTarget = target
        return .move
    }

    func exitDrag() { model.dropTarget = nil }

    func performDrag(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(
            source: sender.draggingSource, pasteboard: sender.draggingPasteboard,
            windowLocation: sender.draggingLocation)
    }

    func acceptDrop(source: Any?, pasteboard: NSPasteboard, windowLocation: NSPoint) -> Bool {
        guard let target = dropTarget(source: source, pasteboard: pasteboard, windowLocation: windowLocation),
            let oid = pasteboard.string(forType: .string)
        else { return false }
        model.moveDraggedCommit(oid, to: target)
        return true
    }

    func dropTarget(source: Any?, pasteboard: NSPasteboard, windowLocation: NSPoint) -> String? {
        guard operations.interactiveRebase === model, operations.resolver == nil, operations.sheet == nil,
            let source = source as? RebaseDragHandleView, source.model === model,
            let oid = pasteboard.string(forType: .string), oid == source.oid, model.draggedCommit == oid
        else { return nil }
        func handles(_ view: NSView) -> [RebaseDragHandleView] {
            if let handle = view as? RebaseDragHandleView { return [handle] }
            return view.subviews.flatMap(handles)
        }
        let rows = handles(view).filter { $0.model === model }
        guard let scroll = rows.first?.enclosingScrollView else { return nil }
        let point = view.convert(windowLocation, from: nil)
        let listRect = view.convert(scroll.bounds, from: scroll)
        guard listRect.contains(point) else { return nil }
        let ordered = rows.map { ($0.oid, view.convert($0.bounds, from: $0).minY) }.sorted { $0.1 < $1.1 }
        return ordered.last(where: { $0.1 <= point.y })?.0 ?? ordered.first?.0
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard operations.interactiveRebase === model, operations.resolver == nil, operations.sheet == nil,
            let window = view.window, event.window === window,
            let responder = window.firstResponder as? NSView,
            responder === view || responder.isDescendant(of: view)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 36, modifiers == [.command], responder === view || responder is NSTextView {
            let clean = operations.session.status?.summary.map { $0.staged + $0.unstaged + $0.conflicted == 0 } ?? true
            if clean { operations.reviewInteractiveRebase(model) }
            return true
        }
        guard !(responder is NSTextView), !(responder is NSPopUpButton) else { return false }
        if event.keyCode == 48, modifiers.isEmpty, responder === view,
            let index = model.selectedIndex
        {
            let oid = model.plan.steps[index].oid
            func descendants(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(descendants) }
            let rendered = descendants(view)
            let handles = rendered.compactMap { $0 as? RebaseDragHandleView }
            if let handle = handles.first(where: { $0.oid == oid }) {
                let top = view.convert(handle.bounds, from: handle).minY
                let bottom =
                    handles.map { view.convert($0.bounds, from: $0).minY }.filter { $0 > top }.min()
                    ?? CGFloat.greatestFiniteMagnitude
                if let text = rendered.compactMap({ $0 as? NSTextView }).first(where: {
                    let y = view.convert($0.bounds, from: $0).minY
                    return $0.isEditable && y >= top && y < bottom
                }) {
                    return window.makeFirstResponder(text)
                }
            }
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            let direction = event.keyCode == 125 ? 1 : -1
            if modifiers == [.command, .option] { model.moveSelection(by: direction); return true }
            if modifiers.isEmpty { model.selectAdjacent(by: direction); return true }
        }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 { operations.interactiveRebase = nil; return true }
        guard let index = model.selectedIndex, let key = event.charactersIgnoringModifiers?.lowercased(),
            key.count == 1, let action = RebaseAction.allCases.first(where: { $0.rawValue.hasPrefix(key) })
        else { return false }
        model.setAction(action, at: index)
        return true
    }
}
