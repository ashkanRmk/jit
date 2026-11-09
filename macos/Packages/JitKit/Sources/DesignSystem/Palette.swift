import Foundation

/// An sRGB color value. Pure data, so contrast can be unit-tested without rendering.
public struct RGBA: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// `RGBA(0x21707A)`, optionally with an opacity.
    public init(_ hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func opacity(_ alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }

    /// This color composited over an opaque background.
    public func over(_ background: RGBA) -> RGBA {
        RGBA(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha),
            alpha: 1)
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio of `self` (composited over `background`) against `background`.
    public func contrast(against background: RGBA) -> Double {
        let foreground = over(background).relativeLuminance
        let back = background.relativeLuminance
        return (max(foreground, back) + 0.05) / (min(foreground, back) + 0.05)
    }
}

/// The four appearance variants every content color defines.
public enum Variant: CaseIterable, Sendable {
    case light
    case dark
    case lightHighContrast
    case darkHighContrast

    public var isDark: Bool { self == .dark || self == .darkHighContrast }
}

/// Light and dark values are designed independently (not inverted). High-contrast values default to
/// the regular ones unless a token needs a stronger variant.
public struct ColorSpec: Sendable, Hashable {
    public let light: RGBA
    public let dark: RGBA
    public let lightHighContrast: RGBA
    public let darkHighContrast: RGBA

    public init(light: RGBA, dark: RGBA, lightHighContrast: RGBA? = nil, darkHighContrast: RGBA? = nil) {
        self.light = light
        self.dark = dark
        self.lightHighContrast = lightHighContrast ?? light
        self.darkHighContrast = darkHighContrast ?? dark
    }

    public func value(for variant: Variant) -> RGBA {
        switch variant {
        case .light: light
        case .dark: dark
        case .lightHighContrast: lightHighContrast
        case .darkHighContrast: darkHighContrast
        }
    }
}

/// Jit's content-layer palette ("Quiet Instrument, under glass"). Glass chrome is system-rendered and
/// has no tokens here. Values: `docs/design-system.md`.
public enum ColorToken: String, CaseIterable, Sendable {
    // Surfaces
    case surfaceCanvas = "surface.canvas"
    case surfacePanel = "surface.panel"
    case surfaceRaised = "surface.raised"
    case surfaceSunken = "surface.sunken"
    case surfaceChromeOpaque = "surface.chromeOpaque"
    // Borders
    case borderSubtle = "border.subtle"
    case borderStrong = "border.strong"
    // Text
    case textPrimary = "text.primary"
    case textSecondary = "text.secondary"
    case textTertiary = "text.tertiary"
    case textDisabled = "text.disabled"
    // Accent
    case accentBase = "accent.base"
    case accentTint = "accent.tint"
    case accentMuted = "accent.muted"
    case accentOnAccent = "accent.onAccent"
    // Interaction overlays (content rows)
    case stateHover = "state.hover"
    case statePressed = "state.pressed"
    // Status
    case statusSuccess = "status.success"
    case statusWarning = "status.warning"
    case statusDanger = "status.danger"
    case statusInfo = "status.info"
    // Diff
    case diffAddBackground = "diff.add.bg"
    case diffAddMark = "diff.add.mark"
    case diffDeleteBackground = "diff.del.bg"
    case diffDeleteMark = "diff.del.mark"

    public var spec: ColorSpec {
        switch self {
        case .surfaceCanvas: ColorSpec(light: RGBA(0xF5F4F1), dark: RGBA(0x161719))
        case .surfacePanel: ColorSpec(light: RGBA(0xFAF9F7), dark: RGBA(0x1B1C1F))
        case .surfaceRaised: ColorSpec(light: RGBA(0xFFFFFF), dark: RGBA(0x222327))
        case .surfaceSunken: ColorSpec(light: RGBA(0xEEECE8), dark: RGBA(0x111214))
        case .surfaceChromeOpaque: ColorSpec(light: RGBA(0xECEAE6), dark: RGBA(0x232428))
        case .borderSubtle:
            ColorSpec(
                light: RGBA(0xE3E0DA), dark: RGBA(0x2B2D31),
                lightHighContrast: RGBA(0xB5B1A9), darkHighContrast: RGBA(0x4A4D54))
        case .borderStrong:
            ColorSpec(
                light: RGBA(0xCDC9C1), dark: RGBA(0x3A3C42),
                lightHighContrast: RGBA(0x8E8A82), darkHighContrast: RGBA(0x6A6D74))
        case .textPrimary:
            ColorSpec(
                light: RGBA(0x1D2023), dark: RGBA(0xE7E5E0),
                lightHighContrast: RGBA(0x0F1113), darkHighContrast: RGBA(0xF4F2EE))
        case .textSecondary:
            ColorSpec(
                light: RGBA(0x545A60), dark: RGBA(0xA8A6A1),
                lightHighContrast: RGBA(0x3F444A), darkHighContrast: RGBA(0xC4C2BD))
        case .textTertiary:
            ColorSpec(
                light: RGBA(0x7A7F85), dark: RGBA(0x76756F),
                lightHighContrast: RGBA(0x5C6167), darkHighContrast: RGBA(0x9E9C96))
        case .textDisabled: ColorSpec(light: RGBA(0xB3B6BA), dark: RGBA(0x4E4E4B))
        case .accentBase:
            ColorSpec(
                light: RGBA(0x21707A), dark: RGBA(0x67B5BA),
                lightHighContrast: RGBA(0x175A63), darkHighContrast: RGBA(0x86CACE))
        case .accentTint: ColorSpec(light: RGBA(0x21707A), dark: RGBA(0x4FA3A9))
        case .accentMuted: ColorSpec(light: RGBA(0x21707A, alpha: 0.12), dark: RGBA(0x67B5BA, alpha: 0.16))
        case .accentOnAccent: ColorSpec(light: RGBA(0xFFFFFF), dark: RGBA(0x0E1A1C))
        case .stateHover: ColorSpec(light: RGBA(0x1D2023, alpha: 0.04), dark: RGBA(0xE7E5E0, alpha: 0.05))
        case .statePressed: ColorSpec(light: RGBA(0x1D2023, alpha: 0.08), dark: RGBA(0xE7E5E0, alpha: 0.09))
        case .statusSuccess: ColorSpec(light: RGBA(0x2F7A4A), dark: RGBA(0x71BE8A))
        case .statusWarning: ColorSpec(light: RGBA(0xA3670F), dark: RGBA(0xE0A651))
        case .statusDanger: ColorSpec(light: RGBA(0xAE3932), dark: RGBA(0xE57A70))
        case .statusInfo: ColorSpec(light: RGBA(0x3D6394), dark: RGBA(0x86A8D6))
        case .diffAddBackground: ColorSpec(light: RGBA(0xE5F1E7), dark: RGBA(0x1A2A20))
        case .diffAddMark: ColorSpec(light: RGBA(0x2F7A4A), dark: RGBA(0x71BE8A))
        case .diffDeleteBackground: ColorSpec(light: RGBA(0xF7E5E3), dark: RGBA(0x2D1C1B))
        case .diffDeleteMark: ColorSpec(light: RGBA(0xAE3932), dark: RGBA(0xE57A70))
        }
    }
}

/// Branch-lane palette for the graph (Phase 2). Content layer only; never used to tint glass.
public enum LaneColor: Int, CaseIterable, Sendable {
    case slate, tidewater, moss, ochre, clay, heather, rosewood, steel

    public var spec: ColorSpec {
        switch self {
        case .slate: ColorSpec(light: RGBA(0x4C6B9F), dark: RGBA(0x8EA7D1))
        case .tidewater: ColorSpec(light: RGBA(0x2B8580), dark: RGBA(0x6FC0B9))
        case .moss: ColorSpec(light: RGBA(0x6F8435), dark: RGBA(0xA9BE72))
        case .ochre: ColorSpec(light: RGBA(0xA9782A), dark: RGBA(0xD9AD62))
        case .clay: ColorSpec(light: RGBA(0xAD5A43), dark: RGBA(0xDD9079))
        case .heather: ColorSpec(light: RGBA(0x82599A), dark: RGBA(0xB897CF))
        case .rosewood: ColorSpec(light: RGBA(0xA8577A), dark: RGBA(0xD891B0))
        case .steel: ColorSpec(light: RGBA(0x5D7380), dark: RGBA(0x9BB0BC))
        }
    }

    public var name: String { String(describing: self) }
}
