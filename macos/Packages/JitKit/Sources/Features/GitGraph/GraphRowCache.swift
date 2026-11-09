import DesignSystem
import Foundation
import GitCore

/// A ref label drawn before a subject (design §3.2).
struct RefLabel: Equatable {
    enum Kind: Equatable {
        case local
        case current
        /// A local branch and its upstream at the same commit: one pill `main ⇄ origin`.
        case localWithUpstream(remote: String, isCurrent: Bool)
        case remote
        case tag
        case detachedHead
    }

    let kind: Kind
    let text: String
    let fullName: String?
}

/// Strings for one visible row. Built only for rows on screen (+ overscan), dropped with their window.
struct GraphRowDisplay {
    let subject: String
    let authorName: String
    let authorEmail: String
    let initials: String
    let avatarSlot: Int
    let date: String
    let dateTooltip: String
    let shortSHA: String
    let labels: [RefLabel]
    let accessibilityLabel: String
}

/// Main-actor cache of materialized rows (design §4.2): windows of 64 rows, at most 16 windows (≈ 1k
/// rows). Reading a row is a direct read of the snapshot's chunk columns — no Git, no copies.
@MainActor final class GraphRowCache {
    static let windowSize = 64
    static let maxWindows = 16

    private var windows: [Int: [GraphRowDisplay?]] = [:]
    private var order: [Int] = []
    private var snapshot: HistorySnapshot = .empty()
    private var refs: RefSnapshot = .empty
    private var labelsByCommit: [ObjectID: [RefLabel]] = [:]
    private var now = Date()
    private let relative = RelativeDateTimeFormatter()
    private let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()
    private let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()

    init() {
        relative.unitsStyle = .abbreviated
    }

    /// Rows already materialized keep their strings when only more rows were appended.
    func update(snapshot: HistorySnapshot, refs: RefSnapshot?, dropRows: Bool) {
        let refsChanged = refs.map { $0.revision != self.refs.revision } ?? false
        self.snapshot = snapshot
        if let refs, refsChanged {
            self.refs = refs
            labelsByCommit = Self.labels(for: refs)
        }
        if dropRows || refsChanged { clear() }
    }

    func clear() {
        windows.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        now = Date()
    }

    var currentRefs: RefSnapshot { refs }

    func labels(for oid: ObjectID) -> [RefLabel] { labelsByCommit[oid] ?? [] }

    func display(_ index: Int) -> GraphRowDisplay? {
        guard index >= 0, index < snapshot.count else { return nil }
        let window = index / Self.windowSize
        let offset = index % Self.windowSize
        if let cached = windows[window]?[offset] { return cached }
        if windows[window] == nil {
            windows[window] = [GraphRowDisplay?](repeating: nil, count: Self.windowSize)
            order.append(window)
            if order.count > Self.maxWindows { windows[order.removeFirst()] = nil }
        }
        let display = materialize(snapshot.row(index))
        windows[window]?[offset] = display
        return display
    }

    private func materialize(_ row: CommitRow) -> GraphRowDisplay {
        let author = snapshot.author(of: row)
        let subject = DisplayText.sanitize(row.subject)
        let date = Date(timeIntervalSince1970: TimeInterval(row.time))
        let dateText =
            now.timeIntervalSince(date) < 7 * 86_400 && date <= now.addingTimeInterval(60)
            ? relative.localizedString(for: date, relativeTo: now) : absolute.string(from: date)
        let labels = labelsByCommit[row.oid] ?? []
        var hash = StableHash()
        hash.combine(author.email.lowercased())
        let shortSHA = row.oid.hex(snapshot.format, length: 7)
        var spoken = "Commit \(shortSHA), \(subject), by \(author.name), \(dateText)"
        if !labels.isEmpty { spoken += ", " + labels.map(\.text).joined(separator: ", ") }
        if row.parentCount > 1 { spoken += ", merge of \(row.parentCount) parents" }
        return GraphRowDisplay(
            subject: subject, authorName: author.name, authorEmail: author.email,
            initials: AvatarStyle.initials(for: author.name), avatarSlot: AvatarStyle.colorSlot(forHash: hash.value),
            date: dateText, dateTooltip: full.string(from: date), shortSHA: shortSHA, labels: labels,
            accessibilityLabel: spoken)
    }

    /// Labels per commit: current branch first, then locals (merged with an upstream at the same
    /// commit), remotes, tags; a detached HEAD gets a `HEAD` pill.
    static func labels(for refs: RefSnapshot) -> [ObjectID: [RefLabel]] {
        var result: [ObjectID: [RefLabel]] = [:]
        var byCommit: [ObjectID: [GitRef]] = [:]
        for ref in refs.refs {
            if let commit = ref.commit, ref.kind != .other { byCommit[commit, default: []].append(ref) }
        }
        for (commit, list) in byCommit {
            var labels: [RefLabel] = []
            var consumedRemotes = Set<String>()
            let locals = list.filter { $0.kind == .local }.sorted {
                ($0.isHead ? 0 : 1, $0.fullName) < ($1.isHead ? 0 : 1, $1.fullName)
            }
            for local in locals {
                if let upstream = local.upstream,
                    let remote = list.first(where: { $0.kind == .remote && $0.shortName == upstream })
                {
                    consumedRemotes.insert(remote.fullName)
                    labels.append(
                        RefLabel(
                            kind: .localWithUpstream(remote: remote.remoteName ?? "", isCurrent: local.isHead),
                            text: local.shortName, fullName: local.fullName))
                } else {
                    labels.append(
                        RefLabel(
                            kind: local.isHead ? .current : .local, text: local.shortName, fullName: local.fullName))
                }
            }
            for remote in list where remote.kind == .remote && !consumedRemotes.contains(remote.fullName) {
                labels.append(RefLabel(kind: .remote, text: remote.shortName, fullName: remote.fullName))
            }
            for tag in list where tag.kind == .tag {
                labels.append(RefLabel(kind: .tag, text: tag.shortName, fullName: tag.fullName))
            }
            result[commit] = labels
        }
        if case .detached(let commit) = refs.head {
            result[commit, default: []].insert(RefLabel(kind: .detachedHead, text: "HEAD", fullName: nil), at: 0)
        }
        return result
    }
}

/// Plain-text display of repository-controlled strings (design §4.9): control characters become visible
/// symbols, bidi overrides are neutralised, and the whole string is isolated so RTL text can't reorder
/// what follows it.
enum DisplayText {
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var needsIsolation = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F:
                // U+2400 block: "control pictures" (␛ for ESC, ␉ for TAB …).
                scalars.append(Unicode.Scalar(0x2400 + scalar.value) ?? "?")
            case 0x7F:
                scalars.append("\u{2421}")
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
                // Explicit direction controls: dropped (isolation below handles RTL text).
                needsIsolation = true
            default:
                if !needsIsolation, isRightToLeft(scalar.value) { needsIsolation = true }
                scalars.append(scalar)
            }
        }
        let clean = String(scalars)
        return needsIsolation ? "\u{2068}" + clean + "\u{2069}" : clean
    }

    /// Hebrew, Arabic, Syriac, Thaana, NKo… and their presentation forms / supplementary blocks.
    static func isRightToLeft(_ value: UInt32) -> Bool {
        (0x0590...0x08FF).contains(value) || (0xFB1D...0xFDFF).contains(value) || (0xFE70...0xFEFF).contains(value)
            || (0x10800...0x10FFF).contains(value) || (0x1E800...0x1EFFF).contains(value)
    }
}
