import Foundation
import GitCore

/// Word-level changes inside paired lines (ADR-0029): within a hunk, a run of deleted lines followed by a
/// run of added lines is paired line by line when the run lengths are within 2× of each other; each pair
/// (both lines < 1,000 bytes) is diffed on tokens with Myers' algorithm. Pure; results in UTF-16 ranges.
public enum WordDiff {
    public static let maxLineBytes = CacheLimits.wordDiffLineBytes

    /// Deleted line → added line, and back.
    public static func pairs(in document: DiffDocument) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for hunk in document.hunks {
            var deleted: [Int] = []
            var added: [Int] = []
            func flush() {
                if !deleted.isEmpty, !added.isEmpty,
                    max(deleted.count, added.count) <= 2 * min(deleted.count, added.count)
                {
                    for (old, new) in zip(deleted, added)
                    where document.bytes(ofLine: old).count < maxLineBytes
                        && document.bytes(ofLine: new).count < maxLineBytes
                    {
                        result[old] = new
                        result[new] = old
                    }
                }
                deleted.removeAll()
                added.removeAll()
            }
            for line in hunk.lines {
                switch document.kind(ofLine: line) {
                case .context: flush()
                case .deleted:
                    if !added.isEmpty { flush() }
                    deleted.append(line)
                case .added: added.append(line)
                }
            }
            flush()
        }
        return result
    }

    /// Words (letters/digits/_), runs of spaces, and single other characters, as UTF-16 ranges.
    static func tokens(_ text: [UInt16]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        func kind(_ unit: UInt16) -> Int {
            if Lexer.isIdentifier(unit) { return 0 }
            if unit == 32 || unit == 9 { return 1 }
            return 2
        }
        while index < text.count {
            let k = kind(text[index])
            var end = index + 1
            if k != 2 { while end < text.count, kind(text[end]) == k { end += 1 } }
            result.append(index..<end)
            index = end
        }
        return result
    }

    /// Changed ranges in `old` and `new` (UTF-16), adjacent changed tokens merged.
    public static func ranges(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        let ta = tokens(a)
        let tb = tokens(b)
        let wa = ta.map { Array(a[$0]) }
        let wb = tb.map { Array(b[$0]) }
        let (keepA, keepB) = myers(wa, wb)
        func merge(_ tokens: [Range<Int>], _ keep: [Bool]) -> [NSRange] {
            var out: [NSRange] = []
            for (index, token) in tokens.enumerated() where !keep[index] {
                if let last = out.last, last.location + last.length == token.lowerBound {
                    out[out.count - 1].length += token.count
                } else {
                    out.append(NSRange(location: token.lowerBound, length: token.count))
                }
            }
            return out
        }
        // Whole-line changes say nothing word-level: no emphasis then.
        if !keepA.contains(true) && !keepB.contains(true) { return ([], []) }
        return (merge(ta, keepA), merge(tb, keepB))
    }

    /// Myers O((N+M)·D): which tokens of each side are part of the longest common subsequence.
    static func myers<T: Equatable>(_ a: [T], _ b: [T]) -> ([Bool], [Bool]) {
        let n = a.count
        let m = b.count
        var keepA = [Bool](repeating: false, count: n)
        var keepB = [Bool](repeating: false, count: m)
        let max = n + m
        guard max > 0 else { return (keepA, keepB) }
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        let offset = max
        search: for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m { break search }
            }
        }
        // Backtrack through the saved V arrays, marking diagonal moves as kept.
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            if d == 0 {
                while x > 0, y > 0 {
                    x -= 1
                    y -= 1
                    keepA[x] = true
                    keepB[y] = true
                }
                break
            }
            let v = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                keepA[x] = true
                keepB[y] = true
            }
            x = previousX
            y = previousY
        }
        return (keepA, keepB)
    }
}
