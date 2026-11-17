import Foundation

/// A previous committed state, recorded while the repository's single writer is held. These values do
/// not keep objects alive: Git's reflog expiration and garbage collection still apply.
public struct RecoveryPoint: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public let operationID: UUID
    public let operation: String
    public let refName: String
    public let oldOID: String
    public let newOID: String?
    public let timestamp: Date
}

struct RecoverySnapshot: Sendable {
    let head: String?
    let headRef: String?
    var refs: [String: String]
    let stashes: Set<String>
}

extension RepositoryHandle {
    nonisolated func recoverySnapshot(includeStashes: Bool = false) async throws(GitCoreError) -> RecoverySnapshot {
        async let head = Self.readHead(engine: gitEngine, in: workingDirectory)
        async let symbolic = gitEngine.run(
            GitCommand(
                ["symbolic-ref", "-q", "HEAD"], in: workingDirectory,
                kind: .read, acceptedExitCodes: [0, 1]))
        async let refBytes = runRead(["for-each-ref", "--format=%(refname)%00%(objectname)"], limit: 64 * 1024 * 1024)
        let bytes: [UInt8]
        let headOID: String?
        let headRef: String?
        do {
            bytes = try await refBytes
            headOID = try await head
            let output = try await symbolic
            headRef = output.exitCode == 0 ? output.stdoutText.trimmingCharacters(in: .newlines) : nil
        } catch let error as GitCoreError { throw error } catch {
            throw .internalError(summary: "Couldn't read recovery metadata.")
        }
        var refs: [String: String] = [:]
        for line in bytes.split(separator: 0x0A) {
            let fields = line.split(separator: 0)
            guard fields.count == 2 else { continue }
            refs[String(decoding: fields[0], as: UTF8.self)] = String(decoding: fields[1], as: UTF8.self)
        }
        var stashes: Set<String> = []
        if includeStashes, refs["refs/stash"] != nil {
            let ids = try await runRead(
                ReadOnlyPolicy.configOverrides + ["stash", "list", "-z", "--format=%H"],
                limit: 2 * 1024 * 1024)
            stashes = Set(ids.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        }
        return RecoverySnapshot(head: headOID, headRef: headRef, refs: refs, stashes: stashes)
    }

    func recordRecovery(_ before: RecoverySnapshot, after: RecoverySnapshot?, operation: String) {
        let operationID = UUID()
        let timestamp = Date()
        var changed: [RecoveryPoint] = []
        var refs = before.refs
        // Detached HEAD and branch switches also have an old committed state worth recovering.
        if let head = before.head, before.head != after?.head || before.headRef != after?.headRef {
            let name = before.headRef ?? "HEAD"
            changed.append(
                RecoveryPoint(
                    id: UUID(), operationID: operationID, operation: operation,
                    refName: name, oldOID: head, newOID: after?.head, timestamp: timestamp))
            refs[name] = nil
        }
        for name in refs.keys.sorted() {
            guard let old = refs[name], after == nil || old != after?.refs[name] else { continue }
            changed.append(
                RecoveryPoint(
                    id: UUID(), operationID: operationID, operation: operation,
                    refName: name, oldOID: old, newOID: after?.refs[name], timestamp: timestamp))
        }
        // Removing a non-tip stash changes its reflog but leaves refs/stash untouched. Record those
        // exact commits too; comparing ref tips alone would lose this important recovery case.
        for oid in before.stashes.subtracting(after?.stashes ?? []).sorted() {
            guard !changed.contains(where: { $0.refName == "refs/stash" && $0.oldOID == oid }) else { continue }
            changed.append(
                RecoveryPoint(
                    id: UUID(), operationID: operationID, operation: operation,
                    refName: "refs/stash", oldOID: oid, newOID: nil, timestamp: timestamp))
        }
        // Keep the previous HEAD first, so a multi-ref operation's primary recovery is predictable.
        recoveryPoints.insert(contentsOf: changed.prefix(Self.recoveryPointLimit), at: 0)
        if recoveryPoints.count > Self.recoveryPointLimit {
            recoveryPoints.removeLast(recoveryPoints.count - Self.recoveryPointLimit)
        }
    }
}
