import AppKit
import Foundation
import GitCore
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct NativeRebaseInputTests {
    func event(_ window: NSWindow, key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func nativeResponderChainSelectsReordersAndSetsAllActions() async throws {
        let (sandbox, _, _, session, operations, editor) = try await InteractiveRebaseFeatureTests.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        let controller = RebaseEditorController(model: editor, operations: operations)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.view.needsLayout = true
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.focusList()
        defer { window.orderOut(nil) }
        #expect(window.firstResponder === controller.view)
        let original = editor.plan.steps.map(\.oid)
        window.sendEvent(try event(window, key: "\u{F701}", code: 125))
        #expect(editor.selection == original[1])
        window.sendEvent(try event(window, key: "\u{F700}", code: 126, modifiers: [.command, .option]))
        #expect(editor.plan.steps.map(\.oid) == [original[1], original[0], original[2], original[3]])
        window.sendEvent(try event(window, key: "\u{F701}", code: 125, modifiers: [.command, .option]))
        #expect(editor.plan.steps.map(\.oid) == original)
        for (key, code, action) in [
            ("p", UInt16(35), RebaseAction.pick), ("r", 15, .reword), ("e", 14, .edit),
            ("s", 1, .squash), ("f", 3, .fixup), ("d", 2, .drop),
        ] {
            window.sendEvent(try event(window, key: key, code: code))
            #expect(editor.plan.steps[1].action == action)
        }
        operations.sheet = .interactiveRebaseStart
        let before = editor.plan.steps
        window.sendEvent(try event(window, key: "p", code: 35))
        #expect(editor.plan.steps == before)
        operations.cancelSheet()
        window.sendEvent(try event(window, key: "\u{1b}", code: 53))
        #expect(operations.interactiveRebase == nil)
    }

    @Test func nativeMessageEditorOwnsLettersArrowsAndModifiedArrows() async throws {
        let (sandbox, _, _, session, operations, editor) = try await InteractiveRebaseFeatureTests.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        editor.setAction(.reword, at: 0)
        let controller = RebaseEditorController(model: editor, operations: operations)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.view.needsLayout = true
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        await ClosedTabDeallocatesTests.spin(100)
        controller.view.layoutSubtreeIfNeeded()
        let text = try #require(descendants(controller.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        controller.focusList()
        window.sendEvent(try event(window, key: "\t", code: 48))
        #expect(window.firstResponder === text)
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        let before = editor.plan.steps.map(\.oid)
        for (key, code) in [("p", UInt16(35)), ("r", 15), ("e", 14), ("s", 1), ("f", 3), ("d", 2)] {
            let input = try event(window, key: key, code: code)
            #expect(!controller.view.performKeyEquivalent(with: input))
            window.sendEvent(input)
        }
        #expect(text.string == "presfd")
        #expect(editor.plan.steps[0].action == .reword)
        #expect(!controller.view.performKeyEquivalent(with: try event(window, key: "\u{F700}", code: 126)))
        #expect(
            !controller.view.performKeyEquivalent(
                with: try event(window, key: "\u{F700}", code: 126, modifiers: [.command, .option])))
        #expect(editor.plan.steps.map(\.oid) == before)
        #expect(
            controller.view.performKeyEquivalent(with: try event(window, key: "\r", code: 36, modifiers: [.command])))
        guard case .confirm = operations.sheet else { Issue.record("Command-Return did not open review"); return }
        operations.cancelSheet()
        controller.focusList()
        #expect(controller.view.performKeyEquivalent(with: try event(window, key: "d", code: 2)))
        #expect(editor.plan.steps[0].action == .drop)
    }
    @Test func nativePasteboardDropUsesRenderedRowsAndRejectsForeignSources() async throws {
        let (sandbox, _, _, session, operations, editor) = try await InteractiveRebaseFeatureTests.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        let controller = RebaseEditorController(model: editor, operations: operations)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.view.needsLayout = true
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        await ClosedTabDeallocatesTests.spin(100)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.registeredDraggedTypes.contains(.string))
        let handles = descendants(controller.view).compactMap { $0 as? RebaseDragHandleView }
        #expect(handles.count == editor.plan.steps.count)
        let source = try #require(handles.first { $0.oid == editor.plan.steps[3].oid })
        let target = try #require(handles.first { $0.oid == editor.plan.steps[0].oid })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(source.oid, forType: .string)
        editor.draggedCommit = source.oid
        let point = target.convert(NSPoint(x: target.bounds.midX + 160, y: target.bounds.midY), to: nil)
        #expect(controller.dropTarget(source: source, pasteboard: board, windowLocation: point) == target.oid)
        #expect(controller.acceptDrop(source: source, pasteboard: board, windowLocation: point))
        #expect(editor.plan.steps[0].oid == source.oid)
        #expect(editor.draggedCommit == nil && editor.dropTarget == nil)
        editor.draggedCommit = target.oid
        let before = editor.plan.steps
        #expect(!controller.acceptDrop(source: NSObject(), pasteboard: board, windowLocation: point))
        #expect(editor.plan.steps == before)
    }

}
