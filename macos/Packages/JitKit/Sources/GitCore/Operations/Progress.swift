import Foundation
import Synchronization

/// One progress update of a long-running Git command (design §4.5), parsed from `--progress` stderr.
public struct OperationProgress: Sendable, Equatable {
    /// Git's phase, e.g. "Receiving objects", "Resolving deltas", "Writing objects".
    public var phase: String
    public var percent: Int?
    public var completed: Int?
    public var total: Int?
    /// Transfer size and rate, e.g. "1.20 MiB | 2.40 MiB/s".
    public var rate: String?
    /// The last `remote:` message (sanitized), if any.
    public var remoteMessage: String?

    public init(
        phase: String, percent: Int? = nil, completed: Int? = nil, total: Int? = nil, rate: String? = nil,
        remoteMessage: String? = nil
    ) {
        self.phase = phase
        self.percent = percent
        self.completed = completed
        self.total = total
        self.rate = rate
        self.remoteMessage = remoteMessage
    }

    /// 0…1 when Git reports a percentage.
    public var fraction: Double? { percent.map { Double(min(max($0, 0), 100)) / 100 } }

    /// "Receiving objects — 42%".
    public var summary: String {
        if let percent { return "\(phase) — \(percent)%" }
        if let completed { return "\(phase) — \(completed)" }
        return phase
    }
}

/// What one `\r`- or `\n`-terminated stderr line means.
public enum ProgressEvent: Sendable, Equatable {
    case progress(OperationProgress)
    /// A `remote: …` line (sanitized), without the prefix.
    case remote(String)
    /// Any other line (kept for error classification).
    case line(String)
}

/// Splits Git's progress stderr on `\r` and `\n` and recognizes
/// `<phase>: <pct>% (<n>/<total>)[, <size> | <rate>][, done.]` (byte-level, ADR-0005).
public struct ProgressParser: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// Feeds bytes and returns the events of every completed line.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ProgressEvent] {
        var events: [ProgressEvent] = []
        for byte in bytes {
            if byte == 0x0D || byte == 0x0A {
                if !pending.isEmpty {
                    if let event = Self.parse(pending) { events.append(event) }
                    pending.removeAll(keepingCapacity: true)
                }
            } else if pending.count < 4096 {
                pending.append(byte)
            }
        }
        return events
    }

    /// The unterminated tail (Git ends with a newline, so normally nothing).
    public mutating func finish() -> [ProgressEvent] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : Self.parse(pending).map { [$0] } ?? []
    }

    static let phases = [
        "Enumerating objects", "Counting objects", "Compressing objects", "Receiving objects", "Resolving deltas",
        "Writing objects", "Updating files", "Checking out files", "Unpacking objects", "Finding sources",
        "Updating index flags", "Checking connectivity", "Total",
    ]

    static func parse(_ line: [UInt8]) -> ProgressEvent? {
        var text = String(decoding: line, as: UTF8.self)
        // Git clears the rest of the line with ANSI "erase to end of line" when stderr is a terminal; it
        // isn't here, but strip it defensively.
        text = text.replacingOccurrences(of: "\u{1B}[K", with: "")
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("remote:") {
            let message = trimmed.dropFirst("remote:".count).trimmingCharacters(in: .whitespaces)
            // `remote: Counting objects: 42% (…)` is server-side progress: report it as progress too.
            if let progress = progress(from: message) {
                var progress = progress
                progress.remoteMessage = nil
                return .progress(progress)
            }
            return message.isEmpty ? nil : .remote(Redaction.redact(message))
        }
        if let progress = progress(from: trimmed) { return .progress(progress) }
        return .line(Redaction.redact(trimmed))
    }

    private static func progress(from text: String) -> OperationProgress? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let phase = String(text[..<colon])
        guard phases.contains(phase) else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        var progress = OperationProgress(phase: phase)
        if let percentEnd = rest.firstIndex(of: "%"),
            let value = Int(rest[..<percentEnd].trimmingCharacters(in: .whitespaces))
        {
            progress.percent = value
        }
        if let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"), open < close {
            let counts = rest[rest.index(after: open)..<close].split(separator: "/")
            if counts.count == 2 {
                progress.completed = Int(counts[0])
                progress.total = Int(counts[1])
            }
            let tail = rest[rest.index(after: close)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
            let rate = tail.replacingOccurrences(of: ", done.", with: "").replacingOccurrences(of: "done.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
            if rate.contains("|") || rate.contains("iB") { progress.rate = rate }
        } else if progress.percent == nil {
            // "Enumerating objects: 12, done." / "Counting objects: 42"
            let number = rest.prefix { $0.isNumber }
            if let value = Int(number) { progress.completed = value }
        }
        return progress
    }
}

/// Feeds stderr bytes through a `ProgressParser` into a bounded `AsyncStream` continuation
/// (`.bufferingNewest(1)` on the consumer side), at most one update per `interval` except phase changes
/// and completions (design §4.5: ≤ 10 Hz). Keeps the remote lines and other lines for error reports.
public final class ProgressSink: Sendable {
    private struct State {
        var parser = ProgressParser()
        var lastYield: ContinuousClock.Instant?
        var lastPhase: String?
        var lastRemote: String?
        var remoteLines: [String] = []
    }

    private let continuation: AsyncStream<OperationProgress>.Continuation?
    private let interval: Duration
    private let state = Mutex(State())

    public init(_ continuation: AsyncStream<OperationProgress>.Continuation?, interval: Duration = .milliseconds(100)) {
        self.continuation = continuation
        self.interval = interval
    }

    /// The `remote:` lines seen so far (sanitized, at most 200).
    public var remoteLines: [String] { state.withLock { $0.remoteLines } }

    /// For `GitCommand.stderrObserver`.
    public var observer: @Sendable ([UInt8]) -> Void { { [self] bytes in self.consume(bytes) } }

    func consume(_ bytes: [UInt8]) {
        let now = ContinuousClock.now
        let updates: [OperationProgress] = state.withLock { state in
            var updates: [OperationProgress] = []
            for event in state.parser.feed(bytes) {
                switch event {
                case .progress(var progress):
                    progress.remoteMessage = state.lastRemote
                    let phaseChanged = progress.phase != state.lastPhase
                    let finished = progress.percent == 100
                    let due = state.lastYield.map { now - $0 >= interval } ?? true
                    state.lastPhase = progress.phase
                    if phaseChanged || finished || due {
                        state.lastYield = now
                        updates.append(progress)
                    }
                case .remote(let message):
                    state.lastRemote = message
                    if state.remoteLines.count < 200 { state.remoteLines.append(message) }
                case .line:
                    break
                }
            }
            return updates
        }
        guard let continuation else { return }
        for update in updates { continuation.yield(update) }
    }
}
