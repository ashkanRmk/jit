import Darwin
import Foundation

/// Open each parent relative to the repository descriptor, never following symlinks. Hash regular
/// files in bounded chunks; a short/read error cannot masquerade as a complete fingerprint.
struct ResetFileState: Sendable, Equatable {
    let type: UInt16
    let mode: UInt16
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let changed: Int64
    let content: UInt64
    static let missing = Self(type: 0, mode: 0, inode: 0, size: 0, modified: 0, changed: 0, content: 0)

    static func read(_ path: String, root: String, hashContent: Bool = true) throws(GitCoreError) -> Self {
        try validate(path)
        var parent = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw .io(summary: "Couldn't open the repository to prepare reset.") }
        defer { close(parent) }
        let components = path.split(separator: "/")
        for part in components.dropLast() {
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return .missing }
                throw .io(summary: "Couldn't inspect “\(path)” safely.")
            }
            close(parent); parent = next
        }
        guard let leaf = components.last else { throw .refused(summary: "A reset path is empty.") }
        let name = String(leaf)
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            throw .io(summary: "Couldn't inspect “\(path)”.")
        }
        let type = UInt16(info.st_mode) & UInt16(S_IFMT)
        var hash = ContentHash()
        if hashContent && type == UInt16(S_IFREG) {
            let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw .staleSnapshot(summary: "“\(path)” changed while preparing reset.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino,
                UInt16(opened.st_mode) & UInt16(S_IFMT) == UInt16(S_IFREG)
            else {
                throw .staleSnapshot(summary: "“\(path)” changed while preparing reset.")
            }
            do {
                while true {
                    if Task.isCancelled { throw GitCoreError.cancelled }
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                    chunk.withUnsafeBytes { hash.combine($0) }
                }
            } catch let error as GitCoreError { throw error } catch {
                throw .io(summary: "Couldn't completely read “\(path)” before reset.")
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, info.st_ino == after.st_ino, info.st_size == after.st_size,
                info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
            else {
                throw .staleSnapshot(summary: "“\(path)” changed while preparing reset.")
            }
        } else if hashContent && type == UInt16(S_IFLNK) {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return readlinkat(parent, name, base, buffer.count)
            }
            guard count >= 0, count < bytes.count else { throw .io(summary: "Couldn't read the link “\(path)”.") }
            bytes.prefix(count).withContiguousStorageIfAvailable { hash.combine(UnsafeRawBufferPointer($0)) }
        }
        return Self(
            type: type, mode: UInt16(info.st_mode), inode: UInt64(info.st_ino), size: info.st_size,
            modified: nanos(info.st_mtimespec), changed: nanos(info.st_ctimespec), content: hash.value)
    }

    static func nanos(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
    static func validate(_ path: String) throws(GitCoreError) {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            })
        else { throw .refused(summary: "A repository path cannot be safely previewed for reset.") }
    }
}
