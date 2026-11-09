import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.15 — stash core on real repositories.
@Suite struct StashTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(action: action, title: "", context: "", changes: "", recoverability: "", verb: "OK")
            .confirm()
    }

    @Test func stashListParsesMessagesWithNewlinesAndUnicode() {
        let raw =
            "stash@{0}\0\(String(repeating: "a", count: 40))\0\(String(repeating: "b", count: 40)) \(String(repeating: "c", count: 40))\01767268800\0On main: line one\nline two ü 文\0"
            + "stash@{1}\0\(String(repeating: "d", count: 40))\0\(String(repeating: "e", count: 40)) \(String(repeating: "f", count: 40)) \(String(repeating: "0", count: 40))\01767268000\0WIP on feature/x: abc1234 Subject\0"
        let entries = StashListParser.parse(Array(raw.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].message == "line one\nline two ü 文")
        #expect(entries[0].branch == "main")
        #expect(!entries[0].hasUntracked)
        #expect(entries[1].branch == "feature/x")
        #expect(entries[1].hasUntracked)
        #expect(entries[1].name == "stash@{1}")
    }

    @Test func stashPushIncludeUntrackedRoundtrip() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n"])
        try repo.write("a.txt", "changed\n")
        try repo.write("new.txt", "untracked ü\n")
        let before = try await RepoFingerprint.capture(repo)
        let entry = try #require(
            try await handle.stashPush(StashPushRequest(message: "Mine", includeUntracked: true), context: Ops.context))
        #expect(entry.hasUntracked)
        #expect(entry.message == "Mine")
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/new.txt"))
        #expect(try Ops.read(repo, "a.txt") == "a\n")
        #expect(try await repo.git("log", "-1", "--format=%cn", "stash@{0}") == "Ada Lovelace")
        #expect(try await handle.applyStash(index: 0, oid: entry.oid, pop: true, context: Ops.context) == .applied)
        let after = try await RepoFingerprint.capture(repo)
        #expect(after.workingTree == before.workingTree)
        #expect(try await handle.stashes().isEmpty)
    }

    @Test func stashPushKeepIndexPreservesIndexBytes() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("b.txt", "unstaged\n")
        let index = try await repo.git("ls-files", "-s")
        try await handle.stashPush(StashPushRequest(keepIndex: true), context: Ops.context)
        #expect(try await repo.git("ls-files", "-s") == index)
        #expect(try Ops.read(repo, "a.txt") == "staged\n")
        #expect(try Ops.read(repo, "b.txt") == "b\n")
    }

    @Test func stashStagedOnly() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("b.txt", "unstaged\n")
        try await handle.stashPush(StashPushRequest(stagedOnly: true), context: Ops.context)
        #expect(try Ops.read(repo, "a.txt") == "a\n")
        #expect(try Ops.read(repo, "b.txt") == "unstaged\n")
    }

    @Test func stashPushPathsOnlyStashesSelected() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n", "b c.txt": "b\n"])
        try repo.write("a.txt", "a changed\n")
        try repo.write("b c.txt", "b changed\n")
        try await handle.stashPush(StashPushRequest(paths: ["b c.txt"]), context: Ops.context)
        #expect(try Ops.read(repo, "a.txt") == "a changed\n")
        #expect(try Ops.read(repo, "b c.txt") == "b\n")
    }

    @Test func stashPushNothingRefused() async throws {
        let (_, repo, handle) = try await Ops.single()
        do {
            try await handle.stashPush(StashPushRequest(), context: Ops.context)
            Issue.record("stashing a clean tree must be refused")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
            guard case .refused = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: repo.path))
    }

    @Test func stashPopConflictKeepsStash() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("a.txt", "one\nstashed\nthree\n")
        let entry = try #require(try await handle.stashPush(StashPushRequest(), context: Ops.context))
        try repo.write("a.txt", "one\ncommitted\nthree\n")
        try await repo.commit("Conflicting")
        let outcome = try await handle.applyStash(index: 0, oid: entry.oid, pop: true, context: Ops.context)
        #expect(outcome == .conflicts(paths: ["a.txt"], stashKept: true))
        #expect(try await handle.stashes().first?.oid == entry.oid)
    }

    @Test func stashDropRejectsShiftedIndex() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("a.txt", "first\n")
        let first = try #require(try await handle.stashPush(StashPushRequest(message: "first"), context: Ops.context))
        try repo.write("a.txt", "second\n")
        try await handle.stashPush(StashPushRequest(message: "second"), context: Ops.context)
        // `first` was stash@{0}; it is now stash@{1}.
        do {
            try await handle.dropStash(index: 0, oid: first.oid, token: confirm(.dropStash(index: 0, oid: first.oid)))
            Issue.record("drop must refuse a shifted index")
        } catch {
            // Exhaustive catch + explicit rethrow: Swift 6.3 SILGen crashes on non-exhaustive typed catches (CI, Xcode 26).
            guard case .staleSnapshot = error else { throw error }
        }
        #expect(try await handle.stashes().count == 2)
        try await handle.dropStash(index: 1, oid: first.oid, token: confirm(.dropStash(index: 1, oid: first.oid)))
        #expect(try await handle.stashes().map(\.message) == ["second"])
    }

    @Test func stashApplyUntrackedCollisionErrors() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("new.txt", "stashed\n")
        let entry = try #require(
            try await handle.stashPush(StashPushRequest(includeUntracked: true), context: Ops.context))
        try repo.write("new.txt", "already here\n")
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.applyStash(index: 0, oid: entry.oid, pop: false, context: Ops.context)
        }
        #expect(try Ops.read(repo, "new.txt") == "already here\n")
        #expect(try await handle.stashes().count == 1)
    }

    @Test func stashClear() async throws {
        let (_, repo, handle) = try await Ops.single()
        try repo.write("a.txt", "x\n")
        try await handle.stashPush(StashPushRequest(), context: Ops.context)
        try await handle.clearStashes(token: confirm(.clearStashes))
        #expect(try await handle.stashes().isEmpty)
    }

    @Test func stashAndSwitchKeepsStashOnSuccess() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n"])
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("a.txt", "other\n")
        try await repo.commit("Other")
        try await repo.git("switch", "-q", "main")
        try repo.write("a.txt", "dirty\n")
        try repo.write("u.txt", "untracked\n")
        #expect(
            try await handle.switchTo(.branch("other"), expected: nil)
                == .wouldOverwrite(paths: ["a.txt"], untracked: false))
        let entry = try await handle.stashAndSwitch(.branch("other"), context: Ops.context, expected: nil)
        #expect(entry?.hasUntracked == true)
        #expect(try await repo.git("symbolic-ref", "--short", "HEAD") == "other")
        #expect(try Ops.read(repo, "a.txt") == "other\n")
    }

    @Test func stashAndSwitchRestoresStashWhenSwitchFails() async throws {
        let (_, repo, handle) = try await Ops.single(["a.txt": "a\n"])
        _ = try await repo.addWorktree("wt", branch: "busy")
        try repo.write("a.txt", "dirty\n")
        try repo.write("u.txt", "untracked\n")
        let before = try await RepoFingerprint.capture(repo)
        await #expect(throws: GitCoreError.self) {
            _ = try await handle.stashAndSwitch(.branch("busy"), context: Ops.context, expected: nil)
        }
        let after = try await RepoFingerprint.capture(repo)
        #expect(after.workingTree == before.workingTree, "\(after.difference(from: before))")
        #expect(after.head == before.head)
        #expect(try await handle.stashes().isEmpty)
    }
}
