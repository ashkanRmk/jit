import DesignSystem
import Foundation
import GitCore

/// Languages the hand-written lexers know (ADR-0012). Detected by extension, then shebang.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, c, javaScript, go, rust, java, kotlin, python, ruby, shell, json, yaml, toml, markdown, html, css
    case plain

    public static func detect(path: String, firstLine: String? = nil) -> SyntaxLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh": return .c
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .javaScript
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "py", "pyi": return .python
        case "rb", "rake", "gemspec": return .ruby
        case "sh", "bash", "zsh", "fish": return .shell
        case "json", "jsonc", "geojson": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "md", "markdown": return .markdown
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard": return .html
        case "css", "scss", "less": return .css
        default: break
        }
        if ["makefile", "dockerfile", "gemfile", "podfile", "rakefile"].contains(name) {
            return name == "makefile" || name == "dockerfile" ? .shell : .ruby
        }
        if let line = firstLine, line.hasPrefix("#!") {
            if line.contains("python") { return .python }
            if line.contains("ruby") { return .ruby }
            if line.contains("node") { return .javaScript }
            if line.contains("sh") { return .shell }
        }
        return .plain
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            [
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate",
                "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating",
                "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat",
                "rethrows", "return", "some", "any", "static", "struct", "subscript", "switch", "throw", "throws",
                "try", "typealias", "var", "where", "while", "consuming", "borrowing", "lazy", "weak", "unowned",
                "final", "convenience", "required", "dynamic", "indirect", "macro", "package",
            ]
        case .c:
            [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
                "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
                "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
                "volatile", "while", "class", "namespace", "template", "typename", "public", "private",
                "protected", "virtual", "override", "new", "delete", "using", "constexpr", "auto", "bool",
                "@interface", "@implementation", "@end", "@property", "@protocol", "id", "self", "super",
            ]
        case .javaScript:
            [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import",
                "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch", "this", "throw",
                "try", "typeof", "var", "void", "while", "yield", "interface", "type", "enum", "implements",
                "private", "public", "protected", "readonly", "as", "declare", "namespace", "abstract",
            ]
        case .go:
            [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                "struct", "switch", "type", "var",
            ]
        case .rust:
            [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                "return", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
            ]
        case .java, .kotlin:
            [
                "abstract", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum",
                "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface",
                "new", "package", "private", "protected", "public", "return", "static", "super", "switch",
                "synchronized", "this", "throw", "throws", "try", "void", "volatile", "while", "fun", "val",
                "var", "when", "object", "companion", "data", "sealed", "override", "suspend", "is", "in", "as",
                "internal", "open", "lateinit", "init",
            ]
        case .python:
            [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match",
                "case",
            ]
        case .ruby:
            [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry",
                "return", "self", "super", "then", "undef", "unless", "until", "when", "while", "yield",
                "require", "attr_reader", "attr_accessor", "private",
            ]
        case .shell:
            [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                "function", "return", "local", "export", "set", "unset", "echo", "exit", "readonly", "source",
                "shift", "trap", "RUN", "FROM", "COPY", "CMD", "ENV", "WORKDIR", "ARG", "ENTRYPOINT",
            ]
        default: []
        }
    }

    var constants: Set<String> {
        ["true", "false", "nil", "null", "None", "True", "False", "undefined", "self", "Self", "this", "NaN"]
    }

    var lineComment: String? {
        switch self {
        case .swift, .c, .javaScript, .go, .rust, .java, .kotlin: "//"
        case .python, .ruby, .shell, .yaml, .toml: "#"
        default: nil
        }
    }

    var hasBlockComments: Bool {
        switch self {
        case .swift, .c, .javaScript, .go, .rust, .java, .kotlin, .css: true
        default: false
        }
    }
}

/// One coloured run: 8 bytes (design §4.1 compact span records). Offsets are UTF-16 in the line's text.
public struct SyntaxSpan: Sendable, Hashable {
    public let start: UInt32
    public let length: UInt16
    public let color: UInt8

    public var range: NSRange { NSRange(location: Int(start), length: Int(length)) }
    public var syntaxColor: SyntaxColor { SyntaxColor(rawValue: color) ?? .operator }
}

/// State carried from one line to the next on the same side of a diff.
struct LexerState: Hashable, Sendable {
    var inBlockComment = false
    /// The delimiter of an open multi-line string (`"""`, `'''`, `` ` ``).
    var openString: [UInt16]?
    var inMarkupComment = false
}

/// Hand-written lexers by language family (ADR-0012). Pure, `Sendable`; works on UTF-16 code units so spans
/// line up with `NSString`/Core Text offsets (emoji and other surrogate pairs included).
struct Lexer: Sendable {
    let language: SyntaxLanguage
    let keywords: Set<String>
    let constants: Set<String>
    let lineComment: [UInt16]?

    init(_ language: SyntaxLanguage) {
        self.language = language
        keywords = language.keywords
        constants = language.constants
        lineComment = language.lineComment.map { Array($0.utf16) }
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit >= 0x80
    }

    static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || (unit >= 48 && unit <= 57) }
    static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    func lex(_ text: [UInt16], state: inout LexerState) -> [SyntaxSpan] {
        guard language != .plain else { return [] }
        var spans: [SyntaxSpan] = []
        func add(_ start: Int, _ end: Int, _ color: SyntaxColor) {
            var position = start
            while position < end {  // lengths are UInt16: split very long runs
                let length = min(end - position, Int(UInt16.max))
                spans.append(SyntaxSpan(start: UInt32(position), length: UInt16(length), color: color.rawValue))
                position += length
            }
        }
        func matches(_ pattern: [UInt16], at index: Int) -> Bool {
            index + pattern.count <= text.count && Array(text[index..<(index + pattern.count)]) == pattern
        }
        let count = text.count
        var index = 0
        let blockOpen: [UInt16] = Array("/*".utf16)
        let blockClose: [UInt16] = Array("*/".utf16)

        // Continue an open block comment / string / markup comment.
        if state.inBlockComment {
            var end = index
            while end < count, !matches(blockClose, at: end) { end += 1 }
            if end < count {
                end += 2
                state.inBlockComment = false
            }
            add(0, end, .comment)
            index = end
        } else if let delimiter = state.openString {
            var end = index
            while end < count, !matches(delimiter, at: end) { end += text[end] == 92 ? 2 : 1 }
            if end < count {
                end += delimiter.count
                state.openString = nil
            }
            add(0, min(end, count), .string)
            index = min(end, count)
        } else if state.inMarkupComment {
            let close: [UInt16] = Array("-->".utf16)
            var end = 0
            while end < count, !matches(close, at: end) { end += 1 }
            if end < count {
                end += 3
                state.inMarkupComment = false
            }
            add(0, min(end, count), .comment)
            index = min(end, count)
        }

        switch language {
        case .markdown:
            if index == 0, text.first == 35 { add(0, count, .keyword); return spans }  // # heading
            while index < count {
                if text[index] == 96 {  // `code`
                    var end = index + 1
                    while end < count, text[end] != 96 { end += 1 }
                    add(index, min(end + 1, count), .string)
                    index = end + 1
                } else {
                    index += 1
                }
            }
            return spans
        case .html:
            lexMarkup(text, from: index, state: &state, add: add)
            return spans
        default:
            break
        }

        var previousSignificant: UInt16 = 0
        while index < count {
            let unit = text[index]
            if let lineComment, matches(lineComment, at: index) {
                add(index, count, .comment)
                return spans
            }
            if language.hasBlockComments, matches(blockOpen, at: index) {
                var end = index + 2
                while end < count, !matches(blockClose, at: end) { end += 1 }
                if end < count { end += 2 } else { state.inBlockComment = true }
                add(index, min(end, count), .comment)
                index = min(end, count)
                continue
            }
            // Strings (with triple-quoted / template forms spanning lines).
            if unit == 34 || unit == 39 || unit == 96 {
                let triple = Array(repeating: unit, count: 3)
                let multiLine: [UInt16]?
                if (language == .swift || language == .python || language == .kotlin), matches(triple, at: index) {
                    multiLine = triple
                } else if unit == 96, language == .javaScript || language == .go || language == .shell {
                    multiLine = [96]
                } else {
                    multiLine = nil
                }
                // Swift has no '…' strings; in Rust a quote is a char literal only when it closes within
                // a few units ('a', '\n'), otherwise it starts a lifetime ('a).
                if unit == 39, language == .swift {
                    index += 1
                    continue
                }
                if unit == 39, language == .rust {
                    let closes =
                        (index + 2 < count && text[index + 2] == 39)
                        || (index + 3 < count && text[index + 1] == 92 && text[index + 3] == 39)
                    if !closes {
                        index += 1
                        continue
                    }
                }
                let delimiter = multiLine ?? [unit]
                var end = index + delimiter.count
                while end < count, !matches(delimiter, at: end) { end += text[end] == 92 ? 2 : 1 }
                if end < count {
                    end += delimiter.count
                } else if multiLine != nil {
                    state.openString = delimiter
                }
                end = min(end, count)
                if language == .json || language == .yaml,
                    let next = text[end...].first(where: { $0 != 32 && $0 != 9 }), next == 58
                {
                    add(index, end, .property)
                } else {
                    add(index, end, .string)
                }
                index = end
                previousSignificant = unit
                continue
            }
            if Self.isDigit(unit), !Self.isIdentifier(previousSignificant) {
                var end = index + 1
                while end < count, Self.isIdentifier(text[end]) || text[end] == 46 { end += 1 }
                add(index, end, .number)
                index = end
                previousSignificant = 48
                continue
            }
            if (unit == 64 || unit == 35) && index + 1 < count && Self.isIdentifierStart(text[index + 1]) {
                // @attribute (Swift, Kotlin, Java, decorators), #directive (C, Swift); `#` comments handled above.
                var end = index + 1
                while end < count, Self.isIdentifier(text[end]) { end += 1 }
                let word = String(decoding: text[index..<end], as: UTF16.self)
                add(index, end, keywords.contains(word) ? .keyword : unit == 35 ? .macro : .attribute)
                index = end
                previousSignificant = 97
                continue
            }
            if unit == 36, language == .shell, index + 1 < count {
                var end = index + 1
                if text[end] == 123 {  // ${…}
                    while end < count, text[end] != 125 { end += 1 }
                    end = min(end + 1, count)
                } else {
                    while end < count, Self.isIdentifier(text[end]) { end += 1 }
                }
                add(index, end, .variable)
                index = end
                continue
            }
            if Self.isIdentifierStart(unit) {
                var end = index + 1
                while end < count, Self.isIdentifier(text[end]) || (language == .ruby && text[end] == 63) { end += 1 }
                let word = String(decoding: text[index..<end], as: UTF16.self)
                var next = end
                while next < count, text[next] == 32 { next += 1 }
                let color: SyntaxColor?
                if language == .json || language == .yaml || language == .toml {
                    color =
                        constants.contains(word)
                        ? .constant
                        : (next < count && (text[next] == 58 || text[next] == 61) && language != .json)
                            ? .property : nil
                } else if keywords.contains(word) {
                    color = .keyword
                } else if constants.contains(word) {
                    color = .constant
                } else if previousSignificant == 46 {
                    color = next < count && text[next] == 40 ? .function : .property
                } else if next < count && text[next] == 40 {
                    color = .function
                } else if let first = word.utf16.first, first >= 65 && first <= 90 {
                    color = .type
                } else {
                    color = nil
                }
                if let color { add(index, end, color) }
                index = end
                previousSignificant = 97
                continue
            }
            if language == .toml, unit == 91, index == 0 {  // [section]
                var end = index
                while end < count, text[end] != 93 { end += 1 }
                add(index, min(end + 1, count), .type)
                index = min(end + 1, count)
                continue
            }
            if unit != 32 && unit != 9 { previousSignificant = unit }
            index += 1
        }
        return spans
    }

    private func lexMarkup(
        _ text: [UInt16], from start: Int, state: inout LexerState, add: (Int, Int, SyntaxColor) -> Void
    ) {
        let count = text.count
        var index = start
        let commentOpen: [UInt16] = Array("<!--".utf16)
        while index < count {
            if index + 4 <= count, Array(text[index..<(index + 4)]) == commentOpen {
                var end = index + 4
                let close: [UInt16] = Array("-->".utf16)
                while end < count, !(end + 3 <= count && Array(text[end..<(end + 3)]) == close) { end += 1 }
                if end < count { end += 3 } else { state.inMarkupComment = true }
                add(index, min(end, count), .comment)
                index = min(end, count)
                continue
            }
            if text[index] == 60 {  // <tag attr="v">
                var end = index + 1
                if end < count, text[end] == 47 || text[end] == 33 || text[end] == 63 { end += 1 }
                let nameStart = end
                while end < count, Self.isIdentifier(text[end]) || text[end] == 45 || text[end] == 58 { end += 1 }
                if end > nameStart { add(nameStart, end, .tag) }
                while end < count, text[end] != 62 {
                    if text[end] == 34 || text[end] == 39 {
                        let quote = text[end]
                        var close = end + 1
                        while close < count, text[close] != quote { close += 1 }
                        add(end, min(close + 1, count), .string)
                        end = min(close + 1, count)
                    } else if Self.isIdentifierStart(text[end]) {
                        let attributeStart = end
                        while end < count, Self.isIdentifier(text[end]) || text[end] == 45 || text[end] == 58 {
                            end += 1
                        }
                        add(attributeStart, end, .attribute)
                    } else {
                        end += 1
                    }
                }
                index = min(end + 1, count)
                continue
            }
            index += 1
        }
    }
}

/// Spans for every line of a `DiffDocument` (flat storage + per-line offsets).
public struct HighlightResult: Sendable {
    let spans: [SyntaxSpan]
    /// `offsets[line] ..< offsets[line + 1]` in `spans`.
    let offsets: [UInt32]

    public func spans(forLine line: Int) -> ArraySlice<SyntaxSpan> {
        guard line + 1 < offsets.count else { return [] }
        return spans[Int(offsets[line])..<Int(offsets[line + 1])]
    }

    public var lineCount: Int { max(0, offsets.count - 1) }
}

/// Highlights documents off the main actor (design §4.1). Limits: ≤ 2 MB and ≤ 50k lines, else plain.
public enum Highlighter {
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxLines = 50_000

    /// `nil` when over the limits, plain text, or cancelled. Old and new sides carry their own state.
    public static func highlight(_ document: DiffDocument, language: SyntaxLanguage) -> HighlightResult? {
        guard language != .plain, document.storage.bytes.count <= maxBytes, document.storage.lineCount <= maxLines
        else { return nil }
        let lexer = Lexer(language)
        var spans: [SyntaxSpan] = []
        var offsets: [UInt32] = [0]
        offsets.reserveCapacity(document.storage.lineCount + 1)
        var perLine = [[SyntaxSpan]](repeating: [], count: document.storage.lineCount)
        for hunk in document.hunks {
            var oldState = LexerState()
            var newState = LexerState()
            for line in hunk.lines {
                if line % 1000 == 0, Task.isCancelled { return nil }
                let text = Array(document.text(ofLine: line).utf16)
                switch document.kind(ofLine: line) {
                case .context:
                    perLine[line] = lexer.lex(text, state: &newState)
                    var copy = oldState
                    _ = lexer.lex(text, state: &copy)
                    oldState = copy
                case .added:
                    perLine[line] = lexer.lex(text, state: &newState)
                case .deleted:
                    perLine[line] = lexer.lex(text, state: &oldState)
                }
            }
        }
        for line in perLine {
            spans += line
            offsets.append(UInt32(spans.count))
        }
        return HighlightResult(spans: spans, offsets: offsets)
    }
}
