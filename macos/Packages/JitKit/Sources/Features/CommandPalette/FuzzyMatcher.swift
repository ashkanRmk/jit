import Foundation

/// Fuzzy subsequence matching for the command palette (ADR-0044, design §3.1). Pure and `Sendable`: the
/// palette ranks off the main actor on a snapshot of its sources.
///
/// Score: every matched character earns a base point; bonuses for a match at a word start (after a space,
/// `/`, `-`, `_`, `.` or a lower→upper case change), for consecutive matches, and for the query being a prefix
/// of the candidate; a small penalty for gaps. Case-insensitive. `nil` when the query isn't a subsequence.
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public let score: Int
        /// UTF-16 offsets of the matched characters (for emphasis by weight).
        public let indices: [Int]
    }

    static let base = 1
    static let wordStartBonus = 8
    static let consecutiveBonus = 5
    static let prefixBonus = 12
    static let firstCharacterBonus = 6
    static let gapPenalty = 1

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().utf16).filter { $0 != 0x20 }
        if needle.isEmpty { return Match(score: 0, indices: []) }
        let original = Array(candidate.utf16)
        let haystack = Array(candidate.lowercased().utf16)
        guard haystack.count == original.count, needle.count <= haystack.count else { return nil }

        // Greedy pass that prefers word starts: for each needle character, take the next word-start occurrence
        // if one exists before the next plain occurrence's run would end; otherwise the next occurrence.
        var indices: [Int] = []
        indices.reserveCapacity(needle.count)
        var position = 0
        for (offset, unit) in needle.enumerated() {
            guard let next = firstIndex(of: unit, in: haystack, from: position) else { return nil }
            var chosen = next
            let previousMatched = indices.last
            let continuesRun = previousMatched.map { next == $0 + 1 } ?? false
            if !continuesRun, !isWordStart(next, original) {
                // Look ahead for a word-start occurrence that still leaves room for the rest of the needle.
                var probe = next + 1
                let remaining = needle.count - offset - 1
                while probe < haystack.count - remaining {
                    if haystack[probe] == unit, isWordStart(probe, original) {
                        chosen = probe
                        break
                    }
                    probe += 1
                }
                if chosen != next, !isSubsequence(Array(needle[(offset + 1)...]), of: haystack, from: chosen + 1) {
                    chosen = next
                }
            }
            indices.append(chosen)
            position = chosen + 1
        }

        var score = 0
        for (offset, index) in indices.enumerated() {
            score += base
            if isWordStart(index, original) { score += wordStartBonus }
            if offset > 0 {
                let gap = index - indices[offset - 1] - 1
                if gap == 0 { score += consecutiveBonus } else { score -= min(gap, 10) * gapPenalty }
            } else if index == 0 {
                score += firstCharacterBonus
            }
        }
        if haystack.starts(with: needle) { score += prefixBonus }
        return Match(score: score, indices: indices)
    }

    static func firstIndex(of unit: UInt16, in haystack: [UInt16], from start: Int) -> Int? {
        var index = start
        while index < haystack.count {
            if haystack[index] == unit { return index }
            index += 1
        }
        return nil
    }

    static func isSubsequence(_ needle: [UInt16], of haystack: [UInt16], from start: Int) -> Bool {
        var position = start
        for unit in needle {
            guard let found = firstIndex(of: unit, in: haystack, from: position) else { return false }
            position = found + 1
        }
        return true
    }

    static func isWordStart(_ index: Int, _ original: [UInt16]) -> Bool {
        guard index > 0 else { return true }
        let previous = original[index - 1]
        if [0x20, 0x2F, 0x2D, 0x5F, 0x2E, 0x3A].contains(previous) { return true }  // space / - _ . :
        let isUpper = original[index] >= 0x41 && original[index] <= 0x5A
        let previousLower = previous >= 0x61 && previous <= 0x7A
        return isUpper && previousLower
    }
}
