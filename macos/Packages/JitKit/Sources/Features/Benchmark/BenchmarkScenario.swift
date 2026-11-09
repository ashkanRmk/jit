import AppKit
import Foundation
import GitCore
import Services
import os

/// `-JitBenchmarkScenario <name>` (all builds, inert unless passed; P6.1, design §4.2): opens the local
/// repositories named in `JIT_BENCH_REPOS` (colon-separated) or `JIT_OPEN`, performs one scripted, read-only
/// action, reports metrics as lines and quits. Measurements come from the same `Signposts` intervals
/// Instruments shows. Never touches the network or credentials and never mutates a repository.
public enum BenchmarkScenario: String, CaseIterable, Sendable {
    /// Open → first graph rows, `JIT_BENCH_RUNS` times (default 10).
    case openRepo = "open-repo"
    /// Graph first rows, scroll steps, page appends, row draws, footprint (the Phase 2 graph benchmark).
    case graphScroll = "graph-scroll"
    /// Select changed files one after another; `diff.switch` per file.
    case diffSwitch = "diff-switch"
    /// Select the largest changed file repeatedly; `diff.switch`.
    case largeDiff = "large-diff"
    /// Open a repository with hundreds of changes; `repo.open`, `core.status`, working-directory list.
    case manyFiles = "many-files"
    /// Open every repository as a tab, switch between them, report footprint.
    case multiTab = "multi-tab"
    /// Open and close the first repository repeatedly; footprint (Phase 1 stress).
    case openCloseLoop = "open-close-loop"

    public enum Request: Equatable, Sendable {
        case none
        case scenario(BenchmarkScenario)
        case unknown(String)
    }

    /// Parses `-JitBenchmarkScenario <name>` from launch arguments. Unknown names never run anything.
    public static func request(from arguments: [String]) -> Request {
        guard let index = arguments.firstIndex(of: "-JitBenchmarkScenario") else { return .none }
        guard index + 1 < arguments.count else { return .unknown("") }
        let name = arguments[index + 1]
        return BenchmarkScenario(rawValue: name).map(Request.scenario) ?? .unknown(name)
    }

    /// The scenario of this process, if any (read once).
    public static let current: Request = request(from: ProcessInfo.processInfo.arguments)

    static let log = Logger(subsystem: Signposts.subsystem, category: "benchmark")

    /// Repositories from `JIT_BENCH_REPOS` (colon-separated) or `JIT_OPEN`. Local paths only.
    static func repositories(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let raw = environment["JIT_BENCH_REPOS"] ?? environment["JIT_OPEN"] ?? ""
        return raw.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.hasPrefix("//") }.map {
            URL(fileURLWithPath: $0)
        }
    }
}

/// Collects interval durations from `Signposts` while a scenario runs.
final class SignpostRecorder: Sendable {
    private struct State {
        var open: [UInt64: (String, ContinuousClock.Instant)] = [:]
        var durations: [String: [Double]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install() {
        Signposts.setObserver { [self] event in
            let now = ContinuousClock.now
            state.withLock { state in
                switch event {
                case .begin(let name, let serial): state.open[serial] = (name, now)
                case .end(let name, let serial):
                    guard let (_, start) = state.open.removeValue(forKey: serial) else { return }
                    state.durations[name, default: []].append(BenchmarkMath.ms(now - start))
                }
            }
        }
    }

    func uninstall() { Signposts.setObserver(nil) }

    func durations(_ interval: Signposts.Interval) -> [Double] {
        state.withLock { $0.durations[interval.name] ?? [] }
    }

    func reset() { state.withLock { $0.durations = [:] } }
}

enum BenchmarkMath {
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// `metric=<name> median=… p90=… max=… n=… unit=ms`
    static func line(_ scenario: BenchmarkScenario, _ metric: String, _ values: [Double], unit: String = "ms")
        -> String
    {
        String(
            format: "scenario=%@ metric=%@ median=%.3f p90=%.3f max=%.3f n=%d unit=%@\n", scenario.rawValue, metric,
            percentile(values, 0.5), percentile(values, 0.9), values.max() ?? 0, values.count, unit)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Runs a scenario against the real window (release builds for numbers).
@MainActor
public enum BenchmarkScenarioRunner {
    public static func run(
        _ scenario: BenchmarkScenario, model: AppModel, controller: MainWindowController,
        report: @escaping (String) -> Void
    ) async {
        let repositories = BenchmarkScenario.repositories()
        let runs = Int(ProcessInfo.processInfo.environment["JIT_BENCH_RUNS"] ?? "") ?? 10
        let recorder = SignpostRecorder()
        recorder.install()
        defer { recorder.uninstall() }
        guard let first = repositories.first else {
            report("scenario=\(scenario.rawValue) error=no-repository (set JIT_BENCH_REPOS or JIT_OPEN)\n")
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        switch scenario {
        case .graphScroll:
            // Driven by GraphBenchmark (enabled for this scenario); the launch hook opens the repository.
            return
        case .openRepo, .manyFiles:
            // Warm-up open (not recorded), then N measured opens of a fresh tab.
            for run in 0...max(1, runs) {
                if run == 1 { recorder.reset() }
                guard await openAndWaitForRows(first, model: model, controller: controller) else {
                    report("scenario=\(scenario.rawValue) error=open-failed\n")
                    return
                }
                if scenario == .manyFiles, let workbench = controller.activeWorkbench {
                    _ = workbench.graph?.selectWorkingDirectory()
                    _ = await waitFor { !(workbench.inspectorModel.workingDirectory?.allFiles.isEmpty ?? true) }
                }
                if let id = model.activeTabID { model.closeTab(id) }
                try? await Task.sleep(for: .milliseconds(150))
            }
            report(BenchmarkMath.line(scenario, "repo.open", recorder.durations(Signposts.repoOpen)))
            report(BenchmarkMath.line(scenario, "graph.firstPage", recorder.durations(Signposts.graphFirstPage)))
            report(BenchmarkMath.line(scenario, "core.status", recorder.durations(Signposts.coreStatus)))
        case .diffSwitch, .largeDiff:
            guard await openAndWaitForRows(first, model: model, controller: controller),
                let workbench = controller.activeWorkbench, workbench.graph?.selectWorkingDirectory() == true
            else {
                report("scenario=\(scenario.rawValue) error=open-failed\n")
                return
            }
            guard await waitFor({ !(workbench.inspectorModel.workingDirectory?.allFiles.isEmpty ?? true) }),
                let workingDirectory = workbench.inspectorModel.workingDirectory
            else {
                report("scenario=\(scenario.rawValue) error=no-changes\n")
                return
            }
            let files = workingDirectory.allFiles.filter { $0.section != .conflicts && !$0.isDirectory }
            // large-diff: the fixture's large file is named `large-*` (gen-repos.sh); otherwise the first file.
            let large = files.first { ($0.path as NSString).lastPathComponent.hasPrefix("large-") } ?? files[0]
            let sequence: [WDFile] = scenario == .largeDiff ? [large] : Array(files.prefix(max(runs, 10)))
            recorder.reset()
            let diff = workbench.diffModel
            for (index, file) in sequence.enumerated() {
                let repeats = scenario == .largeDiff ? runs + 1 : 1
                for repeatIndex in 0..<repeats {
                    if scenario == .largeDiff {
                        // Alternate with nothing selected so every selection is a real switch.
                        workingDirectory.selection = []
                        try? await Task.sleep(for: .milliseconds(50))
                        if repeatIndex == 1 { recorder.reset() }
                    }
                    workingDirectory.selection = [file.id]
                    _ = await waitFor { diff.switchSignpost == nil && diff.state != .loading }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                if index == 0, scenario == .diffSwitch { recorder.reset() }  // first switch warms caches
            }
            report(BenchmarkMath.line(scenario, "diff.switch", recorder.durations(Signposts.diffSwitch)))
            report(BenchmarkMath.line(scenario, "core.diffParse", recorder.durations(Signposts.coreDiffParse)))
            report(
                String(
                    format: "scenario=%@ metric=footprint value=%.1f unit=MB\n", scenario.rawValue,
                    BenchmarkMath.footprintMB()))
        case .multiTab:
            for url in repositories {
                guard await openAndWaitForRows(url, model: model, controller: controller) else {
                    report("scenario=\(scenario.rawValue) error=open-failed\n")
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
            recorder.reset()
            guard let window = controller.window else { return }
            for _ in 0..<max(runs, 5) {
                for tab in model.tabs {
                    model.select(tab.id)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            report(BenchmarkMath.line(scenario, "tab.switch", recorder.durations(Signposts.tabSwitch)))
            try? await Task.sleep(for: .seconds(2))
            report(
                String(
                    format: "scenario=%@ metric=footprint value=%.1f unit=MB tabs=%d\n", scenario.rawValue,
                    BenchmarkMath.footprintMB(), model.tabs.count))
        case .openCloseLoop:
            var samples: [Double] = []
            let cycles = max(runs, 50)
            for cycle in 1...cycles {
                guard await openAndWaitForRows(first, model: model, controller: controller) else {
                    report("scenario=\(scenario.rawValue) error=open-failed\n")
                    return
                }
                if let id = model.activeTabID { model.closeTab(id) }
                try? await Task.sleep(for: .milliseconds(50))
                if cycle == 1 || cycle == 10 || cycle == cycles { samples.append(BenchmarkMath.footprintMB()) }
            }
            try? await Task.sleep(for: .seconds(2))
            report(
                String(
                    format:
                        "scenario=%@ metric=footprint first=%.1f after10=%.1f last=%.1f settled=%.1f cycles=%d unit=MB\n",
                    scenario.rawValue, samples[0], samples[min(1, samples.count - 1)], samples.last ?? 0,
                    BenchmarkMath.footprintMB(), cycles))
        }
    }

    /// Opens `url` in a new tab and waits until its graph shows rows (≤ 60 s).
    private static func openAndWaitForRows(_ url: URL, model: AppModel, controller: MainWindowController) async
        -> Bool
    {
        model.newTab()
        model.open(url)
        await model.settleOpen()
        return await waitFor(seconds: 60) {
            guard let tab = model.activeTab, tab.isRepository, tab.openSignpost == nil,
                let graph = controller.activeWorkbench?.graph
            else { return false }
            return graph.loadedCount > 0
        }
    }

    /// Waits on the main actor for `condition` (benchmark harness only; checks every 10 ms).
    private static func waitFor(seconds: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
