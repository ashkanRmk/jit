import Foundation
import Testing

@testable import Features

/// P6.9 ranking (ADR-0044): word starts, consecutive runs, prefixes, recency, ties, scopes, cap.
@Suite struct FuzzyRankerTests {
    func titles(_ query: String, _ titles: [String], recent: [String] = []) -> [String] {
        let candidates = titles.enumerated().map {
            PaletteCandidate(id: $1, source: .command, title: $1, order: $0)
        }
        return PaletteRanker.rank(query, candidates, recent: recent).map(\.candidate.title)
    }

    @Test func subsequenceRequired() {
        #expect(FuzzyMatcher.match("fhc", in: "Fetch") == nil)
        #expect(FuzzyMatcher.match("ftch", in: "Fetch") != nil)
        #expect(FuzzyMatcher.match("", in: "Fetch")?.score == 0)
    }

    @Test func wordStartBeatsMiddleOfWord() {
        // "pw" hits the word starts of "Pull with…" but only inner letters of "Stepwise".
        #expect(titles("pw", ["Stepwise", "Pull with Rebase"]).first == "Pull with Rebase")
        let match = FuzzyMatcher.match("nb", in: "New Branch…")
        #expect(match?.indices == [0, 4])
    }

    @Test func consecutiveRunBeatsScattered() {
        #expect(titles("push", ["Pull with Rebase and Show History", "Push"]).first == "Push")
        #expect(titles("fetch", ["Fetch All Remotes", "Find Text Characters"]).first == "Fetch All Remotes")
    }

    @Test func exactPrefixWins() {
        #expect(titles("open", ["Reopen Closed Tab", "Open Repository…"]).first == "Open Repository…")
    }

    @Test func recencyBreaksNearTies() {
        let plain = titles("p", ["Pull", "Push"])
        #expect(plain.first == "Pull")  // source order
        #expect(titles("p", ["Pull", "Push"], recent: ["Push"]).first == "Push")
    }

    @Test func tiesFollowSourceOrder() {
        let candidates = [
            PaletteCandidate(id: "f", source: .file, title: "main"),
            PaletteCandidate(id: "r", source: .ref, title: "main"),
            PaletteCandidate(id: "c", source: .command, title: "main"),
        ]
        #expect(PaletteRanker.rank("main", candidates).map(\.candidate.id) == ["c", "r", "f"])
    }

    @Test func scopePrefixFilters() {
        let candidates = [
            PaletteCandidate(id: "cmd", source: .command, title: "Fetch"),
            PaletteCandidate(id: "branch", source: .ref, title: "feature/fetch"),
            PaletteCandidate(id: "file", source: .file, title: "Fetcher.swift"),
        ]
        #expect(PaletteRanker.rank("@fetch", candidates).map(\.candidate.id) == ["branch"])
        #expect(PaletteRanker.rank("/ fet", candidates).map(\.candidate.id) == ["file"])
        #expect(PaletteRanker.rank(">", candidates).map(\.candidate.id) == ["cmd"])
        #expect(PaletteRanker.scope(of: "#jit") == (.repository, "jit"))
        #expect(PaletteRanker.scope(of: "jit") == (nil, "jit"))
    }

    @Test func keywordsMatchWithLowerWeight() {
        let candidates = [
            PaletteCandidate(id: "a", source: .command, title: "Show Activity", keywords: "Repository operations log"),
            PaletteCandidate(id: "b", source: .command, title: "Operations Log"),
        ]
        let ranked = PaletteRanker.rank("operations", candidates)
        #expect(ranked.map(\.candidate.id) == ["b", "a"])
        #expect(ranked[1].titleIndices.isEmpty)
    }

    @Test func resultsAreCapped() {
        let many = (0..<500).map { PaletteCandidate(id: "\($0)", source: .file, title: "file\($0).swift") }
        #expect(PaletteRanker.rank("file", many).count == PaletteRanker.resultLimit)
    }

    @Test func caseInsensitiveAndCamelCaseWordStarts() {
        #expect(FuzzyMatcher.match("GVC", in: "GraphViewController.swift")?.indices == [0, 5, 9])
        #expect(titles("gvc", ["GraphViewController.swift", "give vacuum cleaner"]).count == 2)
    }
}
