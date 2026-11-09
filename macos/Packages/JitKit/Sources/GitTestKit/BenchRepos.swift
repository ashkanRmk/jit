import Foundation

/// The Phase 6 benchmark repositories (design §4.2), built deterministically from fixed seeds, dates and
/// identities with `git fast-import` plus plain file writes. Never committed; built outside the repository
/// by `scripts/benchmarks/gen-repos.sh` (`JitBench make-bench-repo <name> <out>`).
///
/// Same name → same refs (`git for-each-ref`) and the same `git status` output, byte for byte.
public enum BenchRepo: String, CaseIterable, Sendable {
    /// 1,000 commits on `main`, no branches or merges.
    case linear1k = "linear-1k"
    /// 10,000 commits, ≈ 200 feature-branch refs, a merge every 5th commit, 16 features alive at once.
    case branchy10k = "branchy-10k"
    /// 100,000 commits, 1,000 branch refs, 500 tags.
    case huge100k = "huge-100k"
    /// 600 tracked files; 500 changes: 150 staged edits, 150 unstaged edits, 50 partially staged,
    /// 50 staged renames, 100 untracked.
    case manyFiles = "many-files"
    /// One 50,000-line text file rewritten in 200 scattered hunks, plus a 5 MB single-line minified file.
    case largeDiff = "large-diff"
    /// One commit with 50,000 tracked files in 500 directories.
    case wideTree = "wide-tree"

    /// Builds the repository at `path` (must not exist). Returns `main`'s object id.
    @discardableResult
    public func build(at path: String) throws -> String {
        let environment = SyntheticHistory.fixtureEnvironment
        switch self {
        case .linear1k:
            return try Self.importAndCheckout(Self.linearStream(commits: 1000), at: path)
        case .branchy10k:
            let history = SyntheticHistory(
                commits: 10_000, branches: 200, mergeEvery: 5, tags: 100, concurrentFeatures: 16)
            return try history.build(at: path, environment: environment)
        case .huge100k:
            return try SyntheticHistory(commits: 100_000, branches: 1_000, mergeEvery: 20, tags: 500)
                .build(at: path, environment: environment)
        case .wideTree:
            return try Self.importAndCheckout(Self.treeStream(files: 50_000, directories: 500), at: path)
        case .manyFiles:
            let head = try Self.importAndCheckout(Self.treeStream(files: 600, directories: 20), at: path)
            try Self.makeManyChanges(in: path)
            return head
        case .largeDiff:
            let head = try Self.importAndCheckout(Self.largeFileStream(), at: path)
            try Self.rewriteLargeFiles(in: path)
            return head
        }
    }

    // MARK: - Streams

    static func linearStream(commits: Int) -> [UInt8] {
        var rng = SyntheticHistory.Generator(state: 0x4C49_4E45)
        var out = FastImportWriter()
        for mark in 1...commits {
            let author = SyntheticHistory.authors[rng.below(SyntheticHistory.authors.count)]
            let subject =
                mark == 1
                ? "Initial commit"
                : "\(SyntheticHistory.verbs[rng.below(SyntheticHistory.verbs.count)]) "
                    + "\(SyntheticHistory.nouns[rng.below(SyntheticHistory.nouns.count)]) (#\(mark))"
            out.commit(
                ref: "refs/heads/main", mark: mark, author: author, time: Topology.baseTime + Int64(mark) * 60,
                message: subject, parents: mark == 1 ? [] : [mark - 1], file: "f\(mark % 97).txt", contents: "c\(mark)")
        }
        return out.bytes
    }

    static func path(file index: Int, directories: Int) -> String {
        "Sources/Module\(index % directories)/File\(index).swift"
    }

    static func fileContents(_ index: Int) -> String {
        (0..<12).map { "let value\($0) = \(index &* 31 &+ $0) // file \(index) line \($0)" }.joined(separator: "\n")
            + "\n"
    }

    /// One root commit containing `files` small Swift-like files.
    static func treeStream(files: Int, directories: Int) -> [UInt8] {
        var out = FastImportWriter()
        out.bytes.reserveCapacity(files * 600)
        out.line("commit refs/heads/main")
        out.line("mark :1")
        out.line("author \(Topology.identity) \(Topology.baseTime) +0000")
        out.line("committer \(Topology.identity) \(Topology.baseTime) +0000")
        out.data("Add \(files) files\n")
        for index in 0..<files {
            out.line("M 100644 inline \(path(file: index, directories: directories))")
            out.data(fileContents(index))
        }
        out.bytes.append(0x0A)
        return out.bytes
    }

    static let largeLineCount = 50_000

    static func largeLine(_ index: Int, revision: Int) -> String {
        "    case \(index): return compute(\(index), seed: \(revision == 0 ? index : index &* 7 &+ 1)) // row \(index)"
    }

    static func largeFileStream() -> [UInt8] {
        var out = FastImportWriter()
        out.line("commit refs/heads/main")
        out.line("mark :1")
        out.line("author \(Topology.identity) \(Topology.baseTime) +0000")
        out.line("committer \(Topology.identity) \(Topology.baseTime) +0000")
        out.data("Add large files\n")
        out.line("M 100644 inline large-table.swift")
        out.data((0..<largeLineCount).map { largeLine($0, revision: 0) }.joined(separator: "\n") + "\n")
        out.line("M 100644 inline large-minified.js")
        out.data(minified(revision: 0))
        out.line("M 100644 inline README.md")
        out.data("Large diff fixture\n")
        out.bytes.append(0x0A)
        return out.bytes
    }

    /// ≈ 5 MB on one line.
    static func minified(revision: Int) -> String {
        var rng = SyntheticHistory.Generator(state: 0x4D49_4E49 &+ UInt64(revision))
        var text = ""
        text.reserveCapacity(5_300_000)
        var index = 0
        while text.utf8.count < 5_000_000 {
            text += "function f\(index)(a,b){return a*\(rng.below(997))+b^\(rng.below(65_536))};"
            index += 1
        }
        return text + "\n"
    }

    // MARK: - Working-tree edits

    static func rewriteLargeFiles(in path: String) throws {
        // 200 hunks of 5 changed lines, spread evenly over the file.
        var lines = (0..<largeLineCount).map { largeLine($0, revision: 0) }
        for hunk in 0..<200 {
            let start = hunk * (largeLineCount / 200) + 17
            for offset in 0..<5 { lines[start + offset] = largeLine(start + offset, revision: 1) }
        }
        try write(lines.joined(separator: "\n") + "\n", to: "\(path)/large-table.swift")
        try write(minified(revision: 1), to: "\(path)/large-minified.js")
    }

    static func makeManyChanges(in path: String) throws {
        let directories = 20
        func edit(_ index: Int, _ suffix: String) throws {
            let file = "\(path)/\(Self.path(file: index, directories: directories))"
            try write(fileContents(index) + "// \(suffix)\n", to: file)
        }
        var stage: [String] = []
        // 0..<150 staged edits.
        for index in 0..<150 {
            try edit(index, "staged")
            stage.append(Self.path(file: index, directories: directories))
        }
        // 150..<200 partially staged: staged edit, then a further unstaged edit (below).
        for index in 150..<200 {
            try edit(index, "staged")
            stage.append(Self.path(file: index, directories: directories))
        }
        try git(["add", "--"] + stage, in: path)
        for index in 150..<200 { try edit(index, "staged + unstaged") }
        // 200..<350 unstaged edits.
        for index in 200..<350 { try edit(index, "unstaged") }
        // 350..<400 staged renames.
        try FileManager.default.createDirectory(atPath: "\(path)/Renamed", withIntermediateDirectories: true)
        for index in 350..<400 {
            try git(
                ["mv", "--", Self.path(file: index, directories: directories), "Renamed/File\(index).swift"], in: path)
        }
        // 100 untracked files.
        for index in 0..<100 { try write("untracked \(index)\n", to: "\(path)/Untracked/Note\(index).txt") }
    }

    // MARK: - Helpers

    static func write(_ text: String, to file: String) throws {
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }

    @discardableResult
    static func git(_ arguments: [String], in path: String) throws -> String {
        try SyntheticHistory(commits: 0).runGit(arguments, in: path, environment: SyntheticHistory.fixtureEnvironment)
    }

    static func importAndCheckout(_ stream: [UInt8], at path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: path)
        _ = try FastImport.run(stream, in: path, environment: SyntheticHistory.fixtureEnvironment)
        try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: path)
        try git(["reset", "-q", "--hard"], in: path)
        return try git(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
