import AppKit
import SwiftUI

/// Type scale. SF Pro for UI, SF Mono for code/SHAs/paths. Chrome text (toolbar, sidebar, tab titles)
/// uses the system's own fonts and vibrancy instead of these tokens.
public enum TypeToken: String, CaseIterable, Sendable {
    case display = "type.display"
    case title = "type.title"
    case headline = "type.headline"
    case body = "type.body"
    case callout = "type.callout"
    case caption = "type.caption"
    case micro = "type.micro"
    case monoBody = "type.mono.body"
    case monoCaption = "type.mono.caption"

    public var size: CGFloat {
        switch self {
        case .display: 20
        case .title: 15
        case .headline, .body: 13
        case .callout, .monoBody: 12
        case .caption, .monoCaption: 11
        case .micro: 10
        }
    }

    public var lineHeight: CGFloat {
        switch self {
        case .display: 26
        case .title: 20
        case .headline, .body, .monoBody: 18
        case .callout: 16
        case .caption, .monoCaption: 14
        case .micro: 12
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .display, .title, .headline, .micro: .semibold
        case .caption: .medium
        case .body, .callout, .monoBody, .monoCaption: .regular
        }
    }

    public var isMonospaced: Bool { self == .monoBody || self == .monoCaption }
    public var isUppercase: Bool { self == .micro }
    /// Tracking in points (+2 % of size for `micro`).
    public var tracking: CGFloat { self == .micro ? size * 0.02 : 0 }

    public var font: Font {
        .system(size: size, weight: weight, design: isMonospaced ? .monospaced : .default)
    }

    /// The font's own line height (ascender + descender + leading); `lineHeight` adds the rest.
    public var naturalLineHeight: CGFloat {
        let font = nsFont
        return (font.ascender - font.descender + font.leading).rounded()
    }

    public var nsFont: NSFont {
        isMonospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight.nsWeight)
            : .systemFont(ofSize: size, weight: weight.nsWeight)
    }
}

extension Font.Weight {
    fileprivate var nsWeight: NSFont.Weight {
        switch self {
        case .semibold: .semibold
        case .medium: .medium
        case .bold: .bold
        default: .regular
        }
    }
}

extension View {
    /// Applies a type token: font, line height, tracking and case.
    public func typeStyle(_ token: TypeToken) -> some View {
        font(token.font)
            .lineSpacing(max(0, token.lineHeight - token.naturalLineHeight))
            .tracking(token.tracking)
            .textCase(token.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Sizes SF Symbols by an `IconSize` value (symbols scale with font size).
    public func symbolSize(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
    }
}
