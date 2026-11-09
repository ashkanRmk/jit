import Foundation

/// Parses `git for-each-ref --format=<RefParser.format>` output as bytes. Fields are NUL-separated and
/// records end with a newline (no field can contain one: ref names forbid control characters).
public enum RefParser {
    public static let format =
        "%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00"
        + "%(upstream:short)%00%(upstream:track,nobracket)%00%(HEAD)%00%(symref)"

    static let fieldCount = 9

    public static func parse(_ output: [UInt8], head: HeadState, format objectFormat: ObjectFormat) throws(GitCoreError)
        -> RefSnapshot
    {
        var refs: [GitRef] = []
        var remoteHeads: [String: String] = [:]
        var hash = StableHash()
        let failure: GitCoreError? = output.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> GitCoreError? in
            hash.combine(buffer)
            var fields = [Range<Int>](repeating: 0..<0, count: fieldCount)
            var start = 0
            while start < buffer.count {
                guard let end = buffer[start...].firstIndex(of: 0x0A) else {
                    return .internalError(summary: "Git returned an incomplete list of branches and tags.")
                }
                var fieldStart = start
                var field = 0
                for index in start..<end where buffer[index] == 0 {
                    guard field < fieldCount - 1 else { break }
                    fields[field] = fieldStart..<index
                    field += 1
                    fieldStart = index + 1
                }
                guard field == fieldCount - 1 else {
                    return .internalError(summary: "Git returned an unexpected list of branches and tags.")
                }
                fields[field] = fieldStart..<end
                start = end + 1

                func bytes(_ i: Int) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: buffer[fields[i]]) }
                func text(_ i: Int) -> String { String(decoding: bytes(i), as: UTF8.self) }

                let name = text(0)
                if !fields[8].isEmpty {
                    // Symbolic ref (refs/remotes/origin/HEAD → refs/remotes/origin/main).
                    if name.hasPrefix("refs/remotes/"), name.hasSuffix("/HEAD") {
                        let remote = String(name.dropFirst("refs/remotes/".count).dropLast("/HEAD".count))
                        remoteHeads[remote] = text(8)
                    }
                    continue
                }
                guard let object = ObjectID(hex: bytes(1)) else {
                    return .internalError(summary: "Git returned a malformed object id for \(name).")
                }
                let type = bytes(2)
                let isTagObject = equals(type, "tag")
                var commit: ObjectID?
                if equals(type, "commit") {
                    commit = object
                } else if isTagObject, equals(bytes(4), "commit") {
                    commit = ObjectID(hex: bytes(3))
                }
                let kind: GitRef.Kind
                if name.hasPrefix("refs/heads/") {
                    kind = .local
                } else if name.hasPrefix("refs/remotes/") {
                    kind = .remote
                } else if name.hasPrefix("refs/tags/") {
                    kind = .tag
                } else {
                    kind = .other
                }
                let track = parseTrack(bytes(6))
                refs.append(
                    GitRef(
                        fullName: name, kind: kind, object: object, commit: commit, isAnnotatedTag: isTagObject,
                        upstream: fields[5].isEmpty ? nil : text(5), ahead: track.ahead, behind: track.behind,
                        upstreamGone: track.gone, isHead: equals(bytes(7), "*")))
            }
            return nil
        }
        if let failure { throw failure }
        switch head {
        case .branch(let name, let commit):
            hash.combine("branch \(name) \(commit)")
        case .detached(let commit):
            hash.combine("detached \(commit)")
        case .unborn(let name):
            hash.combine("unborn \(name)")
        }
        return RefSnapshot(head: head, refs: refs, remoteHeads: remoteHeads, format: objectFormat, revision: hash.value)
    }

    /// `ahead 2, behind 5` / `ahead 2` / `behind 5` / `gone` / empty.
    static func parseTrack(_ bytes: UnsafeRawBufferPointer) -> (ahead: Int, behind: Int, gone: Bool) {
        if bytes.isEmpty { return (0, 0, false) }
        if equals(bytes, "gone") { return (0, 0, true) }
        var ahead = 0
        var behind = 0
        var index = 0
        while index < bytes.count {
            let isAhead = bytes[index] == 0x61  // "a"head / "b"ehind
            while index < bytes.count, bytes[index] != 0x20 { index += 1 }
            index += 1
            var number = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                number = number &* 10 &+ Int(bytes[index] - 0x30)
                index += 1
            }
            if isAhead { ahead = number } else { behind = number }
            while index < bytes.count, bytes[index] == 0x2C || bytes[index] == 0x20 { index += 1 }
        }
        return (ahead, behind, false)
    }

    @inline(__always) static func equals(_ bytes: UnsafeRawBufferPointer, _ literal: StaticString) -> Bool {
        guard bytes.count == literal.utf8CodeUnitCount else { return false }
        let pointer = literal.utf8Start
        for index in 0..<bytes.count where bytes[index] != pointer[index] { return false }
        return true
    }
}

extension RepositoryHandle {
    /// Reads every ref with one `for-each-ref` call plus HEAD resolution (design §4.1).
    public func refs() async throws(GitCoreError) -> RefSnapshot {
        let directory = workingDirectory
        let engine = self.gitEngine
        let format = try await objectFormat()
        let headTask = Task { () -> Result<HeadState, GitCoreError> in
            do throws(GitCoreError) {
                return .success(try await Self.readHead(engine: engine, directory: directory))
            } catch {
                return .failure(error)
            }
        }
        let output: ProcessOutput
        do {
            output = try await withTaskCancellationHandler {
                try await engine.run(
                    GitCommand(
                        ["for-each-ref", "--format=\(RefParser.format)"], in: directory, kind: .read,
                        timeout: .seconds(60), stdoutLimit: 256 * 1024 * 1024))
            } onCancel: {
                headTask.cancel()
            }
        } catch {
            headTask.cancel()
            throw RepositoryDiscovery.classify(error as? GitCoreError ?? .cancelled, path: directory)
        }
        let head = try await headTask.value.get()
        if Task.isCancelled { throw .cancelled }
        return try RefParser.parse(output.stdout, head: head, format: format)
    }

    static func readHead(engine: GitEngine, directory: String) async throws(GitCoreError) -> HeadState {
        let head = try await RepositoryDiscovery(engine: engine, timeout: .seconds(30)).resolveHead(in: directory)
        switch head {
        case let .branch(name, commit):
            guard let oid = ObjectID(hex: commit) else {
                throw .internalError(summary: "Git returned a malformed HEAD.")
            }
            return .branch(name: name, commit: oid)
        case let .detached(commit):
            guard let oid = ObjectID(hex: commit) else {
                throw .internalError(summary: "Git returned a malformed HEAD.")
            }
            return .detached(commit: oid)
        case let .unborn(branch):
            return .unborn(branch: branch)
        }
    }
}
