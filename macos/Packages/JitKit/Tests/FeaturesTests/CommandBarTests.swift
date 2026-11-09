import Foundation
import GitCore
import GitTestKit
import Testing

@testable import Features

/// Repository command bar (P3.0 spec, Tests section).
@Suite struct CommandBarTests {
    typealias Width = CommandBarLayout.GroupWidth

    static let widths: [CommandBarGroup: Width] = [
        .location: Width(labelled: 200, iconOnly: 120),
        .changes: Width(labelled: 110, iconOnly: 60),
        .terminal: Width(labelled: 100, iconOnly: 40),
        .history: Width(labelled: 120, iconOnly: 70),
        .stash: Width(labelled: 140, iconOnly: 70),
        .branch: Width(labelled: 100, iconOnly: 40),
        .sync: Width(labelled: 220, iconOnly: 110),
    ]

    func layout(_ available: CGFloat, _ groups: [CommandBarGroup], labels: Bool = true) -> CommandBarLayout {
        CommandBarLayout.make(
            available: available, groups: groups, widths: Self.widths, spacing: 10, overflowButton: 30,
            labelsAllowed: labels)
    }

    @Test func phaseThreeShipsExactlyLocationChangesTerminalAndFind() {
        #expect(CommandBarGroup.shipped == [.location, .changes, .terminal, .find])
        // Sync, branch, stash and undo/redo are absent until Phases 4 and 8 build them.
        #expect(!CommandBarGroup.shipped.contains(.sync))
        #expect(!CommandBarGroup.shipped.contains(.stash))
        #expect(!CommandBarGroup.shipped.contains(.history))
    }

    @Test func labelsShowWhenEverythingFits() {
        let result = layout(1000, [.location, .changes, .terminal])
        #expect(result == CommandBarLayout(showsLabels: true, visible: [.location, .changes, .terminal], overflow: []))
    }

    @Test func labelsDropBeforeAnyGroupOverflows() {
        // Labelled: 200+110+100+20 = 430; icon-only: 120+60+40+20 = 240.
        let result = layout(300, [.location, .changes, .terminal])
        #expect(
            result == CommandBarLayout(showsLabels: false, visible: [.location, .changes, .terminal], overflow: []))
    }

    @Test func showLabelsOffForcesIconOnly() {
        let result = layout(1000, [.location, .terminal], labels: false)
        #expect(!result.showsLabels)
        #expect(result.overflow.isEmpty)
    }

    @Test func groupsOverflowInReverseOrderOfPriority() {
        let all: [CommandBarGroup] = [.location, .changes, .sync, .branch, .stash, .history, .terminal]
        // Icon-only sum: 120+60+110+40+70+70+40 = 510 + 6×10 = 570.
        #expect(layout(570, all).overflow.isEmpty)
        // Terminal goes first: 470 for six groups + 30 (⋯) + six gaps of 10 = 560.
        #expect(layout(569, all).overflow == [.terminal])
        #expect(layout(560, all).overflow == [.terminal])
        // Then history (400 + 30 + 50 = 480), then stash (330 + 30 + 40 = 400).
        #expect(layout(559, all).overflow == [.terminal, .history])
        #expect(layout(480, all).overflow == [.terminal, .history])
        #expect(layout(400, all).overflow == [.terminal, .history, .stash])
        let tight = layout(100, all)
        #expect(tight.overflow == [.terminal, .history, .stash, .branch])
        // Location, changes and sync never overflow, however narrow.
        #expect(tight.visible == [.location, .changes, .sync])
    }

    @Test func phaseThreeOverflowOnlyMovesTerminal() {
        let result = layout(150, [.location, .changes, .terminal])
        #expect(result.visible == [.location, .changes])
        #expect(result.overflow == [.terminal])
    }

    // MARK: Location strings from real repositories

    func status(_ repo: TestRepo) async throws -> RepositoryStatus {
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        return try await engine.openRepository(at: URL(fileURLWithPath: repo.path)).status()
    }

    @Test func locationForBranchWithUpstream() async throws {
        let sandbox = try GitSandbox()
        let upstream = try await sandbox.makeRepository("upstream")
        try upstream.write("a.txt", "a\n")
        try await upstream.commit("One")
        try await sandbox.git(["clone", "-q", "--", upstream.path, sandbox.root + "/clone"], in: sandbox.root)
        let clone = TestRepo(sandbox: sandbox, path: sandbox.root + "/clone")
        try clone.write("b.txt", "b\n")
        try await clone.commit("Local")

        let location = CommandBarLocation(repository: "clone", branch: try await status(clone).branch)
        #expect(location.branchTitle == "main")
        #expect(location.tracking == "↑1 ↓0")
        #expect(location.accessibilityLabel == "Repository clone, branch main, 1 commit ahead")
    }

    @Test func locationForBranchWithoutUpstream() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("One")
        let location = CommandBarLocation(repository: "repo", branch: try await status(repo).branch)
        #expect(location.branchTitle == "main")
        #expect(location.tracking == nil)
        #expect(location.accessibilityLabel == "Repository repo, branch main")
    }

    @Test func locationForDetachedHead() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        let sha = try await repo.commit("One")
        try await repo.git("switch", "-q", "--detach", "HEAD")
        let location = CommandBarLocation(repository: "repo", branch: try await status(repo).branch)
        #expect(location.branchTitle == "HEAD \(sha.prefix(7))")
        #expect(location.tracking == nil)
        #expect(location.accessibilityLabel == "Repository repo, detached HEAD at \(sha.prefix(7))")
    }

    @Test func locationForUnbornBranch() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        let location = CommandBarLocation(repository: "repo", branch: try await status(repo).branch)
        #expect(location.branchTitle == "main — no commits")
        #expect(location.accessibilityLabel == "Repository repo, branch main, no commits yet")
    }

    // MARK: Changes

    @Test func changesCountFollowsStatusAndHidesWhenClean() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("One")
        #expect(CommandBarChanges.count(try await status(repo).summary) == nil)

        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "staged and more\n")  // partially staged: one path
        try repo.write("new.txt", "n\n")
        #expect(CommandBarChanges.count(try await status(repo).summary) == 2)
        #expect(CommandBarChanges.title(2, labels: true) == "2 changes")
        #expect(CommandBarChanges.title(1, labels: true) == "1 change")
        #expect(CommandBarChanges.title(2, labels: false) == "2")
    }
}
