import AppKit
import DesignSystem
import Features
import GitCore
import Observation
import Services
import os

/// AppKit lifecycle: one main window with repository tabs (ADR-0007), a Settings window, and a menu bar
/// built in code. Startup reads the small session file synchronously, shows the window with cached
/// tab titles, and only then — after the first frame — lets the active tab load Git data.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static func main() {
        LaunchSignpost.begin()
        LaunchProbe.startIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private var model: AppModel?
    private var windowController: MainWindowController?
    private var settings: SettingsWindowController?
    private var memoryPressure: MemoryPressureMonitor?
    private var recentsMenu: NSMenu?
    private let preferences = PreferencesStore()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window exists, so a dark launch never flashes light.
        applyAppearance()
        observeAppearance()
        NSApp.mainMenu = MainMenu.build(recentsDelegate: self, windowDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let location = StoreLocation.applicationSupport()
        let sessionStore = SessionStore(location: location)
        let model = AppModel(
            engine: GitEngine(), preferences: preferences, recents: RecentsStore(location: location),
            profiles: ProfileStore(location: location), sessionStore: sessionStore)
        let savedSession = sessionStore.load().value
        let controller = MainWindowController(model: model)
        self.model = model
        windowController = controller
        model.restore(savedSession)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        LaunchProbe.firstContentAppeared()

        // After the first frame: the active tab may start Git work.
        DispatchQueue.main.async {
            controller.updateForeground()
            self.runLaunchHooks(model)
        }
        // Discard recovery copies: 7 days / 500 MB, once per launch, off the main thread (ADR-0025).
        Task.detached(priority: .utility) { RecoveryStore(location: location).prune() }
        memoryPressure = MemoryPressureMonitor { [weak model] in model?.handleMemoryPressure() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.recordFrame()
        model?.flush()
        // No Git child may outlive Jit.
        ProcessRunner.terminateAllRunning()
    }

    /// Running writes (stage, discard, commit…) finish before Jit quits; Git processes are only killed after
    /// that, or after 10 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasPendingWrites else { return .terminateNow }
        let running = model.runningOperations
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText =
                running.count == 1 ? "An operation is still running." : "\(running.count) operations are still running."
            alert.informativeText =
                running.prefix(6).joined(separator: "\n")
                + "\n\nQuitting cancels fetches, clones and pushes. Local operations (merge, rebase, commit) finish first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            model.cancelCancellableOperations()
        }
        let reply = TerminateReply()
        model.whenWritesFinish { reply.send() }
        // One-shot limit: a hung hook must not keep Jit from quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated { reply.send() } }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders opened via Finder/Dock or `open -a Jit <folder>` open as repository tabs.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.open(url) }
    }

    // MARK: - Appearance

    private func applyAppearance() {
        #if DEBUG
            // `-JitAppearance light|dark` forces the appearance for screenshots.
            switch UserDefaults.standard.string(forKey: "JitAppearance") {
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
                return
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
                return
            default: break
            }
        #endif
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func observeAppearance() {
        withObservationTracking {
            _ = preferences.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyAppearance()
                self?.observeAppearance()
            }
        }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let value = PreferencesStore.Appearance(rawValue: raw) {
            preferences.appearance = value
        }
    }

    // MARK: - App-level menu actions

    @objc func showSettings(_ sender: Any?) { settingsController().show() }

    @objc func showSettingsProfiles(_ sender: Any?) { settingsController().show(.profiles) }

    @objc func showSettingsAccounts(_ sender: Any?) { settingsController().show(.accounts) }

    @objc func showSettingsNetwork(_ sender: Any?) { settingsController().show(.network) }

    private func settingsController() -> SettingsWindowController {
        if let settings { return settings }
        guard let model else { fatalError("Settings requested before launch finished") }
        let controller = SettingsWindowController(
            preferences: preferences, accounts: model.accounts, engine: model.engine)
        settings = controller
        return controller
    }

    @objc func showJitHelp(_ sender: Any?) {
        // Opens the project README in the user's browser; Jit itself makes no network request.
        if let url = URL(string: "https://github.com/ashkanRmk/jit#readme") { NSWorkspace.shared.open(url) }
    }

    /// ⌘W in windows other than the main window (Settings) closes that window.
    @objc func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == MainMenu.AppSelectors.setAppearance {
            menuItem.state = (menuItem.representedObject as? String) == preferences.appearance.rawValue ? .on : .off
        }
        if menuItem.action == #selector(closeTab(_:)) { return NSApp.keyWindow != nil }
        return true
    }

    // MARK: - Dynamic menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        switch menu.title {
        case "Open Recent": MainMenu.updateRecentsMenu(menu, recents: model.recents)
        case "Window": MainMenu.updateWindowMenu(menu, tabs: model.tabs, activeID: model.activeTabID)
        default: break
        }
    }

    // MARK: - Launch hooks (manual checks, UI tests, benchmarks)

    private func runLaunchHooks(_ model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        // `-JitOpen <path>` or env `JIT_OPEN=<path>` (all builds); `-JitUITestOpenRepository <path>` (debug):
        // NSOpenPanel isn't reliably scriptable. Use the env form with `open`, where AppKit treats path
        // arguments as files to open.
        var path = environment["JIT_OPEN"] ?? UserDefaults.standard.string(forKey: "JitOpen")
        #if DEBUG
            path = path ?? UserDefaults.standard.string(forKey: "JitUITestOpenRepository")
        #endif
        if let path { model.open(URL(fileURLWithPath: path)) }
        if GraphBenchmark.isEnabled, let controller = windowController {
            GraphBenchmark.prepare()
            Task {
                await GraphBenchmark.run(controller: controller, report: Benchmarks.report)
                NSApp.terminate(nil)
            }
        }
        switch BenchmarkScenario.current {
        case .none: break
        case .unknown(let name):
            // Never runs anything; logged so a typo in a script is visible.
            Benchmarks.report("scenario=\(name) error=unknown-scenario\n")
        case .scenario(let scenario):
            if let controller = windowController, scenario != .graphScroll {
                Task {
                    await BenchmarkScenarioRunner.run(
                        scenario, model: model, controller: controller, report: Benchmarks.report)
                    NSApp.terminate(nil)
                }
            }
        }
        if environment["JIT_BENCHMARK_TAB_SWITCH"] != nil, let controller = windowController {
            Task { await Benchmarks.tabSwitch(model: model, controller: controller) }
        }
        if let repository = environment["JIT_STRESS_OPEN_CLOSE"] {
            Task { await Benchmarks.openCloseStress(model: model, path: repository) }
        }
        #if DEBUG
            DebugLaunchActions.run(model: model, controller: windowController)
        #endif
    }
}

/// Benchmark mode (`-JitBenchmarkLaunch`, optional env `JIT_BENCHMARK_OUTPUT=<file>`): measures process start (kernel
/// start time) → first window key, prints `first_window_ms=<value> trigger=<key|content>` to stdout
/// (and the file), then quits. Also emits an os_signpost interval ("Launch",
/// subsystem `jit.performance`) for Instruments. Inactive in normal launches.
@MainActor
final class LaunchProbe {
    private static let signposter = OSSignposter(subsystem: Signposts.subsystem, category: .pointsOfInterest)
    private let interval: OSSignpostIntervalState
    private var observers: [any NSObjectProtocol] = []

    init() {
        interval = Self.signposter.beginInterval("Launch")
        Self.current = self
        // Ends when the first window becomes key, or — when launched in the background, where it never
        // becomes key — when the window is first shown (`firstContentAppeared`).
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.finish(trigger: "key") } })
    }

    /// The active probe, if launched with `-JitBenchmarkLaunch`.
    static var current: LaunchProbe?

    /// Called first thing in `main()`, before any window or app-delegate callback.
    static func startIfRequested() {
        guard current == nil, ProcessInfo.processInfo.arguments.contains("-JitBenchmarkLaunch") else { return }
        _ = LaunchProbe()
    }

    static func firstContentAppeared() {
        // `-JitBenchmarkTrigger key` (used by launch.sh) waits for the key window only.
        guard UserDefaults.standard.string(forKey: "JitBenchmarkTrigger") != "key" else { return }
        current?.finish(trigger: "content")
    }

    private var isFinished = false

    /// `trigger`: "key" (first window became key — the launch.sh method, via LaunchServices) or
    /// "content" (window shown; used when the app is launched in the background and never becomes
    /// active). Only "key" measurements are comparable baselines.
    private func finish(trigger: String) {
        guard !isFinished else { return }
        isFinished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // Let the window commit its first frame before stopping the clock.
        DispatchQueue.main.async { [self] in
            Self.signposter.endInterval("Launch", interval)
            let milliseconds = Self.millisecondsSinceProcessStart()
            Benchmarks.report(String(format: "first_window_ms=%.1f trigger=%@\n", milliseconds, trigger))
            NSApp.terminate(nil)
        }
    }

    /// Wall-clock time since the kernel created this process (`kinfo_proc.kp_proc.p_starttime`).
    static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let startMs = Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
        let nowMs = Double(now.tv_sec) * 1000 + Double(now.tv_usec) / 1000
        return nowMs - startMs
    }
}

/// `launch.firstWindow` (P6.1): process `main()` → first window key + one main-queue turn (the frame commits).
/// Always on; `OSSignposter` costs nothing while no trace records.
@MainActor
enum LaunchSignpost {
    private static var token: Signposts.Token?
    private static var observer: (any NSObjectProtocol)?

    static func begin() {
        token = Signposts.begin(Signposts.launchFirstWindow)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { finish() } }
    }

    private static func finish() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        guard let token else { return }
        self.token = nil
        DispatchQueue.main.async { Signposts.end(token) }
    }
}

/// Answers a deferred quit exactly once.
@MainActor
private final class TerminateReply {
    private var sent = false

    func send() {
        guard !sent else { return }
        sent = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
