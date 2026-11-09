import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Synchronization
import Testing

@testable import Features

/// P6.4: the first window is built from the session file alone — no Git process and no accounts service
/// (Keychain, path monitor) before the window reaches the foreground; Git work starts after that.
@MainActor @Suite(.serialized) struct LaunchWorkTests {
    @Test func launchWithRestoredTabsSpawnsNoGitBeforeForeground() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("launch")
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        let spawned = Locked<[String]>([])
        let root = sandbox.root
        ProcessRunner.spawnObserver.withLock { observer in
            observer = { spec in
                // Only this test's sandbox (parallel suites spawn Git too).
                if spec.workingDirectory.hasPrefix(root) || spec.arguments.contains(where: { $0.hasPrefix(root) }) {
                    spawned.withLock { $0.append(Signposts.gitSubcommand(spec.arguments)) }
                }
            }
        }
        defer { ProcessRunner.spawnObserver.withLock { $0 = nil } }

        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        let tab = SessionState.Tab(id: UUID(), kind: .repository, path: repo.path, titleCache: "launch")
        model.restore(SessionState(tabs: [tab], activeTabID: tab.id))
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        #expect(model.tabs.first?.title == "launch")  // cached title, shown without Git
        #expect(spawned.withLock { $0 }.isEmpty, "Git ran before the first frame: \(spawned.withLock { $0 })")
        #expect(!model.isAccountsLoaded)

        model.setForeground(true)
        #expect(await ClosedTabDeallocatesTests.waitUntil { !spawned.withLock { $0 }.isEmpty })
        // Opening a repository still needs no accounts service.
        #expect(!model.isAccountsLoaded)
        controller.close()
    }

    @Test func accountsServiceIsConfiguredWhenFirstUsed() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let model = ClosedTabDeallocatesTests.makeModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        #expect(!model.isAccountsLoaded)
        let accounts = model.accounts
        #expect(model.isAccountsLoaded)
        #expect(accounts.passphrasePrompt != nil)  // the window's prompt hooks were applied on creation
        withExtendedLifetime(controller) {}
    }
}
