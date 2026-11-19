import AppKit
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

@MainActor @Suite(.serialized) struct CommitSurgeryFeatureTests {
    static func fixture() async throws -> (
        GitSandbox, TestRepo, RepositoryHandle, RepositorySession, OperationsController, String
    ) {
        let (sandbox, repo, handle, session, operations, editor) = try await InteractiveRebaseFeatureTests.fixture()
        operations.interactiveRebase = nil
        return (sandbox, repo, handle, session, operations, editor.plan.steps[1].oid)
    }

    @Test func prepareAndCancelNeverMutateAndNewerActionWins() async throws {
        let (sandbox, repo, _, session, operations, oid) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        let before = try await RepoFingerprint.capture(repo)
        operations.beginCommitSurgery(for: oid, action: .editMessage)
        let first = operations.surgeryPreparation
        operations.cancelSheet()
        await first?.value
        #expect(operations.sheet == nil)
        operations.beginCommitSurgery(for: oid, action: .editMessage)
        let superseded = operations.surgeryPreparation
        operations.beginCommitSurgery(for: oid, action: .drop)
        let latest = operations.surgeryPreparation
        await superseded?.value; await latest?.value
        guard case .commitSurgery(let plan) = operations.sheet else { Issue.record("No direct-action sheet"); return }
        #expect(plan.action == .drop)
        #expect(operations.interactiveRebase == nil)
        operations.cancelSheet()
        #expect(try await RepoFingerprint.capture(repo) == before)
        operations.beginCommitSurgery(for: oid, action: .editMessage)
        let closing = operations.surgeryPreparation
        session.close()
        await closing?.value
        #expect(operations.sheet == nil)
    }

    @Test(arguments: [CommitSurgeryAction.editMessage, .drop])
    func confirmedActionExecutesWithoutGeneralEditor(_ action: CommitSurgeryAction) async throws {
        let (sandbox, repo, handle, session, operations, oid) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        let oldHead = try await repo.git("rev-parse", "HEAD")
        operations.beginCommitSurgery(for: oid, action: action)
        await operations.surgeryPreparation?.value
        guard case .commitSurgery(var plan) = operations.sheet else { Issue.record("Missing surgery plan"); return }
        if action == .editMessage { plan.message = "Safer empty input\n\n# literal message" }
        operations.runCommitSurgery(plan, token: plan.confirmation(context: "test").confirm())
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                session.operations.records.contains { $0.title == action.title && $0.state.isFinished }
            })
        #expect(operations.interactiveRebase == nil)
        #expect(try await handle.operationState() == .clean)
        #expect(try await repo.git("rev-parse", "HEAD") != oldHead)
        if action == .drop {
            #expect(!FileManager.default.fileExists(atPath: repo.path + "/Handle empty input.txt"))
        } else {
            #expect(try await repo.git("log", "--format=%s").contains("Safer empty input"))
        }
        #expect(await ClosedTabDeallocatesTests.waitUntil { session.recoveryPoints.contains { $0.oldOID == oldHead } })
        await session.settle()
        let recovery = ReflogModel(session: session).lastRecoverableOperation
        #expect(recovery?.oldOID == oldHead && recovery?.operation == action.title)
    }

    @Test func staleActionShowsErrorWithoutChangingHistory() async throws {
        let (sandbox, repo, _, session, operations, oid) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        operations.beginCommitSurgery(for: oid, action: .editMessage)
        await operations.surgeryPreparation?.value
        guard case .commitSurgery(var plan) = operations.sheet else { Issue.record("Missing surgery plan"); return }
        plan.message = "Stale edit"
        try await repo.git("branch", "external-change")
        let before = try await RepoFingerprint.capture(repo)
        operations.runCommitSurgery(plan, token: plan.confirmation(context: "test").confirm())
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                operations.model.toast?.failed == true
            })
        #expect(try await RepoFingerprint.capture(repo) == before)
        #expect(operations.interactiveRebase == nil)
    }

    @Test func menuDisablesKnownUnsupportedSelectionsAndValidationKeepsThemDisabled() async throws {
        let (sandbox, _, _, session, operations, oid) = try await Self.fixture()
        defer { withExtendedLifetime(sandbox) {}; session.close() }
        let menu = NSMenu()
        let root = operations.commitSurgeryMenuItems(for: oid, parentCount: 0, singleSelection: true)
        root.forEach(menu.addItem)
        menu.update()
        #expect(root.allSatisfy { !$0.isEnabled && $0.toolTip != nil })
        let multiple = operations.commitSurgeryMenuItems(for: oid, parentCount: 1, singleSelection: false)
        #expect(multiple.allSatisfy { !$0.isEnabled })
        let head = try #require(session.status?.branch.oid)
        let mergeHead = operations.commitSurgeryMenuItems(for: head, parentCount: 2, singleSelection: true)
        #expect(mergeHead[0].isEnabled && !mergeHead[1].isEnabled)
    }
}
