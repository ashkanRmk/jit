import Foundation
import GitCore

/// A deterministic commit-graph description, written into a repository with `git fast-import`.
///
/// Every commit gets a label (its subject). Dates advance one minute per commit from a fixed base and the
/// identity is fixed, so the same topology always produces the same object ids.
///
/// ```swift
/// var t = Topology()
/// t.linear(3, prefix: "A")        // A1 ← A2 ← A3 on main
/// t.branch("feature")             // feature at A3, now current
/// t.commit("F1")
/// t.checkout("main")
/// t.commit("A4")
/// t.merge("feature", label: "M")  // M has parents A4, F1
/// let oids = try await t.write(to: repo)
/// ```
public struct Topology: Sendable {
    struct Commit: Sendable {
        let label: String
        let branch: String
        let parents: [Int]
        let time: Int64
        let file: String
    }

    enum TagSpec: Sendable {
        case lightweight(name: String, commit: Int)
        case annotated(name: String, commit: Int, message: String)
    }

    public static let baseTime: Int64 = 1_767_268_800  // 2026-01-01T12:00:00Z
    public static let identity = "Jit Tests <tests@jit.invalid>"

    private(set) var commits: [Commit] = []
    private(set) var tips: [String: Int] = [:]
    /// Branch order of first appearance (refs are written in this order).
    private(set) var branchOrder: [String] = []
    private(set) var tags: [TagSpec] = []
    private(set) var extraRefs: [(name: String, commit: Int)] = []
    public private(set) var current = "main"
    private(set) var detachedAt: Int?
    private var labels: [String: Int] = [:]
    /// Authors cycle through this list (index = commit index % count); default one fixed identity.
    public var authors: [String] = [Topology.identity]

    public init() {}

    public var commitCount: Int { commits.count }

    func index(of label: String) -> Int {
        guard let index = labels[label] else { preconditionFailure("unknown commit label \(label)") }
        return index
    }

    /// The commit at the tip of `branch`, or the labelled commit.
    func resolve(_ name: String) -> Int {
        tips[name] ?? index(of: name)
    }

    @discardableResult
    private mutating func add(_ label: String, parents: [Int], on branch: String) -> Int {
        precondition(labels[label] == nil, "duplicate label \(label)")
        let index = commits.count
        commits.append(
            Commit(
                label: label, branch: branch, parents: parents, time: Self.baseTime + Int64(index) * 60,
                file: "\(branch.replacingOccurrences(of: "/", with: "_")).txt"))
        labels[label] = index
        if tips[branch] == nil { branchOrder.append(branch) }
        tips[branch] = index
        detachedAt = nil
        return index
    }

    /// One commit on the current branch (a root commit if the branch has none yet).
    public mutating func commit(_ label: String) {
        add(label, parents: tips[current].map { [$0] } ?? [], on: current)
    }

    /// `count` commits labelled `prefix1…prefixN` on the current branch.
    public mutating func linear(_ count: Int, prefix: String) {
        for index in 1...count { commit("\(prefix)\(index)") }
    }

    /// Creates `name` at the current tip (or at `start`, a branch or label) and makes it current.
    public mutating func branch(_ name: String, from start: String? = nil) {
        let at = start.map { resolve($0) } ?? tips[current]
        precondition(at != nil, "branch \(name) needs a start commit")
        if tips[name] == nil { branchOrder.append(name) }
        tips[name] = at
        current = name
    }

    public mutating func checkout(_ name: String) {
        precondition(tips[name] != nil || name == current, "unknown branch \(name)")
        current = name
    }

    /// A merge commit on the current branch: first parent = current tip, then each named branch/label tip.
    public mutating func merge(_ others: String..., label: String) {
        merge(others, label: label)
    }

    public mutating func merge(_ others: [String], label: String) {
        guard let head = tips[current] else { preconditionFailure("merge on an unborn branch") }
        var parents = [head]
        for other in others.map({ resolve($0) }) where !parents.contains(other) { parents.append(other) }
        add(label, parents: parents, on: current)
    }

    /// Starts an unrelated history on `name` (its first commit is a root).
    public mutating func orphan(_ name: String) {
        precondition(tips[name] == nil, "orphan branch \(name) already exists")
        current = name
    }

    /// A lightweight tag, or an annotated one when `message` is given.
    public mutating func tag(_ name: String, at target: String? = nil, message: String? = nil) {
        guard let commit = target.map({ resolve($0) }) ?? tips[current] else {
            preconditionFailure("tag \(name) needs a commit")
        }
        if let message {
            tags.append(.annotated(name: name, commit: commit, message: message))
        } else {
            tags.append(.lightweight(name: name, commit: commit))
        }
    }

    /// An arbitrary ref (e.g. `refs/remotes/origin/main`) at a branch tip or label.
    public mutating func ref(_ fullName: String, at target: String) {
        extraRefs.append((fullName, resolve(target)))
    }

    /// Detaches HEAD at the current tip (or `target`).
    public mutating func detach(at target: String? = nil) {
        detachedAt = target.map { resolve($0) } ?? tips[current]
    }

    // MARK: - fast-import

    /// The `git fast-import` input for this topology. Marks are commit index + 1.
    public func fastImportStream() -> [UInt8] {
        var out = FastImportWriter()
        for (index, commit) in commits.enumerated() {
            out.commit(
                ref: "refs/heads/\(commit.branch)", mark: index + 1, author: authors[index % authors.count],
                time: commit.time, message: commit.label, parents: commit.parents.map { $0 + 1 },
                file: commit.file, contents: commit.label)
        }
        // Branches created but never committed on (pointing at another branch's commit).
        for name in branchOrder {
            guard let tip = tips[name] else { continue }
            out.reset(ref: "refs/heads/\(name)", mark: tip + 1)
        }
        for (name, commit) in extraRefs { out.reset(ref: name, mark: commit + 1) }
        for tag in tags {
            switch tag {
            case let .lightweight(name, commit):
                out.reset(ref: "refs/tags/\(name)", mark: commit + 1)
            case let .annotated(name, commit, message):
                out.annotatedTag(
                    name: name, mark: commit + 1, tagger: Self.identity, time: Self.baseTime, message: message)
            }
        }
        return out.bytes
    }

    /// Imports into `repo` (expected empty), points HEAD at the current branch (or detaches it), checks
    /// out the tree and returns label → full object id.
    @discardableResult
    public func write(to repo: TestRepo) async throws -> [String: String] {
        let marks = try FastImport.run(fastImportStream(), in: repo.path, environment: repo.sandbox.environment)
        if let detachedAt, let commit = marks[detachedAt + 1] {
            try await repo.git("update-ref", "--no-deref", "HEAD", commit)
        } else {
            try await repo.git("symbolic-ref", "HEAD", "refs/heads/\(current)")
        }
        if !commits.isEmpty { try await repo.git("reset", "-q", "--hard") }
        var result: [String: String] = [:]
        for (label, index) in labels { result[label] = marks[index + 1] }
        return result
    }
}

/// Builds `git fast-import` input.
struct FastImportWriter {
    var bytes: [UInt8] = []

    mutating func line(_ text: String) {
        bytes.append(contentsOf: text.utf8)
        bytes.append(0x0A)
    }

    mutating func data(_ text: String) {
        let payload = Array(text.utf8)
        line("data \(payload.count)")
        bytes.append(contentsOf: payload)
    }

    mutating func commit(
        ref: String, mark: Int, author: String, time: Int64, message: String, parents: [Int], file: String,
        contents: String
    ) {
        if parents.isEmpty { reset(ref: ref, mark: nil) }
        line("commit \(ref)")
        line("mark :\(mark)")
        line("author \(author) \(time) +0000")
        line("committer \(author) \(time) +0000")
        data(message + "\n")
        if let first = parents.first { line("from :\(first)") }
        for other in parents.dropFirst() { line("merge :\(other)") }
        line("M 100644 inline \(file)")
        data(contents + "\n")
        bytes.append(0x0A)
    }

    mutating func reset(ref: String, mark: Int?) {
        line("reset \(ref)")
        if let mark { line("from :\(mark)") }
        bytes.append(0x0A)
    }

    mutating func annotatedTag(name: String, mark: Int, tagger: String, time: Int64, message: String) {
        line("tag \(name)")
        line("from :\(mark)")
        line("tagger \(tagger) \(time) +0000")
        data(message + "\n")
        bytes.append(0x0A)
    }
}

/// Runs `git fast-import` with a byte stream on stdin. Test/benchmark support only: uses Foundation's
/// `Process` (GitCore's runner deliberately has no stdin).
public enum FastImport {
    /// Returns mark → object id.
    public static func run(_ stream: [UInt8], in directory: String, environment: [String: String]) throws -> [Int:
        String]
    {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jit-fi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("stream")
        let marks = scratch.appendingPathComponent("marks")
        try Data(stream).write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try gitPath())
        process.arguments = ["fast-import", "--quiet", "--force", "--export-marks=\(marks.path)"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessEnvironment.make(executableDirectory: nil, kind: .write, overrides: environment)
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.standardInput = try FileHandle(forReadingFrom: input)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitCoreError.processFailed(
                exitCode: process.terminationStatus, summary: "fast-import failed",
                detail: String(decoding: stderr, as: UTF8.self))
        }
        var result: [Int: String] = [:]
        for line in try String(contentsOf: marks, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let mark = Int(parts[0].dropFirst()) else { continue }
            result[mark] = String(parts[1])
        }
        return result
    }

    /// The Git the tests use: `JIT_GIT_PATH` if set, else the first of the usual install locations.
    static func gitPath() throws -> String {
        if let explicit = ProcessInfo.processInfo.environment["JIT_GIT_PATH"] { return explicit }
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw GitCoreError.gitNotFound
    }
}
