import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import GitCore

/// Line-level stage / unstage / discard / keep-only (P3.4, design §4.4, §7.4 matrix) on real repositories.
/// Every test checks the target and that everything else — other files, other index entries — is
/// byte-identical.
@Suite struct ApplyTests {
    struct World {
        let sandbox: GitSandbox
        let repo: TestRepo
        let handle: RepositoryHandle
        let hooks: DiscardHooks
        let recovered: Recorded
    }

    final class Recorded: Sendable {
        let paths = Mutex<[String]>([])
        func append(_ path: String) { paths.withLock { $0.append(path) } }
        var all: [String] { paths.withLock { $0 } }
    }

    func world(_ files: [String: [UInt8]], config: [(String, String)] = [], attributes: String? = nil) async throws
        -> World
    {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        for (key, value) in config { try await repo.git("config", key, value) }
        if let attributes { try write(repo, ".gitattributes", Array(attributes.utf8)) }
        for (path, bytes) in files { try write(repo, path, bytes) }
        try write(repo, "bystander.txt", Array("never touched\r\nno newline".utf8))
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "Initial")
        let engine = GitEngine(configuration: sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let recovered = Recorded()
        let root = sandbox.root
        let hooks = DiscardHooks(
            preserve: { path, url in
                let copy = root + "/recovery-" + UUID().uuidString
                try FileManager.default.copyItem(atPath: url.path, toPath: copy)
                recovered.append(path)
                return copy
            }, trash: { _ in })
        return World(sandbox: sandbox, repo: repo, handle: handle, hooks: hooks, recovered: recovered)
    }

    func write(_ repo: TestRepo, _ path: String, _ bytes: [UInt8]) throws {
        let url = URL(fileURLWithPath: repo.path + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    func worktree(_ w: World, _ path: String) -> [UInt8]? {
        FileManager.default.contents(atPath: w.repo.path + "/" + path).map { Array($0) }
    }

    func index(_ w: World, _ path: String) async throws -> [UInt8]? {
        let listing = try await RepositoryHandle.indexListing(engine: w.sandbox.engine, in: w.repo.path)
        guard let entry = listing[path] else { return nil }
        return try await RepositoryHandle.blob(entry.id, engine: w.sandbox.engine, in: w.repo.path)
    }

    /// Everything except `path`: other index entries and other working-tree files.
    func bystanders(_ w: World, except path: String) async throws -> String {
        var listing = try await w.repo.git("ls-files", "-s", "-z").split(separator: "\0").filter {
            !$0.hasSuffix("\t" + path)
        }
        listing.sort()
        var files: [String] = []
        for name in try FileManager.default.subpathsOfDirectory(atPath: w.repo.path).sorted()
        where !name.hasPrefix(".git/") && name != ".git" && name != path {
            let data = FileManager.default.contents(atPath: w.repo.path + "/" + name) ?? Data()
            files.append("\(name)=\(data.base64EncodedString())")
        }
        return listing.joined(separator: "|") + "#" + files.joined(separator: "|")
    }

    func doc(_ w: World, _ target: DiffTarget) async throws -> DiffDocument {
        try await w.handle.openDiff(target)
    }

    func select(_ d: DiffDocument, _ predicate: (DiffLineKind, String) -> Bool) -> Set<Int> {
        Set(
            (0..<d.storage.lineCount).filter {
                d.kind(ofLine: $0) != .context && predicate(d.kind(ofLine: $0), d.text(ofLine: $0))
            })
    }

    @discardableResult
    func run(
        _ w: World, _ target: DiffTarget, _ action: SelectionAction, path: String,
        _ predicate: (DiffLineKind, String) -> Bool
    ) async throws -> ApplyOutcome {
        let before = try await bystanders(w, except: path)
        let d = try await doc(w, target)
        let outcome = try await w.handle.apply(
            SelectionRequest(document: d, lines: select(d, predicate), action: action), hooks: w.hooks)
        #expect(try await bystanders(w, except: path) == before, "unrelated files and index entries unchanged")
        return outcome
    }

    func s(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Stage

    @Test func stageSingleAddedLine() async throws {
        let w = try await world(["f.txt": s("a\nb\nc\n")])
        try write(w.repo, "f.txt", s("a\nnew 1\nb\nnew 2\nc\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "new 2" }
        #expect(try await index(w, "f.txt") == s("a\nb\nnew 2\nc\n"))
        #expect(worktree(w, "f.txt") == s("a\nnew 1\nb\nnew 2\nc\n"))
    }

    @Test func stageSingleDeletedLine() async throws {
        let w = try await world(["f.txt": s("a\nb\nc\nd\n")])
        try write(w.repo, "f.txt", s("a\nd\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "c" }
        #expect(try await index(w, "f.txt") == s("a\nb\nd\n"))
    }

    @Test func stageMixedLinesOneHunk() async throws {
        let w = try await world(["f.txt": s("a\nold 1\nold 2\nz\n")])
        try write(w.repo, "f.txt", s("a\nnew 1\nnew 2\nz\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "old 1" || $1 == "new 2" }
        #expect(try await index(w, "f.txt") == s("a\nold 2\nnew 2\nz\n"))
    }

    @Test func stageLinesAcrossAdjacentHunks() async throws {
        let original = (1...40).map { "line \($0)\n" }.joined()
        let w = try await world(["f.txt": s(original)])
        var edited = original.replacingOccurrences(of: "line 3\n", with: "three\n")
        edited = edited.replacingOccurrences(of: "line 20\n", with: "line 20\ntwenty+\n")
        edited = edited.replacingOccurrences(of: "line 38\n", with: "")
        try write(w.repo, "f.txt", s(edited))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "twenty+" || $1 == "line 38" }
        var expected = original.replacingOccurrences(of: "line 20\n", with: "line 20\ntwenty+\n")
        expected = expected.replacingOccurrences(of: "line 38\n", with: "")
        #expect(try await index(w, "f.txt") == s(expected))
    }

    @Test func stageOnPartiallyStagedFile() async throws {
        let w = try await world(["f.txt": s("a\nb\nc\n")])
        try write(w.repo, "f.txt", s("a\nstaged\nb\nc\n"))
        try await w.repo.git("add", "f.txt")
        try write(w.repo, "f.txt", s("a\nstaged\nb\nmore 1\nc\nmore 2\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "more 2" }
        #expect(try await index(w, "f.txt") == s("a\nstaged\nb\nc\nmore 2\n"))
    }

    @Test func stageLinesOfUntrackedFile() async throws {
        let w = try await world([:])
        try write(w.repo, "new.txt", s("keep 1\nskip\nkeep 2\n"))
        try await run(w, .unstaged(path: "new.txt"), .stage, path: "new.txt") { $1.hasPrefix("keep") }
        #expect(try await index(w, "new.txt") == s("keep 1\nkeep 2\n"))
        #expect(worktree(w, "new.txt") == s("keep 1\nskip\nkeep 2\n"))
    }

    @Test func stagePartialDeletionOfDeletedFile() async throws {
        let w = try await world(["gone.txt": s("a\nb\nc\n")])
        try FileManager.default.removeItem(atPath: w.repo.path + "/gone.txt")
        try await run(w, .unstaged(path: "gone.txt"), .stage, path: "gone.txt") { $1 == "b" }
        #expect(try await index(w, "gone.txt") == s("a\nc\n"))
    }

    @Test func stageFullDeletion() async throws {
        let w = try await world(["gone.txt": s("a\nb\n")])
        try FileManager.default.removeItem(atPath: w.repo.path + "/gone.txt")
        try await run(w, .unstaged(path: "gone.txt"), .stage, path: "gone.txt") { _, _ in true }
        #expect(try await index(w, "gone.txt") == nil)
    }

    // MARK: Unstage

    @Test func unstageSingleLine() async throws {
        let w = try await world(["f.txt": s("a\nb\n")])
        try write(w.repo, "f.txt", s("a\nx\nb\ny\n"))
        try await w.repo.git("add", "f.txt")
        try await run(w, .staged(path: "f.txt"), .unstage, path: "f.txt") { $1 == "y" }
        #expect(try await index(w, "f.txt") == s("a\nx\nb\n"))
        #expect(worktree(w, "f.txt") == s("a\nx\nb\ny\n"))
    }

    @Test func unstageLinesAcrossHunks() async throws {
        let original = (1...30).map { "l\($0)\n" }.joined()
        let w = try await world(["f.txt": s(original)])
        let edited = original.replacingOccurrences(of: "l2\n", with: "two\n").replacingOccurrences(
            of: "l28\n", with: "")
        try write(w.repo, "f.txt", s(edited))
        try await w.repo.git("add", "f.txt")
        try await run(w, .staged(path: "f.txt"), .unstage, path: "f.txt") { $1 == "two" || $1 == "l2" || $1 == "l28" }
        #expect(try await index(w, "f.txt") == s(original))
    }

    @Test func unstageAllLinesOfNewFile() async throws {
        let w = try await world([:])
        try write(w.repo, "new.txt", s("a\nb\n"))
        try await w.repo.git("add", "new.txt")
        try await run(w, .staged(path: "new.txt"), .unstage, path: "new.txt") { _, _ in true }
        #expect(try await index(w, "new.txt") == nil)
        #expect(worktree(w, "new.txt") == s("a\nb\n"))
    }

    @Test func renameStagedUnstageLinesRefused() async throws {
        let body = (1...20).map { "line \($0)\n" }.joined()
        let w = try await world(["old.txt": s(body)])
        try await w.repo.git("mv", "old.txt", "new.txt")
        try write(w.repo, "new.txt", s(body + "extra\n"))
        try await w.repo.git("add", "new.txt")
        let d = try await doc(w, .staged(path: "new.txt", renamedFrom: "old.txt"))
        #expect(PatchBuilder.unsupported(d) == .renamed)
        await #expect(throws: GitCoreError.self) {
            try await w.handle.apply(
                SelectionRequest(document: d, lines: self.select(d) { _, _ in true }, action: .unstage))
        }
    }

    // MARK: Discard / keep only

    @Test func discardSingleLine() async throws {
        let w = try await world(["f.txt": s("a\nb\n")])
        try write(w.repo, "f.txt", s("a\nx\nb\ny\n"))
        try await w.repo.git("add", "f.txt")
        try write(w.repo, "f.txt", s("a\nx\nb\ny\nz\nw\n"))
        let indexBefore = try await index(w, "f.txt")
        let outcome = try await run(w, .unstaged(path: "f.txt"), .discard, path: "f.txt") { $1 == "z" }
        #expect(worktree(w, "f.txt") == s("a\nx\nb\ny\nw\n"))
        #expect(try await index(w, "f.txt") == indexBefore)  // discardNeverTouchesIndex
        #expect(outcome.recoveryID != nil && w.recovered.all == ["f.txt"])
    }

    @Test func keepOnlySelectedLines() async throws {
        let w = try await world(["f.txt": s("a\nb\nc\n")])
        try write(w.repo, "f.txt", s("a\nkeep\nb\ndrop\n"))
        try await run(w, .unstaged(path: "f.txt"), .keepOnly, path: "f.txt") { $1 == "keep" }
        #expect(worktree(w, "f.txt") == s("a\nkeep\nb\nc\n"))
    }

    // MARK: Line endings

    @Test func crlfStageAndDiscard() async throws {
        let w = try await world(["f.txt": s("a\r\nb\r\n")])
        try write(w.repo, "f.txt", s("a\r\nnew\r\nb\r\nother\r\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "new" }
        #expect(try await index(w, "f.txt") == s("a\r\nnew\r\nb\r\n"))
        try await run(w, .unstaged(path: "f.txt"), .discard, path: "f.txt") { $1 == "other" }
        #expect(worktree(w, "f.txt") == s("a\r\nnew\r\nb\r\n"))
    }

    @Test func mixedEolFile() async throws {
        let w = try await world(["f.txt": s("a\nb\r\nc\n")])
        try write(w.repo, "f.txt", s("a\r\nb\r\nC\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "C" || ($0 == .deleted && $1 == "c") }
        #expect(try await index(w, "f.txt") == s("a\nb\r\nC\n"))
    }

    @Test(arguments: [
        ("added", "a\nb", "a\nb\nc"), ("removed", "a\nb\nc", "a\nb"), ("both", "a\nb", "a\nB"),
    ])
    func noTrailingNewline(_ label: String, _ before: String, _ after: String) async throws {
        let w = try await world(["f.txt": s(before)])
        try write(w.repo, "f.txt", s(after))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        let all = select(d) { _, _ in true }
        try await w.handle.apply(SelectionRequest(document: d, lines: all, action: .stage), hooks: w.hooks)
        #expect(try await index(w, "f.txt") == s(after), "\(label): staging every line equals the worktree")
        // Discard everything that is still unstaged (nothing): then unstage all → back to HEAD.
        let staged = try await doc(w, .staged(path: "f.txt"))
        try await w.handle.apply(
            SelectionRequest(document: staged, lines: select(staged) { _, _ in true }, action: .unstage), hooks: w.hooks
        )
        #expect(try await index(w, "f.txt") == s(before), "\(label): unstaging every line restores HEAD")
    }

    @Test func ambiguousFinalNewlineRefused() async throws {
        // Old "a" (no newline) → new "a\nb": staging only "+b" would need the context "a" to gain a newline.
        let w = try await world(["f.txt": s("a")])
        try write(w.repo, "f.txt", s("a\nb\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        do {
            try await w.handle.apply(SelectionRequest(document: d, lines: select(d) { $1 == "b" }, action: .stage))
            Issue.record("expected a refusal")
        } catch {
            #expect(error.summary == UnsupportedReason.ambiguousEol.explanation)
        }
        #expect(try await index(w, "f.txt") == s("a"))
    }

    // MARK: Paths and kinds

    @Test(arguments: ["ünï 文件.txt", "with space \"q\".txt", "-dash.txt", "new\nline.txt"])
    func awkwardPaths(_ name: String) async throws {
        let w = try await world([name: s("a\nb\n")])
        try write(w.repo, name, s("a\nx\nb\ny\n"))
        try await run(w, .unstaged(path: name), .stage, path: name) { $1 == "y" }
        #expect(try await index(w, name) == s("a\nb\ny\n"))
    }

    @Test func modeChangeWithContent() async throws {
        let w = try await world(["run.sh": s("echo 1\n")])
        try write(w.repo, "run.sh", s("echo 1\necho 2\necho 3\n"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.repo.path + "/run.sh")
        try await run(w, .unstaged(path: "run.sh"), .stage, path: "run.sh") { $1 == "echo 2" }
        #expect(try await index(w, "run.sh") == s("echo 1\necho 2\n"))
        #expect(try await w.repo.git("ls-files", "-s", "run.sh").hasPrefix("100644"))  // mode is separate
    }

    @Test func symlinkBinarySubmoduleAndWhitespaceRefused() async throws {
        let w = try await world(["bin": [0, 1, 2], "target.txt": s("t\n")])
        try FileManager.default.createSymbolicLink(atPath: w.repo.path + "/link", withDestinationPath: "target.txt")
        try await w.repo.git("add", "link")
        try await w.repo.git("commit", "-q", "-m", "link")
        try FileManager.default.removeItem(atPath: w.repo.path + "/link")
        try FileManager.default.createSymbolicLink(atPath: w.repo.path + "/link", withDestinationPath: "elsewhere")
        try write(w.repo, "bin", [0, 9, 2])
        try write(w.repo, "target.txt", s("t\nu\n"))
        #expect(PatchBuilder.unsupported(try await doc(w, .unstaged(path: "link"))) == .symlink)
        #expect(PatchBuilder.unsupported(try await doc(w, .unstaged(path: "bin"))) == .binary)
        let hidden = try await w.handle.openDiff(
            .unstaged(path: "target.txt"), options: DiffOptions(ignoreWhitespace: true))
        #expect(PatchBuilder.unsupported(hidden) == .whitespaceIgnored)
        await #expect(throws: GitCoreError.self) {
            try await w.handle.apply(
                SelectionRequest(document: hidden, lines: self.select(hidden) { _, _ in true }, action: .stage))
        }
        #expect(try await index(w, "target.txt") == s("t\n"))
    }

    // MARK: Conversions

    @Test func autocrlfTrueMatrix() async throws {
        let w = try await world(["f.txt": s("a\nb\n")], config: [("core.autocrlf", "true")])
        try write(w.repo, "f.txt", s("a\r\nnew\r\nb\r\nother\r\n"))
        // Index side works and is verified.
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "new" }
        #expect(try await index(w, "f.txt") == s("a\nnew\nb\n"))
        // The working tree is converted: line discard is refused, nothing changes.
        let d = try await doc(w, .unstaged(path: "f.txt"))
        do {
            try await w.handle.apply(
                SelectionRequest(document: d, lines: select(d) { $1 == "other" }, action: .discard), hooks: w.hooks)
            Issue.record("expected refusal")
        } catch {
            #expect(error.summary == UnsupportedReason.filterConversion.explanation)
        }
        #expect(worktree(w, "f.txt") == s("a\r\nnew\r\nb\r\nother\r\n"))
    }

    @Test func eolAttributeMatrix() async throws {
        let w = try await world(["f.txt": s("a\nb\n")], attributes: "*.txt text eol=crlf\n")
        try write(w.repo, "f.txt", s("a\r\nx\r\nb\r\ny\r\n"))
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "x" }
        #expect(try await index(w, "f.txt") == s("a\nx\nb\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        await #expect(throws: GitCoreError.self) {
            try await w.handle.apply(
                SelectionRequest(document: d, lines: self.select(d) { _, _ in true }, action: .discard), hooks: w.hooks)
        }
        #expect(worktree(w, "f.txt") == s("a\r\nx\r\nb\r\ny\r\n"))
    }

    @Test func filterAttributeRefused() async throws {
        let w = try await world(
            ["f.txt": s("a\n")], config: [("filter.upper.clean", "cat"), ("filter.upper.smudge", "cat")],
            attributes: "f.txt filter=upper\n")
        try write(w.repo, "f.txt", s("a\nb\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        do {
            try await w.handle.apply(SelectionRequest(document: d, lines: select(d) { _, _ in true }, action: .stage))
            Issue.record("expected refusal")
        } catch {
            #expect(error.summary == UnsupportedReason.filterConversion.explanation)
        }
    }

    // MARK: Concurrency and locks

    @Test func concurrentModificationDetectedBeforeApply() async throws {
        let w = try await world(["f.txt": s("a\n")])
        try write(w.repo, "f.txt", s("a\nb\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        try write(w.repo, "f.txt", s("a\nB\n"))  // same size, different bytes
        do {
            try await w.handle.apply(SelectionRequest(document: d, lines: select(d) { _, _ in true }, action: .stage))
            Issue.record("expected stale")
        } catch {
            guard case .staleSnapshot = error else { throw error }
        }
        #expect(try await index(w, "f.txt") == s("a\n"))
    }

    @Test func concurrentModificationDuringApplyRollsBack() async throws {
        let w = try await world(["f.txt": s("a\n"), "other.txt": s("o\n")])
        try write(w.repo, "f.txt", s("a\nb\n"))
        try write(w.repo, "other.txt", s("o\nchanged by someone else\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        let repo = w.repo
        // Another writer stages a different file between Jit's check and apply: verification sees the index
        // changed beyond the target, puts the target entry back and reports.
        do {
            _ = try await w.handle.applySelection(
                SelectionRequest(document: d, lines: select(d) { _, _ in true }, action: .stage), hooks: nil,
                beforeApply: { _ = try? await repo.git("add", "other.txt") })
            Issue.record("expected verification failure")
        } catch {
            guard case .verificationFailed = error else { throw error }
        }
        #expect(try await index(w, "f.txt") == s("a\n"))  // rolled back
        #expect(try await index(w, "other.txt") == s("o\nchanged by someone else\n"))  // the other writer's work stays
    }

    @Test func indexLockPresentRefused() async throws {
        let w = try await world(["f.txt": s("a\n")])
        try write(w.repo, "f.txt", s("a\nb\n"))
        let d = try await doc(w, .unstaged(path: "f.txt"))
        FileManager.default.createFile(atPath: w.repo.path + "/.git/index.lock", contents: Data())
        do {
            try await w.handle.apply(SelectionRequest(document: d, lines: select(d) { _, _ in true }, action: .stage))
            Issue.record("expected lock refusal")
        } catch {
            guard case .indexLocked = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: w.repo.path + "/.git/index.lock"))
    }

    @Test func stageThenUnstageSameSelectionRestoresIndex() async throws {
        let w = try await world(["f.txt": s("a\nb\nc\nd\n")])
        try write(w.repo, "f.txt", s("a\nB\nc\nd\ne\n"))
        let before = try await index(w, "f.txt")
        try await run(w, .unstaged(path: "f.txt"), .stage, path: "f.txt") { $1 == "e" || $1 == "b" }
        try await run(w, .staged(path: "f.txt"), .unstage, path: "f.txt") { $1 == "e" || $1 == "b" }
        #expect(try await index(w, "f.txt") == before)
    }
}
