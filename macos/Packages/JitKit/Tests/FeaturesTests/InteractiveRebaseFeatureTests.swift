import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct InteractiveRebaseFeatureTests {
    final class Marker {}
    static var helper: String {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("jit-git-helper").path
    }

    static func fixture() async throws -> (
        GitSandbox, TestRepo, RepositoryHandle, RepositorySession, OperationsController, RebaseEditorModel
    ) {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("rebase-editor")
        let base = try await repo.commit("Create project")
        for name in ["Add parser", "Handle empty input", "Add parser tests", "Clarify errors"] {
            try repo.write(name + ".txt", name + "\n")
            try await repo.commit(name)
        }
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(
            path: repo.path, engine: sandbox.engine, handle: handle, watchesFileSystem: false,
            recoveryLocation: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/state")),
            helperPath: helper)
        session.activate(); await session.settle()
        let app = ClosedTabDeallocatesTests.makeModel(sandbox)
        app.profiles.create(
            GitProfile(
                displayName: "Development", colorIndex: 1,
                author: GitIdentity(name: "Rebase QA", email: "rebase@jit.invalid")), activate: true)
        let operations = OperationsController(session: session, model: app)
        let editor = RebaseEditorModel(plan: try await handle.interactiveRebasePlan(after: base))
        operations.interactiveRebase = editor
        return (sandbox, repo, handle, session, operations, editor)
    }

    @Test func testReorderAndRewordThenRun() async throws {
        let (_, repo, handle, session, operations, editor) = try await Self.fixture()
        editor.selection = editor.plan.steps[1].oid
        editor.moveSelection(by: -1)
        editor.setAction(.reword, at: 0)
        editor.plan.steps[0].message = "Handle empty input safely"
        editor.setAction(.squash, at: 2)
        #expect(editor.plan.steps[2].message.contains("Add parser\n\nAdd parser tests"))
        #expect(editor.plan.validationIssues.isEmpty)
        let old = try await repo.git("rev-parse", "HEAD")
        operations.reviewInteractiveRebase(editor)
        guard case .confirm(let request) = operations.sheet else { Issue.record("Missing confirmation"); return }
        #expect(request.recoveryValue == old)
        #expect(try await repo.git("rev-parse", "HEAD") == old)
        operations.confirmed(request)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                session.operations.records.contains { $0.title == "Interactive rebase" && $0.state.isFinished }
            })
        if let record = session.operations.records.first(where: { $0.title == "Interactive rebase" }),
            case .failed(let error) = record.state
        {
            Issue.record(
                Comment(rawValue: error.title + ": " + error.explanation + " " + (error.technicalDetail ?? "")))
        }
        #expect(try await handle.operationState() == .clean)
        #expect(
            try await repo.git("log", "--reverse", "--format=%s", editor.plan.base + "..HEAD").hasPrefix(
                "Handle empty input safely"))
        #expect(try await repo.git("rev-list", "--count", editor.plan.base + "..HEAD") == "3")
        #expect(operations.interactiveRebase == nil)
        session.close()
    }

    @Test func testCancelConfirmationKeepsEditedPlanAndDoesNotMutateGit() async throws {
        let (_, repo, _, session, operations, editor) = try await Self.fixture()
        let before = try await RepoFingerprint.capture(repo)
        editor.setAction(.drop, at: 1)
        operations.reviewInteractiveRebase(editor)
        operations.cancelSheet()
        #expect(operations.interactiveRebase === editor)
        #expect(editor.plan.steps[1].action == .drop)
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(CommandRegistry.all.contains { $0.id == "branch.interactiveRebase" && $0.inPalette })
        session.close()
    }

    @Test func reorderingAndValidationKeepSelectionAndOriginalMessages() async throws {
        let (sandbox, _, _, session, _, editor) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {} }
        let selected = editor.plan.steps[3].oid
        editor.selection = selected
        editor.moveSelection(by: -1)
        #expect(editor.selectedIndex == 2)
        editor.draggedCommit = selected
        editor.moveDraggedCommit(selected, to: editor.plan.steps[0].oid)
        #expect(editor.draggedCommit == nil && editor.dropTarget == nil)
        #expect(editor.selectedIndex == 0)
        editor.setAction(.fixup, at: 0)
        #expect(!editor.plan.validationIssues.isEmpty)
        editor.setAction(.pick, at: 0)
        #expect(editor.plan.validationIssues.isEmpty)
        session.close()
    }
    @Test(arguments: [false, true])
    func testConflictDuringInteractiveRebaseResolveContinueOrAbort(abort: Bool) async throws {
        let (_, repo, handle, session, operations, editor) = try await Self.fixture()
        try await repo.git("switch", "-c", "onto", editor.plan.base)
        try repo.write("Add parser.txt", "onto content\n")
        let onto = try await repo.commit("Onto with competing parser")
        try await repo.git("switch", "main")
        editor.plan = try await handle.interactiveRebasePlan(after: editor.plan.base, onto: onto)
        editor.setAction(.reword, at: 0)
        editor.plan.steps[0].message = "Resolved parser message"
        let before = try await RepoFingerprint.capture(repo)
        operations.reviewInteractiveRebase(editor)
        guard case .confirm(let request) = operations.sheet else {
            Issue.record("Missing rewrite confirmation"); return
        }
        operations.confirmed(request)
        #expect(await ClosedTabDeallocatesTests.waitUntil { operations.resolver?.phase == .text })
        #expect(await ClosedTabDeallocatesTests.waitUntil { session.operationState.conflicted == 1 })
        if abort {
            operations.abort()
            #expect(
                await ClosedTabDeallocatesTests.waitUntil {
                    if case .confirm = operations.sheet { return true }; return false
                })
            guard case .confirm(let request) = operations.sheet else { return }
            operations.confirmed(request)
            #expect(
                await ClosedTabDeallocatesTests.waitUntil {
                    session.operations.records.contains { $0.title == "Abort" && $0.state.isFinished }
                })
            #expect(try await RepoFingerprint.capture(repo) == before)
            #expect(operations.resolver == nil)
        } else {
            let resolver = try #require(operations.resolver)
            #expect(resolver.isRebase)
            for block in resolver.blocks { resolver.choose(.theirs, for: block) }
            resolver.markResolved()
            #expect(await ClosedTabDeallocatesTests.waitUntil { resolver.phase == .done })
            operations.continueOperation()
            #expect(
                await ClosedTabDeallocatesTests.waitUntil {
                    session.operations.records.contains { $0.title == "Continue" && $0.state.isFinished }
                })
            #expect(try await handle.operationState() == .clean)
            #expect(try await repo.git("log", "-1", "--format=%s", "HEAD~3") == "Resolved parser message")
            #expect(try String(contentsOfFile: repo.path + "/Add parser.txt", encoding: .utf8) == "Add parser\n")
        }
        session.close()
    }

    @Test func draggedCommitMovementPreservesSelectionAndRejectsUnknownCommit() async throws {
        let (sandbox, _, _, session, _, editor) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {} }
        let source = editor.plan.steps[3].oid
        let target = editor.plan.steps[0].oid
        editor.draggedCommit = source
        editor.moveDraggedCommit(source, to: target)
        #expect(editor.plan.steps[0].oid == source)
        #expect(editor.selection == source && editor.draggedCommit == nil && editor.dropTarget == nil)
        editor.draggedCommit = target
        let before = editor.plan.steps
        editor.moveDraggedCommit("foreign payload", to: target)
        #expect(editor.draggedCommit == nil)
        #expect(editor.plan.steps == before && editor.dropTarget == nil)
        session.close()
    }

}
