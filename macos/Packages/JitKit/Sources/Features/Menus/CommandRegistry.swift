import AppKit
import Services

/// The one command registry (ADR-0044): the main menu is built from it, and the command palette lists it, so
/// menus and palette can never disagree. Each command is a first-responder action; enabled state comes from the
/// responder's `validateMenuItem(_:)` and the disabled reason from `CommandAvailability`.
public struct JitCommand: Sendable, Identifiable, Hashable {
    public enum Menu: String, Sendable, CaseIterable {
        case app = "Jit", file = "File", edit = "Edit", view = "View", repository = "Repository"
        case branch = "Branch", window = "Window", help = "Help"
    }

    /// Stable identifier, also the menu item's `identifier` (parity tests).
    public let id: String
    public let title: String
    public let menu: Menu
    /// Path inside the menu for nested items (e.g. ["Find"], ["Appearance"]).
    public let submenu: [String]
    public let action: Selector
    public let key: String
    public let modifiers: NSEvent.ModifierFlags
    /// Separator group inside its menu; a change of group inserts a separator.
    public let group: Int
    public let representedObject: String?
    /// SF Symbol for the palette row.
    public let symbol: String
    /// Hidden key-equivalent alternates (⌘⇧] / ⌘⇧[) are menu-only.
    public let isHiddenAlternate: Bool
    /// System items (Hide, Quit, Services…) are menu-only.
    public let inPalette: Bool
    /// Extra words the palette matches (lower weight).
    public let keywords: String

    init(
        _ id: String, _ title: String, _ menu: Menu, _ action: Selector, key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command, group: Int = 0, submenu: [String] = [],
        represented: String? = nil, symbol: String = "command", hiddenAlternate: Bool = false,
        inPalette: Bool = true, keywords: String = ""
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.submenu = submenu
        self.action = action
        self.key = key
        self.modifiers = key.isEmpty ? [] : modifiers
        self.group = group
        self.representedObject = represented
        self.symbol = symbol
        self.isHiddenAlternate = hiddenAlternate
        self.inPalette = inPalette && !hiddenAlternate
        self.keywords = keywords
    }

    /// Palette title: "Appearance: Dark", "Find: Find Next".
    public var paletteTitle: String {
        guard let parent = submenu.last, parent != "Find" else { return title }
        return "\(parent): \(title)"
    }

    /// Display glyphs for the shortcut (⌃⌥⇧⌘ + key), or "" when none.
    public var shortcutGlyphs: String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        let shifted =
            modifiers.contains(.shift) || (key.count == 1 && key.uppercased() == key && key.lowercased() != key)
        if shifted { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let glyph: String =
            switch key {
            case "\r": "↩"
            case "\t": "⇥"
            case "\u{F700}": "↑"
            case "\u{F701}": "↓"
            case "\u{F702}": "←"
            case "\u{F703}": "→"
            case "}": "]"
            case "{": "["
            case " ": "Space"
            default: key.uppercased()
            }
        return text + glyph
    }

    /// Normalized key equivalent for conflict checks: lowercased key + modifiers (shift folded in for capitals).
    public var shortcutKey: String? {
        guard !key.isEmpty else { return nil }
        var mods = modifiers
        if key.count == 1, key.uppercased() == key, key.lowercased() != key { mods.insert(.shift) }
        let base: String =
            switch key {
            case "}": "]"
            case "{": "["
            default: key.lowercased()
            }
        return "\(mods.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)-\(base)"
    }

    public static func == (lhs: JitCommand, rhs: JitCommand) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Why a command is disabled, in the palette's words ("No upstream configured"). Implemented by responders.
@MainActor
@objc public protocol CommandAvailability {
    func disabledReason(for action: Selector) -> String?
}

public enum CommandRegistry {
    // Selectors implemented by the app delegate.
    static let showSettings = Selector(("showSettings:"))
    static let setAppearance = Selector(("setAppearance:"))
    static let showHelp = Selector(("showJitHelp:"))
    static let showAbout = Selector(("showAboutJit:"))
    static let showAcknowledgements = Selector(("showAcknowledgements:"))
    static let checkForUpdates = Selector(("checkForUpdates:"))
    static let toggleCommandPalette = Selector(("toggleCommandPalette:"))

    /// Every command, in menu order.
    @MainActor public static let all: [JitCommand] = build()

    @MainActor public static func command(_ id: String) -> JitCommand? { all.first { $0.id == id } }

    @MainActor
    private static func build() -> [JitCommand] {
        typealias C = JitCommand
        typealias W = MainWindowController
        var list: [C] = [
            // Jit
            C(
                "app.about", "About Jit", .app, showAbout, group: 0,
                symbol: "info.circle"),
            C(
                "app.checkForUpdates", "Check for Updates…", .app, checkForUpdates, group: 0,
                symbol: "arrow.down.circle", keywords: "upgrade version release what's new change log changelog"),
            C(
                "app.settings", "Settings…", .app, showSettings, key: ",", group: 1, symbol: "gearshape",
                keywords: "preferences"),
            C("app.hide", "Hide Jit", .app, #selector(NSApplication.hide(_:)), key: "h", group: 3, inPalette: false),
            C(
                "app.hideOthers", "Hide Others", .app, #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                [.command, .option], group: 3, inPalette: false),
            C(
                "app.showAll", "Show All", .app, #selector(NSApplication.unhideAllApplications(_:)), group: 3,
                inPalette: false),
            C(
                "app.quit", "Quit Jit", .app, #selector(NSApplication.terminate(_:)), key: "q", group: 4,
                inPalette: false),
            // File
            C("file.newTab", "New Tab", .file, #selector(W.newTab(_:)), key: "t", symbol: "plus.square"),
            C("file.open", "Open Repository…", .file, #selector(W.openRepository(_:)), key: "o", symbol: "folder"),
            C(
                "file.clone", "Clone Repository…", .file, #selector(W.cloneRepository(_:)), key: "N",
                symbol: "square.and.arrow.down"),
            C(
                "file.browse", "Browse Remote Repositories…", .file, #selector(W.browseRemoteRepositories(_:)),
                symbol: "network", keywords: "github gitlab"),
            C(
                "file.closeTab", "Close Tab", .file, #selector(W.closeTab(_:)), key: "w", group: 1,
                symbol: "xmark.square"),
            C(
                "file.reopenTab", "Reopen Closed Tab", .file, #selector(W.reopenClosedTab(_:)), key: "T", group: 1,
                symbol: "arrow.uturn.backward.square"),
            C(
                "file.closeWindow", "Close Window", .file, #selector(NSWindow.performClose(_:)), key: "W", group: 1,
                inPalette: false),
            // Edit
            C("edit.undo", "Undo", .edit, Selector(("undo:")), key: "z", inPalette: false),
            C("edit.redo", "Redo", .edit, Selector(("redo:")), key: "Z", inPalette: false),
            C("edit.cut", "Cut", .edit, #selector(NSText.cut(_:)), key: "x", group: 1, inPalette: false),
            C("edit.copy", "Copy", .edit, #selector(NSText.copy(_:)), key: "c", group: 1, inPalette: false),
            C("edit.paste", "Paste", .edit, #selector(NSText.paste(_:)), key: "v", group: 1, inPalette: false),
            C("edit.delete", "Delete", .edit, #selector(NSText.delete(_:)), group: 1, inPalette: false),
            C(
                "edit.selectAll", "Select All", .edit, #selector(NSText.selectAll(_:)), key: "a", group: 1,
                inPalette: false),
            C(
                "edit.find", "Find…", .edit, #selector(GraphViewController.jitFind(_:)), key: "f", group: 2,
                submenu: ["Find"], symbol: "magnifyingglass", keywords: "search commits"),
            C(
                "edit.findNext", "Find Next", .edit, #selector(GraphViewController.jitFindNext(_:)), key: "g", group: 2,
                submenu: ["Find"], symbol: "chevron.down"),
            C(
                "edit.findPrevious", "Find Previous", .edit, #selector(GraphViewController.jitFindPrevious(_:)),
                key: "G", group: 2, submenu: ["Find"], symbol: "chevron.up"),
            C(
                "edit.findInTabs", "Find in Open Tabs…", .edit, #selector(W.findInOpenTabs(_:)), key: "F", group: 2,
                submenu: ["Find"], symbol: "rectangle.stack", keywords: "search tabs repositories switch"),
            C(
                "edit.goToLine", "Go to Line…", .edit, #selector(DiffViewController.diffGoToLine(_:)), key: "l",
                group: 3, submenu: ["Find"], symbol: "arrow.right.to.line"),
            // View
            C(
                "view.commandPalette", "Command Palette…", .view, toggleCommandPalette, key: "k", symbol: "command",
                inPalette: false),
            C(
                "view.sidebar", "Show Sidebar", .view, #selector(W.toggleSidebar(_:)), key: "s", [.command, .control],
                group: 1, symbol: "sidebar.left"),
            // ⌘B as well (owner request): the menu shows the standard ⌃⌘S.
            C(
                "view.sidebarAlt", "Show Sidebar", .view, #selector(W.toggleSidebar(_:)), key: "b", group: 1,
                hiddenAlternate: true),
            C(
                "view.inspector", "Show Inspector", .view, #selector(W.toggleInspector(_:)), key: "0",
                [.command, .option], group: 1, symbol: "sidebar.right"),
            C(
                "view.focusPrevious", "Focus Previous Pane", .view, #selector(W.focusPreviousPane(_:)),
                key: "\u{F702}", [.command, .option], group: 1, symbol: "rectangle.lefthalf.inset.filled"),
            C(
                "view.focusNext", "Focus Next Pane", .view, #selector(W.focusNextPane(_:)), key: "\u{F703}",
                [.command, .option], group: 1, symbol: "rectangle.righthalf.inset.filled"),
        ]
        for (index, value) in PreferencesStore.Appearance.allCases.enumerated() {
            list.append(
                C(
                    "view.appearance.\(value.rawValue)", value.title, .view, setAppearance, group: 2,
                    submenu: ["Appearance"], represented: value.rawValue,
                    symbol: ["circle.lefthalf.filled", "sun.max", "moon"][min(index, 2)], keywords: "theme"))
        }
        for value in PreferencesStore.GraphDensity.allCases {
            list.append(
                C(
                    "view.density.\(value.rawValue)", value.title, .view,
                    #selector(GraphViewController.setGraphDensity(_:)),
                    group: 2, submenu: ["Graph Density"], represented: value.rawValue, symbol: "list.dash",
                    keywords: "row height"))
        }
        list += [
            C(
                "view.commandBarLabels", "Show Labels", .view,
                #selector(GraphViewController.toggleCommandBarLabels(_:)),
                group: 2, submenu: ["Command Bar"], symbol: "textformat"),
            C(
                "view.focusDiff", "Close Diff", .view, #selector(DiffViewController.toggleFocusDiff(_:)), key: "\r",
                [.command, .option], group: 3, symbol: "xmark"),
            C(
                "view.blame", "Blame File", .view, #selector(DiffViewController.showBlame(_:)), key: "B", group: 3,
                symbol: "person.text.rectangle"),
            C(
                "view.nextChange", "Next Change", .view, #selector(DiffViewController.diffNextChange(_:)),
                key: "\u{F701}", .option, group: 3, symbol: "arrow.down"),
            C(
                "view.previousChange", "Previous Change", .view, #selector(DiffViewController.diffPreviousChange(_:)),
                key: "\u{F700}", .option, group: 3, symbol: "arrow.up"),
            C(
                "view.textSize.larger", "Larger Code Text", .view, #selector(W.increaseCodeTextSize(_:)), key: "+",
                group: 4, symbol: "textformat.size.larger", keywords: "zoom font"),
            C(
                "view.textSize.largerAlt", "Larger Code Text", .view, #selector(W.increaseCodeTextSize(_:)), key: "=",
                group: 4, hiddenAlternate: true),
            C(
                "view.textSize.smaller", "Smaller Code Text", .view, #selector(W.decreaseCodeTextSize(_:)), key: "-",
                group: 4, symbol: "textformat.size.smaller", keywords: "zoom font"),
            C(
                "view.textSize.reset", "Default Code Text Size", .view, #selector(W.resetCodeTextSize(_:)), key: "0",
                group: 4, symbol: "textformat.size", keywords: "zoom font"),
            C(
                "view.fullScreen", "Enter Full Screen", .view, #selector(NSWindow.toggleFullScreen(_:)), key: "f",
                [.command, .control], group: 5, inPalette: false),
            // Repository
            C(
                "repo.refresh", "Refresh", .repository, #selector(W.refreshRepository(_:)), key: "r",
                symbol: "arrow.clockwise"),
            C(
                "repo.fetch", "Fetch", .repository, #selector(W.fetchRepository(_:)), group: 1,
                symbol: "arrow.down.circle"),
            C(
                "repo.fetchAll", "Fetch All Remotes", .repository, #selector(W.fetchAllRemotes(_:)), group: 1,
                symbol: "arrow.down.circle"),
            C("repo.pull", "Pull", .repository, #selector(W.pullRepository(_:)), group: 1, symbol: "arrow.down"),
            C(
                "repo.pullMerge", "Pull with Merge", .repository, #selector(W.pullWithMerge(_:)), group: 1,
                symbol: "arrow.triangle.merge"),
            C(
                "repo.pullRebase", "Pull with Rebase", .repository, #selector(W.pullWithRebase(_:)), group: 1,
                symbol: "arrow.triangle.branch"),
            C("repo.push", "Push", .repository, #selector(W.pushRepository(_:)), group: 1, symbol: "arrow.up"),
            C(
                "repo.stash", "Stash Changes…", .repository, #selector(W.stashChanges(_:)), key: "s",
                [.command, .option], group: 2, symbol: "tray.and.arrow.down"),
            C(
                "repo.popStash", "Pop Latest Stash", .repository, #selector(W.popStash(_:)), group: 2,
                symbol: "tray.and.arrow.up"),
            C(
                "repo.resolve", "Resolve Conflicts", .repository, #selector(W.resolveConflicts(_:)), group: 3,
                symbol: "exclamationmark.triangle"),
            C(
                "repo.continue", "Continue Operation", .repository, #selector(W.continueOperation(_:)), group: 3,
                symbol: "play"),
            C(
                "repo.abort", "Abort Operation…", .repository, #selector(W.abortOperation(_:)), group: 3,
                symbol: "stop"),
            C("repo.remotes", "Remotes…", .repository, #selector(W.showRemotes(_:)), group: 4, symbol: "server.rack"),
            C(
                "repo.profileSwitcher", "Show Profile Switcher", .repository, #selector(W.showProfileSwitcher(_:)),
                key: "p", [.command, .control], group: 4, symbol: "person.crop.circle", keywords: "identity account"),
            C(
                "repo.activity", "Show Activity", .repository, #selector(W.showActivity(_:)), key: "a",
                [.command, .option], group: 4, symbol: "list.bullet.rectangle", keywords: "operations log progress"),
            C(
                "repo.reveal", "Reveal in Finder", .repository, #selector(W.revealRepositoryInFinder(_:)), key: "r",
                [.command, .option], group: 5, symbol: "folder"),
            C(
                "repo.terminal", "Open in Terminal", .repository, #selector(W.openRepositoryInTerminal(_:)), key: "t",
                [.command, .option], group: 5, symbol: "terminal"),
            C(
                "repo.copyPath", "Copy Repository Path", .repository, #selector(W.copyRepositoryPath(_:)), key: "c",
                [.command, .option], group: 5, symbol: "doc.on.doc"),
            // Branch
            C("branch.new", "New Branch…", .branch, #selector(W.newBranch(_:)), symbol: "plus"),
            // Window
            C(
                "window.minimize", "Minimize", .window, #selector(NSWindow.performMiniaturize(_:)), key: "m",
                inPalette: false),
            C("window.zoom", "Zoom", .window, #selector(NSWindow.performZoom(_:)), inPalette: false),
            C(
                "window.nextTab", "Show Next Tab", .window, #selector(W.selectNextTab(_:)), key: "\t", .control,
                group: 1, symbol: "arrow.right.square"),
            C(
                "window.previousTab", "Show Previous Tab", .window, #selector(W.selectPreviousTab(_:)), key: "\t",
                [.control, .shift], group: 1, symbol: "arrow.left.square"),
            C(
                "window.nextTabAlt", "Show Next Tab", .window, #selector(W.selectNextTab(_:)), key: "}", group: 1,
                hiddenAlternate: true),
            C(
                "window.previousTabAlt", "Show Previous Tab", .window, #selector(W.selectPreviousTab(_:)), key: "{",
                group: 1, hiddenAlternate: true),
            C(
                "window.moveTabLeft", "Move Tab Left", .window, #selector(W.moveTabLeft(_:)), group: 1,
                symbol: "arrow.left.to.line"),
            C(
                "window.moveTabRight", "Move Tab Right", .window, #selector(W.moveTabRight(_:)), group: 1,
                symbol: "arrow.right.to.line"),
            C(
                "window.bringAllToFront", "Bring All to Front", .window, #selector(NSApplication.arrangeInFront(_:)),
                group: 2, inPalette: false),
            // Help
            C("help.help", "Jit Help", .help, showHelp, key: "?", symbol: "questionmark.circle"),
            C(
                "help.acknowledgements", "Acknowledgements", .help, showAcknowledgements, group: 1,
                symbol: "doc.text", keywords: "license gpl git source"),
        ]
        return list
    }
}
