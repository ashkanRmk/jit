import Foundation

/// A Git release version as reported by `git --version`.
///
/// Only the first three numeric components are significant. Vendor suffixes such as
/// `(Apple Git-154)` or `.windows.1` are kept in `vendorSuffix` for display.
public struct GitVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let vendorSuffix: String?

    /// Oldest Git that Jit supports (ADR-0006, Phase 0 addendum).
    public static let minimum = GitVersion(major: 2, minor: 39, patch: 0)

    public init(major: Int, minor: Int, patch: Int, vendorSuffix: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.vendorSuffix = vendorSuffix
    }

    /// Parses the output of `git --version`, e.g. `git version 2.39.5 (Apple Git-154)`.
    /// Returns `nil` for anything that is not a recognizable Git version line.
    public init?(parsing output: String) {
        let prefix = "git version "
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        let versionToken = rest.prefix { !$0.isWhitespace }
        let remainder = rest.dropFirst(versionToken.count).trimmingCharacters(in: .whitespaces)

        var numbers: [Int] = []
        var suffixStart: Substring.Index?
        var index = versionToken.startIndex
        while numbers.count < 3, index < versionToken.endIndex {
            let digits = versionToken[index...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            numbers.append(value)
            index = digits.endIndex
            if index < versionToken.endIndex, versionToken[index] == ".", numbers.count < 3 {
                index = versionToken.index(after: index)
            } else {
                break
            }
        }
        if index < versionToken.endIndex { suffixStart = index }
        guard numbers.count >= 2 else { return nil }

        var suffixParts: [String] = []
        if let suffixStart {
            let tail = versionToken[suffixStart...].drop { $0 == "." }
            if !tail.isEmpty { suffixParts.append(String(tail)) }
        }
        if !remainder.isEmpty { suffixParts.append(remainder) }

        self.init(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers.count > 2 ? numbers[2] : 0,
            vendorSuffix: suffixParts.isEmpty ? nil : suffixParts.joined(separator: " ")
        )
    }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    /// `2.39.5`
    public var description: String { "\(major).\(minor).\(patch)" }

    /// `2.39.5 (Apple Git-154)`
    public var displayString: String {
        guard let vendorSuffix else { return description }
        return "\(description) \(vendorSuffix)"
    }
}
