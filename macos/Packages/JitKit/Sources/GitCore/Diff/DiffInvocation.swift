import Foundation

/// What a diff compares (design §4.2).
public enum DiffTarget: Sendable, Hashable {
    /// Index → working tree. An untracked path gets a synthesized new-file patch (no `git add -N`).
    case unstaged(path: String)
    /// HEAD (nothing on an unborn branch) → index. Pass the source of a staged rename so Git pairs them.
    case staged(path: String, renamedFrom: String? = nil)
    /// First parent (the empty tree for a root commit) → commit.
    case commit(ObjectID, path: String?)
    /// `from` → `to` directly.
    case commits(from: ObjectID, to: ObjectID, path: String?)
    /// Commit → working tree (tracked files).
    case commitToWorktree(ObjectID, path: String?)

    public var path: String? {
        switch self {
        case .unstaged(let path), .staged(let path, _): path
        case .commit(_, let path), .commits(_, _, let path), .commitToWorktree(_, let path): path
        }
    }
}

public struct DiffOptions: Sendable, Hashable {
    /// Context lines shown around changes. The document is fetched with the whole file as context when
    /// `fullContext` is set, so expanding context is a layout change over the same buffer.
    public var contextLines: Int
    /// Ask Git for every unchanged line (single-file targets): enables full-file layout and expansion.
    public var fullContext: Bool
    /// `-w`: display only; line actions are refused on such documents (P3.4).
    public var ignoreWhitespace: Bool

    public init(contextLines: Int = 3, fullContext: Bool = true, ignoreWhitespace: Bool = false) {
        self.contextLines = contextLines
        self.fullContext = fullContext
        self.ignoreWhitespace = ignoreWhitespace
    }
}

/// The one canonical `git diff` command line (ADR-0026). Applicable, byte-exact output: no external diff
/// or textconv programs, no colour, full object ids, binary patches, fixed `a/` `b/` prefixes whatever
/// the user's configuration says, paths unescaped except where Git must quote them.
public enum DiffInvocation {
    /// The empty tree's id, the base of a root commit's diff.
    public static func emptyTree(_ format: ObjectFormat) -> String {
        format == .sha1
            ? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            : "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
    }

    /// Context large enough for any file Jit diffs (Git clamps it).
    static let wholeFileContext = 1 << 30

    static let configuration = [
        "-c", "core.quotepath=off", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
        "-c", "diff.relative=false", "-c", "color.ui=false", "-c", "diff.external=", "-c",
        "diff.suppressBlankEmpty=false",
    ]

    /// - Parameter firstParent: the commit's first parent, or `nil` for a root commit (only `.commit`).
    public static func arguments(
        _ target: DiffTarget, options: DiffOptions, format: ObjectFormat, firstParent: ObjectID? = nil
    ) -> [String] {
        let context = options.fullContext && target.path != nil ? wholeFileContext : max(0, options.contextLines)
        var arguments =
            configuration + [
                "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--full-index",
                "--binary", "--find-renames", "-U\(context)", "--src-prefix=a/", "--dst-prefix=b/",
                "--submodule=short",
            ]
        if options.ignoreWhitespace { arguments.append("-w") }
        switch target {
        case .unstaged:
            break
        case .staged:
            arguments.append("--cached")
        case .commit(let oid, _):
            arguments += [firstParent?.hex(format) ?? emptyTree(format), oid.hex(format)]
        case .commits(let from, let to, _):
            arguments += [from.hex(format), to.hex(format)]
        case .commitToWorktree(let oid, _):
            arguments.append(oid.hex(format))
        }
        arguments.append("--")
        if case .staged(_, let source?) = target { arguments.append(source) }
        if let path = target.path { arguments.append(path) }
        return arguments
    }
}
