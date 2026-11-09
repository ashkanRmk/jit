import Foundation
import os

/// The one place every performance interval is declared (P6.1, design §4.1). `OSSignposter` costs almost
/// nothing while no trace is recording, so intervals stay compiled into release builds; Instruments shows
/// them under Points of Interest for subsystem `Signposts.subsystem`.
///
/// Rules: interval names are static; the optional detail is a count or a Git subcommand name — never a
/// path, branch name, URL or argument that could carry private repository content into an exported trace.
public enum Signposts {
    /// The app's bundle identifier (placeholder until Phase 7 picks the real one).
    public static let subsystem = "com.example.jit"

    public enum Category: String, Sendable, CaseIterable {
        case launch, repo, graph, diff, tab, ops, core
    }

    /// A declared interval. `name` is the signpost name shown in Instruments.
    public struct Interval: Sendable, CustomStringConvertible {
        public let category: Category
        public let staticName: StaticString

        public init(_ category: Category, _ name: StaticString) {
            self.category = category
            self.staticName = name
        }

        public var name: String { staticName.description }
        public var description: String { name }
    }

    // App intervals (Services / Features / App).
    public static let launchFirstWindow = Interval(.launch, "launch.firstWindow")
    public static let repoOpen = Interval(.repo, "repo.open")
    public static let graphFirstPage = Interval(.graph, "graph.firstPage")
    public static let graphPage = Interval(.graph, "graph.page")
    public static let diffSwitch = Interval(.diff, "diff.switch")
    public static let tabSwitch = Interval(.tab, "tab.switch")
    public static let operation = Interval(.ops, "ops.run")

    // GitCore spans.
    public static let coreHistoryPage = Interval(.core, "core.historyPage")
    public static let coreLaneLayout = Interval(.core, "core.laneLayout")
    public static let coreStatus = Interval(.core, "core.status")
    public static let coreDiffParse = Interval(.core, "core.diffParse")
    public static let corePatchBuild = Interval(.core, "core.patchBuild")
    public static let coreGitProcess = Interval(.core, "core.git")

    /// Every declared interval (tests assert names are unique and well formed).
    public static let all: [Interval] = [
        launchFirstWindow, repoOpen, graphFirstPage, graphPage, diffSwitch, tabSwitch, operation,
        coreHistoryPage, coreLaneLayout, coreStatus, coreDiffParse, corePatchBuild, coreGitProcess,
    ]

    /// An open interval; pass it to `end`. Ending twice is a no-op.
    public struct Token: Sendable {
        let interval: Interval
        let state: OSSignpostIntervalState
        let serial: UInt64
    }

    public enum Event: Sendable, Equatable {
        case begin(name: String, serial: UInt64)
        case end(name: String, serial: UInt64)
    }

    /// One signposter in the Points of Interest category: `xctrace record` only enables dynamic tracing for
    /// Points of Interest (and a few Apple subsystems), so custom categories would be dropped from scripted
    /// traces. The category lives in the interval name prefix instead (`graph.page`, `core.status`).
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    private struct HookState {
        var observer: (@Sendable (Event) -> Void)?
        var serial: UInt64 = 0
        var ended: Set<UInt64> = []
    }

    private static let hook = OSAllocatedUnfairLock(initialState: HookState())

    /// Test hook: receives every begin/end. `nil` removes it.
    public static func setObserver(_ observer: (@Sendable (Event) -> Void)?) {
        hook.withLock {
            $0.observer = observer
            $0.ended = []
        }
    }

    @discardableResult
    public static func begin(_ interval: Interval, _ detail: String? = nil) -> Token {
        let state: OSSignpostIntervalState =
            if let detail {
                signposter.beginInterval(
                    interval.staticName, id: signposter.makeSignpostID(), "\(detail, privacy: .public)")
            } else {
                signposter.beginInterval(interval.staticName, id: signposter.makeSignpostID())
            }
        let (serial, observer) = hook.withLock { state -> (UInt64, (@Sendable (Event) -> Void)?) in
            state.serial &+= 1
            return (state.serial, state.observer)
        }
        observer?(.begin(name: interval.name, serial: serial))
        return Token(interval: interval, state: state, serial: serial)
    }

    public static func end(_ token: Token) {
        let observer = hook.withLock { state -> (@Sendable (Event) -> Void)?? in
            guard state.observer != nil else { return .some(nil) }
            guard state.ended.insert(token.serial).inserted else { return nil }  // second end
            return .some(state.observer)
        }
        guard let observer else { return }
        signposter.endInterval(token.interval.staticName, token.state)
        observer?(.end(name: token.interval.name, serial: token.serial))
    }

    /// Measures a synchronous body.
    public static func measure<T, E: Error>(
        _ interval: Interval, _ detail: String? = nil, _ body: () throws(E) -> T
    ) throws(E) -> T {
        let token = begin(interval, detail)
        defer { end(token) }
        return try body()
    }

    /// The Git subcommand of an argument list (`-c k=v`, `-C dir` and other leading options skipped),
    /// or "git" when it isn't a plain lowercase word. Never returns paths or values.
    public static func gitSubcommand(_ arguments: [String]) -> String {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" || argument == "--git-dir" || argument == "--work-tree" {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            let isLowercaseWord = argument.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
            let isWord = !argument.isEmpty && argument.count <= 24 && isLowercaseWord
            return isWord ? argument : "git"
        }
        return "git"
    }
}
