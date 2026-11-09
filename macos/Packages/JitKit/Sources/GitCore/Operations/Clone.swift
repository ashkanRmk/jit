import Foundation

/// A clone from URL (design §3.5, §4.6). Clone has no repository yet, so it is a free function.
public struct CloneRequest: Sendable, Hashable {
    public var url: String
    /// Folder the clone is created in.
    public var parentDirectory: String
    /// Name of the new folder (derived from the URL, editable).
    public var name: String
    /// `http://` (unencrypted) only after the user confirmed the insecure transport.
    public var allowInsecureHTTP: Bool

    public init(url: String, parentDirectory: String, name: String, allowInsecureHTTP: Bool = false) {
        self.url = url
        self.parentDirectory = parentDirectory
        self.name = name
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    public var destination: String { (parentDirectory as NSString).appendingPathComponent(name) }
}

public struct CloneOutcome: Sendable, Equatable {
    public var path: String
    /// `.gitmodules` exists: submodules were not cloned (Phase 8).
    public var hasSubmodules: Bool
}

/// URL validation for clone (design §4.6, ADR-0032): scheme allowlist, no option-like URLs.
public enum CloneURL {
    public enum Kind: Sendable, Equatable {
        case https, ssh, scp, git, local, insecureHTTP
    }

    public static func classify(_ raw: String) -> Result<Kind, GitCoreError> {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return .failure(.refused(summary: "Enter a repository URL.")) }
        if url.hasPrefix("-") { return .failure(.refused(summary: "A repository URL can't start with “-”.")) }
        if url.contains("\0") || url.contains("\n")
            || url.contains(" ") && !url.hasPrefix("/") && !url.hasPrefix("file://")
        {
            return .failure(.refused(summary: "The URL contains characters that aren't allowed."))
        }
        if let range = url.range(of: "://") {
            let scheme = url[..<range.lowerBound].lowercased()
            switch scheme {
            case "https": return .success(.https)
            case "ssh", "git+ssh", "ssh+git": return .success(.ssh)
            case "git": return .success(.git)
            case "file": return .success(.local)
            case "http": return .success(.insecureHTTP)
            default:
                return .failure(
                    .refused(summary: "Jit doesn't clone “\(scheme)://” URLs. Use https, ssh or a local path."))
            }
        }
        if url.hasPrefix("/") || url.hasPrefix("~") || url.hasPrefix("./") || url.hasPrefix("../") {
            return .success(.local)
        }
        if url.contains("::") {
            return .failure(.refused(summary: "Remote helper URLs (“transport::address”) aren't allowed."))
        }
        // scp-like: [user@]host:path, where the host part has no slash before the colon.
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/"),
            url.distance(from: url.startIndex, to: colon) > 1
        {
            return .success(.scp)
        }
        return .failure(.refused(summary: "That doesn't look like a repository URL."))
    }

    /// `https://github.com/owner/repo.git` → `repo`.
    public static func derivedName(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/.git") { url.removeLast(5) }
        var last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if last.hasSuffix(".git") { last.removeLast(4) }
        if last.hasSuffix(".bundle") { last.removeLast(7) }
        let cleaned = last.filter { !$0.isNewline && $0 != "\0" }
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "repository" : cleaned
    }
}

/// `git clone --progress -- <url> <dest>` with the non-interactive environment and protocol policy.
/// Cancellation (Task cancellation → SIGTERM to the process group) leaves no partial clone: Git removes a
/// directory it created; Jit verifies and removes the destination only if it did not exist before.
public func cloneRepository(
    _ request: CloneRequest, engine: GitEngine, context: ExecContext = .anonymous,
    progress: AsyncStream<OperationProgress>.Continuation? = nil
) async throws(GitCoreError) -> CloneOutcome {
    let kind = try CloneURL.classify(request.url).get()
    if kind == .insecureHTTP, !request.allowInsecureHTTP {
        throw .refused(
            summary: "This URL uses unencrypted HTTP. Confirm that you want to clone over an insecure connection.")
    }
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix("-") else {
        throw .refused(summary: "Choose a folder name for the clone.")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: request.parentDirectory, isDirectory: &isDirectory),
        isDirectory.boolValue
    else { throw .pathNotFound(path: request.parentDirectory) }
    let destination = request.destination
    let existedBefore = FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory)
    if existedBefore {
        guard isDirectory.boolValue else { throw .refused(summary: "A file named “\(name)” already exists there.") }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
        guard contents.isEmpty else {
            throw .refused(summary: "The folder “\(name)” already exists and isn't empty. Choose another name.")
        }
    }
    let url = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
    var command = GitEnvironment.remoteCommand(
        ["clone", "--progress", "--", url, destination], in: request.parentDirectory, context: context)
    let sink = ProgressSink(progress)
    command.stderrObserver = sink.observer

    func cleanUp() {
        guard FileManager.default.fileExists(atPath: destination) else { return }
        if existedBefore {
            // Keep the user's (empty) folder; remove only what the clone put inside it.
            for item in (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? [] {
                try? FileManager.default.removeItem(atPath: (destination as NSString).appendingPathComponent(item))
            }
        } else {
            try? FileManager.default.removeItem(atPath: destination)
        }
    }

    do {
        _ = try await engine.run(command)
    } catch .processFailed(let code, _, let detail) {
        cleanUp()
        throw .failed(GitErrorClassifier.classify(exitCode: code, stderr: detail))
    } catch {
        cleanUp()
        throw error
    }
    let hasSubmodules = FileManager.default.fileExists(
        atPath: (destination as NSString).appendingPathComponent(".gitmodules"))
    return CloneOutcome(path: destination, hasSubmodules: hasSubmodules)
}
