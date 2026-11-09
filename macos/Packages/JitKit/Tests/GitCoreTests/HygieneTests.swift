import Foundation
import Testing

@testable import GitCore

@Suite struct HygieneTests {
    static let gitCoreSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/GitCore")

    /// Every `.swift` file under `Sources/GitCore`, recursively (relative paths).
    static func sourceFiles() throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: gitCoreSources.path))
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
    }

    @Test func gitCoreImportsFoundationOnly() throws {
        let allowed: Set<String> = ["Foundation", "Darwin", "Dispatch", "System", "Synchronization", "os"]
        let files = try Self.sourceFiles()
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: Self.gitCoreSources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ ["public", "internal", "@testable", "@preconcurrency"].contains($0) })
                else { continue }
                let module = words[index + 1].split(separator: ".").first.map(String.init) ?? ""
                #expect(allowed.contains(module), "\(file) imports \(module)")
            }
        }
    }

    @Test func noShellStringAPI() throws {
        // Production code never launches a shell.
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: Self.gitCoreSources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("/bin/sh"), "\(file) mentions /bin/sh")
            #expect(!text.contains("/bin/zsh") && !text.contains("/bin/bash"), "\(file) mentions a shell")
            #expect(!text.contains("system("), "\(file) calls system()")
        }
    }

    @Test func redactsCredentialsInDetail() {
        let raw = "fatal: unable to access 'https://alice:ghp_secret123@github.com/x/y.git/': token=abc&x=1"
        let redacted = Redaction.redact(raw)
        #expect(!redacted.contains("ghp_secret123"))
        #expect(!redacted.contains("alice"))
        #expect(!redacted.contains("abc"))
        #expect(redacted.contains("https://***@github.com/x/y.git/"))
    }

    @Test func redactsAuthHeadersAndBareTokens() {
        let raw = """
            > Authorization: Basic YWxpY2U6c2VjcmV0
            > Proxy-Authorization: Bearer abc.def.ghi
            remote: token ghp_abcdefghijklmnopqrstuvwxyz0123 and glpat-ABCDEFGHIJKLMNOPQRST12
            """
        let redacted = Redaction.redact(raw)
        for secret in [
            "YWxpY2U6c2VjcmV0", "abc.def.ghi", "ghp_abcdefghijklmnopqrstuvwxyz0123", "glpat-ABCDEFGHIJKLMNOPQRST12",
        ] {
            #expect(!redacted.contains(secret), "leaked \(secret)")
        }
        #expect(redacted.contains("Authorization: Basic ***"))
    }
}
