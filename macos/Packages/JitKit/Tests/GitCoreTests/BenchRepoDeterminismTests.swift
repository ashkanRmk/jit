import Foundation
import GitTestKit
import Testing

/// P6.2: benchmark repositories are reproducible — two builds give identical refs and status.
@Suite struct BenchRepoDeterminismTests {
    func snapshot(_ path: String) throws -> String {
        let refs = try run(["for-each-ref", "--format=%(objectname) %(refname)"], in: path)
        let status = try run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: path)
        return refs + "\n--\n" + status
    }

    func run(_ arguments: [String], in path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.environment = [
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": NSTemporaryDirectory(),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [BenchRepo.linear1k, .manyFiles])
    func twoBuildsAreIdentical(_ repo: BenchRepo) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jit-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try repo.build(at: root.appendingPathComponent("a").path)
        let second = try repo.build(at: root.appendingPathComponent("b").path)
        #expect(first == second)
        let a = try snapshot(root.appendingPathComponent("a").path)
        #expect(!a.isEmpty)
        #expect(a == (try snapshot(root.appendingPathComponent("b").path)))
        if repo == .manyFiles {
            // 150 staged + 50 partial + 150 unstaged + 50 renames + 100 untracked entries.
            let status = try run(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: root.appendingPathComponent("a").path)
            #expect(status.split(separator: "\0").filter { $0.hasPrefix("? ") }.count == 100)
            #expect(status.split(separator: "\0").filter { $0.hasPrefix("2 ") }.count == 50)
        }
    }
}
