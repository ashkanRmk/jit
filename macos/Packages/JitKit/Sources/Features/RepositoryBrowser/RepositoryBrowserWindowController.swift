import AppKit
import Services
import SwiftUI

/// "Remote Repositories" (File ▸ Browse Remote Repositories…, new-tab page): a standard window with a unified
/// toolbar hosting `RepositoryBrowserView`. One instance at a time; closing the window cancels requests and
/// releases the model with its in-memory cache (design §4.7: nothing survives the window).
@MainActor
public final class RepositoryBrowserWindowController: NSWindowController, NSWindowDelegate {
    private static var current: RepositoryBrowserWindowController?

    let model: RepositoryBrowserModel

    /// Shows the browser (creating it on first use) and brings it to the front.
    @discardableResult
    public static func show(
        accounts: AccountsService, clone: @escaping (String) -> Void, switchProfile: @escaping (UUID) -> Void,
        openSettings: @escaping (String) -> Void
    ) -> RepositoryBrowserWindowController {
        let controller =
            current
            ?? RepositoryBrowserWindowController(
                model: RepositoryBrowserModel(
                    accounts: accounts,
                    actions: RepositoryBrowserActions(
                        clone: clone, switchProfile: switchProfile, openSettings: openSettings)))
        current = controller
        controller.present()
        return controller
    }

    /// The open browser, if any (tests and menu validation).
    public static var isShown: Bool { current != nil }

    init(model: RepositoryBrowserModel) {
        self.model = model
        let host = NSHostingController(rootView: RepositoryBrowserView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Remote Repositories"
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentMinSize = NSSize(width: 760, height: 440)
        window.identifier = NSUserInterfaceItemIdentifier("remote-repositories")
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.open()
    }

    public func windowWillClose(_ notification: Notification) {
        model.close()
        if Self.current === self { Self.current = nil }
    }
}
