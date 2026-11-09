import AppKit

/// Syntax-highlighting colours (`syntax.*`, P3.7). Content layer only; each meets 4.5:1 on the canvas and on
/// both diff backgrounds in every variant (`ContrastTests`).
public enum SyntaxColor: UInt8, CaseIterable, Sendable {
    case keyword, type, function, string, number, comment, constant, `operator`, punctuation, property, tag
    case attribute, variable, macro

    public var name: String { "syntax.\(self)" }

    public var spec: ColorSpec {
        switch self {
        case .keyword: ColorSpec(light: RGBA(0x8A1F84), dark: RGBA(0xF07CC0))
        case .type: ColorSpec(light: RGBA(0x0B5577), dark: RGBA(0x6FC9E8))
        case .function: ColorSpec(light: RGBA(0x2F6067), dark: RGBA(0x7CC4B4))
        case .string: ColorSpec(light: RGBA(0x9A2A17), dark: RGBA(0xF0937D))
        case .number: ColorSpec(light: RGBA(0x3B2CA8), dark: RGBA(0xD6C477))
        case .comment: ColorSpec(light: RGBA(0x56606A), dark: RGBA(0x98A3AD))
        case .constant: ColorSpec(light: RGBA(0x5E2F99), dark: RGBA(0xB896EE))
        case .operator, .punctuation: ColorSpec(light: RGBA(0x3D4245), dark: RGBA(0xC9CCCF))
        case .property: ColorSpec(light: RGBA(0x255F86), dark: RGBA(0x8DB9DA))
        case .tag: ColorSpec(light: RGBA(0x0B5577), dark: RGBA(0x6FC9E8))
        case .attribute: ColorSpec(light: RGBA(0x725A12), dark: RGBA(0xD9AE6C))
        case .variable: ColorSpec(light: RGBA(0x255F86), dark: RGBA(0x8DB9DA))
        case .macro: ColorSpec(light: RGBA(0x7A3E12), dark: RGBA(0xF2A25E))
        }
    }

    @MainActor public var nsColor: NSColor { Self.cache[Int(rawValue)] }

    @MainActor private static let cache: [NSColor] = allCases.map { $0.spec.dynamicColor(named: "jit." + $0.name) }
}
