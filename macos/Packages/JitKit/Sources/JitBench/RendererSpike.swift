import AppKit
import DesignSystem
import Features
import GitCore
import GitTestKit

/// `CodeLinesView` first paint, scroll frames and footprint on 2k- and 50k-line diffs in an offscreen
/// window (ADR-0011; the TextKit 2 prototype it was compared with was removed after the decision).
/// Release build: `swift run -c release JitBench renderer-spike`.
@MainActor
enum RendererSpike {
    struct Row {
        let renderer: String
        let lines: Int
        let firstPaintMilliseconds: Double
        let frameP50: Double
        let frameP99: Double
        let frameMax: Double
        let framesOver16: Int
        let frames: Int
        let footprintMB: Double
    }

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func document(lines: Int, in sandbox: GitSandbox) async throws -> DiffDocument {
        let repo = try await sandbox.makeRepository("spike-\(lines)")
        let original = (0..<lines).map { "    let value\($0) = compute(\($0), factor: 3) // original line" }
        try repo.write("big.swift", original.joined(separator: "\n") + "\n")
        try await repo.commit("Initial")
        var edited = original
        for index in stride(from: 3, to: lines, by: 5) {
            edited[index] = "    let value\(index) = compute(\(index), factor: 4) // changed"
        }
        try repo.write("big.swift", edited.joined(separator: "\n") + "\n")
        let engine = GitEngine(configuration: sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return try await handle.openDiff(.unstaged(path: "big.swift")).expandingAll()
    }

    static func window() -> (NSWindow, NSScrollView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered,
            defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        window.contentView = scroll
        return (window, scroll)
    }

    static func ms(_ duration: Duration) -> Double {
        let (seconds, atto) = duration.components
        return Double(seconds) * 1000 + Double(atto) / 1e15
    }

    /// Scrolls 400 steps of 3 rows; each step draws the visible rect (worst case: full redraw).
    static func scrollFrames(_ scroll: NSScrollView, document view: NSView, step: CGFloat) -> [Double] {
        var frames: [Double] = []
        let clock = ContinuousClock()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: scroll.documentVisibleRect) else { return [] }
        var y: CGFloat = 0
        for _ in 0..<400 {
            y += step
            if y + scroll.contentSize.height > view.frame.height { y = 0 }
            let started = clock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.cacheDisplay(in: scroll.documentVisibleRect, to: bitmap)
            frames.append(ms(clock.now - started))
        }
        return frames.sorted()
    }

    static func summarize(_ name: String, lines: Int, first: Double, frames: [Double], footprint: Double) -> Row {
        func p(_ q: Double) -> Double { frames[min(frames.count - 1, Int(Double(frames.count - 1) * q))] }
        return Row(
            renderer: name, lines: lines, firstPaintMilliseconds: first, frameP50: p(0.5), frameP99: p(0.99),
            frameMax: frames.last ?? 0, framesOver16: frames.filter { $0 > 16.7 }.count, frames: frames.count,
            footprintMB: footprint)
    }

    static func codeLines(_ document: DiffDocument) -> Row {
        let base = footprint()
        let clock = ContinuousClock()
        let started = clock.now
        let (window, scroll) = window()
        let view = CodeLinesView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        scroll.documentView = view
        let source = DiffRowsSource(document: document, layout: .unified)
        view.dataSource = source
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: scroll.documentVisibleRect) {
            view.cacheDisplay(in: scroll.documentVisibleRect, to: bitmap)
        }
        let first = ms(clock.now - started)
        let frames = scrollFrames(scroll, document: view, step: view.rowHeight * 3)
        let row = summarize(
            "CodeLinesView", lines: document.rowCount(.unified), first: first, frames: frames,
            footprint: footprint() - base)
        withExtendedLifetime((window, source)) {}
        return row
    }

    static func run() async throws {
        _ = NSApplication.shared
        let sandbox = try GitSandbox()
        for lines in [2_000, 50_000] {
            let document = try await document(lines: lines, in: sandbox)
            for row in [codeLines(document), codeLines(document)] {
                print(
                    String(
                        format:
                            "%@ %d rows: first paint %.1f ms; frame p50 %.2f p99 %.2f max %.2f ms, >16.7 ms: %d/%d; footprint +%.1f MB",
                        row.renderer, row.lines, row.firstPaintMilliseconds, row.frameP50, row.frameP99, row.frameMax,
                        row.framesOver16, row.frames, row.footprintMB))
            }
        }
    }
}
