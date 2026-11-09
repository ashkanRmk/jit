import AppKit
import Foundation
import Testing

@testable import Features

/// P6.9 (ADR-0044): one registry for menus and palette; no shortcut conflicts; no overridden system shortcuts.
@MainActor @Suite(.serialized) struct CommandRegistryTests {
    final class NoopDelegate: NSObject, NSMenuDelegate {}

    static func builtMenu() -> NSMenu {
        _ = NSApplication.shared
        let delegate = NoopDelegate()
        return withExtendedLifetime(delegate) { MainMenu.build(recentsDelegate: delegate, windowDelegate: delegate) }
    }

    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    @Test func idsAreUnique() {
        let ids = CommandRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// MenuPaletteParityTests: every actionable menu item is a registry command and vice versa; every palette
    /// command is a menu item (so palette and menus cannot disagree).
    @Test func menuAndRegistryAreTheSameCommands() {
        let items = Self.allItems(Self.builtMenu()).filter {
            $0.action != nil && !$0.isSeparatorItem && $0.submenu == nil
        }
        let menuIDs = Set(items.compactMap(\.identifier?.rawValue))
        let registryIDs = Set(CommandRegistry.all.map(\.id))
        #expect(menuIDs == registryIDs)
        // Items without an identifier are only the dynamic lists (recents, tabs, profiles) — none at build time.
        let unidentified = items.filter { $0.identifier == nil }.map(\.title)
        #expect(unidentified.isEmpty, "menu items outside the registry: \(unidentified)")
        for command in CommandRegistry.all where command.inPalette {
            let item = items.first { $0.identifier?.rawValue == command.id }
            #expect(item?.action == command.action, "\(command.id)")
            #expect(item?.title == command.title, "\(command.id)")
            #expect(item?.isHidden == false, "\(command.id) is in the palette but hidden in menus")
        }
    }

    /// ShortcutConflictTests: a key equivalent belongs to one action (hidden alternates share their action).
    @Test func noShortcutConflicts() {
        var owners: [String: Selector] = [:]
        for command in CommandRegistry.all {
            guard let key = command.shortcutKey else { continue }
            if let owner = owners[key] {
                #expect(owner == command.action, "\(command.shortcutGlyphs) used by \(owner) and \(command.action)")
            }
            owners[key] = command.action
        }
    }

    /// System shortcuts keep their standard meaning (⌘Q, ⌘H, ⌘M, ⌘,, text editing).
    @Test func standardShortcutsAreNotOverridden() {
        let standard: [String: Selector] = [
            "q": #selector(NSApplication.terminate(_:)), "h": #selector(NSApplication.hide(_:)),
            "m": #selector(NSWindow.performMiniaturize(_:)), ",": CommandRegistry.showSettings,
            "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
            "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:")),
        ]
        for command in CommandRegistry.all where command.modifiers == .command {
            if let expected = standard[command.key] {
                #expect(command.action == expected, "⌘\(command.key.uppercased()) must stay standard")
            }
        }
        #expect(CommandRegistry.all.contains { $0.key == "k" && $0.modifiers == .command })  // ⌘K palette
    }

    @Test func shortcutGlyphs() {
        #expect(CommandRegistry.command("file.reopenTab")?.shortcutGlyphs == "⇧⌘T")
        #expect(CommandRegistry.command("view.inspector")?.shortcutGlyphs == "⌥⌘0")
        #expect(CommandRegistry.command("window.nextTab")?.shortcutGlyphs == "⌃⇥")
        #expect(CommandRegistry.command("repo.fetch")?.shortcutGlyphs == "")
    }

    @Test func paletteHidesSystemOnlyItems() {
        let palette = Set(CommandRegistry.all.filter(\.inPalette).map(\.id))
        #expect(!palette.contains("app.quit"))
        #expect(!palette.contains("window.nextTabAlt"))
        #expect(!palette.contains("view.commandPalette"))
        #expect(palette.contains("repo.push"))
    }
}
