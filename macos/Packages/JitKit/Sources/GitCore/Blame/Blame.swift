import Foundation

/// A commit as blame describes it (first time it is seen).
public struct BlameCommit: Sendable, Hashable {
    public let id: String
    public var author = ""
    public var authorMail = ""
    public var authorTime: Int64 = 0
    public var summary = ""
    /// The commit is a boundary (`--incremental` "boundary"): history before it is not examined.
    public var isBoundary = false
    /// Not committed yet (all-zero id): lines changed in the working tree.
    public var isUncommitted: Bool { id.allSatisfy { $0 == "0" } }
}

/// `count` lines starting at `finalLine` (1-based, in the blamed file) come from `commitID`.
public struct BlameBlock: Sendable, Hashable {
    public let commitID: String
    public let originalLine: Int
    public let finalLine: Int
    public let count: Int
}

public enum BlameEvent: Sendable, Hashable {
    case commit(BlameCommit)
    case block(BlameBlock)
}

public struct BlameOptions: Sendable, Hashable {
    /// `-w`
    public var ignoreWhitespace: Bool
    /// `-M`
    public var detectMoves: Bool
    /// `nil` blames the working-tree file.
    public var revision: ObjectID?

    public init(ignoreWhitespace: Bool = false, detectMoves: Bool = false, revision: ObjectID? = nil) {
        self.ignoreWhitespace = ignoreWhitespace
        self.detectMoves = detectMoves
        self.revision = revision
    }
}

/// Parses `git blame --incremental` output as it arrives (bytes; headers are ASCII, paths/summaries UTF-8).
struct BlameIncrementalParser {
    private var buffer: [UInt8] = []
    private var current: (id: String, original: Int, final: Int, count: Int)?
    private var commit: BlameCommit?
    private var seen: Set<String> = []

    mutating func feed(_ bytes: [UInt8]) -> [BlameEvent] {
        buffer += bytes
        var events: [BlameEvent] = []
        var start = 0
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            handle(buffer[start..<newline], into: &events)
            start = newline + 1
        }
        buffer.removeFirst(start)
        return events
    }

    private mutating func handle(_ line: ArraySlice<UInt8>, into events: inout [BlameEvent]) {
        guard let space = line.firstIndex(of: UInt8(ascii: " ")) else {
            if line.elementsEqual("boundary".utf8) { commit?.isBoundary = true }
            return
        }
        let key = String(decoding: line[line.startIndex..<space], as: UTF8.self)
        let value = line[(space + 1)...]
        if current == nil {
            // "<sha> <orig> <final> <count>"
            let fields = line.split(separator: UInt8(ascii: " ")).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 4, let original = Int(fields[1]), let final = Int(fields[2]),
                let count = Int(fields[3])
            else { return }
            current = (fields[0], original, final, count)
            commit = seen.contains(fields[0]) ? nil : BlameCommit(id: fields[0])
            return
        }
        let text = String(decoding: value, as: UTF8.self)
        switch key {
        case "author": commit?.author = text
        case "author-mail": commit?.authorMail = text
        case "author-time": commit?.authorTime = Int64(text) ?? 0
        case "summary": commit?.summary = text
        case "filename":
            guard let block = current else { return }
            if let commit, seen.insert(commit.id).inserted { events.append(.commit(commit)) }
            events.append(
                .block(
                    BlameBlock(
                        commitID: block.id, originalLine: block.original, finalLine: block.final, count: block.count)))
            current = nil
            commit = nil
        default: break
        }
    }
}

extension RepositoryHandle {
    /// Streams blame for `path` (P3.9): pull-based (Git is read only as fast as the consumer asks, so the
    /// buffer is bounded), cancelled with the consuming task (kills the process group). Git applies
    /// `blame.ignoreRevsFile` from the repository configuration as usual.
    public nonisolated func blame(_ path: String, options: BlameOptions = BlameOptions()) -> AsyncThrowingStream<
        BlameEvent, any Error
    > {
        let reader = BlameReader(handle: self, path: path, options: options)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    /// The blamed text: the working-tree file, or the file at `revision`.
    public func blameContent(_ path: String, revision: ObjectID?) async throws(GitCoreError) -> [UInt8] {
        let topLevel = try requireWorkingTree()
        guard let revision else {
            do {
                return Array(try Data(contentsOf: URL(fileURLWithPath: topLevel).appendingPathComponent(path)))
            } catch {
                throw .io(summary: "Couldn’t read “\(path)”.")
            }
        }
        let format = try await objectFormat()
        return try await runRead(["cat-file", "blob", revision.hex(format) + ":" + path], limit: 64 * 1024 * 1024)
    }

    func blameArguments(_ path: String, options: BlameOptions) async throws(GitCoreError) -> [String] {
        var arguments = ["blame", "--incremental"]
        if options.ignoreWhitespace { arguments.append("-w") }
        if options.detectMoves { arguments.append("-M") }
        if let revision = options.revision { arguments.append(revision.hex(try await objectFormat())) }
        return arguments + ["--", path]
    }
}

/// Owns the Git child and the parser for one blame stream.
actor BlameReader {
    private let handle: RepositoryHandle
    private let path: String
    private let options: BlameOptions
    private var stream: ProcessStream?
    private var parser = BlameIncrementalParser()
    private var pending: [BlameEvent] = []
    private var finished = false

    init(handle: RepositoryHandle, path: String, options: BlameOptions) {
        self.handle = handle
        self.path = path
        self.options = options
    }

    func next() async throws -> BlameEvent? {
        while pending.isEmpty {
            if finished { return nil }
            if stream == nil {
                let arguments = try await handle.blameArguments(path, options: options)
                let directory = handle.info.topLevel ?? handle.info.gitDirectory
                stream = try await handle.gitEngine.stream(
                    GitCommand(arguments, in: directory, kind: .read, timeout: nil))
            }
            guard let bytes = try await stream?.read(maxBytes: 64 * 1024) else {
                finished = true
                stream = nil
                return pending.isEmpty ? nil : pending.removeFirst()
            }
            pending += parser.feed(bytes)
        }
        return pending.removeFirst()
    }
}
