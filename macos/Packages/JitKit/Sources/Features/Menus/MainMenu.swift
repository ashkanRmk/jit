import AppKit
import Services

/// The main menu (design §3.6). Only menus with working items exist — no Branch or Git menus yet.
/// Items target the first responder; `MainWindowController` and the app delegate implement them.
@MainActor
public enum MainMenu {
    /// Selectors implemented by the app delegate.
    public enum AppSelectors {
        public static let showSettings = Selector(("showSettings:"))
        public static let setAppearance = Selector(("setAppearance:"))
        public static let showHelp = Selector(("showJitHelp:"))
    }

    public static func build(recentsDelegate: any NSMenuDelegate, windowDelegate: any NSMenuDelegate) -> NSMenu {
        let main = NSMenu(title: "Main")
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(recentsDelegate: recentsDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(repositoryMenu()))
        let window = windowMenu()
        window.delegate = windowDelegate
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Jit")
        menu.addItem(item("About Jit", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", AppSelectors.showSettings, ","))
        menu.addItem(.separator())
        let services = item("Services", nil)
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Jit", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Jit", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(recentsDelegate: any NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(MainWindowController.newTab(_:)), "t"))
        menu.addItem(item("Open Repository…", #selector(MainWindowController.openRepository(_:)), "o"))
        let recent = item("Open Recent", nil)
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentsDelegate
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Reopen Closed Tab", #selector(MainWindowController.reopenClosedTab(_:)), "T", .command))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "W", .command))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "Z", .command))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = item("Find", nil)
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find…", #selector(GraphViewController.jitFind(_:)), "f"))
        findMenu.addItem(item("Find Next", #selector(GraphViewController.jitFindNext(_:)), "g"))
        findMenu.addItem(item("Find Previous", #selector(GraphViewController.jitFindPrevious(_:)), "G", .command))
        find.submenu = findMenu
        menu.addItem(find)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(
            item("Show Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(
            item("Show Inspector", #selector(MainWindowController.toggleInspector(_:)), "0", [.command, .option]))
        menu.addItem(.separator())
        let appearance = item("Appearance", nil)
        let appearanceMenu = NSMenu(title: "Appearance")
        for (index, value) in PreferencesStore.Appearance.allCases.enumerated() {
            let entry = item(value.title, AppSelectors.setAppearance)
            entry.tag = index
            entry.representedObject = value.rawValue
            appearanceMenu.addItem(entry)
        }
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)
        let density = item("Graph Density", nil)
        let densityMenu = NSMenu(title: "Graph Density")
        for value in PreferencesStore.GraphDensity.allCases {
            let entry = item(value.title, #selector(GraphViewController.setGraphDensity(_:)))
            entry.representedObject = value.rawValue
            densityMenu.addItem(entry)
        }
        density.submenu = densityMenu
        menu.addItem(density)
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func repositoryMenu() -> NSMenu {
        let menu = NSMenu(title: "Repository")
        menu.addItem(item("Refresh", #selector(MainWindowController.refreshRepository(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(
            item(
                "Reveal in Finder", #selector(MainWindowController.revealRepositoryInFinder(_:)), "r",
                [.command, .option]))
        menu.addItem(
            item(
                "Open in Terminal", #selector(MainWindowController.openRepositoryInTerminal(_:)), "t",
                [.command, .option]))
        menu.addItem(
            item(
                "Copy Repository Path", #selector(MainWindowController.copyRepositoryPath(_:)), "c",
                [.command, .option]))
        return menu
    }

    /// Tab items; the tab list itself is appended by `windowMenuNeedsUpdate`.
    static let tabListTag = 7_001

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)), "\t", .control))
        menu.addItem(
            item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "\t", [.control, .shift]))
        // ⌘⇧] / ⌘⇧[ — hidden alternates that share the actions above.
        let next = item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)), "}", .command)
        next.isHidden = true
        next.allowsKeyEquivalentWhenHidden = true
        let previous = item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "{", .command)
        previous.isHidden = true
        previous.allowsKeyEquivalentWhenHidden = true
        menu.addItem(next)
        menu.addItem(previous)
        menu.addItem(item("Move Tab Left", #selector(MainWindowController.moveTabLeft(_:))))
        menu.addItem(item("Move Tab Right", #selector(MainWindowController.moveTabRight(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    /// Rebuilds the tab list at the end of the Window menu.
    public static func updateWindowMenu(_ menu: NSMenu, tabs: [TabModel], activeID: UUID?) {
        for item in menu.items where item.tag == tabListTag { menu.removeItem(item) }
        guard !tabs.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = tabListTag
        menu.addItem(separator)
        for tab in tabs {
            let item = item(tab.title, #selector(MainWindowController.selectTabFromWindowMenu(_:)))
            item.tag = tabListTag
            item.representedObject = tab.id
            item.state = tab.id == activeID ? .on : .off
            item.image = StatusDotImage.image(for: tab.statusDot)
            item.toolTip = tab.tooltip
            menu.addItem(item)
        }
    }

    /// Rebuilds File ▸ Open Recent from the recents store.
    public static func updateRecentsMenu(_ menu: NSMenu, recents: RecentsStore) {
        menu.removeAllItems()
        for entry in recents.entries {
            let item = item(entry.name, #selector(MainWindowController.openRecentRepository(_:)))
            item.representedObject = entry.path
            item.toolTip = entry.path
            item.subtitle = entry.path
            item.isEnabled = !recents.missingPaths.contains(entry.path)
            menu.addItem(item)
        }
        if !recents.entries.isEmpty { menu.addItem(.separator()) }
        menu.addItem(item("Clear Menu", #selector(MainWindowController.clearRecentRepositories(_:))))
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Jit Help", AppSelectors.showHelp, "?"))
        return menu
    }
}

/// Repository ▸ actions through `NSWorkspace` (never shell commands; paths passed as URLs).
@MainActor
public enum RepositoryActions {
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public static func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration())
    }

    public static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
