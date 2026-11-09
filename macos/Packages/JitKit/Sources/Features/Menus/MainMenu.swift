import AppKit
import Services

/// The main menu (design §3.6), built from `CommandRegistry` (ADR-0044). Only menus with working items exist.
/// Items target the first responder; `MainWindowController` and the app delegate implement them.
@MainActor
public enum MainMenu {
    /// Selectors implemented by the app delegate.
    public enum AppSelectors {
        public static let showSettings = CommandRegistry.showSettings
        public static let setAppearance = CommandRegistry.setAppearance
        public static let showHelp = CommandRegistry.showHelp
    }

    public static func build(recentsDelegate: any NSMenuDelegate, windowDelegate: any NSMenuDelegate) -> NSMenu {
        let main = NSMenu(title: "Main")
        for menuKind in JitCommand.Menu.allCases {
            let menu = NSMenu(title: menuKind.rawValue)
            var submenus: [String: NSMenu] = [:]
            var lastGroup: Int?
            for command in CommandRegistry.all where command.menu == menuKind {
                if let lastGroup, lastGroup != command.group,
                    command.submenu.isEmpty || submenus[command.submenu[0]] == nil
                {
                    menu.addItem(.separator())
                }
                lastGroup = command.group
                let target: NSMenu
                if let name = command.submenu.first {
                    if let existing = submenus[name] {
                        target = existing
                    } else {
                        let holder = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                        let sub = NSMenu(title: name)
                        holder.submenu = sub
                        menu.addItem(holder)
                        submenus[name] = sub
                        target = sub
                    }
                    // A group change inside a submenu (Find ▸ Go to Line…) is a separator there.
                    if let previous = target.items.last, previous.tag != command.group, !previous.isSeparatorItem {
                        target.addItem(.separator())
                    }
                } else {
                    target = menu
                }
                target.addItem(item(for: command))
                anchor(after: command.id, in: menu, recentsDelegate: recentsDelegate)
            }
            if menuKind == .window {
                menu.delegate = windowDelegate
                NSApp.windowsMenu = menu
            }
            if menuKind == .help { NSApp.helpMenu = menu }
            main.addItem(submenu(menu))
        }
        return main
    }

    /// A menu item for a registry command (identifier = command id, tag = separator group).
    public static func item(for command: JitCommand) -> NSMenuItem {
        let entry = NSMenuItem(title: command.title, action: command.action, keyEquivalent: command.key)
        entry.keyEquivalentModifierMask = command.modifiers
        entry.identifier = NSUserInterfaceItemIdentifier(command.id)
        entry.representedObject = command.representedObject
        entry.tag = command.group
        if command.isHiddenAlternate {
            entry.isHidden = true
            entry.allowsKeyEquivalentWhenHidden = true
        }
        return entry
    }

    /// Dynamic submenus that are not commands, placed after a fixed registry entry.
    private static func anchor(after id: String, in menu: NSMenu, recentsDelegate: any NSMenuDelegate) {
        switch id {
        case "app.settings":
            menu.addItem(.separator())
            let services = item("Services", nil)
            let servicesMenu = NSMenu(title: "Services")
            services.submenu = servicesMenu
            NSApp.servicesMenu = servicesMenu
            menu.addItem(services)
        case "file.browse":
            let recent = item("Open Recent", nil)
            let recentMenu = NSMenu(title: "Open Recent")
            recentMenu.delegate = recentsDelegate
            recent.submenu = recentMenu
            menu.addItem(recent)
        case "repo.remotes":
            let profile = item("Profile", nil)
            let profileMenu = NSMenu(title: "Profile")
            profileMenu.delegate = ProfileMenu.shared
            profile.submenu = profileMenu
            menu.addItem(profile)
        case "repo.copyPath":
            menu.addItem(.separator())
            let discarded = item("Recently Discarded", nil)
            let discardedMenu = NSMenu(title: "Recently Discarded")
            discardedMenu.delegate = RecentlyDiscardedMenu.shared
            discarded.submenu = discardedMenu
            menu.addItem(discarded)
        default: break
        }
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

    /// Tab items; the tab list itself is appended by `windowMenuNeedsUpdate`.
    static let tabListTag = 7_001

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

/// Repository ▸ Profile: every profile (check mark on the active one) so switching works from the keyboard and
/// VoiceOver without the popover (design §3.1), plus Manage Profiles… (the switcher itself is ⌃⌘P in Repository). Built on demand.
@MainActor
public final class ProfileMenu: NSObject, NSMenuDelegate {
    public static let shared = ProfileMenu()
    /// Set by the window controller.
    public var store: ProfileStore?

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = store?.profiles ?? []
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "No Profiles", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for profile in profiles {
            let item = NSMenuItem(
                title: profile.displayName, action: #selector(MainWindowController.selectProfile(_:)), keyEquivalent: ""
            )
            item.representedObject = profile.id
            item.state = profile.id == store?.activeProfileID ? .on : .off
            item.toolTip = "\(profile.author.name) <\(profile.author.email)>"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Manage Profiles…", action: Selector(("showSettingsProfiles:")), keyEquivalent: ""))
    }
}
