import Foundation
import GitCore
import Observation
import Services

/// Graph mode and UI state (design §4.6) — not row data. Persisted parts (scope, pinned refs) live in the
/// tab's `ui` blob.
@MainActor @Observable
final class GraphViewModel {
    enum ScopeChoice: String, CaseIterable, Sendable {
        case all, current, local, selected

        var title: String {
            switch self {
            case .all: "All Branches"
            case .current: "Current Branch"
            case .local: "Local Branches Only"
            case .selected: "Selected Branches…"
            }
        }
    }

    enum FilterMode: String, Sendable {
        /// Matches highlighted, graph kept (default).
        case highlight
        /// Only matching commits, as a flat list.
        case onlyMatches
    }

    enum DeepSearchState: Equatable {
        case idle
        case running(found: Int)
        case finished(found: Int, limited: Bool)
        case failed(String)
    }

    var scope: ScopeChoice = .all
    /// Full ref names for `.selected`.
    var selectedRefs: [String] = []
    var pinned: [String] = []
    /// Full ref name shown alone (chip `Solo: x ✕`).
    var solo: String?
    /// File history mode (chip `History: path ✕`).
    var fileHistory: (path: String, follow: Bool)?

    var searchText = ""
    var filterMode: FilterMode = .highlight
    /// Matching rows in the loaded history, in row order.
    var matches: [Int32] = []
    var currentMatch: Int?
    var deepSearch: DeepSearchState = .idle
    /// Matches found beyond loaded rows by deep search (ids; selected by loading more history).
    var deepMatches: [ObjectID] = []

    enum PaneState: Equatable {
        case loading
        case empty
        case ready
    }

    /// What the state overlay shows (set by the controller after each history update).
    var paneState: PaneState = .loading
    var historyError: GitCoreError?

    /// Incremented by ⌘F to focus the search field.
    var focusSearchToken = 0

    /// Selected commits in selection order (at most two: compare).
    var selection: [ObjectID] = []
    var wipSelected = false

    var isSearching: Bool { !HistorySearchQuery(searchText).isEmpty }

    var query: HistoryQuery {
        var query = HistoryQuery(pinned: pinned)
        if let solo {
            query.scope = .solo(solo)
        } else {
            switch scope {
            case .all: query.scope = .all
            case .current: query.scope = .current
            case .local: query.scope = .local
            case .selected: query.scope = selectedRefs.isEmpty ? .all : .refs(selectedRefs)
            }
        }
        if let fileHistory {
            query.path = fileHistory.path
            query.follow = fileHistory.follow
        }
        return query
    }

    // MARK: - Persistence (tab `ui`)

    static let scopeKey = "graph.scope"
    static let selectedKey = "graph.selectedRefs"
    static let pinnedKey = "graph.pinned"

    func restore(from ui: [String: JSONValue]) {
        if case .string(let raw) = ui[Self.scopeKey], let choice = ScopeChoice(rawValue: raw) { scope = choice }
        if case .array(let values) = ui[Self.selectedKey] {
            selectedRefs = values.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        if case .array(let values) = ui[Self.pinnedKey] {
            pinned = values.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
    }

    func save(into ui: inout [String: JSONValue]) {
        ui[Self.scopeKey] = .string(scope.rawValue)
        ui[Self.selectedKey] = .array(selectedRefs.map(JSONValue.string))
        ui[Self.pinnedKey] = .array(pinned.map(JSONValue.string))
    }

    // MARK: - Selection

    /// Adds a commit to the selection; a third replaces the oldest (compare takes exactly two).
    func select(_ oid: ObjectID, extending: Bool) {
        wipSelected = false
        if extending {
            selection.removeAll { $0 == oid }
            selection.append(oid)
            if selection.count > 2 { selection.removeFirst(selection.count - 2) }
        } else {
            selection = [oid]
        }
    }
}
