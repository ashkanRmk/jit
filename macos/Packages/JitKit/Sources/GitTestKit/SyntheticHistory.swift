import Foundation

/// Large deterministic histories for benchmarks and scale tests (1k / 10k / 100k commits).
///
/// Shape: `main` plus up to `concurrentFeatures` feature branches alive at once. Each step commits to
/// `main` (40 %) or to one live feature branch; every `mergeEvery`-th commit merges the oldest live
/// feature into `main` and starts a new one from `main`. The last `branches` feature branches keep
/// their refs (merged ones included), `origin/main` trails `main`, and `tags` tags are spread evenly
/// over `main`. A fixed-seed generator makes the output byte-for-byte reproducible.
public struct SyntheticHistory: Sendable {
    public var commits: Int
    public var branches: Int
    public var mergeEvery: Int
    public var tags: Int
    public var concurrentFeatures: Int
    public var seed: UInt64

    public init(
        commits: Int, branches: Int = 50, mergeEvery: Int = 20, tags: Int = 200, concurrentFeatures: Int = 8,
        seed: UInt64 = 0x4A49_5421
    ) {
        self.commits = commits
        self.branches = branches
        self.mergeEvery = mergeEvery
        self.tags = tags
        self.concurrentFeatures = concurrentFeatures
        self.seed = seed
    }

    /// SplitMix64 — tiny, deterministic, independent of Swift's seeded hashing.
    public struct Generator: Sendable {
        public var state: UInt64
        public init(state: UInt64) { self.state = state }
        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        public mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    static let authors = [
        "Ana Ruiz <ana@example.invalid>", "Bo Chen <bo@example.invalid>", "Chidi Okafor <chidi@example.invalid>",
        "Dana Levi <dana@example.invalid>", "Eitan Shah <eitan@example.invalid>",
        "Freya Lund <freya@example.invalid>", "Gus Moreau <gus@example.invalid>",
        "Hana Sato <hana@example.invalid>",
    ]
    static let verbs = ["Fix", "Add", "Refactor", "Update", "Remove", "Improve", "Document", "Speed up"]
    static let nouns = [
        "tab overflow", "status parser", "lane colours", "ref labels", "commit store", "file watcher",
        "search field", "inspector layout", "history reader", "toolbar chips",
    ]

    /// `git fast-import` input. Marks are 1-based commit numbers; HEAD is left for the caller (`main`).
    public func fastImportStream() -> [UInt8] {
        var rng = Generator(state: seed)
        var out = FastImportWriter()
        out.bytes.reserveCapacity(commits * 260)
        struct Feature {
            let name: String
            var tip: Int?  // mark
            let base: Int  // mark on main it started from
        }
        var mainTip: Int?
        var live: [Feature] = []
        var featureSerial = 0
        var finishedFeatures: [(name: String, tip: Int)] = []
        var mainMarks: [Int] = []
        var mark = 0

        func emit(ref: String, parents: [Int], subject: String) -> Int {
            mark += 1
            let time = Topology.baseTime + Int64(mark) * 60
            out.commit(
                ref: ref, mark: mark, author: Self.authors[rng.below(Self.authors.count)], time: time,
                message: subject, parents: parents, file: "f\(mark % 97).txt", contents: "c\(mark)")
            return mark
        }

        func subject() -> String {
            "\(Self.verbs[rng.below(Self.verbs.count)]) \(Self.nouns[rng.below(Self.nouns.count)]) (#\(mark + 1))"
        }

        while mark < commits {
            if mainTip == nil {
                mainTip = emit(ref: "refs/heads/main", parents: [], subject: "Initial commit")
                mainMarks.append(mainTip!)
                continue
            }
            let isMergeStep = (mark + 1) % mergeEvery == 0
            if isMergeStep, let index = live.firstIndex(where: { $0.tip != nil }) {
                let feature = live.remove(at: index)
                mainTip = emit(
                    ref: "refs/heads/main", parents: [mainTip!, feature.tip!],
                    subject: "Merge branch '\(feature.name)'")
                mainMarks.append(mainTip!)
                finishedFeatures.append((feature.name, feature.tip!))
                continue
            }
            while live.count < concurrentFeatures {
                featureSerial += 1
                live.append(Feature(name: "feature/\(featureName(featureSerial))", tip: nil, base: mainTip!))
            }
            if rng.below(10) < 4 {
                mainTip = emit(ref: "refs/heads/main", parents: [mainTip!], subject: subject())
                mainMarks.append(mainTip!)
            } else {
                let index = rng.below(live.count)
                let parent = live[index].tip ?? live[index].base
                live[index].tip = emit(ref: "refs/heads/\(live[index].name)", parents: [parent], subject: subject())
            }
        }

        // Refs: keep only the newest `branches` feature branches (finished first, then live ones).
        let liveWithCommits = live.compactMap { feature in feature.tip.map { (feature.name, $0) } }
        let kept = (finishedFeatures + liveWithCommits).suffix(branches)
        let keptNames = Set(kept.map(\.0))
        var deleted = Set<String>()
        for (name, _) in finishedFeatures + liveWithCommits where !keptNames.contains(name) {
            // `from` the null id deletes the ref fast-import created for the branch.
            if deleted.insert(name).inserted {
                out.line("reset refs/heads/\(name)")
                out.line("from 0000000000000000000000000000000000000000")
                out.bytes.append(0x0A)
            }
        }
        for (name, tip) in kept { out.reset(ref: "refs/heads/\(name)", mark: tip) }
        if let mainTip { out.reset(ref: "refs/heads/main", mark: mainTip) }
        if mainMarks.count > 6 { out.reset(ref: "refs/remotes/origin/main", mark: mainMarks[mainMarks.count - 6]) }
        if tags > 0, !mainMarks.isEmpty {
            let step = max(1, mainMarks.count / tags)
            var version = 0
            for index in stride(from: 0, to: mainMarks.count, by: step) where version < tags {
                version += 1
                let name = "v\(version / 100).\(version / 10 % 10).\(version % 10)"
                if version % 4 == 0 {
                    out.annotatedTag(
                        name: name, mark: mainMarks[index], tagger: Topology.identity,
                        time: Topology.baseTime + Int64(mainMarks[index]) * 60, message: "Release \(name)")
                } else {
                    out.reset(ref: "refs/tags/\(name)", mark: mainMarks[index])
                }
            }
        }
        return out.bytes
    }

    private func featureName(_ serial: Int) -> String {
        let areas = ["graph", "tabs", "diff", "status", "search", "navigator", "inspector", "perf"]
        return "\(areas[serial % areas.count])-\(serial)"
    }

    /// `git init` at `path` (must not exist or be empty), imports, sets HEAD to `main` and checks it out.
    /// Returns the HEAD object id.
    @discardableResult
    public func build(at path: String, environment: [String: String] = SyntheticHistory.fixtureEnvironment) throws
        -> String
    {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: path, environment: environment)
        let marks = try FastImport.run(fastImportStream(), in: path, environment: environment)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: path, environment: environment)
        try runGit(["reset", "-q", "--hard"], in: path, environment: environment)
        _ = marks
        return try runGit(["rev-parse", "HEAD"], in: path, environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Isolated configuration for fixture builds outside a `GitSandbox` (benchmarks).
    public static let fixtureEnvironment: [String: String] = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    ]

    @discardableResult
    func runGit(_ arguments: [String], in directory: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try FastImport.gitPath())
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "TMPDIR", "USER"].contains($0.key) }
        env.merge(environment) { _, new in new }
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
