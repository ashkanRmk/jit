import AppKit
import Services

/// Repository ▸ Recently Discarded (ADR-0025): the active repository's recovery copies, newest first.
/// Choosing one reveals it in Finder; restoring is a manual copy in V1. Rebuilt when opened (no timer).
@MainActor
public final class RecentlyDiscardedMenu: NSObject, NSMenuDelegate {
    public static let shared = RecentlyDiscardedMenu()

    /// The active tab's repository top level; set by the window controller.
    public var repositoryPath: () -> String? = { nil }
    var store = RecoveryStore()
    static let limit = 20

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = repositoryPath().map { store.entries(repository: $0) } ?? []
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Recently Discarded Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for entry in entries.prefix(Self.limit) {
            let item = NSMenuItem(
                title: "\(entry.meta.fileName) — \(formatter.string(from: entry.meta.created))",
                action: #selector(reveal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.file
            item.subtitle = entry.meta.path
            item.toolTip = "Reveal the copy of \(entry.meta.path) in Finder"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "Show Recovery Folder", action: #selector(showFolder(_:)), keyEquivalent: "")
        folder.target = self
        folder.isEnabled = FileManager.default.fileExists(atPath: store.root.path)
        menu.addItem(folder)
    }

    @objc func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func showFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([store.root])
    }
}
