import Foundation

/// One region of a conflicted text file (ADR-0031): ranges into the document's single byte buffer, no
/// per-line objects.
public enum ConflictSegment: Sendable, Hashable {
    /// Merged cleanly by Git.
    case resolved(Range<Int>)
    /// Both sides changed this region. `base` is the common ancestor's text (zdiff3).
    case conflict(ours: Range<Int>, base: Range<Int>, theirs: Range<Int>)
}

/// How one conflict block is resolved in the result.
public enum BlockChoice: Sendable, Hashable {
    case ours
    case theirs
    case oursThenTheirs
    case theirsThenOurs
    case base
    /// Text the user wrote (bytes, line endings as typed).
    case custom([UInt8])
}

/// A conflicted text file loaded from the index stages (design §4.10): Git's own merge of stage 2 (ours)
/// and stage 3 (theirs) over stage 1 (base) via `git merge-file -p --zdiff3`, parsed into segments.
/// Conflict markers already present in the file's history are just content: the document comes from the
/// stages, never from scanning the working-tree file.
public struct ConflictDocument: Sendable {
    public let path: String
    public let entry: ConflictEntry
    /// `merge-file` output with Jit-controlled labels; segment ranges point into it.
    public let bytes: [UInt8]
    public let segments: [ConflictSegment]
    public let ours: [UInt8]
    public let base: [UInt8]
    public let theirs: [UInt8]
    public let markerSize: Int
    /// The working-tree file when loaded (`nil`: missing). Saves are guarded by this hash.
    public let workingTreeHash: FileHash
    public let workingTree: [UInt8]?
    /// The working-tree file is exactly what Git's merge wrote (same text; marker labels ignored), so nothing
    /// the user typed would be lost by saving a result rendered from the stages.
    public let workingTreeMatchesGit: Bool

    public var workingTreeLooksUnedited: Bool { workingTreeMatchesGit }

    public var conflictCount: Int {
        segments.reduce(0) { count, segment in
            if case .conflict = segment { return count + 1 }
            return count
        }
    }

    /// Indices into `segments` of the conflict blocks, in order.
    public var conflictIndices: [Int] {
        segments.indices.filter { if case .conflict = segments[$0] { true } else { false } }
    }

    public func slice(_ range: Range<Int>) -> ArraySlice<UInt8> { bytes[range] }

    /// The result file for `choices` (keyed by segment index). Unresolved blocks keep Git-style markers so
    /// a partially resolved save never loses either side.
    public func render(_ choices: [Int: BlockChoice]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        let lastIndex = segments.indices.last
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .resolved(let range):
                result += bytes[range]
            case .conflict(let oursRange, let baseRange, let theirsRange):
                let isLast = index == lastIndex
                func side(_ range: Range<Int>, _ file: [UInt8], trimEOL: Bool) -> ArraySlice<UInt8> {
                    var slice = bytes[range]
                    if trimEOL, isLast, !file.isEmpty, file.last != 0x0A, slice.last == 0x0A {
                        slice = slice.dropLast()
                        if slice.last == 0x0D, file.last != 0x0D { slice = slice.dropLast() }
                    }
                    return slice
                }
                switch choices[index] {
                case .ours?: result += side(oursRange, ours, trimEOL: true)
                case .theirs?: result += side(theirsRange, theirs, trimEOL: true)
                case .base?: result += side(baseRange, base, trimEOL: true)
                case .oursThenTheirs?:
                    result += side(oursRange, ours, trimEOL: false)
                    result += side(theirsRange, theirs, trimEOL: true)
                case .theirsThenOurs?:
                    result += side(theirsRange, theirs, trimEOL: false)
                    result += side(oursRange, ours, trimEOL: true)
                case .custom(let text)?:
                    result += text
                case nil:
                    let eol: [UInt8] = usesCRLF ? [0x0D, 0x0A] : [0x0A]
                    result += Array(repeating: UInt8(ascii: "<"), count: 7) + Array(" ours".utf8) + eol
                    result += bytes[oursRange]
                    result += Array(repeating: UInt8(ascii: "="), count: 7) + eol
                    result += bytes[theirsRange]
                    result += Array(repeating: UInt8(ascii: ">"), count: 7) + Array(" theirs".utf8) + eol
                }
            }
        }
        return result
    }

    /// The file mostly uses CRLF line endings.
    public var usesCRLF: Bool {
        var crlf = 0
        var lf = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            if index > 0, bytes[index - 1] == 0x0D { crlf += 1 } else { lf += 1 }
        }
        return crlf > lf
    }

    /// Marker lines reduced to their marker characters (labels such as `HEAD` or a branch name dropped), so a
    /// working-tree file can be compared with a re-run of Git's merge whatever labels Git used.
    static func normalizeMarkers(_ bytes: [UInt8], size: Int = 7) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let line = bytes[lineStart..<lineEnd]
            if let first = line.first, [UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|")].contains(first),
                line.count >= size, line.prefix(size).allSatisfy({ $0 == first }),
                line.count == size || line[line.startIndex + size] == 0x20
            {
                result += Array(repeating: first, count: size)
                if line.last == 0x0D { result.append(0x0D) }
            } else {
                result += line
            }
            if lineEnd < bytes.count { result.append(0x0A) }
            lineStart = lineEnd + 1
        }
        return result
    }

    /// Lines in `bytes` that look like conflict markers (Mark as Resolved asks first when any remain).
    public static func containsMarkers(_ bytes: [UInt8]) -> Bool { markerBlockCount(bytes) > 0 }

    static func markerBlockCount(_ bytes: [UInt8]) -> Int {
        var count = 0
        var lineStart = 0
        for index in bytes.indices where bytes[index] == 0x0A || index == bytes.count - 1 {
            let line = bytes[lineStart...index]
            if line.count >= 8, line.prefix(7).allSatisfy({ $0 == UInt8(ascii: "<") }), line.dropFirst(7).first == 0x20
            {
                count += 1
            }
            lineStart = index + 1
        }
        return count
    }

    /// Parses `merge-file` output whose markers are `markerSize` characters followed by our fixed labels.
    static func parse(_ bytes: [UInt8], markerSize: Int) -> [ConflictSegment]? {
        enum State { case outside, ours, base, theirs }
        let open = Array(repeating: UInt8(ascii: "<"), count: markerSize) + Array(" ours".utf8)
        let baseMarker = Array(repeating: UInt8(ascii: "|"), count: markerSize) + Array(" base".utf8)
        let separator = Array(repeating: UInt8(ascii: "="), count: markerSize)
        let close = Array(repeating: UInt8(ascii: ">"), count: markerSize) + Array(" theirs".utf8)

        var segments: [ConflictSegment] = []
        var state = State.outside
        var resolvedStart = 0
        var oursStart = 0
        var oursEnd = 0
        var baseStart = 0
        var baseEnd = 0
        var theirsStart = 0
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let next = min(lineEnd + 1, bytes.count)
            var content = bytes[lineStart..<lineEnd]
            if content.last == 0x0D { content = content.dropLast() }
            switch state {
            case .outside where content.elementsEqual(open):
                if lineStart > resolvedStart { segments.append(.resolved(resolvedStart..<lineStart)) }
                oursStart = next
                state = .ours
            case .ours where content.elementsEqual(baseMarker):
                oursEnd = lineStart
                baseStart = next
                state = .base
            case .ours where content.elementsEqual(separator):
                oursEnd = lineStart
                baseStart = lineStart
                baseEnd = lineStart
                theirsStart = next
                state = .theirs
            case .base where content.elementsEqual(separator):
                baseEnd = lineStart
                theirsStart = next
                state = .theirs
            case .theirs where content.elementsEqual(close):
                segments.append(
                    .conflict(ours: oursStart..<oursEnd, base: baseStart..<baseEnd, theirs: theirsStart..<lineStart))
                resolvedStart = next
                state = .outside
            default:
                break
            }
            lineStart = next
        }
        guard state == .outside else { return nil }
        if resolvedStart < bytes.count { segments.append(.resolved(resolvedStart..<bytes.count)) }
        return segments
    }

    /// Longest run of a marker character at the start of any line, so Jit's markers can't collide with
    /// content (marker size = that + 1, at least 7).
    static func markerSize(for files: [[UInt8]]) -> Int {
        var longest = 6
        for file in files {
            var atLineStart = true
            var run = 0
            var runByte: UInt8 = 0
            for byte in file {
                if atLineStart || (run > 0 && byte == runByte) {
                    if [UInt8(ascii: "<"), UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "|")].contains(byte),
                        run == 0 || byte == runByte
                    {
                        runByte = byte
                        run += 1
                        longest = max(longest, run)
                        atLineStart = false
                        continue
                    }
                }
                atLineStart = byte == 0x0A
                run = 0
            }
        }
        return longest + 1
    }
}

extension RepositoryHandle {
    /// Loads a text conflict (read-only: opening a file never resolves it). Stage blobs are written to a
    /// private 0700 temporary directory for `merge-file` and removed afterwards.
    public nonisolated func loadConflict(_ entry: ConflictEntry) async throws(GitCoreError) -> ConflictDocument {
        guard entry.presentation == .text, let oursStage = entry.ours, let theirsStage = entry.theirs else {
            throw .refused(summary: "This conflict can't be shown as text.")
        }
        let topLevel = try requireWorkingTree()
        let ours = try await blob(oursStage.oid, limit: ConflictLimits.maxTextBytes + 1)
        let theirs = try await blob(theirsStage.oid, limit: ConflictLimits.maxTextBytes + 1)
        var base: [UInt8] = []
        if let stage = entry.base { base = try await blob(stage.oid, limit: ConflictLimits.maxTextBytes + 1) }
        let markerSize = ConflictDocument.markerSize(for: [ours, base, theirs])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jit-conflict-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(ours).write(to: directory.appendingPathComponent("ours"))
            try Data(base).write(to: directory.appendingPathComponent("base"))
            try Data(theirs).write(to: directory.appendingPathComponent("theirs"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw .io(summary: "Jit couldn't prepare the conflict for display.")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let output: ProcessOutput
        do {
            output = try await gitEngine.run(
                GitCommand(
                    [
                        "merge-file", "-p", "--zdiff3", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base", "-L",
                        "theirs", "ours", "base", "theirs",
                    ], in: directory.path, kind: .read, stdoutLimit: 4 * ConflictLimits.maxTextBytes,
                    acceptedExitCodes: Set(0...127)))
        } catch {
            throw RepositoryDiscovery.classify(error, path: topLevel)
        }
        guard let segments = ConflictDocument.parse(output.stdout, markerSize: markerSize) else {
            throw .internalError(summary: "Jit couldn't read Git's merge of this file.")
        }
        let filePath = (topLevel as NSString).appendingPathComponent(entry.path)
        let workingTree = FileManager.default.contents(atPath: filePath).map { [UInt8]($0) }
        // What Git itself wrote into the working tree: the same merge in the configured conflict style.
        var matchesGit = false
        if let workingTree {
            let style =
                (try? await gitEngine.run(
                    GitCommand(
                        ["config", "--get", "merge.conflictStyle"], in: topLevel, kind: .read,
                        acceptedExitCodes: [0, 1])
                ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            var arguments = ["merge-file", "-p"]
            if style == "diff3" {
                arguments.append("--diff3")
            } else if style == "zdiff3" {
                arguments.append("--zdiff3")
            }
            arguments += ["-L", "o", "-L", "b", "-L", "t", "ours", "base", "theirs"]
            if let gitStyle = try? await gitEngine.run(
                GitCommand(
                    arguments, in: directory.path, kind: .read, stdoutLimit: 4 * ConflictLimits.maxTextBytes,
                    acceptedExitCodes: Set(0...127)))
            {
                matchesGit =
                    ConflictDocument.normalizeMarkers(gitStyle.stdout) == ConflictDocument.normalizeMarkers(workingTree)
            }
        }
        return ConflictDocument(
            path: entry.path, entry: entry, bytes: output.stdout, segments: segments, ours: ours, base: base,
            theirs: theirs, markerSize: markerSize, workingTreeHash: workingTree.map { FileHash($0) } ?? .missing,
            workingTree: workingTree, workingTreeMatchesGit: matchesGit)
    }

    /// Writes the resolved text atomically (temp file in the same directory, original mode, `rename(2)`),
    /// after checking that the file still has `expected` content. Returns the new hash.
    public func saveResolution(_ path: String, content: [UInt8], expected: FileHash) async throws(GitCoreError)
        -> FileHash
    {
        let topLevel = try requireWorkingTree()
        let filePath = try Self.resolveInsideWorkingTree(path, topLevel: topLevel)
        let engine = gitEngine
        return try await performExclusive("Save \(Self.describe([path]))", invalidating: [.worktree]) {
            () throws(GitCoreError) -> FileHash in
            try await Self.requireUnmerged(path, engine: engine, topLevel: topLevel)
            let current = FileHash.of(path: filePath) ?? .missing
            guard current == expected else {
                throw .staleSnapshot(summary: "“\(path)” changed outside Jit. Reload it or keep your result.")
            }
            try Self.atomicWrite(content, to: filePath)
            return FileHash(content)
        }
    }

    /// Stages the saved result (`git add -- <path>`) after re-verifying its hash. Only on explicit request.
    public func markResolved(_ path: String, expected: FileHash) async throws(GitCoreError) {
        let topLevel = try requireWorkingTree()
        let filePath = try Self.resolveInsideWorkingTree(path, topLevel: topLevel)
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        _ = try await performExclusive("Mark \(Self.describe([path])) resolved", invalidating: [.index, .worktree]) {
            () throws(GitCoreError) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            try await Self.requireUnmerged(path, engine: engine, topLevel: topLevel)
            guard (FileHash.of(path: filePath) ?? .missing) == expected else {
                throw .staleSnapshot(
                    summary: "“\(path)” changed since you saved it. Review it before marking it resolved.")
            }
            try await Self.runPathspecCommand(
                ["add"], paths: [path], engine: engine, in: topLevel, gitDirectory: gitDirectory)
        }
    }

    /// Fallback resolutions (design §3.9) — take one side, keep the modified file, or delete it. Always
    /// confirmed: the token names the path and the choice.
    public func resolveWithSide(_ path: String, choice: ConflictFallbackChoice, token: ConfirmationToken)
        async throws(GitCoreError)
    {
        let topLevel = try requireWorkingTree()
        _ = try Self.resolveInsideWorkingTree(path, topLevel: topLevel)
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        try token.verify(.resolveConflict(path: path, choice: choice.rawValue))
        let handle = self
        _ = try await performExclusive("Resolve \(Self.describe([path]))", invalidating: [.index, .worktree]) {
            () throws(GitCoreError) in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            // Re-read inside the gate: the entry must still be conflicted, and the choice must fit its kind.
            guard let entry = try await handle.conflicts().first(where: { $0.path == path }) else {
                throw .staleSnapshot(summary: "“\(path)” is no longer conflicted.")
            }
            switch (entry.presentation, choice) {
            case (.modifyDelete, .keepFile), (.modifyDelete, .deleteFile), (.bothDeleted, .deleteFile),
                (.bothDeleted, .keepFile), (.pickSide, .ours), (.pickSide, .theirs), (.modifyDelete, .ours),
                (.modifyDelete, .theirs), (.bothDeleted, .ours), (.bothDeleted, .theirs):
                break
            default:
                throw .refused(summary: "That choice doesn't apply to this conflict. Nothing was changed.")
            }
            func run(_ arguments: [String]) async throws(GitCoreError) {
                try await Self.runPathspecCommand(
                    arguments, paths: [path], engine: engine, in: topLevel, gitDirectory: gitDirectory)
            }
            switch choice {
            case .ours, .theirs:
                let stage = choice == .ours ? entry.ours : entry.theirs
                if stage == nil {
                    try await run(["rm", "-q", "--ignore-unmatch"])
                } else {
                    try await run(["checkout", choice == .ours ? "--ours" : "--theirs"])
                    try await run(["add"])
                }
            case .keepFile:
                guard FileManager.default.fileExists(atPath: (topLevel as NSString).appendingPathComponent(path)) else {
                    throw .staleSnapshot(summary: "“\(path)” no longer exists on disk.")
                }
                try await run(["add"])
            case .deleteFile:
                try await run(["rm", "-q", "--ignore-unmatch"])
            }
        }
    }

    /// A repository-relative path: no absolute, empty, `.`, `..` or `.git` components, and its parent directory
    /// must resolve (symlinks followed) inside the working tree.
    static func resolveInsideWorkingTree(_ path: String, topLevel: String) throws(GitCoreError) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
        else {
            throw .refused(summary: "“\(path)” isn't a path inside this repository.")
        }
        let filePath = (topLevel as NSString).appendingPathComponent(path)
        let parent = (filePath as NSString).deletingLastPathComponent
        guard let resolvedParent = realpath(parent, nil), let resolvedTop = realpath(topLevel, nil) else {
            throw .staleSnapshot(summary: "The folder of “\(path)” no longer exists.")
        }
        defer {
            free(resolvedParent)
            free(resolvedTop)
        }
        let parentString = String(cString: resolvedParent)
        let topString = String(cString: resolvedTop)
        guard parentString == topString || parentString.hasPrefix(topString + "/") else {
            throw .refused(summary: "“\(path)” is outside this repository.")
        }
        return filePath
    }

    /// Only conflicted paths may be written or marked by the resolver.
    static func requireUnmerged(_ path: String, engine: GitEngine, topLevel: String) async throws(GitCoreError) {
        guard try await unmergedPathList(engine: engine, in: topLevel).contains(path) else {
            throw .staleSnapshot(summary: "“\(path)” is no longer conflicted.")
        }
    }

    static func atomicWrite(_ content: [UInt8], to filePath: String) throws(GitCoreError) {
        let directory = (filePath as NSString).deletingLastPathComponent
        let temporary = (directory as NSString).appendingPathComponent(".jit-resolve-\(UUID().uuidString)")
        var mode: mode_t = 0o644
        var info = stat()
        if lstat(filePath, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw .refused(summary: "This path is a symbolic link; choose a side instead.")
            }
            mode = info.st_mode & 0o7777
        }
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else {
            throw .io(summary: "Jit couldn't write the resolved file (\(String(cString: strerror(errno)))).")
        }
        var written = 0
        let ok = content.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let result = write(fd, buffer.baseAddress?.advanced(by: written), buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += result
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard ok, synced else {
            unlink(temporary)
            throw .io(summary: "Jit couldn't write the resolved file (\(String(cString: strerror(errno)))).")
        }
        _ = chmod(temporary, mode)
        guard rename(temporary, filePath) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw .io(summary: "Jit couldn't replace the file (\(message)).")
        }
    }
}

/// Fallback resolutions for non-text conflicts (design §3.9).
public enum ConflictFallbackChoice: String, Sendable, Hashable {
    /// `git checkout --ours -- p && git add -- p` (or `git rm` when ours deleted it).
    case ours
    case theirs
    /// Modify/delete: keep the modified file (`git add`).
    case keepFile
    /// Modify/delete: delete it (`git rm`).
    case deleteFile
}

/// Which side is which, per operation (ADR-0033). Never "local/remote".
public struct ConflictLabels: Sendable, Equatable {
    public var ours: String
    public var theirs: String
    /// Rebase inverts ours/theirs: shown once per session.
    public var explanation: String?

    public init(ours: String, theirs: String, explanation: String? = nil) {
        self.ours = ours
        self.theirs = theirs
        self.explanation = explanation
    }

    public static func make(for state: RepoOperationState, currentBranch: String?) -> ConflictLabels {
        let branch = currentBranch.map { "Current branch \($0)" } ?? "Current HEAD"
        switch state {
        case .merging(let source, _):
            return ConflictLabels(
                ours: "\(branch) (ours)", theirs: "Incoming \(source.isEmpty ? "changes" : source) (theirs)")
        case .rebasing(_, let onto, _, _, let stopped, _):
            let target = onto.isEmpty ? "the upstream" : String(onto.prefix(7))
            let commit = stopped.map { "Your commit \($0.shortOID) “\($0.subject)”" } ?? "Your commit"
            return ConflictLabels(
                ours: "Upstream being rebased onto: \(target) + already-replayed commits (ours)",
                theirs: "\(commit) (theirs)",
                explanation:
                    "During a rebase Git replays your commits onto the upstream, so “ours” is the upstream and “theirs” is your commit."
            )
        case .cherryPicking(let commit, _, _):
            return ConflictLabels(
                ours: "\(branch) (ours)",
                theirs: "Picked commit \(commit.map { "\($0.shortOID) “\($0.subject)”" } ?? "") (theirs)")
        case .reverting(let commit, _, _):
            return ConflictLabels(
                ours: "\(branch) (ours)",
                theirs: "Reverse of \(commit.map { "\($0.shortOID) “\($0.subject)”" } ?? "the commit") (theirs)")
        default:
            return ConflictLabels(ours: "\(branch) (ours)", theirs: "Incoming changes (theirs)")
        }
    }
}
