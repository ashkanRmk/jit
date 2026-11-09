import AppKit
import GitCore
import Observation
import Services

/// One pane's text: a byte buffer plus a line table (ranges, kinds, owning conflict segment). Strings are
/// materialized only for the rows a `CodeLinesView` draws (ADR-0005).
struct PaneText {
    enum Pane { case ours, theirs, base, result }

    var bytes: [UInt8] = []
    var lines: [Range<Int>] = []
    var kinds: [CodeCell.Kind] = []
    /// Segment index of the conflict a line belongs to (`-1` for clean lines).
    var segments: [Int32] = []
    /// Display numbers (`0` for marker rows).
    var numbers: [Int32] = []
    var placeholders: [Int: String] = [:]
    /// First row of each conflict segment.
    var blockRows: [Int: Range<Int>] = [:]
    var maxColumns = 0

    var lineCount: Int { lines.count }

    func text(_ row: Int) -> String {
        if let placeholder = placeholders[row] { return placeholder }
        var range = lines[row]
        if range.count > 0, bytes[range.upperBound - 1] == 0x0D { range = range.lowerBound..<(range.upperBound - 1) }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    mutating func append(_ slice: ArraySlice<UInt8>, kind: CodeCell.Kind, segment: Int, placeholder: String? = nil) {
        let firstRow = lines.count
        if slice.isEmpty {
            if let placeholder {
                placeholders[lines.count] = placeholder
                lines.append(bytes.count..<bytes.count)
                kinds.append(.marker)
                segments.append(Int32(segment))
                numbers.append(0)
            }
        } else {
            let start = bytes.count
            bytes += slice
            var lineStart = start
            var number = (numbers.last { $0 > 0 } ?? 0)
            for index in start..<bytes.count where bytes[index] == 0x0A || index == bytes.count - 1 {
                let end = bytes[index] == 0x0A ? index : index + 1
                lines.append(lineStart..<end)
                kinds.append(kind)
                segments.append(Int32(segment))
                if kind != .marker { number += 1 }
                numbers.append(kind == .marker ? 0 : number)
                maxColumns = max(maxColumns, end - lineStart)
                lineStart = index + 1
            }
        }
        if segment >= 0, lines.count > firstRow {
            blockRows[segment] = (blockRows[segment]?.lowerBound ?? firstRow)..<lines.count
        }
    }

    mutating func marker(_ text: String, segment: Int) {
        placeholders[lines.count] = text
        lines.append(bytes.count..<bytes.count)
        kinds.append(.marker)
        segments.append(Int32(segment))
        numbers.append(0)
        blockRows[segment] = (blockRows[segment]?.lowerBound ?? (lines.count - 1))..<lines.count
    }
}

/// The three-way conflict resolver for one repository (design §3.8). Holds the conflict list, the open
/// document and the user's block choices; the document itself is a byte buffer with range segments.
@MainActor @Observable
final class ResolverModel {
    enum Phase: Equatable {
        case loading
        case text
        /// Non-text conflict (design §3.9).
        case fallback
        case failed(String)
        /// No conflicts remain.
        case done
    }

    @ObservationIgnored unowned let controller: OperationsController
    private(set) var entries: [ConflictEntry]
    private(set) var entry: ConflictEntry?
    private(set) var document: ConflictDocument?
    private(set) var phase: Phase = .loading
    private(set) var labels = ConflictLabels(ours: "Ours", theirs: "Theirs")
    private(set) var choices: [Int: BlockChoice] = [:]
    private(set) var current = 0
    var showsBase = false
    /// Saved to disk, matching `diskHash`.
    private(set) var isDirty = false
    /// The file changed on disk since Jit loaded or saved it (design §3.8 state).
    private(set) var externalChange = false
    private(set) var ours = PaneText()
    private(set) var theirs = PaneText()
    private(set) var base = PaneText()
    private(set) var result = PaneText()
    /// Bumped when pane text changes (the views reload).
    private(set) var revision = 0
    private(set) var lastLoadDuration: Duration?
    var editing: Int?

    @ObservationIgnored private var undoStack: [[Int: BlockChoice]] = []
    @ObservationIgnored private var redoStack: [[Int: BlockChoice]] = []
    @ObservationIgnored private var diskHash: FileHash = .missing
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(controller: OperationsController, entries: [ConflictEntry]) {
        self.controller = controller
        self.entries = entries
    }

    var blocks: [Int] { document?.conflictIndices ?? [] }
    var unresolvedCount: Int { blocks.filter { choices[$0] == nil }.count }
    var currentSegment: Int? { blocks.indices.contains(current) ? blocks[current] : nil }
    var canMarkResolved: Bool { phase == .text && unresolvedCount == 0 && !externalChange }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var operationTitle: String {
        switch controller.session.operationState {
        case .merging(let source, _):
            "Merging \(source.isEmpty ? "changes" : source) into \(controller.currentBranch ?? "HEAD")"
        case .rebasing(let head, _, let step, let total, _, _): "Rebasing \(head) · commit \(step) of \(total)"
        case .cherryPicking(let commit, _, _): "Cherry-picking \(commit?.shortOID ?? "")"
        case .reverting(let commit, _, _): "Reverting \(commit?.shortOID ?? "")"
        default: "Resolving conflicts"
        }
    }

    var isRebase: Bool {
        if case .rebasing = controller.session.operationState { return true }
        return false
    }

    // MARK: Loading

    func open(path: String) {
        guard let entry = entries.first(where: { $0.path == path }) else { return }
        load(entry)
    }

    func reloadEntries() {
        Task {
            let fresh = await controller.session.conflicts()
            entries = fresh
            if let next = fresh.first {
                load(next)
            } else {
                entry = nil
                document = nil
                phase = .done
            }
        }
    }

    private func load(_ entry: ConflictEntry) {
        self.entry = entry
        document = nil
        choices = [:]
        undoStack = []
        redoStack = []
        current = 0
        isDirty = false
        externalChange = false
        labels = ConflictLabels.make(for: controller.session.operationState, currentBranch: controller.currentBranch)
        guard entry.presentation == .text else {
            phase = .fallback
            return
        }
        phase = .loading
        loadTask?.cancel()
        let started = ContinuousClock.now
        loadTask = Task {
            guard let repository = controller.session.repository else { return }
            do throws(GitCoreError) {
                let document = try await repository.loadConflict(entry)
                guard !Task.isCancelled else { return }
                self.document = document
                diskHash = document.workingTreeHash
                if !document.workingTreeLooksUnedited, document.workingTree != nil {
                    // The file on disk was edited already: never silently discard it (design §4.10).
                    externalChange = true
                }
                phase = .text
                rebuild()
                lastLoadDuration = ContinuousClock.now - started
            } catch {
                phase = .failed(error.summary)
            }
        }
    }

    // MARK: Panes

    private func rebuild() {
        guard let document else { return }
        var ours = PaneText()
        var theirs = PaneText()
        var base = PaneText()
        var result = PaneText()
        for (index, segment) in document.segments.enumerated() {
            switch segment {
            case .resolved(let range):
                let slice = document.bytes[range]
                ours.append(slice, kind: .context, segment: -1)
                theirs.append(slice, kind: .context, segment: -1)
                base.append(slice, kind: .context, segment: -1)
                result.append(slice, kind: .context, segment: -1)
            case .conflict(let oursRange, let baseRange, let theirsRange):
                let choice = choices[index]
                let kind: CodeCell.Kind = choice == nil ? .conflict : .resolved
                ours.append(
                    document.bytes[oursRange], kind: kind, segment: index, placeholder: "(no lines on this side)")
                theirs.append(
                    document.bytes[theirsRange], kind: kind, segment: index, placeholder: "(no lines on this side)")
                base.append(
                    document.bytes[baseRange], kind: kind, segment: index, placeholder: "(no lines in the base)")
                switch choice {
                case nil:
                    result.marker("Unresolved — choose ours, theirs, both, or edit", segment: index)
                    result.append(
                        document.bytes[oursRange], kind: .conflict, segment: index, placeholder: "(ours: no lines)")
                    result.marker("── theirs ──", segment: index)
                    result.append(
                        document.bytes[theirsRange], kind: .conflict, segment: index, placeholder: "(theirs: no lines)")
                case .ours?:
                    result.append(document.bytes[oursRange], kind: .resolved, segment: index, placeholder: "(empty)")
                case .theirs?:
                    result.append(document.bytes[theirsRange], kind: .resolved, segment: index, placeholder: "(empty)")
                case .base?:
                    result.append(document.bytes[baseRange], kind: .resolved, segment: index, placeholder: "(empty)")
                case .oursThenTheirs?:
                    result.append(
                        document.bytes[oursRange] + document.bytes[theirsRange], kind: .resolved, segment: index,
                        placeholder: "(empty)")
                case .theirsThenOurs?:
                    result.append(
                        document.bytes[theirsRange] + document.bytes[oursRange], kind: .resolved, segment: index,
                        placeholder: "(empty)")
                case .custom(let text)?:
                    result.append(text[...], kind: .resolved, segment: index, placeholder: "(empty)")
                }
            }
        }
        self.ours = ours
        self.theirs = theirs
        self.base = base
        self.result = result
        revision += 1
    }

    // MARK: Block actions

    func choose(_ choice: BlockChoice, for segment: Int? = nil) {
        guard let segment = segment ?? currentSegment else { return }
        undoStack.append(choices)
        redoStack = []
        choices[segment] = choice
        isDirty = true
        rebuild()
        // Move on to the next unresolved block.
        if let next = blocks.firstIndex(where: { choices[$0] == nil }) { current = next }
    }

    func reset(_ segment: Int? = nil) {
        guard let segment = segment ?? currentSegment, choices[segment] != nil else { return }
        undoStack.append(choices)
        redoStack = []
        choices[segment] = nil
        isDirty = true
        rebuild()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(choices)
        choices = previous
        isDirty = true
        rebuild()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(choices)
        choices = next
        isDirty = true
        rebuild()
    }

    func select(segment: Int) {
        if let index = blocks.firstIndex(of: segment) { current = index }
    }

    func next(forward: Bool) {
        guard !blocks.isEmpty else { return }
        let unresolved = blocks.indices.filter { choices[blocks[$0]] == nil }
        let candidates = unresolved.isEmpty ? Array(blocks.indices) : unresolved
        if forward {
            current = candidates.first { $0 > current } ?? candidates.first ?? current
        } else {
            current = candidates.last { $0 < current } ?? candidates.last ?? current
        }
    }

    /// Text for the manual editor: the current choice, or ours then theirs when unresolved.
    func editableText(for segment: Int) -> String {
        guard let document, case .conflict(let oursRange, _, let theirsRange) = document.segments[segment] else {
            return ""
        }
        let bytes: [UInt8]
        switch choices[segment] {
        case .custom(let text)?: bytes = text
        case .theirs?: bytes = Array(document.bytes[theirsRange])
        case .ours?: bytes = Array(document.bytes[oursRange])
        default: bytes = Array(document.bytes[oursRange] + document.bytes[theirsRange])
        }
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    func applyEdit(_ text: String, to segment: Int) {
        guard let document else { return }
        var normalized = text
        if !normalized.isEmpty, !normalized.hasSuffix("\n") { normalized += "\n" }
        if document.usesCRLF { normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n") }
        choose(.custom(Array(normalized.utf8)), for: segment)
        editing = nil
    }

    // MARK: Disk

    /// Called after file-system refreshes: an edit outside Jit shows the external-change banner.
    func checkDisk() {
        guard phase == .text, let entry, let topLevel = controller.session.info?.topLevel else { return }
        let path = (topLevel as NSString).appendingPathComponent(entry.path)
        let data = FileManager.default.contents(atPath: path).map { FileHash($0) } ?? .missing
        if data != diskHash { externalChange = true }
    }

    /// Reload from Disk: drop the choices and start again from Git's conflict.
    func reloadFromDisk() {
        guard let entry else { return }
        load(entry)
        externalChange = false
    }

    /// Keep My Result: accept the new disk content as the save baseline (my result overwrites it on save).
    func keepMyResult() {
        guard let entry, let topLevel = controller.session.info?.topLevel else { return }
        let path = (topLevel as NSString).appendingPathComponent(entry.path)
        diskHash = FileManager.default.contents(atPath: path).map { FileHash($0) } ?? .missing
        externalChange = false
        isDirty = true
    }

    @discardableResult
    func save() async -> Bool {
        guard let document, let entry, !externalChange else { return false }
        let content = document.render(choices)
        switch await controller.session.saveResolution(entry.path, content: content, expected: diskHash) {
        case .success(let hash):
            diskHash = hash
            isDirty = false
            return true
        case .failure(let error):
            if error.title == "The repository changed" { externalChange = true }
            controller.present(error)
            return false
        }
    }

    /// Mark as Resolved: only when every block is resolved; asks first if marker-like lines remain.
    func markResolved() {
        guard canMarkResolved, let document, let entry else { return }
        let content = document.render(choices)
        let proceed = { [weak self] in
            guard let self else { return }
            Task {
                if self.isDirty || (self.document?.workingTreeHash == self.diskHash) {
                    guard await self.save() else { return }
                }
                switch await self.controller.session.markResolved(entry.path, expected: self.diskHash) {
                case .success: self.reloadEntries()
                case .failure(let error): self.controller.present(error)
                }
            }
        }
        if ConflictDocument.containsMarkers(content) {
            let alert = NSAlert()
            alert.messageText = "“\(entry.path)” still contains lines that look like conflict markers."
            alert.informativeText =
                "They may be part of your file, or a leftover from the conflict. Mark it as resolved anyway?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Mark as Resolved")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertSecondButtonReturn { proceed() }
                }
            }
        } else {
            proceed()
        }
    }
}
