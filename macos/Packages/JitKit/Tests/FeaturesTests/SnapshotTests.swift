import AppKit
import DesignSystem
import Foundation
import GitCore
import GitTestKit
import Services
import SwiftUI
import Testing

@testable import Features

/// §18.4 visual regression (P6.11): real data from GitTestKit repositories (fixed dates, identities and so
/// fixed SHAs), offscreen rendering, light / dark / Increase Contrast / Reduce Transparency variants.
@MainActor
@Suite(.serialized, .enabled(if: Snapshot.isComparable, "snapshot references are pinned to another macOS version"))
struct SnapshotTests {
    typealias V = Snapshot.Variant

    /// AppKit content snapshots hide the floating glass chrome they host (command bar, diff chrome, selection
    /// capsule): glass is not captured offscreen (ADR-0040) and is reviewed in live captures instead.
    func hideGlassChrome(in view: NSView) {
        for subview in view.subviews {
            let type = String(describing: Swift.type(of: subview))
            if ["GraphBar", "DiffChromeView", "SelectionCapsule", "GraphStateOverlay"].contains(where: type.contains) {
                subview.isHidden = true
            } else {
                hideGlassChrome(in: subview)
            }
        }
    }

    func check(_ view: NSView, _ name: String, _ variant: V, size: NSSize) {
        let rep = Snapshot.render(view, size: size, variant: variant)
        if let failure = Snapshot.verify(rep, name: name, variant: variant) { Issue.record(Comment(rawValue: failure)) }
    }

    static func appModel(_ sandbox: GitSandbox) -> AppModel {
        ClosedTabDeallocatesTests.makeModel(sandbox)
    }

    // MARK: Empty state (new-tab page)

    @Test(arguments: [V.light, .dark, .lightOpaque, .darkOpaque, .lightHighContrast])
    func newTabPage(_ variant: V) throws {
        let sandbox = try GitSandbox()
        let model = Self.appModel(sandbox)
        model.restore(nil)
        let actions = NewTabActions(
            open: {}, clone: {}, browse: {}, openPath: { _ in }, locate: { _ in }, reveal: { _ in })
        check(
            Snapshot.host(NewTabView(model: model, actions: actions), variant: variant), "new-tab", variant,
            size: NSSize(width: 900, height: 560))
    }

    // MARK: Profile switcher

    @Test(arguments: [V.light, .dark, .lightOpaque, .darkOpaque])
    func profileSwitcher(_ variant: V) throws {
        let sandbox = try GitSandbox()
        let store = ProfileStore(location: StoreLocation(directory: URL(fileURLWithPath: sandbox.root + "/Profiles")))
        let work = GitProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "Work", colorIndex: 1,
            author: GitIdentity(name: "Ada Lovelace", email: "ada@corp.example"))
        let personal = GitProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, displayName: "Personal", colorIndex: 4,
            author: GitIdentity(name: "Ada", email: "ada@home.example"))
        store.create(work, activate: true)
        store.create(personal)
        let view = ProfileSwitcherView(
            store: store, newProfile: { _ in }, editProfile: { _ in }, manageProfiles: {}, dismiss: {})
        check(
            Snapshot.host(view.frame(width: 320), variant: variant), "profile-switcher", variant,
            size: NSSize(width: 320, height: 260))
    }

    // MARK: Command palette

    @Test(arguments: [V.light, .dark, .lightOpaque, .darkOpaque])
    func commandPalette(_ variant: V) async throws {
        let sandbox = try GitSandbox()
        let model = Self.appModel(sandbox)
        model.restore(nil)
        let controller = MainWindowController(model: model)
        let palette = CommandPaletteModel(window: controller)
        palette.reload()
        palette.query = ">tab"
        // Ranking runs off the main actor; wait for it.
        _ = await ClosedTabDeallocatesTests.waitUntil { palette.rows.first?.entry.title.contains("Tab") == true }
        #expect(palette.rows.first?.entry.title.contains("Tab") == true)
        let view = CommandPaletteView(model: palette).frame(maxHeight: .infinity, alignment: .top)
        check(
            Snapshot.host(view, variant: variant), "command-palette", variant,
            size: NSSize(width: CommandPaletteView.width, height: 480))
        withExtendedLifetime(controller) {}
    }

    // MARK: Diff (unified, side by side)

    func diffController(_ layout: DiffLayout) async throws -> (DiffViewController, RepositorySession) {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("snapshot-diff")
        let before = (1...30).map { "    let value\($0) = compute(\($0)) // line \($0)\n" }.joined()
        try repo.write("Sources/Model.swift", before)
        try await repo.commit("Add model")
        var after = before.replacingOccurrences(of: "compute(4)", with: "measure(4, scale: 2)")
        after = after.replacingOccurrences(of: "    let value12 = compute(12) // line 12\n", with: "")
        after += "    let added = true\n"
        try repo.write("Sources/Model.swift", after)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        let model = DiffViewModel(session: session, defaults: .scratch())
        model.layout = layout
        let controller = DiffViewController(model: model)
        model.open(.unstaged(path: "Sources/Model.swift"))
        #expect(await ClosedTabDeallocatesTests.waitUntil { model.state == .loaded && model.source != nil })
        // Syntax spans arrive asynchronously; wait until they are attached.
        _ = await ClosedTabDeallocatesTests.waitUntil { model.highlight != nil }
        return (controller, session)
    }

    @Test(arguments: [V.light, .dark, .darkHighContrast])
    func unifiedDiff(_ variant: V) async throws {
        let (controller, session) = try await diffController(.unified)
        defer { session.close() }
        hideGlassChrome(in: controller.view)
        check(controller.view, "diff-unified", variant, size: NSSize(width: 820, height: 520))
    }

    @Test(arguments: [V.light, .dark])
    func splitDiff(_ variant: V) async throws {
        let (controller, session) = try await diffController(.split)
        defer { session.close() }
        hideGlassChrome(in: controller.view)
        check(controller.view, "diff-split", variant, size: NSSize(width: 1000, height: 520))
    }

    // MARK: Graph

    @Test(arguments: [V.light, .dark, .lightHighContrast])
    func repositoryGraph(_ variant: V) async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository("snapshot-graph")
        try repo.write("a.txt", "1\n")
        try await repo.commit("Initial commit")
        try await repo.git("checkout", "-q", "-b", "feature/search")
        for index in 1...3 {
            try repo.write("s\(index).txt", "\(index)\n")
            try await repo.commit("Add search step \(index)")
        }
        try await repo.git("checkout", "-q", "main")
        try repo.write("b.txt", "2\n")
        try await repo.commit("Fix toolbar layout")
        try await repo.git("merge", "-q", "--no-ff", "feature/search", "-m", "Merge branch 'feature/search'")
        try await repo.git("tag", "v1.0")
        let model = Self.appModel(sandbox)
        model.restore(nil)
        let window = MainWindowController(model: model)
        window.window?.appearance = variant.appearance
        window.showWindow(nil)
        model.setForeground(true)
        model.open(URL(fileURLWithPath: repo.path))
        await model.settleOpen()
        #expect(await ClosedTabDeallocatesTests.waitUntil { window.activeGraph?.loadedCount ?? 0 >= 6 })
        let graph = try #require(window.activeGraph)
        graph.view.removeFromSuperview()
        hideGlassChrome(in: graph.view)
        check(graph.view, "graph", variant, size: NSSize(width: 900, height: 420))
        window.close()
    }

    // MARK: Harness self-checks

    @Test func harnessIsDeterministicAndDetectsAOnePointShift() {
        let make = { (offset: CGFloat) -> NSView in
            Snapshot.host(
                Text("Deterministic").typeStyle(.body).padding(.leading, Space.s6 + offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading),
                variant: .light)
        }
        let size = NSSize(width: 240, height: 60)
        let first = Snapshot.render(make(0), size: size, variant: .light)
        let second = Snapshot.render(make(0), size: size, variant: .light)
        let shifted = Snapshot.render(make(1), size: size, variant: .light)
        #expect(Snapshot.difference(first, second).0 == 0)
        #expect(Snapshot.difference(first, shifted).0 > Snapshot.maxDifferingFraction)
    }
}
