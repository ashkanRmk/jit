import AppKit
import SwiftUI

extension Variant {
    /// The variant AppKit is drawing with right now (light/dark × Increase Contrast).
    public static func resolve(_ appearance: NSAppearance) -> Variant {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return resolve(
            bestMatch: match,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    /// `NSAppearance(named:)` only yields the high-contrast names while the system setting is on, so
    /// the setting itself is consulted too.
    static func resolve(bestMatch: NSAppearance.Name?, increaseContrast: Bool) -> Variant {
        switch bestMatch {
        case .accessibilityHighContrastAqua: return .lightHighContrast
        case .accessibilityHighContrastDarkAqua: return .darkHighContrast
        case .darkAqua: return increaseContrast ? .darkHighContrast : .dark
        default: return increaseContrast ? .lightHighContrast : .light
        }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

extension ColorSpec {
    /// A dynamic `NSColor` that re-resolves whenever the drawing appearance changes.
    public func dynamicColor(named name: String) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            self.value(for: .resolve(appearance)).nsColor
        }
    }
}

@MainActor private var colorCache: [String: NSColor] = [:]

@MainActor private func cachedColor(_ name: String, _ spec: ColorSpec) -> NSColor {
    if let color = colorCache[name] { return color }
    let color = spec.dynamicColor(named: "jit." + name)
    colorCache[name] = color
    return color
}

extension ColorToken {
    @MainActor public var nsColor: NSColor { cachedColor(rawValue, spec) }
    @MainActor public var color: Color { Color(nsColor: nsColor) }
}

extension LaneColor {
    @MainActor public var nsColor: NSColor { cachedColor("lane.\(rawValue)", spec) }
    @MainActor public var color: Color { Color(nsColor: nsColor) }
}

extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.token(.textSecondary))`
    @MainActor public static func token(_ token: ColorToken) -> Color { token.color }
}
