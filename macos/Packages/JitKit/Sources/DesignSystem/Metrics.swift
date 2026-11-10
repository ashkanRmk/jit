import CoreGraphics

/// 4 pt grid. `Space.s4` = 8 pt.
public enum Space {
    public static let s1: CGFloat = 2
    public static let s2: CGFloat = 4
    public static let s3: CGFloat = 6
    public static let s4: CGFloat = 8
    public static let s5: CGFloat = 12
    public static let s6: CGFloat = 16
    public static let s7: CGFloat = 20
    public static let s8: CGFloat = 24
    public static let s9: CGFloat = 32
    public static let s10: CGFloat = 40

    public static let all: [(String, CGFloat)] = [
        ("space.1", s1), ("space.2", s2), ("space.3", s3), ("space.4", s4), ("space.5", s5),
        ("space.6", s6), ("space.7", s7), ("space.8", s8), ("space.9", s9), ("space.10", s10),
    ]
}

/// Continuous-corner radii, chosen to nest concentrically: an inner radius = outer radius − inset.
/// 0.0.3 made every step a little squarer. Custom glass chrome uses `ChromeShape.control` (`md`).
public enum Radius {
    public static let xs: CGFloat = 3
    public static let sm: CGFloat = 5
    public static let md: CGFloat = 7
    public static let lg: CGFloat = 10

    public static let all: [(String, CGFloat)] = [
        ("radius.xs", xs), ("radius.sm", sm), ("radius.md", md), ("radius.lg", lg),
    ]

    /// Radius for a shape inset by `inset` inside a shape with `outer` radius, so corners stay concentric.
    public static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat { max(0, outer - inset) }
}

public enum Border {
    /// One device pixel on Retina.
    public static let hairline: CGFloat = 0.5
    public static let emphasis: CGFloat = 1
}

/// Content-layer shadows, light appearance only (dark uses luminance steps). Never on glass, never animated.
public struct ShadowToken: Sendable {
    public let y: CGFloat
    public let blur: CGFloat
    public let opacity: Double

    public static let level1 = ShadowToken(y: 1, blur: 3, opacity: 0.06)
    public static let level2 = ShadowToken(y: 4, blur: 12, opacity: 0.10)
}

public enum IconSize {
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let hero: CGFloat = 40
}

public enum PanelMetrics {
    public static let windowMinWidth: CGFloat = 960
    public static let windowMinHeight: CGFloat = 600
    public static let sidebarMin: CGFloat = 200
    public static let sidebarDefault: CGFloat = 260
    public static let sidebarMax: CGFloat = 380
    public static let inspectorMin: CGFloat = 340
    public static let inspectorDefault: CGFloat = 420
    public static let inspectorMax: CGFloat = 640
    public static let contentColumnMax: CGFloat = 520
}

public enum Density: String, CaseIterable, Sendable {
    case compact
    case comfortable

    public var rowHeight: CGFloat { self == .compact ? 22 : 26 }
}
