import AppKit
import DesignSystem
import GitCore
import SwiftUI

/// The ⌘K panel (design §3.1): a borderless child `NSPanel` of the main window, centered in its upper third,
/// hosting `CommandPaletteView`. It becomes key for typing but never main, so the main window keeps its
/// responder chain for the commands it runs. Closes on ⎋, ⌘K, executing a row, or losing key status.
@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private weak var windowController: MainWindowController?
    private var panel: PalettePanel?
    private let model: CommandPaletteModel
    private(set) var isOpen = false

    init(window: MainWindowController) {
        windowController = window
        model = CommandPaletteModel(window: window)
        super.init()
        model.close = { [weak self] in self?.close() }
        trimObserver = NotificationCenter.default.addObserver(
            forName: CacheLimits.trimNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { CommandPaletteModel.trimCaches() } }
    }

    nonisolated(unsafe) private var trimObserver: (any NSObjectProtocol)?

    deinit { trimObserver.map(NotificationCenter.default.removeObserver) }

    func open(over parent: NSWindow) {
        guard !isOpen else { return }
        isOpen = true
        model.reload()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, over: parent)
        parent.addChildWindow(panel, ordered: .above)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let final = panel.frame
        panel.alphaValue = 0
        if !reduceMotion { panel.setFrame(final.offsetBy(dx: 0, dy: -Space.s2), display: false) }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PaletteMotion.appear
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(final, display: true) }
        }
    }

    func setQuery(_ query: String) { model.query = query }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        let parent = panel.parent
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PaletteMotion.dismiss
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard !self.isOpen else { return }
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                parent?.makeKey()
            }
        }
    }

    private func makePanel() -> PalettePanel {
        let host = NSHostingView(rootView: CommandPaletteView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        let panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.delegate = self
        panel.title = "Command Palette"
        panel.setAccessibilityLabel("Command Palette")
        panel.onToggle = { [weak self] in self?.close() }
        return panel
    }

    /// Top edge in the upper third of the parent (below the toolbar); content grows downward.
    private func position(_ panel: NSPanel, over parent: NSWindow) {
        let size = NSSize(width: CommandPaletteView.width, height: max(panel.frame.height, 60))
        let frame = parent.frame
        let top = frame.maxY - max(96, frame.height * 0.18)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2, y: top - size.height, width: size.width,
                height: size.height), display: false)
        (panel as? PalettePanel)?.anchorTop = top
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Borderless panel that can become key (for the search field) and keeps its top edge fixed while the
/// result list changes height.
final class PalettePanel: NSPanel {
    var anchorTop: CGFloat?
    var onToggle: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setContentSize(_ size: NSSize) {
        guard let anchorTop else { return super.setContentSize(size) }
        setFrame(
            NSRect(x: frame.minX, y: anchorTop - size.height, width: size.width, height: size.height),
            display: true)
    }

    /// ⌘K while open closes (the main menu's target lives in the main window's chain).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "k" {
            onToggle?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onToggle?() }
}

/// Palette motion (design §3.1): appear 140 ms ease-out, dismiss 100 ms; within the panel range.
enum PaletteMotion {
    static let appear: Double = 0.14
    static let dismiss: Double = 0.10
}
