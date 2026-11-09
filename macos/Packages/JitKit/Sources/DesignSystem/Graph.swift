import AppKit

/// Graph geometry per density (design §3.2). All values in points.
public struct GraphMetrics: Sendable, Equatable {
    public let rowHeight: CGFloat
    public let laneSpacing: CGFloat
    /// Lanes past `maxVisibleLanes` are squeezed to this spacing (and drawn at reduced opacity).
    public let compressedLaneSpacing: CGFloat
    public let leadingInset: CGFloat
    public let nodeRadius: CGFloat
    public let mergeNodeRadius: CGFloat
    public let headRingGap: CGFloat
    public let headRingWidth: CGFloat
    public let edgeWidth: CGFloat
    public let maxVisibleLanes: Int
    public let pillHeight: CGFloat
    public let pillPadding: CGFloat
    public let pillSpacing: CGFloat
    public let avatarSize: CGFloat
    /// Graph column never takes more than this share of the table width.
    public let maxGraphShare: CGFloat

    public static let compact = GraphMetrics(
        rowHeight: 24, laneSpacing: 14, compressedLaneSpacing: 6, leadingInset: 10, nodeRadius: 3.5,
        mergeNodeRadius: 4, headRingGap: 2.5, headRingWidth: 1.25, edgeWidth: 1.5, maxVisibleLanes: 12,
        pillHeight: 16, pillPadding: 6, pillSpacing: 4, avatarSize: 16, maxGraphShare: 0.4)

    public static let comfortable = GraphMetrics(
        rowHeight: 30, laneSpacing: 16, compressedLaneSpacing: 6, leadingInset: 12, nodeRadius: 4,
        mergeNodeRadius: 4.5, headRingGap: 3, headRingWidth: 1.25, edgeWidth: 1.75, maxVisibleLanes: 12,
        pillHeight: 18, pillPadding: 6, pillSpacing: 4, avatarSize: 18, maxGraphShare: 0.4)

    public static func forDensity(_ density: Density) -> GraphMetrics {
        density == .compact ? .compact : .comfortable
    }

    /// x of a lane centre inside the graph column.
    public func laneX(_ lane: Int) -> CGFloat {
        if lane < maxVisibleLanes { return leadingInset + (CGFloat(lane) + 0.5) * laneSpacing }
        return leadingInset + CGFloat(maxVisibleLanes) * laneSpacing
            + (CGFloat(lane - maxVisibleLanes) + 0.5) * compressedLaneSpacing
    }

    /// Column width needed for `lanes` lanes.
    public func columnWidth(lanes: Int) -> CGFloat {
        let visible = min(lanes, maxVisibleLanes)
        let compressed = max(0, lanes - maxVisibleLanes)
        return leadingInset * 2 + CGFloat(visible) * laneSpacing + CGFloat(compressed) * compressedLaneSpacing
    }

    /// Snaps a vertical line's x to the device pixel grid so a line of `width` stays crisp.
    public static func snap(_ x: CGFloat, width: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = (width * scale).rounded()
        let odd = Int(pixels) % 2 == 1
        let base = (x * scale).rounded(.down) / scale
        return odd ? base + 0.5 / scale : (x * scale).rounded() / scale
    }
}

/// Lane colours resolved once per appearance into `CGColor`s (no per-draw `NSColor` resolution).
@MainActor public final class GraphColorTable {
    public private(set) var lanes: [CGColor] = []
    public private(set) var laneFills: [CGColor] = []
    public private(set) var laneOutlines: [CGColor] = []
    public private(set) var canvas: CGColor = .clear
    public private(set) var neutralFill: CGColor = .clear
    public private(set) var textPrimary: NSColor = .labelColor
    public private(set) var textSecondary: NSColor = .secondaryLabelColor
    public private(set) var textTertiary: NSColor = .tertiaryLabelColor
    public private(set) var warning: CGColor = .clear
    public private(set) var headRing: CGColor = .clear
    public private(set) var variant: Variant = .light
    private var resolvedFor: NSAppearance.Name?
    private var resolvedIncreaseContrast = false

    public init() {}

    /// Re-resolves when the appearance (or Increase Contrast) changed. Returns true if it did.
    @discardableResult
    public func update(for appearance: NSAppearance) -> Bool {
        let name = appearance.name
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        guard name != resolvedFor || contrast != resolvedIncreaseContrast || lanes.isEmpty else { return false }
        resolvedFor = name
        resolvedIncreaseContrast = contrast
        let variant = Variant.resolve(appearance)
        self.variant = variant
        func cg(_ rgba: RGBA) -> CGColor {
            CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        let slots = LaneColor.allCases.map { $0.spec.value(for: variant) }
        lanes = slots.map(cg)
        laneFills = slots.map { cg($0.opacity(variant.isDark ? 0.22 : 0.14)) }
        laneOutlines = slots.map { cg($0.opacity(0.6)) }
        canvas = cg(ColorToken.surfaceCanvas.spec.value(for: variant))
        neutralFill = cg(ColorToken.stateHover.spec.value(for: variant).opacity(variant.isDark ? 0.10 : 0.07))
        warning = cg(ColorToken.statusWarning.spec.value(for: variant))
        appearance.performAsCurrentDrawingAppearance {
            headRing = NSColor.controlAccentColor.cgColor
        }
        textPrimary = ColorToken.textPrimary.nsColor
        textSecondary = ColorToken.textSecondary.nsColor
        textTertiary = ColorToken.textTertiary.nsColor
        return true
    }

    public func lane(_ slot: UInt8) -> CGColor { lanes.isEmpty ? .black : lanes[Int(slot) % lanes.count] }
}

/// Deterministic initials-avatar colours (no network, design §2): a stable hash of the email picks one
/// of the lane hues (avatars are small marks next to text, so lane hues read as "a person", not a lane).
public enum AvatarStyle {
    public static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    public static func colorSlot(forHash hash: UInt64) -> Int { Int(hash % UInt64(LaneColor.allCases.count)) }
}

/// Fonts used by the graph's custom-drawn cells and the navigator (type scale variants of `TypeToken`).
public enum GraphTypography {
    public static var subject: NSFont { TypeToken.body.nsFont }
    public static var subjectEmphasized: NSFont { .systemFont(ofSize: TypeToken.body.size, weight: .semibold) }
    public static var pill: NSFont { .systemFont(ofSize: TypeToken.caption.size, weight: .medium) }
    public static var pillEmphasized: NSFont { .systemFont(ofSize: TypeToken.caption.size, weight: .semibold) }
    /// Initials inside the 16–18 pt avatar.
    public static var avatar: NSFont { .systemFont(ofSize: 8, weight: .semibold) }
    public static var secondary: NSFont { TypeToken.callout.nsFont }
    public static var mono: NSFont { TypeToken.monoCaption.nsFont }
    /// Navigator rows use the system sidebar size; the current branch is semibold.
    public static var sidebar: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
    public static var sidebarEmphasized: NSFont { .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
}
