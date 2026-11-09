import Foundation

/// What a palette row stands for. Order is the tie-break source order (design §3.1).
public enum PaletteSource: Int, Sendable, Comparable, CaseIterable {
    case command = 0
    case ref = 1
    case file = 2
    case repository = 3
    case commit = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Prefix scope characters: `>` commands, `@` branches/tags, `/` files, `#` repositories/tabs, `:` SHA.
    public var prefix: Character {
        switch self {
        case .command: ">"
        case .ref: "@"
        case .file: "/"
        case .repository: "#"
        case .commit: ":"
        }
    }

    public var title: String {
        switch self {
        case .command: "Commands"
        case .ref: "Branches & Tags"
        case .file: "Files"
        case .repository: "Repositories"
        case .commit: "Commits"
        }
    }
}

/// A rankable palette entry (value type; built on the main actor, ranked anywhere).
public struct PaletteCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let source: PaletteSource
    public let title: String
    /// Extra words matched with a lower weight (menu path, path components, upstream).
    public let keywords: String
    public let order: Int

    public init(id: String, source: PaletteSource, title: String, keywords: String = "", order: Int = 0) {
        self.id = id
        self.source = source
        self.title = title
        self.keywords = keywords
        self.order = order
    }
}

public struct PaletteRanked: Sendable, Equatable {
    public let candidate: PaletteCandidate
    public let score: Int
    /// Matched UTF-16 offsets in `candidate.title` (empty when matched through keywords only).
    public let titleIndices: [Int]
}

public enum PaletteRanker {
    public static let resultLimit = 50
    /// Bonus per recency rank (most recent first) for commands run from the palette.
    static let recencyBonus = [10, 8, 6, 4, 2]

    /// Splits a leading scope prefix off the query.
    public static func scope(of query: String) -> (PaletteSource?, String) {
        guard let first = query.first, let source = PaletteSource.allCases.first(where: { $0.prefix == first }) else {
            return (nil, query.trimmingCharacters(in: .whitespaces))
        }
        return (source, String(query.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// Ranks `candidates` for `query` (scope prefix included). `recent` holds candidate ids, most recent first.
    public static func rank(_ query: String, _ candidates: [PaletteCandidate], recent: [String] = []) -> [PaletteRanked]
    {
        let (scope, text) = scope(of: query)
        let pool = scope.map { scope in candidates.filter { $0.source == scope } } ?? candidates
        var ranked: [PaletteRanked] = []
        ranked.reserveCapacity(min(pool.count, 512))
        for candidate in pool {
            var score: Int
            var indices: [Int] = []
            if let match = FuzzyMatcher.match(text, in: candidate.title) {
                score = match.score
                indices = match.indices
            } else if !candidate.keywords.isEmpty, let match = FuzzyMatcher.match(text, in: candidate.keywords) {
                score = match.score / 2
            } else {
                continue
            }
            if let position = recent.firstIndex(of: candidate.id), position < recencyBonus.count {
                score += recencyBonus[position]
            }
            ranked.append(PaletteRanked(candidate: candidate, score: score, titleIndices: indices))
        }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.source != b.candidate.source { return a.candidate.source < b.candidate.source }
            if a.candidate.order != b.candidate.order { return a.candidate.order < b.candidate.order }
            return a.candidate.title.count < b.candidate.title.count
        }
        return Array(ranked.prefix(resultLimit))
    }
}
