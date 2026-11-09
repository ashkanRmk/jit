import AppKit
import Foundation
import GitCore
import GitTestKit
import Services
import Testing

@testable import Features

/// P6.5 / P6.6: inactive and hidden tabs do no work and reconcile when shown; caches stay bounded and trim
/// under memory pressure; no repeating timers or perpetual animations in the sources.
@MainActor @Suite(.serialized) struct IdleAndCacheTests {
    static func model(_ sandbox: GitSandbox) -> AppModel {
        let location = StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/AppSupport"))
        let defaults = UserDefaults(suiteName: "jit.idle.\(UUID().uuidString)") ?? .standard
        let model = AppModel(
            engine: sandbox.engine, preferences: PreferencesStore(defaults: defaults),
            recents: RecentsStore(location: location), profiles: ProfileStore(location: location),
            sessionStore: nil, watchesFileSystem: true)
        model.restore(nil)
        return model
    }

    static func repo(_ sandbox: GitSandbox, _ name: String) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository(name)
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        return repo
    }

    static func open(_ model: AppModel, _ repo: TestRepo) async throws -> TabModel {
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        let tab = try #require(model.activeTab)
        #expect(await ClosedTabDeallocatesTests.waitUntil { tab.session?.status != nil })
        return tab
    }

    // MARK: Tab suspension (ADR-0042)

    @Test func inactiveTabReleasesWatcher() async throws {
        let sandbox = try GitSandbox()
        let model = Self.model(sandbox)
        model.setForeground(true)
        let a = try await Self.open(model, try await Self.repo(sandbox, "a"))
        #expect(a.session?.isWatching == true)
        let b = try await Self.open(model, try await Self.repo(sandbox, "b"))
        #expect(a.session?.isWatching == false)  // hidden tab: no FSEvents stream
        #expect(b.session?.isWatching == true)
    }

    @Test func occludedWindowPausesRefresh() async throws {
        let sandbox = try GitSandbox()
        let model = Self.model(sandbox)
        model.setForeground(true)
        let tab = try await Self.open(model, try await Self.repo(sandbox, "occluded"))
        #expect(tab.session?.isWatching == true)
        model.setForeground(false)  // minimized, covered, other Space or app inactive
        #expect(tab.session?.isWatching == false)
        model.setForeground(true)
        #expect(tab.session?.isWatching == true)
    }

    @Test func suspendedTabReconcilesExternalEdits() async throws {
        let sandbox = try GitSandbox()
        let model = Self.model(sandbox)
        model.setForeground(true)
        let repoA = try await Self.repo(sandbox, "suspended")
        let a = try await Self.open(model, repoA)
        #expect(a.session?.status?.summary?.untracked == 0)
        _ = try await Self.open(model, try await Self.repo(sandbox, "other"))
        // While A is hidden and then dropped under memory pressure, its files change outside Jit.
        model.handleMemoryPressure()
        #expect(a.session?.lifecycle == .suspended)
        try repoA.write("new.txt", "external\n")
        try repoA.write("a.txt", "changed\n")
        try await repoA.git("add", "a.txt")
        model.select(a.id)
        #expect(
            await ClosedTabDeallocatesTests.waitUntil {
                a.session?.status?.summary?.untracked == 1 && a.session?.status?.summary?.staged == 1
            })
        #expect(a.session?.isWatching == true)
    }

    // MARK: Cache limits (ADR-0043)

    final class Rows: CodeLinesDataSource {
        let rowCount: Int
        init(_ count: Int) { rowCount = count }
        var columnCount: Int { 1 }
        var maxColumnCharacters: Int { 40 }
        var maxLineNumber: Int { rowCount }
        func cell(row: Int, column: Int) -> CodeCell {
            CodeCell(kind: .context, oldNumber: row + 1, newNumber: row + 1, text: "line \(row) of a long file")
        }
        func isSelected(row: Int, column: Int) -> Bool { false }
        func highlights(row: Int, column: Int) -> (ranges: [NSRange], current: NSRange?) { ([], nil) }
    }

    @Test func codeLineCacheIsBoundedAndTrims() {
        let rows = Rows(CacheLimits.codeLines + 2000)
        let view = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.dataSource = rows
        let rect = view.bounds
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) {
            // Draw every row once (in slices, as scrolling would).
            var y: CGFloat = 0
            while y < rect.height {
                let slice = NSRect(x: 0, y: y, width: rect.width, height: min(2000, rect.height - y))
                view.cacheDisplay(in: slice, to: bitmap)
                y += slice.height
            }
        }
        #expect(view.cachedLineCount > 0)
        #expect(view.cachedLineCount <= CacheLimits.codeLines)
        NotificationCenter.default.post(name: CacheLimits.trimNotification, object: nil)
        #expect(view.cachedLineCount == 0)
        withExtendedLifetime(rows) {}
    }

    @Test func memoryPressureTrimsPaletteIndexAndSuspendsInactiveTabs() async throws {
        let sandbox = try GitSandbox()
        let model = Self.model(sandbox)
        model.setForeground(true)
        let a = try await Self.open(model, try await Self.repo(sandbox, "pressure-a"))
        let b = try await Self.open(model, try await Self.repo(sandbox, "pressure-b"))
        model.handleMemoryPressure()
        #expect(a.session?.lifecycle == .suspended)
        #expect(b.session?.lifecycle == .active)  // the visible tab keeps everything
        #expect(CommandPaletteModel.fileIndexCacheCount <= CacheLimits.paletteFileIndexRepositories)
    }

    // MARK: No repeating timers / perpetual animation (design §4.4)

    @Test func noRepeatingTimersOrPerpetualAnimationsInSources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        // Dev-only executables are exempt (benchmarks, rig); one-shot timers (timeouts, grace periods) are fine.
        let exempt = ["JitBench", "TestRig"]
        let forbidden = [
            "repeats: true", "Timer.scheduledTimer", "Timer.publish", "TimelineView", "CVDisplayLink",
            "CADisplayLink", "displayLink(", "repeatForever", ".schedule(deadline: .now(), repeating",
        ]
        var findings: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !exempt.contains(where: { url.path.contains("/\($0)/") }) else {
                continue
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? ""
                for pattern in forbidden where code.contains(pattern) {
                    findings.append("\(url.lastPathComponent):\(number + 1): \(pattern)")
                }
            }
        }
        #expect(findings.isEmpty, "\(findings)")
    }
}
