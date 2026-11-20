import Darwin
import Foundation

extension RepositoryHandle {
    /// Reads the right-hand version of a single-file diff, including unchanged bytes omitted by Git.
    public func diffFileContent(_ target: DiffTarget, path: String, limit: Int) async throws(GitCoreError) -> [UInt8] {
        guard limit >= 0, limit < Int.max else { throw .internalError(summary: "Invalid file size limit.") }
        switch target {
        case .staged:
            return try await runRead(["cat-file", "blob", ":0:" + path], limit: limit)
        case .commit(let oid, _), .commits(_, let oid, _, _):
            let revision = oid.hex(try await objectFormat())
            return try await runRead(["cat-file", "blob", revision + ":" + path], limit: limit)
        case .unstaged, .commitToWorktree:
            let root = try requireWorkingTree()
            return try Self.readDiffWorktreeFile(path, root: root, limit: limit)
        }
    }

    private static func readDiffWorktreeFile(_ path: String, root: String, limit: Int) throws(GitCoreError) -> [UInt8] {
        let failure = GitCoreError.io(summary: "Couldn’t read “\(path)” in the working tree.")
        guard !path.contains("\0"),
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            })
        else { throw failure }
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw failure }
        defer { close(directory) }
        let fd = openat(directory, path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw failure }
        guard info.st_size <= limit else { throw .outputTooLarge(limitBytes: limit) }
        var bytes = Data()
        do {
            while bytes.count <= limit,
                let chunk = try file.read(upToCount: limit + 1 - bytes.count), !chunk.isEmpty
            {
                bytes.append(chunk)
            }
        } catch {
            throw failure
        }
        guard bytes.count <= limit else { throw .outputTooLarge(limitBytes: limit) }
        return Array(bytes)
    }
}
