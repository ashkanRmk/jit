#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug-only launch arguments used for repeatable manual checks and design screenshots:
    /// - `-JitAppearance light|dark` (AppDelegate) forces the appearance. (`-JitOpen <path>` works in all builds.)
    /// - `-JitShowGallery YES`: open the Design System gallery (`-JitGallerySection <name>` picks a section).
    /// - `-JitSnapshot <file.png>` (+ optional `-JitSnapshotWindow <title or scene id>`): after the UI settles, render
    ///   the window's view hierarchy (including its frame view) to a PNG and quit. This draws the opaque
    ///   content exactly; Liquid Glass is composited by the window server and is only approximated, so
    ///   glass review needs real screen captures.
    struct DebugLaunchActions: ViewModifier {
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content.task {
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: "JitShowGallery") { openWindow(id: "design-system") }
                if let output = defaults.string(forKey: "JitSnapshot") {
                    try? await Task.sleep(for: .seconds(defaults.double(forKey: "JitSnapshotDelay").nonZero ?? 2))
                    WindowSnapshot.write(windowTitled: defaults.string(forKey: "JitSnapshotWindow"), to: output)
                    NSApp.terminate(nil)
                }
            }
        }
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

    extension Double {
        fileprivate var nonZero: Double? { self == 0 ? nil : self }
    }
#endif
