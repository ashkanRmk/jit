import AppKit
import DesignSystem
import Foundation
import SwiftUI
import Testing

/// Offscreen snapshot harness (P6.11, ADR-0040): renders a view in an offscreen window at a fixed size,
/// 2× scale and forced appearance, and compares it with a reference PNG in `__Snapshots__/`.
///
/// - Record: `UPDATE_SNAPSHOTS=1 swift test --package-path macos/Packages/JitKit --filter SnapshotTests`
/// - Tolerance: a pixel differs when any channel differs by more than 6/255; a snapshot fails when more than
///   0.1 % of pixels differ (anti-aliasing noise stays below that; a 1-pt shift does not — `harnessDetects…`).
/// - References are pinned to the macOS version in `__Snapshots__/os-version.txt`; on another version the
///   suite is disabled with that reason (never silently passed).
/// - Liquid Glass is composited by the window server and is not captured offscreen: chrome is snapshotted in
///   its opaque (Reduce Transparency) rendering, and live glass is reviewed with real window captures
///   (`scripts/testing/screenshot.sh`, visual-review.md).
@MainActor
enum Snapshot {
    enum Variant: String, CaseIterable {
        case light, dark
        case lightHighContrast = "light-ic"
        case darkHighContrast = "dark-ic"
        case lightOpaque = "light-rt"
        case darkOpaque = "dark-rt"

        var appearance: NSAppearance? {
            switch self {
            case .light, .lightOpaque: NSAppearance(named: .aqua)
            case .dark, .darkOpaque: NSAppearance(named: .darkAqua)
            case .lightHighContrast: NSAppearance(named: .accessibilityHighContrastAqua)
            case .darkHighContrast: NSAppearance(named: .accessibilityHighContrastDarkAqua)
            }
        }

        var opaqueChrome: Bool { self == .lightOpaque || self == .darkOpaque }
    }

    nonisolated static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
    static let scale: CGFloat = 2
    static let channelTolerance = 6
    static let maxDifferingFraction = 0.001
    nonisolated static var recording: Bool { ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] != nil }

    nonisolated static var currentOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    nonisolated static var pinnedOS: String? {
        (try? String(contentsOf: directory.appendingPathComponent("os-version.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether references match this macOS version (or we are recording).
    nonisolated static var isComparable: Bool { recording || pinnedOS == currentOS }

    /// Renders `view` at `size` (points) in an offscreen window with `variant`'s appearance.
    static func render(_ view: NSView, size: NSSize, variant: Variant) -> NSBitmapImageRep {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.appearance = variant.appearance
        view.appearance = variant.appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        // Two passes: SwiftUI settles observation-driven updates after the first layout.
        for _ in 0..<2 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32)!
        rep.size = size
        NSAppearance.current = variant.appearance
        view.cacheDisplay(in: view.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    /// Hosts a SwiftUI view with the variant's opaque-chrome environment.
    static func host<V: View>(_ view: V, variant: Variant) -> NSView {
        let dark = [.dark, .darkOpaque, .darkHighContrast].contains(variant)
        let hosting = NSHostingView(
            // Opaque backdrop (popover/panel content has none of its own; alpha edges are not stable to compare).
            rootView: view.background(ColorToken.surfaceChromeOpaque.color)
                .environment(\.jitOpaqueChrome, variant.opaqueChrome)
                .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        hosting.appearance = variant.appearance
        return hosting
    }

    /// Compares (or records) `name-variant.png`; returns a failure message or nil.
    static func verify(_ rep: NSBitmapImageRep, name: String, variant: Variant) -> String? {
        let file = directory.appendingPathComponent("\(name)-\(variant.rawValue).png")
        guard let data = rep.representation(using: .png, properties: [:]) else { return "could not encode" }
        if recording {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file)
            try? Data(currentOS.utf8).write(to: directory.appendingPathComponent("os-version.txt"))
            return nil
        }
        guard let referenceData = try? Data(contentsOf: file), let reference = NSBitmapImageRep(data: referenceData)
        else {
            return "missing reference \(file.lastPathComponent) (record with UPDATE_SNAPSHOTS=1)"
        }
        let (fraction, diff) = difference(rep, reference)
        guard fraction > maxDifferingFraction else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("jit-snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let actual = out.appendingPathComponent("\(name)-\(variant.rawValue)-actual.png")
        let diffFile = out.appendingPathComponent("\(name)-\(variant.rawValue)-diff.png")
        try? data.write(to: actual)
        try? diff?.representation(using: .png, properties: [:])?.write(to: diffFile)
        return String(
            format: "%@-%@: %.3f%% of pixels differ (limit %.3f%%); actual %@, diff %@, reference %@", name,
            variant.rawValue, fraction * 100, maxDifferingFraction * 100, actual.path, diffFile.path, file.path)
    }

    /// Fraction of differing pixels and a diff image (differing pixels in red over a dimmed copy).
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Double, NSBitmapImageRep?) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return (1, nil) }
        // Normalize both to 8-bit RGBA so byte layouts match (PNG decoding may change the format).
        func rgba(_ rep: NSBitmapImageRep) -> [UInt8] {
            let width = rep.pixelsWide
            let height = rep.pixelsHigh
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            bytes.withUnsafeMutableBytes { buffer in
                guard let image = rep.cgImage,
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let pa = rgba(a)
        let pb = rgba(b)
        let diff = a.copy() as? NSBitmapImageRep
        var differing = 0
        var index = 0
        while index < pa.count {
            var differs = false
            for channel in 0..<4 where abs(Int(pa[index + channel]) - Int(pb[index + channel])) > channelTolerance {
                differs = true
            }
            if differs {
                differing += 1
                let pixel = index / 4
                var red = [255, 0, 0, 255]
                diff?.setPixel(&red, atX: pixel % a.pixelsWide, y: a.pixelsHigh - 1 - pixel / a.pixelsWide)
            }
            index += 4
        }
        return (Double(differing) / Double(a.pixelsWide * a.pixelsHigh), diff)
    }
}
