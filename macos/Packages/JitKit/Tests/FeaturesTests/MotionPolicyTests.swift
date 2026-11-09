import Foundation
import Testing

/// P6.8: animations come from motion tokens (or are instant), SwiftUI animations honour Reduce Motion, and
/// nothing animates with a literal duration. Source scan of Features (Gallery excluded: it shows the tokens).
@Suite struct MotionPolicyTests {
    static func featureSources() throws -> [(String, [Substring])] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Features")
        var result: [(String, [Substring])] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/Gallery/"), !url.path.contains("/Benchmark/")
            else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            result.append((url.lastPathComponent, text.split(separator: "\n", omittingEmptySubsequences: false)))
        }
        return result
    }

    @Test func noLiteralAnimationDurations() throws {
        var findings: [String] = []
        let literal = try Regex(#"(duration:\s*[0-9.]+[^0-9])|(\.duration\s*=\s*0\.[0-9])"#)
        for (file, lines) in try Self.featureSources() {
            for (number, line) in lines.enumerated() where line.contains(literal) && !line.contains("Benchmark") {
                findings.append("\(file):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test func swiftUIAnimationsHonourReduceMotion() throws {
        var findings: [String] = []
        for (file, lines) in try Self.featureSources() {
            for (number, line) in lines.enumerated()
            where line.contains("withAnimation(") || line.contains(".animation(") {
                // Either nil under Reduce Motion, or opacity-only/instant by construction.
                let window = lines[number..<min(lines.count, number + 2)].joined(separator: " ")
                if !window.contains("reduceMotion") {
                    findings.append("\(file):\(number + 1)")
                }
            }
        }
        #expect(findings.isEmpty, "animations without a Reduce Motion path: \(findings)")
    }
}
