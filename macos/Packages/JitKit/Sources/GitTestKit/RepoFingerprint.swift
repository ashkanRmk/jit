import Foundation
import GitCore

/// Everything an abort, refusal or cancel must leave untouched (Phase 4 test plan): HEAD (symbolic and
/// OID), every ref, the index (mode, OID, stage, path), the working tree (every file's bytes, untracked
/// included, `.git` excluded) and the operation-state files. `before == after` proves nothing changed.
public struct RepoFingerprint: Equatable, CustomStringConvertible {
    public let head: String
    public let refs: String
    public let index: String
    public let workingTree: [String: Data]
    public let stateFiles: [String: Data]

    public static let stateFileNames = [
        "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
        "BISECT_LOG", "AUTO_MERGE", "rebase-merge", "rebase-apply", "sequencer",
    ]

    public static func capture(_ repo: TestRepo) async throws -> RepoFingerprint {
        let symbolic = (try? await repo.git("symbolic-ref", "-q", "HEAD")) ?? "(detached)"
        let oid = (try? await repo.git("rev-parse", "-q", "--verify", "HEAD")) ?? "(unborn)"
        let refs = try await repo.git("for-each-ref", "--format=%(refname) %(objectname)")
        let index = try await repo.git("ls-files", "-s", "-z")
        let gitDirectory = try await repo.git("rev-parse", "--absolute-git-dir")
        return RepoFingerprint(
            head: "\(symbolic) \(oid)", refs: refs, index: index,
            workingTree: files(under: repo.path, skipping: ".git"),
            stateFiles: stateFiles(in: gitDirectory))
    }

    static func files(under root: String, skipping: String) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return result }
        for case let relative as String in enumerator {
            if relative == skipping || relative.hasPrefix(skipping + "/") {
                if relative == skipping { enumerator.skipDescendants() }
                continue
            }
            let path = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                // Dangling symlink: record its target.
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                    result[relative] = Data(("symlink:" + target).utf8)
                }
                continue
            }
            if let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
                type == .typeSymbolicLink
            {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
                result[relative] = Data(("symlink:" + target).utf8)
                continue
            }
            if isDirectory.boolValue { continue }
            var data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            if let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int {
                data.append(contentsOf: Array("\nmode:\(mode & 0o111 != 0 ? "x" : "-")".utf8))
            }
            result[relative] = data
        }
        return result
    }

    static func stateFiles(in gitDirectory: String) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in stateFileNames {
            let path = gitDirectory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                for (relative, data) in files(under: path, skipping: "\u{0}") { result[name + "/" + relative] = data }
            } else {
                result[name] = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            }
        }
        return result
    }

    public var description: String {
        "HEAD \(head)\nrefs:\n\(refs)\nindex entries: \(index.split(separator: "\0").count)\n"
            + "files: \(workingTree.keys.sorted())\nstate: \(stateFiles.keys.sorted())"
    }

    /// What differs (for test failure messages).
    public func difference(from other: RepoFingerprint) -> String {
        var lines: [String] = []
        if head != other.head { lines.append("HEAD \(other.head) → \(head)") }
        if refs != other.refs { lines.append("refs differ") }
        if index != other.index { lines.append("index differs") }
        for key in Set(workingTree.keys).union(other.workingTree.keys).sorted()
        where workingTree[key] != other.workingTree[key] {
            lines.append("file \(key) differs")
        }
        for key in Set(stateFiles.keys).union(other.stateFiles.keys).sorted()
        where stateFiles[key] != other.stateFiles[key] {
            lines.append("state \(key) differs")
        }
        return lines.joined(separator: "\n")
    }
}
