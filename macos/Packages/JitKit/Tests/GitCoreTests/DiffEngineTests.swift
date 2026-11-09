import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Byte-exact diff engine (P3.3, ADR-0026): real `git diff` output for every fixture, parsed, checked and
/// re-emitted byte for byte.
@Suite struct DiffEngineTests {
    func open(_ repo: TestRepo) async throws -> RepositoryHandle {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
    }

    func committed(_ sandbox: GitSandbox, _ files: [String: String]) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        return repo
    }

    func writeBytes(_ repo: TestRepo, _ path: String, _ bytes: [UInt8]) throws {
        let url = URL(fileURLWithPath: repo.path + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    /// Opens the diff and checks the round-trip property every fixture must hold.
    func diff(_ handle: RepositoryHandle, _ target: DiffTarget, context: Int = 3, full: Bool = false) async throws
        -> DiffDocument
    {
        let document = try await handle.openDiff(target, options: DiffOptions(contextLines: context, fullContext: full))
        #expect(document.storage.serialize() == document.storage.bytes, "round trip for \(target)")
        return document
    }

    func lines(_ document: DiffDocument) -> [(DiffLineKind, String)] {
        (0..<document.storage.lineCount).map { (document.kind(ofLine: $0), document.text(ofLine: $0)) }
    }

    // MARK: Line endings

    @Test func crlfAndMixedLineEndingsArePreserved() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try writeBytes(repo, "crlf.txt", Array("one\r\ntwo\r\n".utf8))
        try writeBytes(repo, "mixed.txt", Array("a\nb\r\nc\n".utf8))
        try await repo.commit("Initial")
        try writeBytes(repo, "crlf.txt", Array("one\r\nTWO\r\n".utf8))
        try writeBytes(repo, "mixed.txt", Array("a\r\nb\r\nc\n".utf8))
        let handle = try await open(repo)

        let crlf = try await diff(handle, .unstaged(path: "crlf.txt"))
        let changed = (0..<crlf.storage.lineCount).filter { crlf.kind(ofLine: $0) != .context }
        #expect(changed.map { crlf.text(ofLine: $0) } == ["two", "TWO"])
        #expect(changed.allSatisfy { crlf.isCRLF(line: $0) })
        #expect(crlf.fileBytes(ofLine: changed[1]) == Array("TWO\r\n".utf8))

        let mixed = try await diff(handle, .unstaged(path: "mixed.txt"))
        let deleted = try #require((0..<mixed.storage.lineCount).first { mixed.kind(ofLine: $0) == .deleted })
        let added = try #require((0..<mixed.storage.lineCount).first { mixed.kind(ofLine: $0) == .added })
        #expect(!mixed.isCRLF(line: deleted) && mixed.isCRLF(line: added))
        #expect(mixed.text(ofLine: deleted) == "a" && mixed.text(ofLine: added) == "a")
    }

    @Test(arguments: [("old", "a\nb", "a\nb\n"), ("new", "a\nb\n", "a\nb"), ("both", "a\nb", "a\nc")])
    func noTrailingNewline(_ label: String, _ before: String, _ after: String) async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["f.txt": before])
        try repo.write("f.txt", after)
        let document = try await diff(try await open(repo), .unstaged(path: "f.txt"))
        let marked = (0..<document.storage.lineCount).filter { document.noNewline(line: $0) }
        switch label {
        case "old":
            #expect(marked.map { document.kind(ofLine: $0) } == [.deleted])
        case "new":
            #expect(marked.map { document.kind(ofLine: $0) } == [.added])
        default:
            #expect(marked.map { document.kind(ofLine: $0) } == [.deleted, .added])
        }
        for line in marked { #expect(document.fileBytes(ofLine: line).last != UInt8(ascii: "\n")) }
    }

    // MARK: Headers

    @Test func stagedRenameWithEditsAndCopy() async throws {
        let sandbox = try GitSandbox()
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let repo = try await committed(sandbox, ["old name.txt": body])
        try await repo.git("mv", "old name.txt", "new \"name\".txt")
        try repo.write("new \"name\".txt", body.replacingOccurrences(of: "line 5\n", with: "line five\n"))
        try await repo.git("add", "-A")
        let handle = try await open(repo)

        let document = try await diff(handle, .staged(path: "new \"name\".txt", renamedFrom: "old name.txt"))
        let file = try #require(document.files.first)
        #expect(document.files.count == 1)
        #expect(file.status == .renamed && file.oldPath == "old name.txt" && file.newPath == "new \"name\".txt")
        #expect((file.similarity ?? 0) > 50)
        #expect(lines(document).filter { $0.0 != .context }.map(\.1) == ["line 5", "line five"])

        // Copy detection is not in the canonical command; parse Git's own copy output to cover the header.
        try await repo.commit("Rename")
        try repo.write("copy.txt", body)
        try await repo.git("add", "copy.txt")
        let output = try await sandbox.engine.run(
            GitCommand(["diff", "--cached", "-C", "-C", "--full-index", "--no-color"], in: repo.path))
        let storage = try PatchParser.parse(output.stdout)
        #expect(storage.serialize() == output.stdout)
        #expect(storage.files.first?.status == .copied && storage.files.first?.newPath == "copy.txt")
    }

    @Test func modeChangeSymlinkBinaryAndEmptyFile() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["run.sh": "echo\n", "blob.bin": "x"])
        try writeBytes(repo, "blob.bin", [0, 1, 2, 0, 255])
        try await repo.commit("Binary")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/run.sh")
        try writeBytes(repo, "blob.bin", [0, 9, 2, 0, 255])
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "run.sh")
        try repo.write("empty.txt", "")
        try await repo.git("add", "link", "empty.txt")
        let handle = try await open(repo)

        let mode = try await diff(handle, .unstaged(path: "run.sh"))
        #expect(mode.files.first?.modeChanged == true && mode.files.first?.newMode == 0o100755)
        #expect(mode.files.first?.path == "run.sh" && mode.hunks.isEmpty)

        let binary = try await diff(handle, .unstaged(path: "blob.bin"))
        #expect(binary.files.first?.isBinary == true && binary.hunks.isEmpty)

        let link = try await diff(handle, .staged(path: "link"))
        #expect(link.files.first?.isSymlink == true && link.files.first?.status == .added)
        #expect(lines(link).map(\.1) == ["run.sh"])
        #expect(link.noNewline(line: 0))

        let empty = try await diff(handle, .staged(path: "empty.txt"))
        #expect(empty.files.first?.status == .added && empty.files.first?.path == "empty.txt" && empty.hunks.isEmpty)
    }

    @Test func submoduleShortFormat() async throws {
        let sandbox = try GitSandbox()
        let sub = try await committed(sandbox, ["s.txt": "s\n"])
        let parent = try await sandbox.makeRepository("parent")
        try parent.write("p.txt", "p\n")
        try await parent.commit("Parent")
        try await sandbox.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", "--", sub.path, "mod"], in: parent.path)
        try await parent.commit("Add submodule")
        let inner = TestRepo(sandbox: sandbox, path: parent.path + "/mod")
        try inner.write("s.txt", "changed\n")
        try await inner.commit("Inner change")

        let document = try await diff(try await open(parent), .unstaged(path: "mod"))
        let file = try #require(document.files.first)
        #expect(file.isSubmodule)
        #expect(lines(document).map(\.1).allSatisfy { $0.hasPrefix("Subproject commit ") })
    }

    @Test(arguments: [
        "ünïcödé 文件.txt", "with space.txt", "quote\"d.txt", "back\\slash.txt", "new\nline.txt", "-leading-dash.txt",
        "tab\there.txt",
    ])
    func awkwardPaths(_ name: String) async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, [name: "a\n"])
        try repo.write(name, "b\n")
        let handle = try await open(repo)
        let document = try await diff(handle, .unstaged(path: name))
        #expect(document.files.map(\.path) == [name])
        #expect(lines(document).map(\.1) == ["a", "b"])
        // The same path as a staged mode-only change has no ---/+++ lines: the path comes from `diff --git`.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/" + name)
        try repo.write(name, "a\n")
        try await sandbox.git(["add", "--", name], in: repo.path)
        let modeOnly = try await diff(handle, .staged(path: name))
        #expect(modeOnly.files.map(\.path) == [name] && modeOnly.files.first?.modeChanged == true)
    }

    // MARK: Untracked synthesis

    @Test func untrackedPatchMatchesGitIntentToAdd() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        let cases: [(String, [UInt8])] = [
            ("plain.txt", Array("one\ntwo\n".utf8)), ("no newline.txt", Array("x\r\ny".utf8)),
            ("sp\"ecial.txt", Array("q\n".utf8)), ("empty.txt", []),
        ]
        for (path, bytes) in cases { try writeBytes(repo, path, bytes) }
        let handle = try await open(repo)
        // A throwaway clone of the working tree shows what Git itself prints after `add -N`.
        let mirror = sandbox.root + "/mirror"
        try FileManager.default.copyItem(atPath: repo.path, toPath: mirror)
        for (path, _) in cases {
            let ours = try await diff(handle, .unstaged(path: path))
            #expect(ours.files.first?.status == .added && ours.files.first?.path == path)
            try await sandbox.git(["add", "-N", "--", path], in: mirror)
            let theirs = try await sandbox.engine.run(
                GitCommand(
                    DiffInvocation.arguments(
                        .unstaged(path: path), options: DiffOptions(fullContext: false), format: .sha1),
                    in: mirror)
            ).stdout
            // `add -N` diffs show the new-file header with the blob id Git computed; ours must be identical.
            #expect(
                String(decoding: ours.storage.bytes, as: UTF8.self) == String(decoding: theirs, as: UTF8.self),
                "\(path)")
        }
        // Nothing was added to the index of the real repository.
        #expect(try await repo.git("ls-files") == "a.txt")
    }

    // MARK: Layouts

    @Test func splitLayoutAlignment() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["f.txt": "keep\nold 1\nold 2\nold 3\nkeep 2\ngone\nkeep 3\n"])
        try repo.write("f.txt", "keep\nnew 1\nkeep 2\nkeep 3\nadded\n")
        let document = try await diff(try await open(repo), .unstaged(path: "f.txt"))
        var pairs: [(String?, String?)] = []
        for index in 0..<document.rowCount(.split) {
            if case .lines(let left, let right) = document.splitRow(index) {
                pairs.append((left.map { document.text(ofLine: $0) }, right.map { document.text(ofLine: $0) }))
            }
        }
        let expected: [(String?, String?)] = [
            ("keep", "keep"), ("old 1", "new 1"), ("old 2", nil), ("old 3", nil), ("keep 2", "keep 2"),
            ("gone", nil), ("keep 3", "keep 3"), (nil, "added"),
        ]
        #expect(pairs.count == expected.count)
        for (got, want) in zip(pairs, expected) { #expect(got.0 == want.0 && got.1 == want.1) }
        // Every line appears exactly once per side.
        let left = pairs.compactMap(\.0)
        let right = pairs.compactMap(\.1)
        #expect(left == ["keep", "old 1", "old 2", "old 3", "keep 2", "gone", "keep 3"])
        #expect(right == ["keep", "new 1", "keep 2", "keep 3", "added"])
    }

    @Test func fullFileRowsMatchPostimage() async throws {
        let sandbox = try GitSandbox()
        let original = (1...200).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
        let repo = try await committed(sandbox, ["f.txt": original])
        var edited = original.replacingOccurrences(of: "line 10\r\n", with: "ten\r\n")
        edited = edited.replacingOccurrences(of: "line 150\r\n", with: "")
        edited += "tail without newline"
        try repo.write("f.txt", edited)
        let document = try await diff(try await open(repo), .unstaged(path: "f.txt"), full: true)

        var post: [UInt8] = []
        var pre: [UInt8] = []
        for index in 0..<document.rowCount(.fullFile) {
            guard case .line(let line) = document.row(.fullFile, index) else { continue }
            if document.kind(ofLine: line) != .deleted { post += document.fileBytes(ofLine: line) }
            if document.kind(ofLine: line) != .added { pre += document.fileBytes(ofLine: line) }
        }
        #expect(post == Array(edited.utf8))
        #expect(pre == Array(original.utf8))

        // The unified layout hides long unchanged runs; expansion is a layout change over the same buffer.
        #expect(document.gaps.count == 3)  // before the first change, between, after the last
        let unifiedLines = (0..<document.rowCount(.unified)).filter {
            if case .line = document.row(.unified, $0) { true } else { false }
        }.count
        #expect(unifiedLines < 30)
        let expanded = document.expandingContext(gap: 1, lines: 5)
        #expect(expanded.storage === document.storage)
        #expect(expanded.gaps[1].count == document.gaps[1].count - 10)
        #expect(document.expandingAll().gaps.isEmpty)
        #expect(document.expandingAll().rowCount(.unified) == document.storage.lineCount + document.hunks.count)
    }

    @Test func searchAndLineIDs() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["f.txt": "alpha\nbeta\n"])
        try repo.write("f.txt", "alpha\nBeta Beta\n")
        let document = try await diff(try await open(repo), .unstaged(path: "f.txt"))
        let matches = document.search("beta")
        #expect(matches.count == 3)  // "beta" once, "Beta" twice
        #expect(document.search("beta", caseSensitive: true).count == 1)
        for line in 0..<document.storage.lineCount { #expect(document.line(document.lineID(line)) == line) }
    }

    @Test func commitDiffsIncludingRootCommit() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        let root = try #require(ObjectID(hex: try await repo.commit("Root")))
        try repo.write("b.txt", "b\n")
        let second = try #require(ObjectID(hex: try await repo.commit("Second")))
        let handle = try await open(repo)
        let rootDiff = try await diff(handle, .commit(root, path: nil))
        #expect(rootDiff.files.map(\.path) == ["a.txt"] && rootDiff.files.first?.status == .added)
        let secondDiff = try await diff(handle, .commit(second, path: nil))
        #expect(secondDiff.files.map(\.path) == ["b.txt"])
        let range = try await diff(handle, .commits(from: root, to: second, path: nil))
        #expect(range.files.map(\.path) == ["b.txt"])
    }

    // MARK: Token and memory

    @Test func snapshotTokenDescribesWhatTheDiffShows() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["f.txt": "a\n"])
        try repo.write("f.txt", "b\n")
        let handle = try await open(repo)
        let document = try await diff(handle, .unstaged(path: "f.txt"))
        let token = try #require(document.token)
        #expect(token.headID != nil && !token.indexEntry.isEmpty && token.worktreeBlobID?.count == 40)
        #expect(token.worktreeBlobID == (try await repo.git("hash-object", "--no-filters", "f.txt")))
        #expect(try await handle.snapshotToken(for: "f.txt").sameState(as: token))
        try repo.write("f.txt", "c\n")
        #expect(!(try await handle.snapshotToken(for: "f.txt").sameState(as: token)))
    }

    @Test func diffDocumentMemory50kLines() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(
            sandbox, ["big.txt": (0..<50_000).map { "original line \($0)" }.joined(separator: "\n") + "\n"])
        try repo.write("big.txt", (0..<50_000).map { "changed line number \($0)" }.joined(separator: "\n") + "\n")
        let clock = ContinuousClock()
        let started = clock.now
        let document = try await diff(try await open(repo), .unstaged(path: "big.txt"))
        let elapsed = clock.now - started
        let lines = document.storage.lineCount
        #expect(lines == 100_000)
        let gitBytes = document.storage.bytes.count
        let total = document.approximateBytes
        let perLine = Double(total) / Double(lines)
        let overhead = Double(total - gitBytes) / Double(lines)
        print(
            "diffDocumentMemory50kLines: \(lines) lines, \(total) bytes, \(String(format: "%.1f", perLine)) B/line total, "
                + "\(String(format: "%.1f", overhead)) B/line beyond Git's output, read+parse+layout \(elapsed)")
        #expect(MemoryLayout<LineRecord>.stride == 16)
        #expect(overhead <= 40)
    }
}
