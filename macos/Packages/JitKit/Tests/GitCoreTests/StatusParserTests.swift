import Foundation
import Testing

@testable import GitCore

/// Porcelain v2 samples in the exact `-z` shape Git 2.39+ emits (captured from real repositories,
/// object names shortened to keep the fixtures readable — the parser doesn't interpret them).
@Suite struct StatusParserTests {
    static let oid = "1f2e3d4c5b6a79881f2e3d4c5b6a79881f2e3d4c"
    static let zero = "0000000000000000000000000000000000000000"

    func bytes(_ records: [String]) -> [UInt8] {
        records.flatMap { Array($0.utf8) + [0] }
    }

    @Test func parsesBranchHeadersWithUpstream() throws {
        let snapshot = try StatusParser.parse(
            bytes([
                "# branch.oid \(Self.oid)", "# branch.head main", "# branch.upstream origin/main",
                "# branch.ab +3 -12",
            ]))
        #expect(
            snapshot.branch == BranchHeader(oid: Self.oid, head: "main", upstream: "origin/main", ahead: 3, behind: 12))
        #expect(snapshot.summary.isClean)
        #expect(snapshot.entries.count == 0)
    }

    @Test func parsesNoUpstream() throws {
        let snapshot = try StatusParser.parse(bytes(["# branch.oid \(Self.oid)", "# branch.head feature/x"]))
        #expect(snapshot.branch.upstream == nil)
        #expect(snapshot.branch.ahead == nil && snapshot.branch.behind == nil)
        #expect(snapshot.branch.repositoryHead == .branch(name: "feature/x", commit: Self.oid))
    }

    @Test func parsesDetached() throws {
        let snapshot = try StatusParser.parse(bytes(["# branch.oid \(Self.oid)", "# branch.head (detached)"]))
        #expect(snapshot.branch.isDetached)
        #expect(snapshot.branch.repositoryHead == .detached(commit: Self.oid))
    }

    @Test func parsesUnborn() throws {
        let snapshot = try StatusParser.parse(bytes(["# branch.oid (initial)", "# branch.head main", "? new.txt"]))
        #expect(snapshot.branch.isUnborn)
        #expect(snapshot.branch.repositoryHead == .unborn(branch: "main"))
        #expect(snapshot.summary.untracked == 1)
    }

    @Test func parsesRenameEntryZFormat() throws {
        let snapshot = try StatusParser.parse(
            bytes([
                "# branch.oid \(Self.oid)", "# branch.head main",
                "2 R. N... 100644 100644 100644 \(Self.oid) \(Self.oid) R100 new name.txt", "old name.txt",
                "1 .M N... 100644 100644 100644 \(Self.oid) \(Self.oid) after.txt",
            ]))
        let entries = snapshot.entries
        #expect(entries.count == 2)
        #expect(entries.kind(at: 0) == .renamedOrCopied)
        #expect(entries.path(at: 0) == "new name.txt")
        #expect(entries.originalPath(at: 0) == "old name.txt")
        #expect(entries.statusCodes(at: 0) == ("R", "."))
        #expect(entries.metadataFields(at: 0).last == "R100")
        #expect(entries.path(at: 1) == "after.txt")
        #expect(entries.originalPath(at: 1) == nil)
        #expect(snapshot.summary == StatusSummary(staged: 1, unstaged: 1))
    }

    @Test func parsesUnmergedEntries() throws {
        let snapshot = try StatusParser.parse(
            bytes([
                "u UU N... 100644 100644 100644 100644 \(Self.oid) \(Self.oid) \(Self.oid) conflict.txt",
                "u AA N... 000000 100644 100644 100644 \(Self.zero) \(Self.oid) \(Self.oid) both added.txt",
            ]))
        #expect(snapshot.summary == StatusSummary(conflicted: 2))
        #expect(snapshot.entries.kind(at: 1) == .unmerged)
        #expect(snapshot.entries.path(at: 1) == "both added.txt")
        #expect(snapshot.entries.statusCodes(at: 0) == ("U", "U"))
    }

    @Test func parsesUntrackedAndIgnored() throws {
        let snapshot = try StatusParser.parse(bytes(["? untracked.txt", "? dir/", "! build/", "! .DS_Store"]))
        #expect(snapshot.summary == StatusSummary(untracked: 2, ignored: 2))
        #expect(snapshot.entries.path(at: 1) == "dir/")
        #expect(snapshot.entries.kind(at: 2) == .ignored)
        #expect(snapshot.summary.isClean == false)
    }

    @Test func parsesUnicodeAndSpacesPaths() throws {
        let names = ["café — résumé.txt", "日本語/ファイル.md", "  leading spaces", "tab\there", "new\nline"]
        let snapshot = try StatusParser.parse(
            bytes(names.map { "1 M. N... 100644 100644 100644 \(Self.oid) \(Self.oid) \($0)" }))
        #expect((0..<snapshot.entries.count).map(snapshot.entries.path(at:)) == names)
        #expect(snapshot.summary.staged == names.count)
    }

    @Test func parsesSubmoduleFields() throws {
        let snapshot = try StatusParser.parse(
            bytes([
                "1 .M SC.U 160000 160000 160000 \(Self.oid) \(Self.oid) vendor/lib",
                "1 .M N... 100644 100644 100644 \(Self.oid) \(Self.oid) plain.txt",
            ]))
        #expect(snapshot.entries.isSubmodule(at: 0))
        #expect(snapshot.entries.submodule[0] == 0b1011)
        #expect(!snapshot.entries.isSubmodule(at: 1))
    }

    @Test func partiallyStagedCountsBoth() throws {
        let snapshot = try StatusParser.parse(
            bytes(["1 MM N... 100644 100644 100644 \(Self.oid) \(Self.oid) both.txt"]))
        #expect(snapshot.summary == StatusSummary(staged: 1, unstaged: 1, changedFiles: 1, partiallyStaged: 1))
        #expect(snapshot.entries.isPartiallyStaged(at: 0))
    }

    @Test(arguments: [
        // missing final NUL
        Array("? file.txt".utf8),
        // too few fields
        Array("1 M. N... 100644\0".utf8),
        // rename without its original path token
        Array("2 R. N... 100644 100644 100644 a b R100 new.txt\0".utf8),
        // unknown record type
        Array("x what\0".utf8),
        // untracked record without path
        Array("?\0".utf8),
    ])
    func rejectsTruncatedRecord(_ input: [UInt8]) {
        #expect(throws: GitCoreError.self) { try StatusParser.parse(input) }
    }

    @Test func emptyOutputIsCleanAndUnknownHeadersIgnored() throws {
        #expect(try StatusParser.parse([]).summary.isClean)
        let snapshot = try StatusParser.parse(bytes(["# stash 3", "# branch.oid \(Self.oid)"]))
        #expect(snapshot.branch.oid == Self.oid)
    }
}

@Suite struct OperationStateDetectorTests {
    func gitDir(_ files: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jit-op-\(UUID().uuidString)").path
        for (name, contents) in files {
            let path = dir + "/" + name
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func detectsEachMarker() throws {
        #expect(OperationStateDetector.detect(gitDirectory: try gitDir([:])) == OperationState.none)
        #expect(OperationStateDetector.detect(gitDirectory: try gitDir(["MERGE_HEAD": "x"])) == .merging)
        #expect(OperationStateDetector.detect(gitDirectory: try gitDir(["CHERRY_PICK_HEAD": "x"])) == .cherryPicking)
        #expect(OperationStateDetector.detect(gitDirectory: try gitDir(["REVERT_HEAD": "x"])) == .reverting)
        #expect(OperationStateDetector.detect(gitDirectory: try gitDir(["BISECT_LOG": "x"])) == .bisecting)
        #expect(
            OperationStateDetector.detect(
                gitDirectory: try gitDir(["rebase-merge/msgnum": "3\n", "rebase-merge/end": "7\n"]))
                == .rebasing(step: 3, total: 7))
        #expect(
            OperationStateDetector.detect(
                gitDirectory: try gitDir(["rebase-apply/next": "1", "rebase-apply/last": "2"]))
                == .rebasing(step: 1, total: 2))
        #expect(
            OperationStateDetector.detect(
                gitDirectory: try gitDir(["rebase-apply/applying": "", "rebase-apply/next": "1"]))
                == .applyingMailbox)
    }
}
