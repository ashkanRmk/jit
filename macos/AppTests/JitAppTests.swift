import AppKit
import Features
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

/// App-level state against real repositories (`GitTestKit`), without UI automation.
@MainActor
final class Harness {
    let sandbox: GitSandbox
    let directory: URL
    let model: AppModel
    let sessionStore: SessionStore

    init(watches: Bool = false) throws {
        sandbox = try GitSandbox()
        directory = URL(fileURLWithPath: sandbox.root).appendingPathComponent("support")
        let location = StoreLocation(directory: directory)
        sessionStore = SessionStore(location: location)
        let defaults = UserDefaults(suiteName: "jit.apptests.\(UUID().uuidString)") ?? .standard
        model = AppModel(
            engine: sandbox.engine, preferences: PreferencesStore(defaults: defaults),
            recents: RecentsStore(location: location), profiles: ProfileStore(location: location),
            sessionStore: sessionStore, watchesFileSystem: watches)
        model.restore(nil)
    }

    func repository(_ name: String) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository(name)
        try repo.write("README.md", name)
        try await repo.commit("Initial")
        return repo
    }

    @discardableResult
    func open(_ repo: TestRepo) async throws -> TabModel {
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        return try #require(model.activeTab)
    }

    func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor @Suite(.serialized) struct AppModelTests {
    @Test func testLaunchWithoutSessionShowsNewTabPage() throws {
        let harness = try Harness()
        #expect(harness.model.tabs.count == 1)
        #expect(harness.model.activeTab?.kind == .newTab)
    }

    @Test func testOpenReplacesNewTabPageThenAddsTabs() async throws {
        let harness = try Harness()
        let a = try await harness.repository("alpha")
        let b = try await harness.repository("beta")
        let first = try await harness.open(a)
        #expect(harness.model.tabs.count == 1)  // the new-tab page became the repository tab
        #expect(first.title == "alpha")
        try await harness.open(b)
        #expect(harness.model.tabs.map(\.title) == ["alpha", "beta"])
        #expect(harness.model.recents.entries.map(\.name) == ["beta", "alpha"])
    }

    @Test func testConcurrentOpensAllComplete() async throws {
        let harness = try Harness()
        let repos = [
            try await harness.repository("a"), try await harness.repository("b"), try await harness.repository("c"),
        ]
        // e.g. three folders dropped on the Dock icon at once
        for repo in repos { harness.model.open(URL(fileURLWithPath: repo.path)) }
        await harness.model.settleOpen()
        #expect(Set(harness.model.tabs.map(\.title)) == ["a", "b", "c"])
    }

    @Test func testLocateKeepsRecentWhenNewFolderFails() async throws {
        let harness = try Harness()
        let tab = try await harness.open(try await harness.repository("a"))
        let plain = try harness.sandbox.makeDirectory("plain")
        var failures = 0
        harness.model.onOpenFailure = { _, _ in failures += 1 }
        // The chosen folder doesn't exist, so the open fails and the old entry must survive.
        harness.model.relocate(tab.id, to: URL(fileURLWithPath: plain + "/does-not-exist"))
        await harness.model.settleOpen()
        #expect(failures == 1)
        #expect(harness.model.recents.entries.map(\.name) == ["a"])
    }

    @Test func testOpeningSameRepoFocusesExistingTab() async throws {
        let harness = try Harness()
        let a = try await harness.repository("alpha")
        let b = try await harness.repository("beta")
        let alpha = try await harness.open(a)
        try await harness.open(b)
        // From a subdirectory: discovery resolves the top level, so the existing tab is focused.
        try a.write("sub/dir/file.txt", "x")
        harness.model.open(URL(fileURLWithPath: a.path + "/sub/dir"))
        await harness.model.settleOpen()
        #expect(harness.model.tabs.count == 2)
        #expect(harness.model.activeTabID == alpha.id)
    }

    @Test func testCloseActivatesRightThenLeft() async throws {
        let harness = try Harness()
        let model = harness.model
        for name in ["a", "b", "c"] { try await harness.open(try await harness.repository(name)) }
        let ids = model.tabs.map(\.id)
        model.select(ids[1])
        model.closeTab(ids[1])
        #expect(model.activeTabID == ids[2])  // right neighbor
        model.closeTab(ids[2])
        #expect(model.activeTabID == ids[0])  // no right neighbor: left
        model.closeTab(ids[0])
        #expect(model.tabs.count == 1)  // last tab closed: new-tab page, window stays
        #expect(model.activeTab?.kind == .newTab)
    }

    @Test func testReopenClosedTabRestoresPosition() async throws {
        let harness = try Harness()
        let model = harness.model
        for name in ["a", "b", "c"] { try await harness.open(try await harness.repository(name)) }
        let middle = model.tabs[1]
        model.closeTab(middle.id)
        #expect(model.tabs.map(\.title) == ["a", "c"])
        #expect(model.canReopenClosedTab)
        model.reopenClosedTab()
        #expect(model.tabs.map(\.title) == ["a", "b", "c"])
        #expect(model.activeTab?.title == "b")
        #expect(!model.canReopenClosedTab)
    }

    @Test func testReopenStackKeepsTen() async throws {
        let harness = try Harness()
        let repo = try await harness.repository("a")
        for _ in 0..<12 {
            let tab = try await harness.open(repo)
            harness.model.closeTab(tab.id)
        }
        #expect(harness.model.recentlyClosed.count == 10)
    }

    @Test func testKeyboardCyclingWraps() async throws {
        let harness = try Harness()
        let model = harness.model
        for name in ["a", "b", "c"] { try await harness.open(try await harness.repository(name)) }
        model.select(model.tabs[2].id)
        model.selectNextTab()
        #expect(model.activeIndex == 0)
        model.selectPreviousTab()
        #expect(model.activeIndex == 2)
        model.moveTab(model.tabs[2].id, by: -1)
        #expect(model.tabs.map(\.title) == ["a", "c", "b"])
        model.moveTab(model.tabs[0].id, by: -1)  // already leftmost: no change
        #expect(model.tabs.map(\.title) == ["a", "c", "b"])
    }

    @Test func testOnlyActiveTabLoadsAndOnlyInForeground() async throws {
        let harness = try Harness()
        let model = harness.model
        for name in ["a", "b", "c"] { try await harness.open(try await harness.repository(name)) }
        let state = model.sessionState
        // Relaunch from the saved session.
        let relaunched = try Harness()
        relaunched.model.restore(state)
        #expect(relaunched.model.tabs.map(\.title) == ["a", "b", "c"])
        let sessions = relaunched.model.tabs.compactMap(\.session)
        #expect(sessions.allSatisfy { $0.lifecycle == .unloaded })  // window shows cached titles first
        relaunched.model.setForeground(true)
        let active = try #require(relaunched.model.activeTab?.session)
        #expect(try await relaunched.waitUntil { active.lifecycle == .active && active.status != nil })
        #expect(sessions.filter { $0.lifecycle != .unloaded }.count == 1)
        relaunched.model.setForeground(false)
        #expect(active.lifecycle == .inactive)
    }

    @Test func testNoStreamWhenAppInactive() async throws {
        let harness = try Harness(watches: true)
        let tab = try await harness.open(try await harness.repository("a"))
        let session = try #require(tab.session)
        harness.model.setForeground(true)
        #expect(try await harness.waitUntil { session.isWatching })
        harness.model.setForeground(false)  // app resigned active / window hidden
        #expect(!session.isWatching)
        let callbacks = RepositoryWatcher.callbackCount.load(ordering: .relaxed)
        try (tab.path.map { TestRepo(sandbox: harness.sandbox, path: $0) })?.write("README.md", "changed")
        try await Task.sleep(for: .milliseconds(600))
        #expect(RepositoryWatcher.callbackCount.load(ordering: .relaxed) == callbacks)
        harness.model.setForeground(true)
        #expect(try await harness.waitUntil { session.isWatching && session.status?.summary?.unstaged == 1 })
    }

    @Test func testStatusDotFollowsSession() async throws {
        let harness = try Harness()
        let repo = try await harness.repository("a")
        try repo.write("README.md", "dirty")
        let tab = try await harness.open(repo)
        harness.model.setForeground(true)
        #expect(try await harness.waitUntil { tab.statusDot == .changes })
        #expect(tab.branch == "main")
    }

    @Test func testMissingRepositoryRestoresAsErrorTab() async throws {
        let harness = try Harness()
        let tab = SessionState.Tab(
            id: UUID(), kind: .repository, path: harness.sandbox.root + "/gone", titleCache: "gone")
        harness.model.restore(SessionState(tabs: [tab], activeTabID: tab.id))
        harness.model.setForeground(true)
        let session = try #require(harness.model.activeTab?.session)
        #expect(try await harness.waitUntil { session.error != nil })
        #expect(harness.model.activeTab?.statusDot == .danger)
        #expect(session.error == .pathNotFound(path: harness.sandbox.root + "/gone"))
    }

    @Test func testSessionPersistsTabsLayoutAndUIState() async throws {
        let harness = try Harness()
        let tab = try await harness.open(try await harness.repository("a"))
        tab.sidebarCollapsed = true
        tab.ui = ["graph": .string("anchor")]
        harness.model.layout.sidebarWidth = 300
        harness.model.flush()
        let saved = try #require(harness.sessionStore.load().value)
        #expect(saved.tabs.first?.sidebarCollapsed == true)
        #expect(saved.tabs.first?.ui == ["graph": .string("anchor")])
        #expect(saved.layout?.sidebarWidth == 300)
        #expect(saved.activeTabID == tab.id)
    }
}

@Suite struct TabOrderingTests {
    @Test func move() {
        #expect(TabOrdering.move([0, 1, 2, 3], from: 0, to: 2) == [1, 2, 0, 3])
        #expect(TabOrdering.move([0, 1, 2, 3], from: 3, to: 0) == [3, 0, 1, 2])
        #expect(TabOrdering.move([0, 1], from: 5, to: 0) == [0, 1])
    }

    @Test func close() {
        #expect(TabOrdering.indexToActivate(afterClosing: 1, count: 3) == 1)  // the right neighbor shifts in
        #expect(TabOrdering.indexToActivate(afterClosing: 2, count: 3) == 1)
        #expect(TabOrdering.indexToActivate(afterClosing: 0, count: 1) == nil)
    }

    @Test func cycle() {
        #expect(TabOrdering.cycle(2, by: 1, count: 3) == 0)
        #expect(TabOrdering.cycle(0, by: -1, count: 3) == 2)
    }

    @Test func overflowIndexMath() {
        let roomy = TabOrdering.layout(count: 3, available: 1000, minWidth: 132, maxWidth: 232, spacing: 4)
        #expect(roomy.tabWidth == 232 && !roomy.overflows)
        let compressed = TabOrdering.layout(count: 5, available: 800, minWidth: 132, maxWidth: 232, spacing: 4)
        #expect(compressed.tabWidth == 156 && !compressed.overflows)
        let overflowing = TabOrdering.layout(count: 40, available: 800, minWidth: 132, maxWidth: 232, spacing: 4)
        #expect(overflowing.tabWidth == 132 && overflowing.overflows)
        #expect(overflowing.contentWidth == 5436, "\(overflowing.contentWidth)")
        #expect(TabOrdering.dropIndex(for: 1, translation: 140, tabWidth: 132, spacing: 4, count: 4) == 2)
        #expect(TabOrdering.dropIndex(for: 1, translation: -500, tabWidth: 132, spacing: 4, count: 4) == 0)
        #expect(TabOrdering.dropIndex(for: 1, translation: 30, tabWidth: 132, spacing: 4, count: 4) == 1)
        #expect(TabOrdering.neighborOffset(for: 2, source: 1, destination: 3, tabWidth: 132, spacing: 4) == -136)
        #expect(TabOrdering.neighborOffset(for: 0, source: 2, destination: 0, tabWidth: 132, spacing: 4) == 136)
        #expect(TabOrdering.neighborOffset(for: 3, source: 2, destination: 0, tabWidth: 132, spacing: 4) == 0)
    }
}

@MainActor @Suite struct LayoutStateTests {
    @Test func testWidthsClampToMinMax() {
        let layout = LayoutState(sidebarWidth: 10, inspectorWidth: 10_000)
        #expect(layout.sidebarWidth == 200)
        #expect(layout.inspectorWidth == 560)
        layout.sidebarWidth = 9_999
        #expect(layout.sidebarWidth == 380)
        layout.inspectorWidth = .nan
        #expect(layout.inspectorWidth == 360)
    }

    @Test func testPersistence() throws {
        let layout = LayoutState(sidebarWidth: 290, inspectorWidth: 410)
        let restored = LayoutState(layout.record)
        #expect(restored.sidebarWidth == 290 && restored.inspectorWidth == 410)
        #expect(LayoutState(nil).sidebarWidth == 248)
    }
}

/// Menu enabling through the real window controller's validation (no UI automation).
@MainActor @Suite(.serialized) struct MenuStateTests {
    func item(_ selector: Selector) -> NSMenuItem { NSMenuItem(title: "", action: selector, keyEquivalent: "") }

    @Test func testRepositoryMenuDisabledOnNewTab() throws {
        let harness = try Harness()
        let controller = MainWindowController(model: harness.model)
        defer { controller.close() }
        for selector in [
            #selector(MainWindowController.refreshRepository(_:)),
            #selector(MainWindowController.revealRepositoryInFinder(_:)),
            #selector(MainWindowController.openRepositoryInTerminal(_:)),
            #selector(MainWindowController.copyRepositoryPath(_:)),
        ] {
            #expect(!controller.validateMenuItem(item(selector)), "\(selector)")
        }
    }

    @Test func testFileMenuItemsEnabledState() async throws {
        let harness = try Harness()
        let controller = MainWindowController(model: harness.model)
        defer { controller.close() }
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.newTab(_:)))))
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.openRepository(_:)))))
        #expect(!controller.validateMenuItem(item(#selector(MainWindowController.reopenClosedTab(_:)))))
        #expect(!controller.validateMenuItem(item(#selector(MainWindowController.selectNextTab(_:)))))
        let tab = try await harness.open(try await harness.repository("a"))
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.refreshRepository(_:)))))
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.copyRepositoryPath(_:)))))
        harness.model.newTab()
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.selectNextTab(_:)))))
        harness.model.closeTab(tab.id)
        #expect(controller.validateMenuItem(item(#selector(MainWindowController.reopenClosedTab(_:)))))
    }

    @Test func testMenusOnlyWhenTheyHaveWorkingItems() {
        let menu = MainMenu.build(recentsDelegate: MenuDelegateStub(), windowDelegate: MenuDelegateStub())
        let titles = menu.items.map(\.title)
        // Phase 4 adds the Branch menu with working items; there is still no Git menu.
        #expect(titles == ["Jit", "File", "Edit", "View", "Repository", "Branch", "Window", "Help"])
        // ⌘1–⌘3 stay reserved for workbench modes.
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(all) }
        let commandDigits = all(menu).filter {
            ["1", "2", "3"].contains($0.keyEquivalent) && $0.keyEquivalentModifierMask == .command
        }
        #expect(commandDigits.isEmpty)
    }
}

final class MenuDelegateStub: NSObject, NSMenuDelegate {}

@MainActor @Suite struct Phase4MenuTests {
    func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }

    @Test func phase4ShortcutsMatchTheRegistry() {
        let menu = MainMenu.build(recentsDelegate: MenuDelegateStub(), windowDelegate: MenuDelegateStub())
        let all = items(menu)
        func item(_ title: String) -> NSMenuItem? { all.first { $0.title == title } }
        #expect(item("Clone Repository…")?.keyEquivalent == "N")
        #expect(item("Clone Repository…")?.keyEquivalentModifierMask == .command)
        #expect(item("Show Activity")?.keyEquivalent == "a")
        #expect(item("Show Activity")?.keyEquivalentModifierMask == [.command, .option])
        #expect(item("Stash Changes…")?.keyEquivalent == "s")
        #expect(item("Stash Changes…")?.keyEquivalentModifierMask == [.command, .option])
        for title in ["Fetch", "Pull", "Push", "Remotes…", "New Branch…", "Abort Operation…"] {
            #expect(item(title) != nil, "\(title)")
        }
    }

    @Test func noTwoItemsShareAShortcut() {
        let menu = MainMenu.build(recentsDelegate: MenuDelegateStub(), windowDelegate: MenuDelegateStub())
        var seen: [String: String] = [:]
        for item in items(menu) where !item.keyEquivalent.isEmpty && !item.isHidden {
            let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
            #expect(seen[key] == nil, "\(item.title) and \(seen[key] ?? "") share a shortcut")
            seen[key] = item.title
        }
    }
}
