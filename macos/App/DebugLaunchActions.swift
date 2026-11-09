#if DEBUG
    import AppKit
    import Features
    import SwiftUI

    /// Debug-only launch arguments used for repeatable manual checks and design screenshots:
    /// - `-JitAppearance light|dark` (AppDelegate) forces the appearance. (`-JitOpen <path>` works in all builds.)
    /// - `-JitShowGallery YES`: open the Design System gallery (`-JitGallerySection <name>` picks a section).
    /// - `-JitShowDropOverlay YES`: show the folder drop overlay.
    /// - `-JitShowSettings general|profiles|accounts|network`, `-JitShowProfilePopover YES`, `-JitShowRepositoryBrowser YES`, `-JitShowProfileEditor YES`: open those
    ///   surfaces for screenshots.
    /// - `-JitSnapshot <file.png>` (+ optional `-JitSnapshotWindow <title or id>`): after the UI settles, render
    ///   the window's view hierarchy to a PNG and quit. This draws opaque content exactly; Liquid Glass is
    ///   composited by the window server and only approximated — prefer real captures
    ///   (`scripts/testing/screenshot.sh`) where Screen Recording is allowed.
    @MainActor
    enum DebugLaunchActions {
        private static var galleryWindow: NSWindow?

        static func run(model: AppModel, controller: MainWindowController?) {
            let defaults = UserDefaults.standard
            NSApp.mainMenu?.addItem(debugMenu())
            if defaults.bool(forKey: "JitShowGallery") { showGallery() }
            if let pane = defaults.string(forKey: "JitShowSettings") {
                let selector: Selector =
                    switch pane {
                    case "profiles": Selector(("showSettingsProfiles:"))
                    case "accounts": Selector(("showSettingsAccounts:"))
                    case "network": Selector(("showSettingsNetwork:"))
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
