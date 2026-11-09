import CoreServices
import Foundation
import GitCore
import GitTestKit
import Testing

@testable import Services

@Suite struct FSEventClassifierTests {
    let regular = RepositoryLayout(worktree: "/r", gitDirectory: "/r/.git", commonDirectory: "/r/.git")
    let linked = RepositoryLayout(
        worktree: "/wt", gitDirectory: "/main/.git/worktrees/wt", commonDirectory: "/main/.git")
    let bare = RepositoryLayout(worktree: nil, gitDirectory: "/b.git", commonDirectory: "/b.git")

    func classify(_ path: String, _ layout: RepositoryLayout, flags: Int = 0) -> FSEventClassifier.Outcome {
        FSEventClassifier.classify(path: path, flags: UInt32(flags), layout: layout)
    }

    @Test func ignoresObjectsLocksAndLogs() {
        #expect(classify("/r/.git/objects/ab", regular) == .ignore)
        #expect(classify("/r/.git/objects/pack/", regular) == .ignore)
        #expect(classify("/r/.git/index.lock", regular) == .ignore)
        #expect(classify("/r/.git/refs/heads/main.lock", regular) == .ignore)
        #expect(classify("/r/.git/logs/refs/heads", regular) == .ignore)
        #expect(classify("/r/.git/FETCH_HEAD", regular) == .ignore)
        #expect(classify("/elsewhere/file", regular) == .ignore)
    }

    @Test func classifiesGitFiles() {
        #expect(classify("/r/.git/index", regular) == .invalidate([.index]))
        #expect(classify("/r/.git/HEAD", regular) == .invalidate([.head]))
        #expect(classify("/r/.git/refs/heads/feature", regular) == .invalidate([.refs]))
        #expect(classify("/r/.git/packed-refs", regular) == .invalidate([.refs]))
        #expect(classify("/r/.git/config", regular) == .invalidate([.config]))
        #expect(classify("/r/.git/info/exclude", regular) == .invalidate([.worktree]))
        for marker in [
            "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply/next",
        ] {
            #expect(classify("/r/.git/\(marker)", regular) == .invalidate([.operationState]), "\(marker)")
        }
    }

    @Test func directoryLevelEventForGitDirectoryInvalidatesItsTopLevelKinds() {
        // Directory-level streams report `/r/.git/` when `.git/index` or `.git/HEAD` change.
        #expect(classify("/r/.git/", regular) == .invalidate(FSEventClassifier.gitDirectoryLevel))
        #expect(classify("/r/.git/refs/heads/", regular) == .invalidate([.refs]))
    }

    @Test func worktreePaths() {
        #expect(classify("/r/src/", regular) == .invalidate([.worktree]))
        #expect(classify("/r", regular) == .invalidate([.worktree]))
        #expect(classify("/r/.github/workflows", regular) == .invalidate([.worktree]))  // not the git dir
        #expect(classify("/rx/file", regular) == .ignore)  // prefix of another folder
    }

    @Test func linkedWorktreeLayout() {
        #expect(classify("/main/.git/worktrees/wt", linked) == .invalidate(FSEventClassifier.gitDirectoryLevel))
        #expect(classify("/main/.git/worktrees/wt/index", linked) == .invalidate([.index]))
        #expect(classify("/main/.git/worktrees/other/index", linked) == .ignore)
        #expect(classify("/main/.git/refs/heads", linked) == .invalidate([.refs]))
        #expect(classify("/main/.git/objects/aa", linked) == .ignore)
        #expect(classify("/wt/file.txt", linked) == .invalidate([.worktree]))
        #expect(classify("/main/src/file.txt", linked) == .ignore)  // the main worktree isn't ours
        // The per-worktree git directory is inside the common directory, so two roots suffice.
        #expect(linked.watchedRoots == ["/wt", "/main/.git"])
    }

    @Test func bareLayout() {
        #expect(bare.watchedRoots == ["/b.git"])
        #expect(classify("/b.git/refs/heads", bare) == .invalidate([.refs]))
        #expect(classify("/b.git/HEAD", bare) == .invalidate([.head]))
    }

    @Test func flags() {
        #expect(classify("/r/src", regular, flags: kFSEventStreamEventFlagMustScanSubDirs) == .rescan)
        #expect(classify("/r/.git/objects", regular, flags: kFSEventStreamEventFlagKernelDropped) == .rescan)
        #expect(classify("/r", regular, flags: kFSEventStreamEventFlagRootChanged) == .rootChanged)
    }

    @Test func watchedRootsDeduplicateNestedGitDirectory() {
        #expect(regular.watchedRoots == ["/r"])
    }
}

/// Lifecycle and live updates against real repositories.
@MainActor @Suite(.serialized) struct RepositorySessionTests {
    func repository(_ sandbox: GitSandbox) async throws -> TestRepo {
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        return repo
    }

    func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + TimingBudget.latency(timeout)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func testLifecycleTransitions() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        #expect(session.lifecycle == .unloaded)
        #expect(session.statusDot == .notLoaded)
        session.activate()
        #expect(session.lifecycle == .loading)
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil })
        #expect(session.isWatching)
        #expect(session.statusDot == .clean)
        session.deactivate()
        #expect(session.lifecycle == .inactive)
        #expect(!session.isWatching)
        #expect(session.status != nil)  // kept for instant re-display
        session.suspend()
        #expect(session.lifecycle == .suspended)
        let before = session.refreshCount
        session.activate()
        #expect(session.lifecycle == .active)
        #expect(session.isWatching)
        // Exactly one revalidation on re-activation.
        #expect(try await waitUntil { session.refreshCount == before + 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.refreshCount == before + 1)
        session.close()
        #expect(session.lifecycle == .closed)
        #expect(!session.isWatching && !session.hasHandle)
        session.activate()
        #expect(session.lifecycle == .closed)
    }

    @Test func testStageAndUnstageRefreshStatusAndClearBusy() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, watchesFileSystem: false)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil })
        try repo.write("staged.txt", "new\n")
        session.reload()
        #expect(try await waitUntil { session.status?.summary?.untracked == 1 })

        try await session.stage(["staged.txt"])
        #expect(!session.isBusy)
        #expect(try await waitUntil { session.status?.summary?.staged == 1 })
        try await session.unstage(["staged.txt"])
        #expect(try await waitUntil { session.status?.summary?.untracked == 1 && session.status?.summary?.staged == 0 })
        #expect(session.pendingWrites.isEmpty)
    }

    @Test func testDotIsNotLoadedUntilFirstStatus() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        let session = RepositorySession(path: repo.path, engine: sandbox.engine, handle: handle)
        #expect(session.info != nil && session.status == nil)
        #expect(session.statusDot == .notLoaded)  // never "No local changes" before Git was asked
    }

    @Test func testDeactivateCancelsInFlightWork() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let marker = sandbox.root + "/survived"
        let real = try GitLocator(configuration: .init(allowsEnvironmentOverride: false)).locate().path
        let wrapper = sandbox.root + "/slow-git"
        try """
        #!/bin/sh
        for a in "$@"; do if [ "$a" = status ]; then sleep 2; touch '\(marker)'; fi; done
        exec '\(real)' "$@"
        """.write(toFile: wrapper, atomically: true, encoding: .utf8)
        chmod(wrapper, 0o755)
        var configuration = sandbox.engineConfiguration()
        configuration.locator = .init(allowsEnvironmentOverride: true, environment: ["JIT_GIT_PATH": wrapper])
        let session = RepositorySession(path: repo.path, engine: GitEngine(configuration: configuration))
        session.activate()
        #expect(try await waitUntil { session.hasHandle })  // discovery done, status running
        try await Task.sleep(for: .milliseconds(200))
        session.deactivate()
        #expect(session.lifecycle == .inactive)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!FileManager.default.fileExists(atPath: marker), "status process outlived deactivate")
        #expect(session.status == nil)
    }

    @Test func testExternalEditUpdatesStatusWithinOneSecond() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil && session.isWatching })
        try await Task.sleep(for: .milliseconds(300))  // let the stream settle
        let clock = ContinuousClock()
        let start = clock.now
        try repo.write("a.txt", "edited elsewhere\n")
        #expect(try await waitUntil(.seconds(2)) { session.status?.summary?.unstaged == 1 })
        #expect(clock.now - start < TimingBudget.latency(.seconds(1)))
        #expect(session.statusDot == .changes)
        // A commit made outside Jit (Terminal) updates the header too.
        try await repo.commit("Outside")
        #expect(try await waitUntil(.seconds(2)) { session.status?.summary?.isClean == true })
    }

    @Test func testNoEventsWhileInactive() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil })
        session.deactivate()
        let refreshes = session.refreshCount
        try repo.write("a.txt", "while hidden\n")
        try await Task.sleep(for: .milliseconds(700))
        #expect(session.refreshCount == refreshes)
        session.activate()
        #expect(try await waitUntil { session.status?.summary?.unstaged == 1 })
    }

    @Test func testDeletedRepositoryBecomesError() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.isWatching })
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(atPath: repo.path)
        #expect(try await waitUntil { session.error != nil })
        #expect(session.statusDot == .danger)
    }

    @Test func testMissingPathLoadsAsError() async throws {
        let sandbox = try GitSandbox()
        let session = RepositorySession(path: sandbox.root + "/missing", engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.error != nil })
        #expect(session.lifecycle == .active)
        #expect(!session.isWatching)
    }

    @Test func testChurnIsCoalescedAndEndsCorrect() async throws {
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil && session.isWatching })
        try await Task.sleep(for: .milliseconds(300))
        let before = session.refreshCount
        // ~1.5 s of continuous writes: 30 bursts of 100 files.
        for burst in 0..<30 {
            for index in 0..<100 { try repo.write("churn/\(burst)/f\(index).txt", "\(index)") }
            try await Task.sleep(for: .milliseconds(50))
        }
        // `churn/` is one untracked entry (untracked directories collapse).
        #expect(try await waitUntil(.seconds(5)) { session.status?.summary?.untracked == 1 })
        try await Task.sleep(for: .milliseconds(800))
        let refreshes = session.refreshCount - before
        // 3,000 file writes in 30 bursts: at most a refresh or two per burst, never one per file.
        #expect(refreshes >= 1 && refreshes <= 45, "refreshes during churn: \(refreshes)")
    }

    @Test func testIndexWritesByStatusDoNotLoop() async throws {
        // Status must not rewrite `.git/index` (which would fire FSEvents → status → …).
        let sandbox = try GitSandbox()
        let repo = try await repository(sandbox)
        try await Task.sleep(for: .milliseconds(1100))
        try repo.write("a.txt", "a\n")  // racily-clean entry: plain `git status` would refresh the index
        let session = RepositorySession(path: repo.path, engine: sandbox.engine)
        session.activate()
        #expect(try await waitUntil { session.lifecycle == .active && session.status != nil })
        try await Task.sleep(for: .seconds(1.5))
        #expect(session.refreshCount <= 2, "status refreshes kept firing: \(session.refreshCount)")
    }
}
