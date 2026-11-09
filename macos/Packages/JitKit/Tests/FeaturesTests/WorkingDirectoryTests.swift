import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// Working-directory panel (P3.1): sections and rows from real status, display transforms, and the model's
/// stage/unstage/drag flow through `RepositorySession`.
@Suite struct WorkingDirectoryTests {
    func snapshot(_ repo: TestRepo) async throws -> StatusSnapshot {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        _ = try await handle.status()
        return try #require(await handle.lastSnapshot())
    }

    func committed(_ sandbox: GitSandbox, _ files: [String: String]) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        return repo
    }

    // MARK: Sections

    @Test func partiallyStagedFileAppearsInBothSections() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "staged and more\n")
        try repo.write("new.txt", "n\n")

        let list = WorkingDirectoryList(snapshot: try await snapshot(repo))
        #expect(list.staged.map(\.path) == ["a.txt"])
        #expect(list.unstaged.map(\.path).sorted() == ["a.txt", "new.txt"])
        #expect(list.staged[0].isPartial && list.unstaged.first { $0.path == "a.txt" }?.isPartial == true)
        let untracked = try #require(list.unstaged.first { $0.path == "new.txt" })
        #expect(untracked.change == .untracked && untracked.change.letter == "U")
        #expect(list.conflicts.isEmpty)
    }

    @Test func stagedRenameUnstagesBothPaths() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["old.txt": String(repeating: "same\n", count: 20)])
        try await repo.git("mv", "old.txt", "new.txt")
        let list = WorkingDirectoryList(snapshot: try await snapshot(repo))
        let row = try #require(list.staged.first)
        #expect(row.change == .renamed && row.path == "new.txt" && row.originalPath == "old.txt")
        #expect(row.operationPaths == ["old.txt", "new.txt"])
        #expect(list.unstaged.isEmpty)
    }

    @Test func conflictsHaveTheirOwnSectionAndCannotBeStaged() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["both.txt": "base\n"])
        try await repo.git("switch", "-q", "-c", "other")
        try repo.write("both.txt", "theirs\n")
        try await repo.commit("Theirs")
        try await repo.git("switch", "-q", "main")
        try repo.write("both.txt", "ours\n")
        try await repo.commit("Ours")
        _ = try? await repo.git("merge", "-q", "other")

        let list = WorkingDirectoryList(snapshot: try await snapshot(repo))
        #expect(list.conflicts.map(\.path) == ["both.txt"])
        #expect(list.conflicts[0].conflict == .bothModified && !list.conflicts[0].canStageOrUnstage)
        #expect(list.staged.isEmpty && list.unstaged.isEmpty)
    }

    @Test func modeAndSymlinkBadges() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["run.sh": "echo\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path + "/run.sh")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: "run.sh")
        try await repo.git("add", "link")

        let list = WorkingDirectoryList(snapshot: try await snapshot(repo))
        #expect(list.unstaged.first { $0.path == "run.sh" }?.badges == [.executable(true)])
        #expect(list.staged.first { $0.path == "link" }?.badges == [.symlink])
    }

    // MARK: Display

    func file(_ section: WDSection, _ path: String, _ change: WDChange = .modified) -> WDFile {
        WDFile(
            section: section, path: path, originalPath: nil, change: change, isPartial: false, badges: [],
            conflict: nil, submodule: nil)
    }

    @Test func sortAndFilter() {
        let files = [
            file(.unstaged, "src/zeta.swift"), file(.unstaged, "docs/alpha.md", .added),
            file(.unstaged, "b.txt", .deleted),
        ]
        func paths(_ sort: WDSort, filter: String = "", stats: [String: LineStats] = [:]) -> [String] {
            WDDisplay.items(
                files, section: .unstaged, filter: filter, sort: sort, tree: false, collapsed: [], stats: stats
            )
            .compactMap { if case .file(let file, _) = $0 { file.path } else { nil } }
        }
        #expect(paths(.path) == ["b.txt", "docs/alpha.md", "src/zeta.swift"])
        #expect(paths(.name) == ["docs/alpha.md", "b.txt", "src/zeta.swift"])
        #expect(paths(.status) == ["docs/alpha.md", "src/zeta.swift", "b.txt"])  // A, M, D
        let stats = [
            WDFile.id(.unstaged, "b.txt"): LineStats(additions: 0, deletions: 40),
            WDFile.id(.unstaged, "src/zeta.swift"): LineStats(additions: 3, deletions: 1),
        ]
        #expect(paths(.size, stats: stats) == ["b.txt", "src/zeta.swift", "docs/alpha.md"])  // unknown last
        #expect(paths(.path, filter: "zt") == ["src/zeta.swift"])  // fuzzy
    }

    @Test func treeGroupsFoldersAndCollapses() {
        let files = [
            file(.staged, "src/app/main.swift"), file(.staged, "src/util.swift"), file(.staged, "README.md"),
        ]
        func ids(_ collapsed: Set<String>) -> [String] {
            WDDisplay.items(
                files, section: .staged, filter: "", sort: .path, tree: true, collapsed: collapsed, stats: [:]
            )
            .map { item in
                switch item {
                case .folder(let folder): "\(folder.depth)d \(folder.path) (\(folder.files.count))"
                case .file(let file, let depth): "\(depth) \(file.path)"
                }
            }
        }
        #expect(
            ids([]) == [
                "0d src (2)", "1d src/app (1)", "2 src/app/main.swift", "1 src/util.swift", "0 README.md",
            ])
        #expect(ids([WDFolder.id(.staged, "src")]) == ["0d src (2)", "0 README.md"])
    }

    @Test func countsLine() {
        #expect(
            WDCounts.line(StatusSummary(staged: 3, unstaged: 5, untracked: 1, conflicted: 0, ignored: 0))
                == "3 staged · 5 unstaged · 1 untracked")
        #expect(
            WDCounts.line(StatusSummary(staged: 0, unstaged: 0, untracked: 0, conflicted: 0, ignored: 2))
                == "No changes")
    }

    // MARK: Model with a real session

    @MainActor
    func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    func model(_ repo: TestRepo) async throws -> WorkingDirectoryModel {
        let handle = try await repo.sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: repo.sandbox.engine, handle: handle, watchesFileSystem: false)
        session.activate()
        #expect(try await waitUntil { session.status != nil })
        let model = WorkingDirectoryModel(session: session)
        model.handle = handle
        model.activate()
        #expect(try await waitUntil { !model.isLoading })
        return model
    }

    @Test @MainActor func stageAndUnstageByDragMoveRowsBetweenSections() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n", "b.txt": "b\n"])
        try repo.write("a.txt", "a2\n")
        try repo.write("b.txt", "b2\n")
        let model = try await model(repo)
        #expect(model.list.unstaged.map(\.path) == ["a.txt", "b.txt"])

        // Drag the selection (both rows) from Unstaged onto Staged.
        model.selection = [WDFile.id(.unstaged, "a.txt"), WDFile.id(.unstaged, "b.txt")]
        let payload = model.beginDrag(try #require(model.list.unstaged.first))
        #expect(model.drop([payload], into: .staged))
        #expect(
            try await waitUntil { model.list.staged.map(\.path) == ["a.txt", "b.txt"] && model.list.unstaged.isEmpty })
        #expect(try await repo.git("diff", "--cached", "--name-only") == "a.txt\nb.txt")

        // Dropping onto the section it came from does nothing; a foreign string does nothing.
        let back = model.beginDrag(try #require(model.list.staged.last))
        #expect(!model.drop([back], into: .staged))
        #expect(!model.drop(["hello"], into: .unstaged))
        #expect(model.drop([back], into: .unstaged))
        #expect(try await waitUntil { model.list.staged.map(\.path) == ["a.txt"] })
        #expect(try await repo.git("diff", "--cached", "--name-only") == "a.txt")
    }

    @Test @MainActor func spaceTogglesAndStatsLoadLazily() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        try repo.write("a.txt", "a\nb\nc\n")
        let model = try await model(repo)
        let row = try #require(model.list.unstaged.first)
        #expect(model.stats.isEmpty)  // nothing on screen yet: no numstat ran
        model.rowAppeared(row)
        #expect(try await waitUntil { model.stats[row.id] == LineStats(additions: 2, deletions: 0) })

        model.selection = [row.id]
        model.toggleSelection()
        #expect(try await waitUntil { model.list.staged.map(\.path) == ["a.txt"] })
        #expect(model.selection.isEmpty)  // the selected row moved sections
    }

    @Test @MainActor func lockedIndexShowsBannerAndRetryWorks() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        try repo.write("a.txt", "changed\n")
        let model = try await model(repo)
        let lock = repo.path + "/.git/index.lock"
        FileManager.default.createFile(atPath: lock, contents: Data())
        model.stageAll()
        #expect(try await waitUntil { model.banner != nil })
        #expect(model.banner?.contains("index.lock") == true && model.canRetry)
        #expect(FileManager.default.fileExists(atPath: lock))  // never removed by Jit

        try FileManager.default.removeItem(atPath: lock)
        model.retry()
        #expect(try await waitUntil { model.list.staged.map(\.path) == ["a.txt"] })
        #expect(model.banner == nil)
    }

    @Test @MainActor func cleanTreeLoadsLastCommitSubject() async throws {
        let sandbox = try GitSandbox()
        let repo = try await committed(sandbox, ["a.txt": "a\n"])
        let model = try await model(repo)
        #expect(model.list.isClean)
        #expect(try await waitUntil { model.lastCommitSubject == "Initial" })
    }
}
