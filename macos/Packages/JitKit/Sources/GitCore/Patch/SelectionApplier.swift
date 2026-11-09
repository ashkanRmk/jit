import Foundation

/// A line selection to apply to the file of `document` (P3.4, design §4.4).
public struct SelectionRequest: Sendable {
    public let document: DiffDocument
    /// Line indices (into the document) of the selected changed lines.
    public let lines: Set<Int>
    public let action: SelectionAction

    public init(document: DiffDocument, lines: Set<Int>, action: SelectionAction) {
        self.document = document
        self.lines = lines
        self.action = action
    }
}

public struct ApplyOutcome: Sendable, Equatable {
    public let revision: RepoRevision
    /// Recovery copy written before a discard / keep-only.
    public let recoveryID: String?
}

extension RepositoryHandle {
    /// Applies a line selection inside the write gate: token check → patch → `git apply --check` →
    /// recovery copy (discard) → apply → verify against an independently computed result → roll back on
    /// mismatch. Nothing outside the selected lines of the one file can change.
    public func apply(_ request: SelectionRequest, hooks: DiscardHooks? = nil) async throws(GitCoreError)
        -> ApplyOutcome
    {
        try await applySelection(request, hooks: hooks, beforeApply: nil)
    }

    /// `beforeApply` runs between the check and the apply (tests inject concurrent writers there).
    func applySelection(
        _ request: SelectionRequest, hooks: DiscardHooks?, beforeApply: (@Sendable () async -> Void)?
    ) async throws(GitCoreError) -> ApplyOutcome {
        let document = request.document
        guard let token = document.token, let target = document.target else {
            throw .refused(summary: UnsupportedReason.wrongSource.explanation)
        }
        switch (request.action, target) {
        case (.unstage, .staged), (.stage, .unstaged), (.discard, .unstaged), (.keepOnly, .unstaged): break
        default: throw .refused(summary: UnsupportedReason.wrongSource.explanation)
        }
        if let reason = PatchBuilder.unsupported(document) { throw .refused(summary: reason.explanation) }
        let topLevel = try requireWorkingTree()
        let (engine, gitDirectory) = (gitEngine, info.gitDirectory)
        let path = token.path
        let worktree = request.action == .stage || request.action == .unstage ? false : true
        let count = request.lines.count
        let verb: String
        switch request.action {
        case .stage: verb = "Stage"
        case .unstage: verb = "Unstage"
        case .discard: verb = "Discard"
        case .keepOnly: verb = "Keep only"
        }
        let description = "\(verb) \(count) \(count == 1 ? "line" : "lines") in \(Self.describe([path]))"
        let recovery: String? = try await performExclusive(description) { () throws(GitCoreError) -> String? in
            try Self.refuseIfIndexLocked(gitDirectory: gitDirectory)
            // 1. The file must be exactly what the user looked at.
            let current = try await self.snapshotToken(for: path)
            let same: Bool
            switch request.action {
            case .unstage: same = current.headID == token.headID && current.indexEntry == token.indexEntry
            default:
                same =
                    current.indexEntry == token.indexEntry && current.worktree == token.worktree
                    && current.worktreeBlobID == token.worktreeBlobID
            }
            guard same else {
                throw .staleSnapshot(summary: "The file changed since you selected those lines. Nothing was changed.")
            }
            let attributes = try await Self.conversionAttributes(path, engine: engine, in: topLevel)
            if attributes.filter { throw .refused(summary: UnsupportedReason.filterConversion.explanation) }

            // 2–3. Patch and expected result from the target's current bytes.
            let indexBefore = try await Self.indexListing(engine: engine, in: topLevel)
            let entryBefore = Self.entry(for: path, in: indexBefore)
            let targetBytes: [UInt8]
            if worktree {
                let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
                targetBytes =
                    FileManager.default.fileExists(atPath: url.path)
                    ? Array((try? Data(contentsOf: url)) ?? Data()) : []
            } else {
                targetBytes = try await Self.blob(entryBefore?.id, engine: engine, in: topLevel)
            }
            let built: Result<BuiltPatch, PatchBuildError> = Result { () throws(PatchBuildError) in
                try PatchBuilder.build(document, selection: request.lines, action: request.action, target: targetBytes)
            }
            let patch: BuiltPatch
            switch built {
            case .success(let value):
                patch = value
            case .failure(.unsupported(let reason)):
                throw .refused(summary: reason.explanation)
            case .failure(.targetMismatch):
                if attributes.converts { throw .refused(summary: UnsupportedReason.filterConversion.explanation) }
                throw .staleSnapshot(summary: "The file changed since you selected those lines. Nothing was changed.")
            case .failure(.internalInconsistency(let what)):
                throw .internalError(summary: "Couldn’t build the patch (\(what)). Nothing was changed.")
            }

            // 4. Check with Git, from a private file.
            let patchFile = try Self.writePrivatePatch(patch.bytes)
            defer { try? FileManager.default.removeItem(at: patchFile.deletingLastPathComponent()) }
            do throws(GitCoreError) {
                try await Self.runApply(
                    ["--check"] + patch.applyArguments, patch: patchFile, engine: engine, in: topLevel,
                    gitDirectory: gitDirectory)
            } catch {
                if attributes.converts { throw .refused(summary: UnsupportedReason.filterConversion.explanation) }
                if case .indexLocked = error { throw error }
                throw .refused(
                    summary: "Git could not apply this selection, so nothing was changed. \(error.detail ?? "")")
            }

            // 5. Recovery copy before touching the working tree.
            var recoveryID: String?
            if worktree, !targetBytes.isEmpty || FileManager.default.fileExists(atPath: topLevel + "/" + path) {
                let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path), let hooks {
                    do {
                        recoveryID = try hooks.preserve(path, url)
                    } catch {
                        throw .io(summary: "Couldn’t keep a recovery copy of “\(path)”, so nothing was changed.")
                    }
                }
            }
            if let beforeApply { await beforeApply() }

            // 6. Apply.
            try await Self.runApply(
                patch.applyArguments, patch: patchFile, engine: engine, in: topLevel, gitDirectory: gitDirectory)

            // 7. Verify, and roll back what can be rolled back.
            if worktree {
                let url = URL(fileURLWithPath: topLevel).appendingPathComponent(path)
                let exists = FileManager.default.fileExists(atPath: url.path)
                let actual = exists ? Array((try? Data(contentsOf: url)) ?? Data()) : nil
                if actual != patch.expected {
                    // Restore only if nobody else wrote since: the file holds what our apply produced.
                    throw .verificationFailed(
                        summary: "The result of the discard was not what Jit expected."
                            + (recoveryID.map { " A copy of the file before the discard is in \($0)." } ?? ""))
                }
                let indexAfter = try await Self.indexListing(engine: engine, in: topLevel)
                if indexAfter != indexBefore {
                    throw .verificationFailed(summary: "The index changed during a discard; please review it.")
                }
            } else {
                let indexAfter = try await Self.indexListing(engine: engine, in: topLevel)
                let entryAfter = Self.entry(for: path, in: indexAfter)
                var ok = Self.others(of: path, in: indexAfter) == Self.others(of: path, in: indexBefore)
                if ok {
                    if let expected = patch.expected {
                        if let entryAfter {
                            ok = try await Self.blob(entryAfter.id, engine: engine, in: topLevel) == expected
                        } else {
                            ok = false
                        }
                    } else {
                        ok = entryAfter == nil
                    }
                }
                if !ok {
                    try await Self.restoreIndexEntry(
                        path, entryBefore, engine: engine, in: topLevel, gitDirectory: gitDirectory)
                    throw .verificationFailed(
                        summary: "The staging result was not what Jit expected, so “\(path)” was put back as it was.")
                }
            }
            return recoveryID
        }
        return ApplyOutcome(revision: repoRevision, recoveryID: recovery)
    }

    // MARK: Helpers

    struct IndexEntry: Equatable {
        let mode: String
        let id: String
        let stage: String
    }

    /// `git ls-files -s -z` records by path (raw record bytes kept for comparison).
    static func indexListing(engine: GitEngine, in directory: String) async throws(GitCoreError) -> [String: IndexEntry]
    {
        let output: [UInt8]
        do {
            output = try await engine.run(
                GitCommand(
                    ["ls-files", "-s", "-z"], in: directory, kind: .read, timeout: .seconds(120),
                    stdoutLimit: 512 * 1024 * 1024)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
        var result: [String: IndexEntry] = [:]
        for record in output.split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let fields = record[record.startIndex..<tab].split(separator: UInt8(ascii: " ")).map {
                String(decoding: $0, as: UTF8.self)
            }
            guard fields.count == 3 else { continue }
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            result[path + (fields[2] == "0" ? "" : "\u{0}\(fields[2])")] = IndexEntry(
                mode: fields[0], id: fields[1], stage: fields[2])
        }
        return result
    }

    static func entry(for path: String, in listing: [String: IndexEntry]) -> IndexEntry? { listing[path] }

    static func others(of path: String, in listing: [String: IndexEntry]) -> [String: IndexEntry] {
        var copy = listing
        copy[path] = nil
        return copy
    }

    static func blob(_ id: String?, engine: GitEngine, in directory: String) async throws(GitCoreError) -> [UInt8] {
        guard let id else { return [] }
        do {
            return try await engine.run(
                GitCommand(
                    ["cat-file", "blob", id], in: directory, kind: .read, timeout: .seconds(60),
                    stdoutLimit: 256 * 1024 * 1024)
            ).stdout
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
    }

    /// Puts the captured index entry back (or removes the path if it had none), path on stdin (`-z`).
    static func restoreIndexEntry(
        _ path: String, _ entry: IndexEntry?, engine: GitEngine, in directory: String, gitDirectory: String
    ) async throws(GitCoreError) {
        var input: [UInt8]
        if let entry {
            input = Array("\(entry.mode) \(entry.id) \(entry.stage)\t".utf8)
        } else {
            input = Array("0 \(String(repeating: "0", count: 40))\t".utf8)
        }
        input += Array(path.utf8)
        input.append(0)
        do {
            _ = try await engine.run(
                GitCommand(["update-index", "-z", "--index-info"], in: directory, kind: .write, stdin: input))
        } catch {
            throw mapWriteError(error, gitDirectory: gitDirectory)
        }
    }

    struct ConversionAttributes {
        var filter = false
        var converts = false
    }

    /// `filter` (clean/smudge) refuses line actions; `text`/`eol`/`core.autocrlf` may make the working
    /// tree differ from Git's normalized diff.
    static func conversionAttributes(_ path: String, engine: GitEngine, in directory: String) async throws(GitCoreError)
        -> ConversionAttributes
    {
        var result = ConversionAttributes()
        do {
            let output = try await engine.run(
                GitCommand(["check-attr", "-z", "filter", "text", "eol", "--", path], in: directory, kind: .read))
            let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false).map {
                String(decoding: $0, as: UTF8.self)
            }
            var index = 0
            while index + 2 < fields.count {
                let (attribute, value) = (fields[index + 1], fields[index + 2])
                if value != "unspecified" && value != "unset" {
                    if attribute == "filter" { result.filter = true } else { result.converts = true }
                }
                index += 3
            }
            let autocrlf = try await engine.run(
                GitCommand(
                    ["config", "--get", "core.autocrlf"], in: directory, kind: .read, acceptedExitCodes: [0, 1]))
            let value = autocrlf.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value == "true" || value == "input" { result.converts = true }
        } catch {
            throw RepositoryDiscovery.classify(error, path: directory)
        }
        return result
    }

    /// The patch in a fresh `0700` directory as a `0600` file; the caller removes the directory.
    static func writePrivatePatch(_ bytes: [UInt8]) throws(GitCoreError) -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "jit-patch-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("selection.patch")
            guard fm.createFile(atPath: file.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return file
        } catch {
            throw .io(summary: "Couldn’t write a temporary patch file.")
        }
    }

    static func runApply(
        _ arguments: [String], patch: URL, engine: GitEngine, in directory: String, gitDirectory: String
    ) async throws(GitCoreError) {
        do {
            _ = try await engine.run(
                GitCommand(
                    ["apply", "--whitespace=nowarn"] + arguments + [patch.path], in: directory, kind: .write,
                    timeout: .seconds(120)))
        } catch {
            throw mapWriteError(error, gitDirectory: gitDirectory)
        }
    }
}
