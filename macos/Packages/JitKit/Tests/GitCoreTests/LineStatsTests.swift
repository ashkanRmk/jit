import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Lazy numstat for the working-directory panel (P3.1) against real repositories.
@Suite struct LineStatsTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    @Test func lineStatsStagedAndUnstagedSides() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try await repo.commit("One")
        try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        let handle = try await open(repo)

        #expect(
            try await handle.lineStats(staged: true, paths: ["a.txt"]) == [
                "a.txt": LineStats(additions: 2, deletions: 1)
            ])
        #expect(
            try await handle.lineStats(staged: false, paths: ["a.txt"]) == [
                "a.txt": LineStats(additions: 2, deletions: 0)
            ])
    }

    @Test func lineStatsOnlyForRequestedLiteralPaths() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("*.txt", "star\n")
        try repo.write("b.txt", "b\n")
        try await repo.commit("One")
        try repo.write("*.txt", "star\nmore\n")
        try repo.write("b.txt", "b\nmore\n")
        let handle = try await open(repo)
        // `*.txt` is a file name, not a glob: b.txt must not be reported.
        #expect(
            try await handle.lineStats(staged: false, paths: ["*.txt"]) == [
                "*.txt": LineStats(additions: 1, deletions: 0)
            ])
    }

    @Test func lineStatsBinaryAndUntracked() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try Data([0, 1, 2, 0, 255]).write(to: URL(fileURLWithPath: repo.path + "/blob.bin"))
        try await repo.commit("One")
        try Data([0, 9, 9, 0, 255]).write(to: URL(fileURLWithPath: repo.path + "/blob.bin"))
        try repo.write("new.txt", "n\n")
        let handle = try await open(repo)
        let result = try await handle.lineStats(staged: false, paths: ["blob.bin", "new.txt"])
        #expect(result["blob.bin"]?.isBinary == true)
        #expect(result["new.txt"] == nil)  // untracked: in neither diff
    }

    @Test func lineStatsStagedRenameAndUnbornHead() async throws {
        let sandbox = try GitSandbox()
        let unborn = try await sandbox.makeRepository("unborn")
        try unborn.write("first.txt", "a\nb\n")
        try await unborn.git("add", "first.txt")
        #expect(
            try await open(unborn).lineStats(staged: true, paths: ["first.txt"])
                == ["first.txt": LineStats(additions: 2, deletions: 0)])

        let repo = try await sandbox.makeRepository()
        try repo.write("old.txt", String(repeating: "line\n", count: 20))
        try await repo.commit("One")
        try await repo.git("mv", "old.txt", "new.txt")
        let stats = try await open(repo).lineStats(staged: true, paths: ["old.txt", "new.txt"])
        #expect(stats == ["new.txt": LineStats(additions: 0, deletions: 0)])
    }

    @Test func numstatParserHandlesRenameRecords() throws {
        let bytes = Array("3\t1\tplain.txt\u{0}-\t-\tbin\u{0}0\t0\t\u{0}old name\u{0}new name\u{0}".utf8)
        #expect(
            try NumstatParser.parse(bytes) == [
                "plain.txt": LineStats(additions: 3, deletions: 1), "bin": LineStats(additions: nil, deletions: nil),
                "new name": LineStats(additions: 0, deletions: 0),
            ])
    }
}
