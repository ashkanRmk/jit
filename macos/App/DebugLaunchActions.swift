#if DEBUG
    import AppKit
    import Features
    import SwiftUI

    /// Debug-only launch arguments used for repeatable manual checks and design screenshots:
    /// - `-JitAppearance light|dark` (AppDelegate) forces the appearance. (`-JitOpen <path>` works in all builds.)
    /// - `-JitShowGallery YES`: open the Design System gallery (`-JitGallerySection <name>` picks a section).
    /// - `-JitShowDropOverlay YES`: show the folder drop overlay.
    /// - `-JitShowCommandPalette YES` (+ `-JitPaletteQuery <text>`): open the ⌘K palette.
    /// - `-JitShowSettings general|profiles|accounts|network|git`, `-JitShowProfilePopover YES`, `-JitShowRepositoryBrowser YES`, `-JitShowProfileEditor YES`: open those
    ///   surfaces for screenshots.
    /// - `-JitSnapshot <file.png>` (+ optional `-JitSnapshotWindow <title or id>`): after the UI settles, render
    ///   the window's view hierarchy to a PNG and quit. This draws opaque content exactly; Liquid Glass is
    ///   composited by the window server and only approximated — prefer real captures
    ///   (`scripts/testing/screenshot.sh`) where Screen Recording is allowed.
    @MainActor
    enum DebugLaunchActions {
        private static var galleryWindow: NSWindow?

        /// `-JitTabSequence 2,3,1`: selects those tabs (1-based) one every 2.5 s and prints where each toolbar
        /// item sits (window x), for checking the toolbar layout across tab kinds without driving the keyboard.
        /// A step that is a path (`2,/path/to/repo,1`) opens that repository as the New Tab page would.
        private static func runTabSequence(_ sequence: String, model: AppModel) {
            let steps = sequence.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // `-JitTabSequenceInterval <seconds>` (default 2.5): small values hammer tab switching.
            let saved = UserDefaults.standard.double(forKey: "JitTabSequenceInterval")
            let interval = saved > 0 ? saved : 2.5
            for (step, token) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + interval * Double(step)) {
                    if token.hasPrefix("/") {
                        model.open(URL(fileURLWithPath: token))
                    } else if let index = Int(token), model.tabs.indices.contains(index - 1) {
                        model.select(model.tabs[index - 1].id)
                    } else {
                        return
                    }
                    let index = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + min(1, interval / 2)) {
                        let items = NSApp.mainWindow?.toolbar?.items ?? NSApp.windows.first?.toolbar?.items ?? []
                        let layout = items.map { item -> String in
                            guard let view = item.view, view.window != nil else { return item.itemIdentifier.rawValue }
                            let frame = view.convert(view.bounds, to: nil)
                            return "\(item.itemIdentifier.rawValue)@\(Int(frame.minX))-\(Int(frame.maxX))"
                        }
                        print("tab-sequence step=\(step + 1) tab=\(index) \(layout.joined(separator: " "))")
                        fflush(stdout)
                    }
                }
            }
        }

        static func run(model: AppModel, controller: MainWindowController?) {
            let defaults = UserDefaults.standard
            NSApp.mainMenu?.addItem(debugMenu())
            if let sequence = defaults.string(forKey: "JitTabSequence") { runTabSequence(sequence, model: model) }
            if defaults.bool(forKey: "JitShowGallery") { showGallery() }
            if let pane = defaults.string(forKey: "JitShowSettings") {
                let selector: Selector =
                    switch pane {
                    case "profiles": Selector(("showSettingsProfiles:"))
                    case "accounts": Selector(("showSettingsAccounts:"))
                    case "network": Selector(("showSettingsNetwork:"))
                    case "git": Selector(("showSettingsGit:"))
                    default: Selector(("showSettings:"))
                    }
                NSApp.sendAction(selector, to: nil, from: nil)
            }
            if defaults.bool(forKey: "JitShowRepositoryBrowser") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.sendAction(
                        #selector(MainWindowController.browseRemoteRepositories(_:)), to: nil, from: nil)
                }
            }
            if defaults.bool(forKey: "JitShowProfilePopover") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.sendAction(#selector(MainWindowController.showProfileSwitcher(_:)), to: nil, from: nil)
                }
            }
            if defaults.bool(forKey: "JitShowProfileEditor") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller?.presentProfileEditor(nil, prefillFromGitConfig: false)
                }
            }
            if defaults.bool(forKey: "JitShowCommandPalette") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    controller?.toggleCommandPalette(nil)
                    if let query = defaults.string(forKey: "JitPaletteQuery") { controller?.setPaletteQuery(query) }
                }
            }
            if defaults.bool(forKey: "JitShowUpdates") {
                // `-JitShowUpdates YES` (+ `-JitUpdateCheck YES` to ask GitHub, `-JitUpdateCurrentVersion <v>`).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller?.presentUpdates(checkNow: defaults.bool(forKey: "JitUpdateCheck"))
                }
            }
            if defaults.bool(forKey: "JitShowDropOverlay") {
                controller?.showDropOverlayForScreenshot()
            }
            if let output = defaults.string(forKey: "JitSnapshot") {
                let delay = defaults.double(forKey: "JitSnapshotDelay")
                DispatchQueue.main.asyncAfter(deadline: .now() + (delay == 0 ? 2 : delay)) {
                    WindowSnapshot.write(windowTitled: defaults.string(forKey: "JitSnapshotWindow"), to: output)
                    NSApp.terminate(nil)
                }
            }
        }

        private static func debugMenu() -> NSMenuItem {
            let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Debug")
            let gallery = NSMenuItem(
                title: "Design System", action: #selector(DebugTarget.showGallery), keyEquivalent: "d")
            gallery.keyEquivalentModifierMask = [.command, .option]
            gallery.target = DebugTarget.shared
            menu.addItem(gallery)
            item.submenu = menu
            return item
        }

        static func showGallery() {
            if galleryWindow == nil {
                let host = NSHostingController(rootView: DesignSystemGallery().frame(minWidth: 900, minHeight: 600))
                let window = NSWindow(contentViewController: host)
                window.title = "Design System"
                window.identifier = NSUserInterfaceItemIdentifier("design-system")
                window.setContentSize(NSSize(width: 1180, height: 820))
                window.isReleasedWhenClosed = false
                galleryWindow = window
            }
            galleryWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    final class DebugTarget: NSObject {
        static let shared = DebugTarget()
        @objc func showGallery() { DebugLaunchActions.showGallery() }
    }

    @MainActor
    enum WindowSnapshot {
        static func write(windowTitled title: String?, to path: String) {
            let window = NSApp.windows.first { window in
                window.isVisible && !(window is NSPanel) && !window.title.isEmpty
                    && (title.map { window.title.contains($0) || (window.identifier?.rawValue.contains($0) ?? false) }
                        ?? true)
            }
            guard let frameView = window?.contentView?.superview else {
                FileHandle.standardError.write(Data("snapshot: no matching window\n".utf8))
                return
            }
            guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            print("snapshot: \(path)")
        }
    }
#endif
