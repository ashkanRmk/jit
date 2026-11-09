import Foundation

/// Entry points for the release-built `JitBench` micro-benchmarks (P6.2). Not app API: `@_spi(Benchmarks)`.
@_spi(Benchmarks)
public enum CoreBenchmarks {
    /// `git log` output for the whole history of `repository` in the graph's format, plus its refs.
    public static func historyOutput(_ repository: RepositoryHandle, engine: GitEngine) async throws(GitCoreError) -> (
        [UInt8], RefSnapshot
    ) {
        let refs = try await repository.refs()
        guard let arguments = HistoryQuery().arguments(refs: refs, skip: 0) else { return ([], refs) }
        let output = try await engine.run(
            GitCommand(arguments, in: repository.path, timeout: nil, stdoutLimit: 1 << 31))
        return (output.stdout, refs)
    }

    /// Parses `output` and lays out lanes into a commit store, as the history loader does. Returns
    /// (rows, store bytes).
    public static func parseAndLayout(_ output: [UInt8], refs: RefSnapshot) throws(GitCoreError) -> (Int, Int) {
        var parser = LogParser()
        var layouter = LaneLayouter(refs: refs)
        var builder = CommitStoreBuilder()
        try parser.consume(output) { (record: borrowing LogParser.Record) throws(GitCoreError) in
            let author = builder.internAuthor(name: record.name, email: record.email)
            layouter.layout(oid: record.oid, parents: record.parents, subject: record.subject)
            builder.append(
                oid: record.oid, parents: record.parents, author: author, time: record.time, subject: record.subject,
                lane: layouter.output)
        }
        return (builder.count, builder.chunksForSnapshot().reduce(0) { $0 + $1.storageBytes })
    }

    /// Line indices of every added/removed line of the document's first file.
    public static func changedLines(_ document: DiffDocument) -> [Int] {
        guard let file = document.files.first else { return [] }
        return file.hunks.flatMap { document.hunks[$0].lines }.filter { document.storage.lines[$0].kind != .context }
    }
}
