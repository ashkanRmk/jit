import AppKit
import Foundation
import Testing

@testable import DesignSystem

@Suite struct ContrastTests {
    static let contentSurfaces: [ColorToken] = [.surfaceCanvas, .surfacePanel, .surfaceRaised, .surfaceSunken]

    func minimumContrast(_ token: ColorToken, _ variant: Variant, on surfaces: [ColorToken] = contentSurfaces)
        -> Double
    {
        surfaces.map { token.spec.value(for: variant).contrast(against: $0.spec.value(for: variant)) }.min() ?? 0
    }

    @Test(arguments: Variant.allCases)
    func bodyTextMeetsAA(_ variant: Variant) {
        for token in [ColorToken.textPrimary, .textSecondary] {
            let ratio = minimumContrast(token, variant)
            #expect(ratio >= 4.5, "\(token.rawValue) \(variant): \(ratio)")
        }
    }

    @Test(arguments: Variant.allCases)
    func tertiaryTextAndMarksMeetThreeToOne(_ variant: Variant) {
        let tokens: [ColorToken] = [
            .textTertiary, .accentBase, .statusSuccess, .statusWarning, .statusDanger, .statusInfo,
            .diffAddMark, .diffDeleteMark,
        ]
        for token in tokens {
            let ratio = minimumContrast(token, variant)
            #expect(ratio >= 3, "\(token.rawValue) \(variant): \(ratio)")
        }
    }

    @Test(arguments: Variant.allCases)
    func laneLinesMeetThreeToOneOnCanvas(_ variant: Variant) {
        let canvas = ColorToken.surfaceCanvas.spec.value(for: variant)
        for lane in LaneColor.allCases {
            let ratio = lane.spec.value(for: variant).contrast(against: canvas)
            #expect(ratio >= 3, "lane \(lane.name) \(variant): \(ratio)")
        }
    }

    @Test(arguments: Variant.allCases)
    func textOnDiffBackgroundsMeetsAA(_ variant: Variant) {
        let text = ColorToken.textPrimary.spec.value(for: variant)
        for background in [ColorToken.diffAddBackground, .diffDeleteBackground] {
            #expect(text.contrast(against: background.spec.value(for: variant)) >= 4.5)
        }
    }

    @Test(arguments: Variant.allCases)
    func textOnAccentMeetsAA(_ variant: Variant) {
        let ratio = ColorToken.accentOnAccent.spec.value(for: variant)
            .contrast(against: ColorToken.accentTint.spec.value(for: variant))
        #expect(ratio >= 4.5, "\(variant): \(ratio)")
    }

    @Test func increaseContrastIsNeverWeaker() {
        for token in [ColorToken.textSecondary, .textTertiary, .borderSubtle, .borderStrong] {
            for (regular, high) in [(Variant.light, Variant.lightHighContrast), (.dark, .darkHighContrast)] {
                let canvasRegular = ColorToken.surfaceCanvas.spec.value(for: regular)
                let canvasHigh = ColorToken.surfaceCanvas.spec.value(for: high)
                #expect(
                    token.spec.value(for: high).contrast(against: canvasHigh)
                        > token.spec.value(for: regular).contrast(against: canvasRegular),
                    "\(token.rawValue) high contrast is not stronger")
            }
        }
    }

    @Test func contrastMathMatchesWCAGReference() {
        #expect(abs(RGBA(0x000000).contrast(against: RGBA(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(RGBA(0x777777).contrast(against: RGBA(0xFFFFFF)) - 4.48) < 0.01)
    }
}

@Suite @MainActor struct ResolutionTests {
    @Test func resolvesEveryAppearance() {
        let cases: [(NSAppearance.Name?, Bool, Variant)] = [
            (.aqua, false, .light), (.darkAqua, false, .dark),
            (.aqua, true, .lightHighContrast), (.darkAqua, true, .darkHighContrast),
            (.accessibilityHighContrastAqua, false, .lightHighContrast),
            (.accessibilityHighContrastDarkAqua, false, .darkHighContrast),
            (nil, false, .light),
        ]
        for (name, increaseContrast, expected) in cases {
            #expect(Variant.resolve(bestMatch: name, increaseContrast: increaseContrast) == expected)
        }
    }

    @Test func resolvesRealAppearances() throws {
        // With Increase Contrast off (as on CI), real appearances map to the regular variants.
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return }
        #expect(Variant.resolve(try #require(NSAppearance(named: .aqua))) == .light)
        #expect(Variant.resolve(try #require(NSAppearance(named: .darkAqua))) == .dark)
    }

    @Test func dynamicColorsFollowAppearance() throws {
        let color = ColorToken.surfaceCanvas.nsColor
        for (name, variant) in [(NSAppearance.Name.aqua, Variant.light), (.darkAqua, .dark)] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved = RGBA(0)
            appearance.performAsCurrentDrawingAppearance {
                let srgb = color.usingColorSpace(.sRGB) ?? .black
                resolved = RGBA(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: 1)
            }
            let expected = ColorToken.surfaceCanvas.spec.value(for: variant)
            #expect(abs(resolved.red - expected.red) < 0.01 && abs(resolved.blue - expected.blue) < 0.01)
        }
    }

    @Test func reduceTransparencyFallbackIsOpaque() {
        for variant in Variant.allCases {
            #expect(ColorToken.surfaceChromeOpaque.spec.value(for: variant).alpha == 1)
        }
    }
}

/// Views never hardcode colors, fonts or blurs; glass goes through DesignSystem helpers.
@Suite struct StylingLintTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let forbidden = [
        "Color(red:", "Color(.sRGB", "Color(hue:", "Color(white:", "NSColor(red:", "NSColor(srgbRed:",
        "NSColor(calibratedRed:", "NSColor(deviceRed:", "NSColor(white:", "#colorLiteral",
        ".font(.system(size:", "NSFont.systemFont(ofSize:", "NSFont(name:", "Font.custom(",
        "NSVisualEffectView", ".glassEffect(", "NSGlassEffectView(", "CIFilter", ".blur(radius:",
    ]

    @Test func viewsUseDesignSystemTokens() throws {
        let checked = ["macos/Packages/JitKit/Sources/Features", "macos/App"]
        var scanned = 0
        for directory in checked {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let file as String in files where file.hasSuffix(".swift") {
                scanned += 1
                let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                for pattern in Self.forbidden {
                    #expect(!text.contains(pattern), "\(directory)/\(file) uses \(pattern)")
                }
            }
        }
        #expect(scanned > 0)
    }
}
