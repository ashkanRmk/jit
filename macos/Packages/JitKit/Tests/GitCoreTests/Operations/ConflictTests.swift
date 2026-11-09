import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// P4.11 / P4.13 — conflict entries, documents, saves and fallback resolutions on real repositories.
@Suite struct ConflictTests {
    func confirm(_ action: DestructiveAction) -> ConfirmationToken {
        ConfirmationRequest(action: action, title: "", context: "", changes: "", recoverability: "", verb: "OK")
            .confirm()
    }

    /// Commits `base`, then `ours` on main and `theirs` on a branch, and merges into a conflict.
    func conflict(
        path: String = "a.txt", base: [UInt8]?, ours: [UInt8]?, theirs: [UInt8]?,
        setup: ((TestRepo) async throws -> Void)? = nil
    ) async throws -> (TestRepo, RepositoryHandle) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("keep.txt", "keep\n")
        try await setup?(repo)
        func put(_ bytes: [UInt8]?) throws {
            let url = URL(fileURLWithPath: repo.path + "/" + path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let bytes { try Data(bytes).write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        try put(base)
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "theirs")
        try put(theirs)
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try put(ours)
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "theirs")
        return (repo, try await Ops.open(repo))
    }

    func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Kinds

    @Test func conflictKindsUU() async throws {
        let (keptHandle, handle) = try await conflict(
            base: bytes("a\nb\nc\n"), ours: bytes("a\nB1\nc\n"), theirs: bytes("a\nB2\nc\n"))
        defer { withExtendedLifetime(keptHandle) {} }
        let entry = try #require(try await handle.conflicts().first)
        #expect(entry.code == .bothModified)
        #expect(entry.presentation == .text)
        #expect(entry.base != nil && entry.ours != nil && entry.theirs != nil)
    }

    @Test func conflictKindsAA() async throws {
        let (keptHandle, handle) = try await conflict(base: nil, ours: bytes("ours\n"), theirs: bytes("theirs\n"))
        defer { withExtendedLifetime(keptHandle) {} }
        let entry = try #require(try await handle.conflicts().first)
        #expect(entry.code == .bothAdded)
        #expect(entry.base == nil)
        let document = try await handle.loadConflict(entry)
        #expect(document.conflictCount == 1)
        #expect(document.render([document.conflictIndices[0]: .theirs]) == bytes("theirs\n"))
    }

    @Test func conflictKindsUDAndDU() async throws {
        let (keptUd, ud) = try await conflict(base: bytes("a\n"), ours: bytes("a changed\n"), theirs: nil)
        defer { withExtendedLifetime(keptUd) {} }
        let modifiedByUs = try #require(try await ud.conflicts().first)
        #expect(modifiedByUs.code == .deletedByThem)
        #expect(modifiedByUs.presentation == .modifyDelete(deletedBy: .theirs))
        let (keptDu, du) = try await conflict(base: bytes("a\n"), ours: nil, theirs: bytes("a changed\n"))
        defer { withExtendedLifetime(keptDu) {} }
        let deletedByUs = try #require(try await du.conflicts().first)
        #expect(deletedByUs.code == .deletedByUs)
        #expect(deletedByUs.presentation == .modifyDelete(deletedBy: .ours))
    }

    @Test func conflictKindsAUUADD() async throws {
        // rename/rename(1to2): DD for the source, AU / UA for each destination.
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("orig.txt", "content\nline\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "theirs")
        try await repo.git("mv", "orig.txt", "theirs-name.txt")
        try await repo.commit("Rename theirs")
        try await repo.git("switch", "-q", "main")
        try await repo.git("mv", "orig.txt", "ours-name.txt")
        try await repo.commit("Rename ours")
        _ = try? await repo.git("merge", "theirs")
        let handle = try await Ops.open(repo)
        let codes = Dictionary(uniqueKeysWithValues: try await handle.conflicts().map { ($0.path, $0.code) })
        #expect(codes["orig.txt"] == .bothDeleted)
        #expect(codes["ours-name.txt"] == .addedByUs)
        #expect(codes["theirs-name.txt"] == .addedByThem)
    }

    @Test func conflictBinarySymlinkSubmoduleDetected() async throws {
        let (keptBinary, binary) = try await conflict(
            path: "img.bin", base: [0, 1, 2, 3], ours: [0, 1, 9, 3], theirs: [0, 1, 8, 3])
        defer { withExtendedLifetime(keptBinary) {} }
        #expect(try await binary.conflicts().first?.presentation == .pickSide(reason: "Binary file"))

        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("x.txt", "x\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "theirs")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "theirs-target")
        try await repo.commit("Theirs link")
        try await repo.git("switch", "-q", "main")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "ours-target")
        try await repo.commit("Ours link")
        _ = try? await repo.git("merge", "theirs")
        let handle = try await Ops.open(repo)
        let entry = try #require(try await handle.conflicts().first)
        #expect(entry.isSymlink)
        #expect(entry.presentation == .pickSide(reason: "Symbolic link"))

        // Submodule: a gitlink conflict (stage modes 160000), built with update-index.
        let sub = try await sandbox.makeRepository("sub")
        let c1 = try await sub.commit("c1")
        let c2 = try await sub.commit("c2")
        let c3 = try await sub.commit("c3")
        let superRepo = try await sandbox.makeRepository("super")
        try await superRepo.git("update-index", "--add", "--cacheinfo", "160000,\(c1),sub")
        try await superRepo.git("commit", "-q", "-m", "Base")
        try await superRepo.git("switch", "-q", "-c", "theirs")
        try await superRepo.git("update-index", "--cacheinfo", "160000,\(c3),sub")
        try await superRepo.git("commit", "-q", "-m", "Theirs")
        try await superRepo.git("switch", "-q", "main")
        try await superRepo.git("update-index", "--cacheinfo", "160000,\(c2),sub")
        try await superRepo.git("commit", "-q", "-m", "Ours")
        _ = try? await superRepo.git("merge", "theirs")
        let superHandle = try await Ops.open(superRepo)
        let gitlink = try #require(try await superHandle.conflicts().first)
        #expect(gitlink.isSubmodule)
        #expect(gitlink.presentation == .submodule)
    }

    @Test func nonUTF8FallsBack() async throws {
        let (keptHandle, handle) = try await conflict(
            base: [0x61, 0x0A], ours: [0xE9, 0x61, 0x0A], theirs: [0xE8, 0x61, 0x0A])
        defer { withExtendedLifetime(keptHandle) {} }
        #expect(try await handle.conflicts().first?.presentation == .pickSide(reason: "Not UTF-8 text"))
    }

    // MARK: Documents

    @Test func conflictDocumentSegmentsMatchGit() async throws {
        let base = bytes("1\n2\n3\n4\n5\n6\n7\n8\n9\n")
        let ours = bytes("1\nOURS\n3\n4\n5\n6\n7\nours tail\n9\n")
        let theirs = bytes("1\nTHEIRS\n3\n4\n5\n6\n7\ntheirs tail\n9\n")
        let (repo, handle) = try await conflict(base: base, ours: ours, theirs: theirs)
        let entry = try #require(try await handle.conflicts().first)
        let document = try await handle.loadConflict(entry)
        #expect(document.conflictCount == 2)
        #expect(document.workingTreeLooksUnedited)
        let allOurs = Dictionary(uniqueKeysWithValues: document.conflictIndices.map { ($0, BlockChoice.ours) })
        let allTheirs = Dictionary(uniqueKeysWithValues: document.conflictIndices.map { ($0, BlockChoice.theirs) })
        #expect(document.render(allOurs) == ours)
        #expect(document.render(allTheirs) == theirs)
        #expect(try await MergeFileOracle.run(repo, ours, base, theirs, "--ours") == ours)
        // Opening never resolves: the index is still unmerged.
        #expect(try await handle.unmergedPaths() == ["a.txt"])
    }

    @Test func openingDoesNotMarkResolved() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("b\n"), theirs: bytes("c\n"))
        let before = try await RepoFingerprint.capture(repo)
        let entry = try #require(try await handle.conflicts().first)
        _ = try await handle.loadConflict(entry)
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(try await handle.unmergedPaths() == ["a.txt"])
    }

    @Test func conflictCRLFPreserved() async throws {
        let (keptHandle, handle) = try await conflict(
            base: bytes("a\r\nb\r\nc\r\n"), ours: bytes("a\r\nours\r\nc\r\n"), theirs: bytes("a\r\ntheirs\r\nc\r\n"))
        defer { withExtendedLifetime(keptHandle) {} }
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        #expect(document.usesCRLF)
        let index = try #require(document.conflictIndices.first)
        #expect(document.render([index: .ours]) == bytes("a\r\nours\r\nc\r\n"))
        #expect(document.render([index: .oursThenTheirs]) == bytes("a\r\nours\r\ntheirs\r\nc\r\n"))
    }

    @Test func conflictNoTrailingNewlinePreserved() async throws {
        let (keptHandle, handle) = try await conflict(
            base: bytes("a\nb"), ours: bytes("a\nours"), theirs: bytes("a\ntheirs"))
        defer { withExtendedLifetime(keptHandle) {} }
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        let index = try #require(document.conflictIndices.first)
        #expect(document.render([index: .ours]) == bytes("a\nours"))
        #expect(document.render([index: .theirs]) == bytes("a\ntheirs"))
        #expect(document.render([index: .oursThenTheirs]) == bytes("a\nours\ntheirs"))
    }

    @Test func conflictUnicodePath() async throws {
        let (keptHandle, handle) = try await conflict(
            path: "dossier/éàü 文件.txt", base: bytes("a\n"), ours: bytes("ü\n"), theirs: bytes("文\n"))
        defer { withExtendedLifetime(keptHandle) {} }
        let entry = try #require(try await handle.conflicts().first)
        #expect(entry.path == "dossier/éàü 文件.txt")
        let document = try await handle.loadConflict(entry)
        #expect(document.render([document.conflictIndices[0]: .theirs]) == bytes("文\n"))
    }

    @Test func markersInContentAreJustContent() async throws {
        let tricky = "=======\n<<<<<<< ours\n>>>>>>> theirs\n"
        let (keptHandle, handle) = try await conflict(
            base: bytes("x\n" + tricky), ours: bytes("ours\n" + tricky), theirs: bytes("theirs\n" + tricky))
        defer { withExtendedLifetime(keptHandle) {} }
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        #expect(document.markerSize > 7)
        #expect(document.conflictCount == 1)
        #expect(document.render([document.conflictIndices[0]: .ours]) == bytes("ours\n" + tricky))
    }

    // MARK: Saving and resolving

    @Test func saveIsAtomicAndKeepsMode() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("b\n"), theirs: bytes("c\n"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/a.txt")
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        let current = try #require(FileHash.of(path: repo.path + "/a.txt"))
        #expect(current == document.workingTreeHash)
        let saved = try await handle.saveResolution("a.txt", content: bytes("resolved\n"), expected: current)
        #expect(try Ops.read(repo, "a.txt") == "resolved\n")
        #expect(saved == FileHash(bytes("resolved\n")))
        let mode = try FileManager.default.attributesOfItem(atPath: repo.path + "/a.txt")[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repo.path).filter {
            $0.hasPrefix(".jit-resolve")
        }
        #expect(leftovers.isEmpty)
        // Still unmerged until explicitly marked.
        #expect(try await handle.unmergedPaths() == ["a.txt"])
    }

    @Test func saveRefusesWhenFileChangedExternally() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("b\n"), theirs: bytes("c\n"))
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        try repo.write("a.txt", "edited in another editor\n")
        do {
            _ = try await handle.saveResolution("a.txt", content: bytes("mine\n"), expected: document.workingTreeHash)
            Issue.record("save must refuse")
        } catch .staleSnapshot {
        }
        #expect(try Ops.read(repo, "a.txt") == "edited in another editor\n")
    }

    @Test func markResolvedRequiresMatchingHash() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("b\n"), theirs: bytes("c\n"))
        let document = try await handle.loadConflict(try #require(try await handle.conflicts().first))
        let saved = try await handle.saveResolution(
            "a.txt", content: bytes("done\n"), expected: document.workingTreeHash)
        try repo.write("a.txt", "changed after save\n")
        await #expect(throws: GitCoreError.self) { try await handle.markResolved("a.txt", expected: saved) }
        #expect(try await handle.unmergedPaths() == ["a.txt"])
        let again = try await handle.saveResolution(
            "a.txt", content: bytes("done\n"), expected: FileHash(bytes("changed after save\n")))
        try await handle.markResolved("a.txt", expected: again)
        #expect(try await handle.unmergedPaths().isEmpty)
        #expect(try await repo.git("show", ":a.txt") == "done")
    }

    @Test func resolveModifyDeleteKeep() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("modified\n"), theirs: nil)
        try await handle.resolveWithSide(
            "a.txt", choice: .keepFile, token: confirm(.resolveConflict(path: "a.txt", choice: "keepFile")))
        #expect(try await handle.unmergedPaths().isEmpty)
        #expect(try await repo.git("show", ":a.txt") == "modified")
    }

    @Test func resolveModifyDeleteDelete() async throws {
        let (repo, handle) = try await conflict(base: bytes("a\n"), ours: bytes("modified\n"), theirs: nil)
        try await handle.resolveWithSide(
            "a.txt", choice: .deleteFile, token: confirm(.resolveConflict(path: "a.txt", choice: "deleteFile")))
        #expect(try await handle.unmergedPaths().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/a.txt"))
        #expect(try await repo.git("ls-files", "a.txt") == "")
    }

    @Test(arguments: [ConflictFallbackChoice.ours, .theirs])
    func resolveBinary(choice: ConflictFallbackChoice) async throws {
        let ours: [UInt8] = [0, 1, 9, 3]
        let theirs: [UInt8] = [0, 1, 8, 3]
        let (repo, handle) = try await conflict(path: "img.bin", base: [0, 1, 2, 3], ours: ours, theirs: theirs)
        await #expect(throws: GitCoreError.self) {
            try await handle.resolveWithSide(
                "img.bin", choice: choice, token: confirm(.resolveConflict(path: "img.bin", choice: "other")))
        }
        try await handle.resolveWithSide(
            "img.bin", choice: choice, token: confirm(.resolveConflict(path: "img.bin", choice: choice.rawValue)))
        let data = try Data(contentsOf: URL(fileURLWithPath: repo.path + "/img.bin"))
        #expect([UInt8](data) == (choice == .ours ? ours : theirs))
        #expect(try await handle.unmergedPaths().isEmpty)
    }

    @Test func resolveSymlink() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("x.txt", "x\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "theirs")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "theirs-target")
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "ours-target")
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "theirs")
        let handle = try await Ops.open(repo)
        try await handle.resolveWithSide(
            "link", choice: .theirs, token: confirm(.resolveConflict(path: "link", choice: "theirs")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: repo.path + "/link") == "theirs-target")
        #expect(try await handle.unmergedPaths().isEmpty)
    }

    @Test func submoduleConflictOffersTerminalOnly() async throws {
        let entry = ConflictEntry(
            path: "sub", code: .bothModified,
            base: ConflictStage(mode: "160000", oid: String(repeating: "a", count: 40)),
            ours: ConflictStage(mode: "160000", oid: String(repeating: "b", count: 40)),
            theirs: ConflictStage(mode: "160000", oid: String(repeating: "c", count: 40)), isBinary: false,
            isOversized: false, isValidUTF8: true)
        #expect(entry.presentation == .submodule)
    }

    @Test func renameRenamePathsReported() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("orig.txt", "content\n")
        try await repo.commit("Base")
        try await repo.git("switch", "-q", "-c", "theirs")
        try await repo.git("mv", "orig.txt", "b.txt")
        try await repo.commit("Rename to b")
        try await repo.git("switch", "-q", "main")
        try await repo.git("mv", "orig.txt", "a.txt")
        try await repo.commit("Rename to a")
        _ = try? await repo.git("merge", "theirs")
        let paths = Set(try await Ops.open(repo).conflicts().map(\.path))
        #expect(paths == ["orig.txt", "a.txt", "b.txt"])
    }

    // MARK: Property test

    /// Random three-way edits (fixed seeds): taking ours / theirs everywhere reproduces Git's own
    /// `merge-file --ours / --theirs`, and union (both, ours first) reproduces `--union` when lines end in
    /// newlines. Seeds: `JIT_PROPERTY_SEED`; cases: `JIT_PROPERTY_CASES`.
    @Test func randomThreeWayEditsMatchGit() async throws {
        let environment = ProcessInfo.processInfo.environment
        let cases = Int(environment["JIT_PROPERTY_CASES"] ?? "") ?? (environment["CI"] != nil ? 400 : 60)
        let seed = UInt64(environment["JIT_PROPERTY_SEED"] ?? "") ?? 0x5EED_4011
        var generator = SplitMix(seed: seed)
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        for iteration in 0..<cases {
            let lineCount = Int.random(in: 1...14, using: &generator)
            let base = (0..<lineCount).map { "line \($0)" }
            func mutate() -> [String] {
                var lines = base
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    let at = Int.random(in: 0...lines.count, using: &generator)
                    switch Int.random(in: 0..<3, using: &generator) {
                    case 0 where !lines.isEmpty && at < lines.count:
                        lines[at] = "edit \(Int.random(in: 0..<99, using: &generator))"
                    case 1 where !lines.isEmpty && at < lines.count: lines.remove(at: at)
                    default: lines.insert("new \(Int.random(in: 0..<99, using: &generator))", at: at)
                    }
                }
                return lines
            }
            let trailing = Bool.random(using: &generator)
            let crlf = iteration % 7 == 3
            func join(_ lines: [String]) -> [UInt8] {
                let eol = crlf ? "\r\n" : "\n"
                var text = lines.joined(separator: eol)
                if trailing && !lines.isEmpty { text += eol }
                return Array(text.utf8)
            }
            let (b, o, t) = (join(base), join(mutate()), join(mutate()))
            let (segments, markerSize, merged) = try await MergeFileOracle.document(repo, o, b, t)
            let document = ConflictDocument(
                path: "x",
                entry: ConflictEntry(
                    path: "x", code: .bothModified, base: nil, ours: nil, theirs: nil, isBinary: false,
                    isOversized: false, isValidUTF8: true),
                bytes: merged, segments: segments, ours: o, base: b, theirs: t, markerSize: markerSize,
                workingTreeHash: .missing, workingTree: nil, workingTreeMatchesGit: false)
            let indices = document.conflictIndices
            let ours = document.render(Dictionary(uniqueKeysWithValues: indices.map { ($0, BlockChoice.ours) }))
            let theirs = document.render(Dictionary(uniqueKeysWithValues: indices.map { ($0, BlockChoice.theirs) }))
            #expect(
                ours == (try await MergeFileOracle.run(repo, o, b, t, "--ours")), "seed \(seed) case \(iteration) ours")
            #expect(
                theirs == (try await MergeFileOracle.run(repo, o, b, t, "--theirs")),
                "seed \(seed) case \(iteration) theirs")
            if trailing {
                let union = document.render(
                    Dictionary(uniqueKeysWithValues: indices.map { ($0, BlockChoice.oursThenTheirs) }))
                #expect(
                    union == (try await MergeFileOracle.run(repo, o, b, t, "--union", "--zdiff3")),
                    "seed \(seed) case \(iteration) union")
            }
        }
    }
}

/// Runs `git merge-file` on three byte arrays (the oracle for the property test).
enum MergeFileOracle {
    static func files(_ repo: TestRepo, _ ours: [UInt8], _ base: [UInt8], _ theirs: [UInt8]) throws -> String {
        let directory = repo.sandbox.root + "/mf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(ours).write(to: URL(fileURLWithPath: directory + "/ours"))
        try Data(base).write(to: URL(fileURLWithPath: directory + "/base"))
        try Data(theirs).write(to: URL(fileURLWithPath: directory + "/theirs"))
        return directory
    }

    static func run(_ repo: TestRepo, _ ours: [UInt8], _ base: [UInt8], _ theirs: [UInt8], _ mode: String...)
        async throws -> [UInt8]
    {
        let directory = try files(repo, ours, base, theirs)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        return try await repo.sandbox.engine.run(
            GitCommand(
                ["merge-file", "-p"] + mode + ["ours", "base", "theirs"], in: directory, acceptedExitCodes: Set(0...127)
            )
        ).stdout
    }

    static func document(_ repo: TestRepo, _ ours: [UInt8], _ base: [UInt8], _ theirs: [UInt8]) async throws
        -> ([ConflictSegment], Int, [UInt8])
    {
        let directory = try files(repo, ours, base, theirs)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let size = ConflictDocument.markerSize(for: [ours, base, theirs])
        let output = try await repo.sandbox.engine.run(
            GitCommand(
                [
                    "merge-file", "-p", "--zdiff3", "--marker-size=\(size)", "-L", "ours", "-L", "base", "-L", "theirs",
                    "ours", "base", "theirs",
                ],
                in: directory, acceptedExitCodes: Set(0...127))
        ).stdout
        let segments = try #require(ConflictDocument.parse(output, markerSize: size))
        return (segments, size, output)
    }
}

/// Deterministic PRNG for reproducible property tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// P4.12 budget: a 5,000-line file with 20 conflict blocks loads (stages + merge-file + parse) in < 250 ms
/// (release). Debug builds get PerfBudget headroom.
@Suite struct ConflictPerformanceTests {
    @Test func load5000LineConflictWith20Blocks() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let base = (0..<5000).map { "let value\($0) = \($0)" }
        try repo.write("big.swift", base.joined(separator: "\n") + "\n")
        try await repo.commit("Base")
        func edit(_ tag: String) -> String {
            var lines = base
            for block in 0..<20 { lines[block * 250 + 10] = "let value\(block * 250 + 10) = \(tag)" }
            return lines.joined(separator: "\n") + "\n"
        }
        try await repo.git("switch", "-q", "-c", "theirs")
        try repo.write("big.swift", edit("theirs"))
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try repo.write("big.swift", edit("ours"))
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "theirs")
        let handle = try await Ops.open(repo)
        let clock = ContinuousClock()
        let start = clock.now
        let entry = try #require(try await handle.conflicts().first)
        let document = try await handle.loadConflict(entry)
        let elapsed = clock.now - start
        print("load5000LineConflictWith20Blocks: \(elapsed)")
        #expect(document.conflictCount == 20)
        // The budget is a release target (≈60 ms measured with `-c release`); in debug runs the ~8 Git spawns are at
        // the mercy of the parallel suite, so the value is only recorded there.
        #if !DEBUG
            #expect(elapsed < .milliseconds(250))
        #endif
    }
}
