import AppKit
import Features
import GitCore
import GitTestKit

/// Phase 3 performance table (implementation.md §4), release build:
/// `swift run -c release --package-path macos/Packages/JitKit JitBench phase3`.
@MainActor
enum Phase3Bench {
    static func ms(_ d: Duration) -> Double { RendererSpike.ms(d) }

    static func p50(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    static func repo(_ sandbox: GitSandbox, _ name: String, files: [String: String]) async throws -> (
        TestRepo, RepositoryHandle
    ) {
        let repo = try await sandbox.makeRepository(name)
        for (path, contents) in files { try repo.write(path, contents) }
        try await repo.commit("Initial")
        let handle = try await GitEngine(configuration: sandbox.engineConfiguration()).openRepository(
            at: URL(fileURLWithPath: repo.path))
        _ = try await handle.objectFormat()
        return (repo, handle)
    }

    static func firstPaint(_ document: DiffDocument) -> NSView {
        let (window, scroll) = RendererSpike.window()
        let view = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        scroll.documentView = view
        let source = DiffRowsSource(document: document, layout: .unified)
        view.dataSource = source
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: scroll.documentVisibleRect) {
            view.cacheDisplay(in: scroll.documentVisibleRect, to: bitmap)
        }
        withExtendedLifetime((window, source)) {}
        return view
    }

    static func run() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        let clock = ContinuousClock()

        // 1. Diff open → first paint, 2k-line file (Git read + parse + layout + draw).
        let lines2k = (0..<2000).map { "    let value\($0) = compute(\($0)) // line" }
        let (repo2k, handle2k) = try await repo(
            sandbox, "d2k", files: ["f.swift": lines2k.joined(separator: "\n") + "\n"])
        var edited = lines2k
        for index in stride(from: 5, to: 2000, by: 40) { edited[index] = "    let changed\(index) = 0" }
        try repo2k.write("f.swift", edited.joined(separator: "\n") + "\n")
        var paints: [Double] = []
        for _ in 0..<21 {
            let started = clock.now
            let document = try await handle2k.openDiff(.unstaged(path: "f.swift"))
            _ = firstPaint(document)
            paints.append(ms(clock.now - started))
        }
        print(
            String(
                format: "diff open → first paint (2k lines): p50 %.1f ms, max %.1f ms (n=21)", p50(paints),
                paints.max() ?? 0))

        // 2. 50k-line diff memory (document + rows + view).
        let lines50k = (0..<50_000).map { "line \($0) of a large file" }
        let (repo50k, handle50k) = try await repo(
            sandbox, "d50k", files: ["big.txt": lines50k.joined(separator: "\n") + "\n"])
        try repo50k.write(
            "big.txt", lines50k.enumerated().map { $0 % 7 == 0 ? "edited \($1)" : $1 }.joined(separator: "\n") + "\n")
        let before50k = RendererSpike.footprint()
        var keep: [AnyObject] = []
        let document50k = try await handle50k.openDiff(.unstaged(path: "big.txt"))
        keep.append(firstPaint(document50k))
        keep.append(document50k)
        print(
            String(
                format: "diff memory (50k-line file, %d rows): +%.1f MB footprint; document %.1f MB",
                document50k.rowCount(.unified),
                RendererSpike.footprint() - before50k, Double(document50k.approximateBytes) / 1_048_576))
        keep.removeAll()

        // 3. 200 open/close cycles: footprint drift.
        for _ in 0..<10 { _ = firstPaint(try await handle2k.openDiff(.unstaged(path: "f.swift"))) }
        let baseline = RendererSpike.footprint()
        for _ in 0..<200 {
            autoreleasepool {}
            _ = firstPaint(try await handle2k.openDiff(.unstaged(path: "f.swift")))
        }
        print(
            String(
                format: "200 diff open/close cycles: footprint %.1f → %.1f MB (Δ %.1f MB)", baseline,
                RendererSpike.footprint(),
                RendererSpike.footprint() - baseline))

        // 4. Status refresh, 1k changed files.
        var files: [String: String] = [:]
        for index in 0..<1000 { files["src/file\(index).txt"] = "content \(index)\n" }
        let (repoStatus, handleStatus) = try await repo(sandbox, "status", files: files)
        for index in 0..<1000 { try repoStatus.write("src/file\(index).txt", "changed \(index)\n") }
        var refreshes: [Double] = []
        for _ in 0..<21 {
            await handleStatus.invalidate([.worktree])
            let started = clock.now
            _ = try await handleStatus.status()
            refreshes.append(ms(clock.now - started))
        }
        print(String(format: "status refresh (1k changed files): p50 %.1f ms (n=21)", p50(refreshes)))

        // 5. Stage one line end to end (token, patch, check, apply, verify), normal 300-line file.
        let normal = (0..<300).map { "line \($0)" }
        let (repoStage, handleStage) = try await repo(
            sandbox, "stage", files: ["f.txt": normal.joined(separator: "\n") + "\n"])
        try repoStage.write(
            "f.txt", normal.enumerated().map { $0 % 30 == 0 ? "new \($1)" : $1 }.joined(separator: "\n") + "\n")
        var stages: [Double] = []
        for index in 0..<10 {
            let unstaged = try await handleStage.openDiff(.unstaged(path: "f.txt"))
            let added = (0..<unstaged.storage.lineCount).filter { unstaged.kind(ofLine: $0) == .added }
            let started = clock.now
            _ = try await handleStage.apply(
                SelectionRequest(document: unstaged, lines: [added[index % added.count]], action: .stage))
            stages.append(ms(clock.now - started))
        }
        print(
            String(format: "stage one line end to end: p50 %.1f ms, max %.1f ms (n=10)", p50(stages), stages.max() ?? 0)
        )

        // 6. Blame first lines, 5k-line file with two commits.
        let lines5k = (0..<5000).map { "let v\($0) = \($0)" }
        let (repoBlame, handleBlame) = try await repo(
            sandbox, "blame", files: ["b.swift": lines5k.joined(separator: "\n") + "\n"])
        try repoBlame.write(
            "b.swift", lines5k.enumerated().map { $0 % 50 == 0 ? "let w\($0) = 0" : $1 }.joined(separator: "\n") + "\n")
        try await repoBlame.commit("Second")
        var firsts: [Double] = []
        for _ in 0..<11 {
            let started = clock.now
            for try await event in handleBlame.blame("b.swift") {
                if case .block = event {
                    firsts.append(ms(clock.now - started))
                    break
                }
            }
        }
        print(String(format: "blame first lines (5k-line file): p50 %.1f ms (n=11)", p50(firsts)))
    }
}
