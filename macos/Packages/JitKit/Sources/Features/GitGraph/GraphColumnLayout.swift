import Foundation
import Services

/// The graph table's columns as the user arranged them: order, hidden columns and preferred widths. Saved
/// with the tab (`ui["graph.columns"]`); the last arrangement also seeds new tabs (`PreferencesStore`).
struct GraphColumnLayout: Equatable {
    enum Column: String, CaseIterable {
        case refs, graph, subject, author, date, sha

        var title: String {
            switch self {
            case .refs: "Branch / Tag"
            case .graph: "Graph"
            case .subject: "Message"
            case .author: "Author"
            case .date: "Date"
            case .sha: "SHA"
            }
        }

        var defaultWidth: CGFloat {
            switch self {
            case .refs: 150
            case .graph: 80
            case .subject: 420
            case .author: 150
            case .date: 104
            case .sha: 72
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .refs: 96
            case .graph: 24
            case .subject: 160
            case .author: 80
            case .date: 64
            case .sha: 56
            }
        }

        /// The message column always shows: it takes the width the others leave.
        var canHide: Bool { self != .subject }
        /// The graph column sizes itself to the lanes on screen.
        var userResizable: Bool { self != .graph }
    }

    var order: [Column] = Column.allCases
    var hidden: Set<Column> = []
    var widths: [Column: CGFloat] = [:]

    init() {}

    /// Reads the saved value. Before 0.0.2 it was a plain `{column: width}` object.
    init(json: JSONValue?) {
        guard case .object(let values) = json else { return }
        var widthValues = values
        if case .object(let nested) = values["widths"] { widthValues = nested }
        for (key, value) in widthValues {
            if let column = Column(rawValue: key), case .number(let width) = value, width.isFinite, width > 0 {
                widths[column] = max(column.minWidth, CGFloat(width))
            }
        }
        if case .array(let names) = values["order"] {
            var seen: [Column] = []
            for case .string(let name) in names {
                if let column = Column(rawValue: name), !seen.contains(column) { seen.append(column) }
            }
            // Columns added by a later version keep their default place.
            for column in Column.allCases where !seen.contains(column) {
                let index = Column.allCases.firstIndex(of: column) ?? seen.count
                seen.insert(column, at: min(index, seen.count))
            }
            order = seen
        }
        if case .array(let names) = values["hidden"] {
            for case .string(let name) in names {
                if let column = Column(rawValue: name), column.canHide { hidden.insert(column) }
            }
        }
    }

    var json: JSONValue {
        .object([
            "widths": .object(
                Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, JSONValue.number(Double($0.value))) })),
            "order": .array(order.map { .string($0.rawValue) }),
            "hidden": .array(hidden.map(\.rawValue).sorted().map(JSONValue.string)),
        ])
    }

    func width(_ column: Column) -> CGFloat { widths[column] ?? column.defaultWidth }

    mutating func setHidden(_ column: Column, _ isHidden: Bool) {
        guard column.canHide else { return }
        if isHidden { hidden.insert(column) } else { hidden.remove(column) }
    }

    /// Widths that fit `available` points: every visible column at its preferred width when there is room
    /// for a comfortable message column; otherwise the SHA hides, then author, date and branch narrow to their
    /// minimum. The message column takes the rest. `fixed` are widths the layout does not choose (the graph).
    func fitted(available: CGFloat, fixed: [Column: CGFloat] = [:], comfortableSubject: CGFloat = 220)
        -> (widths: [Column: CGFloat], autoHidden: Set<Column>)
    {
        var result: [Column: CGFloat] = [:]
        var autoHidden = Set<Column>()
        let visible = order.filter { !hidden.contains($0) }
        for column in visible where column != .subject { result[column] = fixed[column] ?? width(column) }
        func others() -> CGFloat { result.values.reduce(0, +) }
        if available - others() < comfortableSubject, result[.sha] != nil {
            result[.sha] = nil
            autoHidden.insert(.sha)
        }
        // The branch column narrows last: its labels are the hardest to read when cut.
        for column in [Column.author, .date, .refs] {
            let missing = comfortableSubject - (available - others())
            guard missing > 0, let width = result[column] else { continue }
            result[column] = max(column.minWidth, width - missing)
        }
        result[.subject] = max(Column.subject.minWidth, available - others())
        return (result, autoHidden)
    }
}
