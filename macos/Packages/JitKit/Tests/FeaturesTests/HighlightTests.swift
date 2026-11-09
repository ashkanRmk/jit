import DesignSystem
import Foundation
import GitCore
import GitTestKit
import Testing

@testable import Features

/// Syntax highlighting (ADR-0012) and word diff (ADR-0029), P3.7.
@Suite struct HighlightTests {
    func spans(_ line: String, _ language: SyntaxLanguage, state: LexerState = LexerState()) -> [(String, SyntaxColor)]
    {
        var state = state
        let units = Array(line.utf16)
        return Lexer(language).lex(units, state: &state).map {
            (String(decoding: units[Int($0.start)..<(Int($0.start) + Int($0.length))], as: UTF16.self), $0.syntaxColor)
        }
    }

    @Test func highlightSpansUTF16OffsetsWithEmoji() {
        let result = spans("let 😀 = \"héllo 👋\" // done", .swift)
        #expect(result.map(\.0) == ["let", "\"héllo 👋\"", "// done"])
        #expect(result.map(\.1) == [.keyword, .string, .comment])
        // Offsets index UTF-16, so the emoji (2 units) shifts the string start to 9.
        var state = LexerState()
        let raw = Lexer(.swift).lex(Array("let 😀 = \"x\"".utf16), state: &state)
        #expect(raw.map(\.start) == [0, 9])
    }

    @Test func languageFamilies() {
        #expect(spans("func load(path: String) -> Int {", .swift).map(\.1) == [.keyword, .function, .type, .type])
        #expect(spans("@MainActor final class A {}", .swift).map(\.1) == [.attribute, .keyword, .keyword, .type])
        #expect(
            spans("def run(x): return None  # note", .python).map(\.1) == [
                .keyword, .function, .keyword, .constant, .comment,
            ])
        #expect(
            spans("{\"name\": \"jit\", \"n\": 3, \"ok\": true}", .json).map(\.1) == [
                .property, .string, .property, .number, .property, .constant,
            ])
        #expect(spans("<a href=\"x\">", .html).map(\.1) == [.tag, .attribute, .string])
        #expect(spans("echo $HOME ${USER}", .shell).map(\.1) == [.keyword, .variable, .variable])
        #expect(spans("fn f<'a>(x: &'a str) -> char { 'c' }", .rust).map(\.1).contains(.string))
        #expect(SyntaxLanguage.detect(path: "x/script", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(SyntaxLanguage.detect(path: "View.TSX") == .javaScript)
    }

    @Test func blockCommentsAndMultilineStringsCarryState() {
        var state = LexerState()
        let lexer = Lexer(.swift)
        _ = lexer.lex(Array("let a = 1 /* start".utf16), state: &state)
        #expect(state.inBlockComment)
        var spans = lexer.lex(Array("still comment */ let b".utf16), state: &state)
        #expect(!state.inBlockComment && spans.first?.syntaxColor == .comment && spans.last?.syntaxColor == .keyword)
        _ = lexer.lex(Array("let s = \"\"\"".utf16), state: &state)
        #expect(state.openString == Array("\"\"\"".utf16))
        spans = lexer.lex(Array("text \"\"\" + x".utf16), state: &state)
        #expect(state.openString == nil && spans.first?.syntaxColor == .string)
    }

    func document(_ before: String, _ after: String, name: String = "f.swift") async throws -> DiffDocument {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepository()
        try repo.write(name, before)
        try await repo.commit("One")
        try repo.write(name, after)
        let handle = try await sandbox.engine.openRepository(at: URL(fileURLWithPath: repo.path))
        return try await handle.openDiff(.unstaged(path: name))
    }

    @Test func highlightKeepsSidesSeparate() async throws {
        // The old side opens a block comment the new side does not have.
        let doc = try await document("/* old\nlet a = 1\n*/\nlet z = 0\n", "let a = 1\nlet z = 0\n")
        let result = try #require(Highlighter.highlight(doc, language: .swift))
        for line in 0..<doc.storage.lineCount
        where doc.kind(ofLine: line) != .deleted && doc.text(ofLine: line) == "let a = 1" {
            #expect(result.spans(forLine: line).first?.syntaxColor == .keyword)
        }
    }

    @Test func highlightLimitsFallbackPlain() async throws {
        let big = (0..<50_001).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let doc = try await document("x\n", big)
        #expect(doc.storage.lineCount > Highlighter.maxLines)
        #expect(Highlighter.highlight(doc, language: .swift) == nil)
        #expect(Highlighter.highlight(try await document("a\n", "b\n", name: "f.txt"), language: .plain) == nil)
    }

    @Test func highlightCancelOnDocumentClose() async throws {
        let text = (0..<40_000).map { "let value\($0) = compute(\($0)) // c" }.joined(separator: "\n") + "\n"
        let doc = try await document("x\n", text)
        let task = Task.detached { () -> HighlightResult? in
            withUnsafeCurrentTask { $0?.cancel() }
            return Highlighter.highlight(doc, language: .swift)
        }
        #expect(await task.value == nil)
    }

    @Test func wordDiffPairsAndLimits() async throws {
        let long = String(repeating: "x", count: 1200)
        let doc = try await document(
            "keep\nlet total = a + b\nmid\n\(long)\nend\na1\na2\na3\na4\na5\nlast\n",
            "keep\nlet total = a - b\nmid\n\(long)y\nend\nb1\nlast\n")
        let pairs = WordDiff.pairs(in: doc)
        let deleted = (0..<doc.storage.lineCount).filter { doc.kind(ofLine: $0) == .deleted }
        let byText = Dictionary(uniqueKeysWithValues: deleted.map { (doc.text(ofLine: $0), $0) })
        // Paired: same position in a deletion run followed by an addition run.
        let totalOld = try #require(byText["let total = a + b"])
        #expect(pairs[totalOld].map { doc.text(ofLine: $0) } == "let total = a - b")
        // Lines of 1,000 bytes or more are never paired.
        #expect(pairs[try #require(byText[long])] == nil)
        // Five deletions against one addition: run lengths differ more than 2×, nothing paired.
        #expect(pairs[try #require(byText["a1"])] == nil)
        let ranges = WordDiff.ranges(old: "let total = a + b", new: "let total = a - b")
        #expect(ranges.old == [NSRange(location: 14, length: 1)] && ranges.new == [NSRange(location: 14, length: 1)])
        // Completely different lines: no word emphasis.
        #expect(WordDiff.ranges(old: "abc", new: "xyz") == ([], []))
    }

    @Test func myersFindsLongestCommonSubsequence() {
        let a = Array("ABCABBA")
        let b = Array("CBABAC")
        let (keepA, keepB) = WordDiff.myers(a, b)
        #expect(keepA.filter { $0 }.count == 4 && keepB.filter { $0 }.count == 4)  // LCS length 4
        let common = zip(a, keepA).filter(\.1).map(\.0)
        #expect(common == zip(b, keepB).filter(\.1).map(\.0))
    }
}
