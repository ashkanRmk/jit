import CoreServices
import Dispatch
import Foundation
import GitCore
import Synchronization

/// Directories a repository's events can come from.
public struct RepositoryLayout: Sendable, Equatable {
    public var worktree: String?
    public var gitDirectory: String
    public var commonDirectory: String

    public init(worktree: String?, gitDirectory: String, commonDirectory: String) {
        self.worktree = worktree
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }

    public init(_ info: RepositoryInfo) {
        self.init(worktree: info.topLevel, gitDirectory: info.gitDirectory, commonDirectory: info.commonDirectory)
    }

    /// Roots to watch: the worktree plus any git/common directory outside it (linked worktrees,
    /// `--separate-git-dir`); the git directory alone for bare repositories.
    public var watchedRoots: [String] {
        var roots: [String] = []
        for candidate in [worktree, gitDirectory, commonDirectory].compactMap({ $0 }) {
            let path = Self.canonical(candidate)
            if !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                roots.removeAll { $0.hasPrefix(path + "/") }
                roots.append(path)
            }
        }
        return roots
    }

    /// The form FSEvents reports paths in (symlinks resolved, e.g. `/private/var/…`).
    public var canonical: RepositoryLayout {
        RepositoryLayout(
            worktree: worktree.map(Self.canonical), gitDirectory: Self.canonical(gitDirectory),
            commonDirectory: Self.canonical(commonDirectory))
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Maps one FSEvents path to cache invalidations (pure; ADR-0008).
public enum FSEventClassifier {
    public enum Outcome: Sendable, Equatable {
        case ignore
        case invalidate(Set<InvalidationKind>)
        /// Events were dropped or coalesced above the reported path: revalidate everything.
        case rescan
        /// A watched root was moved or deleted.
        case rootChanged
    }

    /// Everything a change at the top level of a git directory can mean when FSEvents reports only the
    /// directory (directory-level streams don't name the file).
    static let gitDirectoryLevel: Set<InvalidationKind> = [.index, .head, .refs, .config, .operationState]

    public static func classify(path rawPath: String, flags: UInt32, layout: RepositoryLayout) -> Outcome {
        if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 { return .rootChanged }
        let rescanFlags =
            UInt32(kFSEventStreamEventFlagMustScanSubDirs) | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
        if flags & rescanFlags != 0 { return .rescan }

        let path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        // The per-worktree git directory first: for linked worktrees it lives inside the common directory.
        let isLinked = layout.gitDirectory != layout.commonDirectory
        for (directory, isCommonOnly) in [(layout.gitDirectory, false), (layout.commonDirectory, isLinked)] {
            if path == directory { return .invalidate(gitDirectoryLevel) }
            if path.hasPrefix(directory + "/") {
                return classifyInGitDirectory(String(path.dropFirst(directory.count + 1)), isCommonOnly: isCommonOnly)
            }
        }
        if let worktree = layout.worktree, path == worktree || path.hasPrefix(worktree + "/") {
            return .invalidate([.worktree])
        }
        return .ignore
    }

    private static func classifyInGitDirectory(_ relative: String, isCommonOnly: Bool) -> Outcome {
        if relative.hasSuffix(".lock") { return .ignore }
        let first = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relative
        switch first {
        case "objects", "logs", "hooks", "lfs", "fsmonitor--daemon", "ORIG_HEAD", "FETCH_HEAD", "COMMIT_EDITMSG",
            "description", "gitk.cache":
            return .ignore
        case "index", "sharedindex": return .invalidate([.index])
        case "HEAD": return .invalidate([.head])
        case "refs", "packed-refs", "reftable": return .invalidate([.refs])
        case "config", "config.worktree": return .invalidate([.config])
        case "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
            "BISECT_LOG", "BISECT_START", "rebase-merge", "rebase-apply", "sequencer":
            return .invalidate([.operationState])
        // `info/exclude` changes what counts as untracked; submodule git dirs change submodule state.
        case "info", "modules": return .invalidate([.worktree])
        // Other worktrees' private state.
        case "worktrees": return isCommonOnly ? .ignore : .invalidate([.worktree])
        default: return .ignore
        }
    }
}

/// One FSEvents stream for one visible repository (ADR-0008): directory-level events, 0.2 s FSEvents
/// latency (its own coalescing — no timers of ours), delivered on a private serial queue. Each batch
/// is classified and handed to `handler` once.
public final class RepositoryWatcher: @unchecked Sendable {
    public struct Batch: Sendable, Equatable {
        public var kinds: Set<InvalidationKind> = []
        public var rootChanged = false
    }

    /// FSEvents callbacks delivered process-wide (debug counter for "no work in background" checks).
    public static let callbackCount = Atomic<Int>(0)

    public let layout: RepositoryLayout
    private let latency: CFTimeInterval
    private let handler: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "jit.fsevents", qos: .utility)
    /// Touched only on `queue` (callbacks) or before start / after stop.
    private var stream: FSEventStreamRef?
    private let lock = Mutex<Bool>(false)  // isRunning

    public init(layout: RepositoryLayout, latency: CFTimeInterval = 0.2, handler: @escaping @Sendable (Batch) -> Void) {
        self.layout = layout.canonical
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { $0 } }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            watcher.deliver(count: count, paths: array, flags: flags)
        }
        let roots = layout.watchedRoots as CFArray
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, roots, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, createFlags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        lock.withLock { $0 = true }
        return true
    }

    /// Stops and releases the stream. After it returns no callback is running or will run.
    public func stop() {
        let wasRunning = lock.withLock { running in
            defer { running = false }
            return running
        }
        guard wasRunning, let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // Drain any callback already executing on the queue before releasing.
        queue.sync {}
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(count: Int, paths: NSArray, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard isRunning else { return }
        Self.callbackCount.add(1, ordering: .relaxed)
        var batch = Batch()
        for index in 0..<count {
            guard let path = paths[index] as? String else { continue }
            switch FSEventClassifier.classify(path: path, flags: flags[index], layout: layout) {
            case .ignore: break
            case .invalidate(let kinds): batch.kinds.formUnion(kinds)
            case .rescan: batch.kinds.formUnion(InvalidationKind.allCases)
            case .rootChanged:
                batch.rootChanged = true
                batch.kinds.formUnion(InvalidationKind.allCases)
            }
        }
        if !batch.kinds.isEmpty || batch.rootChanged { handler(batch) }
    }
}
