# ADR-0012: Syntax highlighting

- Status: accepted
- Date: 2026-11-09
- Phase: P3
- Requirements: §6, §14, §19; ADR-0002, ADR-0011

## Context
Diffs should be highlighted without blocking first paint, without a web view, and without making the app
much larger. Candidates (design §4.1, spike S2): (a) the tree-sitter C runtime plus one compiled grammar
per language as a SwiftPM C target; (b) small hand-written lexers in Swift by language family.

## Decision
(b) hand-written lexers (`Features/DiffViewer/Highlighter.swift`), one per family: C-like (Swift, C/C++/
Objective-C, JavaScript/TypeScript incl. JSX/TSX, Go, Rust, Java, Kotlin), hash-comment (Python, Ruby,
Shell incl. Makefile/Dockerfile), JSON, YAML, TOML, Markdown, HTML/XML, CSS. Detection by extension, then
shebang. They colour keywords, types (capitalised), functions (followed by `(`), properties (after `.`),
strings (incl. multi-line `"""`/`'''`/template strings), numbers, comments (incl. block comments carried
across lines), attributes/decorators, directives/macros, shell variables, JSON/YAML keys, markup tags and
attributes. Old and new sides of a diff each carry their own lexer state.

Spans are 8-byte records `(start UTF-16, length, colour)` with a per-line offset table, computed off the
main actor (`Task.detached`), cancelled with the document, limited to ≤ 2 MB and ≤ 50k lines (plain above).
The body draws plain text first; spans swap in when ready (rows are fixed height, so no layout shift).
Colours are `syntax.*` tokens (`DesignSystem/Syntax.swift`), each ≥ 4.5:1 on the canvas and both diff
backgrounds in all four variants (`ContrastTests.syntaxColorsMeetAAOnCodeBackgrounds`).

## Consequences
- Tree-sitter was **not prototyped** (deviation from the spike plan): adding a C target and ~16 vendored
  grammars (each a large generated `parser.c`) conflicts with ADR-0002's pure-Swift direction and with the
  binary-size budget, and the lexers meet the "never block first paint" criterion by construction. Its
  binary-size and speed numbers were therefore not measured. Revisit if semantic accuracy (e.g. nested
  generics, string interpolation colouring) becomes a user-visible problem.
- Lexers are heuristic: they do not parse, so unusual constructs may be coloured imperfectly; text is
  never altered.
- The whole document is lexed once (fast, off-main) rather than strictly the visible window plus margin.
- Evidence: `HighlightTests` (UTF-16 offsets with emoji, language families, state across lines, sides kept
  separate, limits → plain, cancellation).
