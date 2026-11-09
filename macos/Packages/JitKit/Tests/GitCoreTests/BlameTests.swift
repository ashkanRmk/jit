import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Blame (P3.9) on real repositories.
@Suite struct BlameTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        try await GitEngine(configuration: repo.sandbox.engineConfiguration()).openRepository(
            at: URL(fileURLWithPath: repo.path))
    }

    func collect(_ stream: AsyncThrowingStream<BlameEvent, any Error>) async throws -> (
        [String: BlameCommit], [BlameBlock]
    ) {
        var commits: [String: BlameCommit] = [:]
        var blocks: [BlameBlock] = []
        for try await event in stream {
            switch event {
            case .commit(let commit): commits[commit.id] = commit
            case .block(let block): blocks.append(block)
            }
        }
        return (commits, blocks)
    }

    @Test func blameIncrementalParsesAllLines() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let first = try await repo.commit("First")
        try repo.write(
            "f.txt", (1...10).map { $0 % 3 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n")
        let second = try await repo.commit("Second ünïcode")
        try repo.write(
            "f.txt", (1...10).map { $0 % 3 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\nlocal\n"
        )

        let (commits, blocks) = try await collect(try await open(repo).blame("f.txt"))
        // Every final line exactly once.
        let lines = blocks.flatMap { $0.finalLine..<($0.finalLine + $0.count) }.sorted()
        #expect(lines == Array(1...11))
        func owner(_ line: Int) -> String? {
            blocks.first { ($0.finalLine..<($0.finalLine + $0.count)).contains(line) }?.commitID
        }
        #expect(
            owner(1) == first && owner(3) == second && owner(6) == second
                && owner(11).map { commits[$0]?.isUncommitted } == true)
        #expect(commits[second]?.summary == "Second ünïcode" && commits[first]?.authorTime ?? 0 > 0)
        #expect(!(commits[first]?.author.isEmpty ?? true))

        // At a revision: the committed file, and content to match.
        let handle = try await open(repo)
        let at = try #require(ObjectID(hex: first))
        let (_, old) = try await collect(handle.blame("f.txt", options: BlameOptions(revision: at)))
        #expect(old.allSatisfy { $0.commitID == first } && old.reduce(0) { $0 + $1.count } == 10)
        #expect(
            String(decoding: try await handle.blameContent("f.txt", revision: at), as: UTF8.self).hasPrefix(
                "line 1\nline 2\nline 3\n"))
    }

    @Test func blameCancel() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", (1...3000).map { "l\($0)" }.joined(separator: "\n"))
        try await repo.commit("One")
        let handle = try await open(repo)
        let task = Task { () -> Int in
            var count = 0
            for try await _ in handle.blame("f.txt") { count += 1 }
            return count
        }
        task.cancel()
        let result = await task.result
        // Either cancelled before reading or finished early; never hangs, never throws anything else.
        switch result {
        case .success: break
        case .failure(let error): #expect(error is CancellationError || (error as? GitCoreError) == .cancelled)
        }
    }

    @Test func blameIgnoreRevsFileRespected() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("f.txt", "a\nb\nc\n")
        let original = try await repo.commit("Original")
        try repo.write("f.txt", "a \nb \nc \n")  // whitespace-only reformat
        let reformat = try await repo.commit("Reformat")
        try repo.write(".git-blame-ignore-revs", reformat + "\n")
        let handle = try await open(repo)
        let (_, before) = try await collect(handle.blame("f.txt"))
        #expect(before.allSatisfy { $0.commitID == reformat })
        try await repo.git("config", "blame.ignoreRevsFile", ".git-blame-ignore-revs")
        let (_, after) = try await collect(handle.blame("f.txt"))
        #expect(after.allSatisfy { $0.commitID == original })
    }

    @Test func blameFirstLinesOf5kLineFile() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let lines = (1...5000).map { "let value\($0) = \($0)" }
        try repo.write("big.swift", lines.joined(separator: "\n") + "\n")
        try await repo.commit("One")
        var edited = lines
        for index in stride(from: 0, to: 5000, by: 50) { edited[index] = "let changed\(index) = 0" }
        try repo.write("big.swift", edited.joined(separator: "\n") + "\n")
        try await repo.commit("Two")
        let handle = try await open(repo)
        _ = try await handle.objectFormat()
        let clock = ContinuousClock()
        let started = clock.now
        var firstBlock: Duration?
        var total = 0
        for try await event in handle.blame("big.swift") {
            if case .block(let block) = event {
                if firstBlock == nil { firstBlock = clock.now - started }
                total += block.count
            }
        }
        let all = clock.now - started
        print("blameFirstLinesOf5kLineFile: first block \(firstBlock ?? .zero), all 5000 lines \(all) (debug build)")
        #expect(total == 5000)
        // Release budget 200 ms (≈30 ms measured in isolation); debug builds under the full parallel suite get the
        // standard PerfBudget headroom.
        #expect(try #require(firstBlock) < PerfBudget.limit(.milliseconds(200)))
    }
}
