import Foundation
import GitTestKit
import Synchronization
import Testing

@testable import GitCore

/// P6.1: every performance interval is declared once, well named, and begin/end are paired — including
/// the GitCore spans emitted by a real status refresh. Serialized: the observer hook is process-global.
@Suite(.serialized) struct SignpostNamingTests {
    @Test func intervalsAreUniqueAndWellFormed() {
        let names = Signposts.all.map(\.name)
        #expect(Set(names).count == names.count)
        for interval in Signposts.all {
            #expect(interval.name.hasPrefix(interval.category.rawValue + "."), "\(interval.name)")
            #expect(interval.name.allSatisfy { $0.isLowercase || $0.isUppercase || $0 == "." })
        }
        // The design §4.1 list.
        for required in [
            "launch.firstWindow", "repo.open", "graph.firstPage", "graph.page", "diff.switch", "tab.switch",
            "core.historyPage", "core.laneLayout", "core.status", "core.diffParse", "core.patchBuild", "core.git",
        ] {
            #expect(names.contains(required), "\(required) missing")
        }
    }

    @Test func beginAndEndArePairedAndDoubleEndIsIgnored() {
        let events = Locked<[Signposts.Event]>([])
        Signposts.setObserver { event in events.withLock { $0.append(event) } }
        defer { Signposts.setObserver(nil) }
        let token = Signposts.begin(Signposts.corePatchBuild)
        Signposts.end(token)
        Signposts.end(token)
        let value = try? Signposts.measure(Signposts.coreDiffParse) { () throws(GitCoreError) in 42 }
        #expect(value == 42)
        let mine = events.withLock { $0 }.filter {
            switch $0 {
            case .begin(let name, _), .end(let name, _): name == "core.patchBuild" || name == "core.diffParse"
            }
        }
        #expect(mine.count == 4)
        #expect(mine.first == .begin(name: "core.patchBuild", serial: token.serial))
        #expect(mine[1] == .end(name: "core.patchBuild", serial: token.serial))
    }

    @Test func statusRefreshEmitsPairedCoreSpans() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commit("Initial")
        let engine = GitEngine(configuration: repo.sandbox.engineConfiguration())
        let handle = try await engine.openRepository(at: URL(fileURLWithPath: repo.path))

        let events = Locked<[Signposts.Event]>([])
        Signposts.setObserver { event in events.withLock { $0.append(event) } }
        _ = try await handle.status()
        Signposts.setObserver(nil)

        let recorded = events.withLock { $0 }
        var begun: [UInt64: String] = [:]
        for event in recorded {
            switch event {
            case .begin(let name, let serial): begun[serial] = name
            case .end(let name, let serial):
                // Every end belongs to a begin seen earlier (parallel tests may add unrelated pairs).
                if let started = begun[serial] { #expect(started == name) }
            }
        }
        let ended = Set(recorded.compactMap { if case .end(let name, _) = $0 { name } else { nil } })
        #expect(ended.contains("core.status"))
        #expect(ended.contains("core.git"))
    }

    @Test func gitSubcommandNeverLeaksArguments() {
        let status = Signposts.gitSubcommand(["-c", "credential.helper=", "--no-optional-locks", "status", "-z"])
        #expect(status == "status")
        #expect(Signposts.gitSubcommand(["-C", "/private/repo", "log", "--", "secret.txt"]) == "log")
        #expect(Signposts.gitSubcommand(["for-each-ref"]) == "for-each-ref")
        #expect(Signposts.gitSubcommand(["/path/to/Thing"]) == "git")
        #expect(Signposts.gitSubcommand(["--version"]) == "git")
        #expect(Signposts.gitSubcommand([]) == "git")
    }
}
