import Foundation
import GitTestKit
import Testing

@testable import GitCore

/// Random files × random edits × random partial staging × random selections (P3.4): every operation's
/// result equals a simple model, and the side it must not touch is byte-identical. Cases from
/// `JIT_PROPERTY_CASES`; a failing case prints its seed (`JIT_PROPERTY_SEED`) and case number.
@Suite struct ApplyPropertyTests {
    static let words = ["alpha", "beta", "gamma", "δέλτα", "😀 emoji", "", "  indented", "tab\there", "x"]

    func randomFile(_ rng: inout SplitMix64) -> [UInt8] {
        let count = Int.random(in: 0...14, using: &rng)
        var out: [UInt8] = []
        for index in 0..<count {
            out += Array((Self.words.randomElement(using: &rng) ?? "").utf8)
            out += Array(" \(Int.random(in: 0...3, using: &rng))".utf8)
            let last = index == count - 1
            if last && Int.random(in: 0..<5, using: &rng) == 0 { break }  // no final newline
            out += Int.random(in: 0..<3, using: &rng) == 0 ? [13, 10] : [10]
        }
        return out
    }

    func edit(_ bytes: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var lines = PatchBuilder.splitLines(bytes).map(Array.init)
        var out: [[UInt8]] = []
        for line in lines {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: continue
            case 1: out.append(Array("changed \(Int.random(in: 0...9, using: &rng))\n".utf8))
            case 2: out.append(line); out.append(Array("inserted\(Int.random(in: 0...9, using: &rng))\r\n".utf8))
            default: out.append(line)
            }
        }
        if Int.random(in: 0..<4, using: &rng) == 0 { out.append(Array("appended\n".utf8)) }
        if !out.isEmpty, Int.random(in: 0..<6, using: &rng) == 0, var last = out.popLast() {
            if last.last == 10 { last.removeLast(); if last.last == 13 { last.removeLast() } } else { last.append(10) }
            out.append(last)
        }
        lines = out
        return lines.flatMap { $0 }
    }

    /// The model: walk the document's lines and keep what the operation keeps.
    func model(_ d: DiffDocument, _ selected: Set<Int>, _ action: SelectionAction) -> [UInt8] {
        var out: [UInt8] = []
        for line in 0..<d.storage.lineCount {
            let kind = d.kind(ofLine: line)
            let isSelected = selected.contains(line)
            let keep: Bool
            switch (action, kind) {
            case (_, .context): keep = true
            case (.stage, .deleted): keep = !isSelected
            case (.stage, .added): keep = isSelected
            case (_, .added): keep = !isSelected  // unstage / discard: selected additions go away
            case (_, .deleted): keep = isSelected  // and selected deletions come back
            }
            if keep { out += d.fileBytes(ofLine: line) }
        }
        return out
    }

    @Test func randomSelectionsMatchModel() async throws {
        let (cases, seed) = SplitMix64.propertyConfiguration(localDefault: 150, ciDefault: 2000)
        print("ApplyPropertyTests: \(cases) cases, JIT_PROPERTY_SEED=\(seed)")
        var rng = SplitMix64(seed: seed)
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("bystander.txt", "b\n")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "init")
        let engine = GitEngine(configuration: sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let url = URL(fileURLWithPath: repo.path + "/f.txt")
        var counts: [String: Int] = [:]
        for number in 0..<cases {
            let label = "case \(number) (JIT_PROPERTY_SEED=\(seed))"
            // HEAD version, a staged version, and a working-tree version.
            let head = randomFile(&rng)
            try Data(head).write(to: url)
            try await repo.git("add", "f.txt")
            _ = try await repo.git("commit", "-q", "--allow-empty", "-m", "case \(number)")
            let staged = edit(head, &rng)
            try Data(staged).write(to: url)
            try await repo.git("add", "f.txt")
            try Data(edit(staged, &rng)).write(to: url)

            let action: SelectionAction = [.stage, .stage, .unstage, .discard, .keepOnly].randomElement(using: &rng)!
            let d = try await handle.openDiff(action == .unstage ? .staged(path: "f.txt") : .unstaged(path: "f.txt"))
            let changed = (0..<d.storage.lineCount).filter { d.kind(ofLine: $0) != .context }
            guard !changed.isEmpty else { counts["no change", default: 0] += 1; continue }
            var selected = Set(changed.filter { _ in Bool.random(using: &rng) })
            if selected.isEmpty { selected.insert(changed.randomElement(using: &rng)!) }
            let effective = action == .keepOnly ? Set(changed).subtracting(selected) : selected
            let effectiveAction: SelectionAction = action == .keepOnly ? .discard : action
            if effective.isEmpty { counts["empty keep-only", default: 0] += 1; continue }

            let indexBefore = try await repo.git("ls-files", "-s")
            let worktreeBefore = try Data(contentsOf: url)
            do {
                _ = try await handle.apply(SelectionRequest(document: d, lines: selected, action: action))
            } catch {
                // Only the documented refusal is allowed; nothing may have changed.
                #expect(error.summary == UnsupportedReason.ambiguousEol.explanation, "\(label): \(error.summary)")
                #expect(try await repo.git("ls-files", "-s") == indexBefore, "\(label)")
                #expect(try Data(contentsOf: url) == worktreeBefore, "\(label)")
                counts["refused ambiguous EOL", default: 0] += 1
                continue
            }
            let expected = model(d, effective, effectiveAction)
            switch effectiveAction {
            case .stage, .unstage:
                let blob = try await sandbox.engine.run(GitCommand(["show", ":f.txt"], in: repo.path)).stdout
                #expect(blob == expected, "\(label): index")
                #expect(try Data(contentsOf: url) == worktreeBefore, "\(label): worktree untouched")
            default:
                #expect(Array(try Data(contentsOf: url)) == expected, "\(label): worktree")
                #expect(try await repo.git("ls-files", "-s") == indexBefore, "\(label): index untouched")
            }
            #expect(try await repo.git("show", ":bystander.txt") == "b", "\(label)")
            counts["\(action)", default: 0] += 1
        }
        print("ApplyPropertyTests outcome: \(counts.sorted { $0.key < $1.key })")
    }
}
