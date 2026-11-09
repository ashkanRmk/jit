import Foundation

/// What a line selection does (design §4.4).
public enum SelectionAction: Sendable, Hashable {
    /// Unstaged diff → index (`git apply --cached`).
    case stage
    /// Staged diff → index (`git apply --cached -R`).
    case unstage
    /// Unstaged diff → working tree (`git apply -R`).
    case discard
    /// Unstaged diff: discard every changed line that is *not* selected.
    case keepOnly
}

/// Why a line action is not offered (each maps to a disabled control with this explanation).
public enum UnsupportedReason: String, Sendable, Hashable, CaseIterable {
    case binary, symlink, submodule, typeChange, whitespaceIgnored, filterConversion, ambiguousEol, truncated
    case renamed, noSelection, wrongSource, conflicted

    public var explanation: String {
        switch self {
        case .binary: "Binary files can only be staged or discarded as a whole."
        case .symlink: "A symbolic link’s target can only be changed as a whole."
        case .submodule: "Submodules can only be staged or unstaged as a whole."
        case .typeChange: "The file changed type; stage or unstage the whole file."
        case .whitespaceIgnored: "Line actions are off while whitespace changes are hidden."
        case .filterConversion: "This file uses line-ending or filter conversion; stage the whole file instead."
        case .ambiguousEol:
            "This selection would change only whether the file ends with a newline; include the neighbouring line."
        case .truncated: "The diff is truncated; line actions need the whole file."
        case .renamed: "Unstage the renamed file as a whole."
        case .noSelection: "Select changed lines first."
        case .wrongSource: "This action does not apply to this diff."
        case .conflicted: "Resolve the conflict first."
        }
    }
}

/// A built patch and what the target must look like after applying it.
public struct BuiltPatch: Sendable, Equatable {
    public let path: String
    public let bytes: [UInt8]
    /// `git apply` flags besides `--check`/`--whitespace`.
    public let applyArguments: [String]
    /// Whole target file after a correct apply; `nil` when the patch deletes it.
    public let expected: [UInt8]?
    /// The patch creates (`new file`) or removes (`deleted file`) the target entry.
    public let createsFile: Bool
    public let deletesFile: Bool
}

/// Selection → patch (ADR-0013). Pure: no Git, no files. The expected result is computed separately from
/// the patch text (by splicing the target's current bytes), so a builder bug shows up as a verification
/// failure instead of silently staging the wrong bytes.
public enum PatchBuilder {
    /// Reasons this document's file cannot take line actions at all.
    public static func unsupported(_ document: DiffDocument, file index: Int = 0) -> UnsupportedReason? {
        guard document.files.indices.contains(index) else { return .wrongSource }
        let file = document.files[index]
        if document.options.ignoreWhitespace { return .whitespaceIgnored }
        if file.isSubmodule { return .submodule }
        if file.isBinary { return .binary }
        if let old = file.oldMode, let new = file.newMode, old & 0o170000 != new & 0o170000 { return .typeChange }
        if file.isSymlink { return .symlink }
        if file.status == .renamed || file.status == .copied { return .renamed }
        return nil
    }

    static func source(of action: SelectionAction) -> String {
        action == .unstage ? "staged" : "unstaged"
    }

    /// Builds the patch for `selection` (line indices of changed lines in `document`, one file).
    /// - Parameter target: the current bytes of what the patch applies to — the index blob for stage
    ///   and unstage, the working-tree file for discard (empty for a file that does not exist there).
    public static func build(
        _ document: DiffDocument, selection: Set<Int>, action: SelectionAction, target: [UInt8]
    ) throws(PatchBuildError) -> BuiltPatch {
        if let reason = unsupported(document) { throw .unsupported(reason) }
        guard let fileIndex = document.files.indices.first else { throw .unsupported(.wrongSource) }
        let file = document.files[fileIndex]
        let lines = document.storage.lines
        let changed = Set(file.hunks.flatMap { document.hunks[$0].lines }.filter { lines[$0].kind != .context })
        var selected = selection.intersection(changed)
        // Checked before keep-only takes the complement: keeping "nothing selected" must never mean
        // "discard every change in the file".
        guard !selected.isEmpty else { throw .unsupported(.noSelection) }
        var operation = action
        if action == .keepOnly {
            selected = changed.subtracting(selected)
            operation = .discard
        }
        guard !selected.isEmpty else { throw .unsupported(.noSelection) }
        let reverse = operation != .stage

        // Every line in patch terms: kind after the selection table, or dropped.
        struct Emitted {
            var kind: DiffLineKind
            var line: Int
        }
        var hunkTexts: [UInt8] = []
        var delta = 0  // lines the already emitted hunks add on the side being computed
        // Result-side lines (what the target holds after apply) per hunk, for the splice model.
        var spliced: [(range: Range<Int>, now: [Int], after: [Int])] = []
        for hunkIndex in file.hunks {
            let hunk = document.hunks[hunkIndex]
            let hasSelection = hunk.lines.contains { selected.contains($0) }
            var emitted: [Emitted] = []
            for line in hunk.lines {
                let kind = lines[line].kind
                let isSelected = selected.contains(line)
                switch (kind, isSelected, reverse) {
                case (.context, _, _): emitted.append(Emitted(kind: .context, line: line))
                case (.added, true, _): emitted.append(Emitted(kind: .added, line: line))
                case (.deleted, true, _): emitted.append(Emitted(kind: .deleted, line: line))
                case (.added, false, false): break  // stage: unselected addition is not in the index
                case (.deleted, false, false): emitted.append(Emitted(kind: .context, line: line))
                case (.added, false, true): emitted.append(Emitted(kind: .context, line: line))
                case (.deleted, false, true): break  // the target never had it
                }
            }
            // The side the target holds now (pre for a forward patch, post for a reverse one) and after.
            let targetNow = emitted.filter { reverse ? $0.kind != .deleted : $0.kind != .added }
            let targetAfter = emitted.filter { reverse ? $0.kind != .added : $0.kind != .deleted }
            let nowStart = reverse ? Int(hunk.newStart) : Int(hunk.oldStart)
            let nowCount = reverse ? Int(hunk.newCount) : Int(hunk.oldCount)
            guard targetNow.count == nowCount else { throw .internalInconsistency("hunk side count") }
            let nowFirst = nowCount > 0 ? nowStart - 1 : nowStart  // 0-based first line in the target
            spliced.append((nowFirst..<(nowFirst + nowCount), targetNow.map(\.line), targetAfter.map(\.line)))
            guard hasSelection else { continue }

            // A line without final newline must be the last line of its side.
            for side in [targetNow, targetAfter] {
                for (offset, item) in side.enumerated() where lines[item.line].noNewline && offset != side.count - 1 {
                    throw .unsupported(.ambiguousEol)
                }
            }
            let oldSide = emitted.filter { $0.kind != .added }.count
            let newSide = emitted.filter { $0.kind != .deleted }.count
            // Positions: the target side keeps Git's numbers; the other side follows from earlier hunks.
            let insertionNow = nowCount > 0 ? nowStart : nowStart + 1
            let otherCount = reverse ? oldSide : newSide
            let insertionOther = insertionNow + delta
            let otherStart = otherCount > 0 ? insertionOther : insertionOther - 1
            let (oldStart, newStart) = reverse ? (otherStart, nowStart) : (nowStart, otherStart)
            delta += reverse ? (oldSide - newSide) : (newSide - oldSide)
            hunkTexts += Array("@@ -\(oldStart),\(oldSide) +\(newStart),\(newSide) @@\n".utf8)
            for item in emitted {
                hunkTexts.append(item.kind.prefix)
                hunkTexts += document.bytes(ofLine: item.line)
                if lines[item.line].isCRLF { hunkTexts.append(UInt8(ascii: "\r")) }
                hunkTexts.append(UInt8(ascii: "\n"))
                if lines[item.line].noNewline { hunkTexts += document.storage.noNewlineMarker }
            }
        }

        // Expected target: the current target with each hunk's range replaced by its result lines.
        let targetLines = splitLines(target)
        var expected: [UInt8] = []
        var cursor = 0
        for (range, documentNow, resultLines) in spliced {
            guard range.lowerBound >= cursor, range.upperBound <= targetLines.count else {
                throw .targetMismatch
            }
            // The target must hold exactly the lines the diff says it holds.
            for (offset, line) in documentNow.enumerated() {
                let actual: ArraySlice<UInt8> = targetLines[range.lowerBound + offset]
                let wanted: [UInt8] = document.fileBytes(ofLine: line)
                if !actual.elementsEqual(wanted) { throw .targetMismatch }
            }
            for index in cursor..<range.lowerBound { expected += targetLines[index] }
            for line in resultLines { expected += document.fileBytes(ofLine: line) }
            cursor = range.upperBound
        }
        for index in cursor..<targetLines.count { expected += targetLines[index] }

        // Headers. The target may not exist yet (a new file staged, a deleted file restored) and the
        // result may be "no file" (every line of a new file unstaged, every line of a deletion staged).
        let path = file.path
        let allSelected = selected == changed
        let targetMissing = reverse ? file.newPath == nil : file.oldPath == nil
        let resultMissing = reverse ? file.status == .added && allSelected : file.status == .deleted && allSelected
        let quotedA = RepositoryHandle.quoted("a/" + path)
        let quotedB = RepositoryHandle.quoted("b/" + path)
        // In forward patch terms: is the old side absent (new file) or the new side absent (deletion)?
        let newFileHeader = reverse ? resultMissing : targetMissing
        let deletionHeader = reverse ? targetMissing : resultMissing
        var header = Array("diff --git \(quotedA) \(quotedB)\n".utf8)
        if newFileHeader {
            header += Array("new file mode \(String(file.newMode ?? file.oldMode ?? 0o100644, radix: 8))\n".utf8)
            header += Array("--- /dev/null\n+++ \(quotedB)\n".utf8)
        } else if deletionHeader {
            header += Array("deleted file mode \(String(file.oldMode ?? file.newMode ?? 0o100644, radix: 8))\n".utf8)
            header += Array("--- \(quotedA)\n+++ /dev/null\n".utf8)
        } else {
            header += Array("--- \(quotedA)\n+++ \(quotedB)\n".utf8)
        }
        var arguments: [String] = []
        if operation != .discard { arguments.append("--cached") }
        if reverse { arguments.append("-R") }
        return BuiltPatch(
            path: path, bytes: header + hunkTexts, applyArguments: arguments,
            expected: resultMissing ? nil : expected, createsFile: targetMissing, deletesFile: resultMissing)
    }

    /// Lines with their terminators (the last one may have none).
    static func splitLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            result.append(bytes[start...index])
            start = index + 1
        }
        if start < bytes.count { result.append(bytes[start...]) }
        return result
    }
}

public enum PatchBuildError: Error, Sendable, Equatable {
    case unsupported(UnsupportedReason)
    /// The target's current bytes differ from what the diff says (stale, or a conversion).
    case targetMismatch
    case internalInconsistency(String)
}
