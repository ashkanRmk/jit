import Foundation

/// Every failure `GitCore` reports. Each case has a short, user-presentable `summary`; raw process
/// output is only ever exposed as `detail`, after redaction.
public enum GitCoreError: Error, Sendable, Equatable {
    case gitNotFound
    case gitTooOld(found: GitVersion, required: GitVersion)
    case notARepository(path: String)
    case pathNotFound(path: String)
    case permissionDenied(path: String)
    /// Git refused the repository because of `safe.directory` / dubious ownership.
    case unsafeRepository(path: String)
    case cancelled
    case timedOut(seconds: Int)
    case outputTooLarge(limitBytes: Int)
    case processFailed(exitCode: Int32, summary: String, detail: String)
    case launchFailed(errno: Int32)
    case io(summary: String)
    case internalError(summary: String)

    public var summary: String {
        switch self {
        case .gitNotFound:
            "Git isn't installed on this Mac."
        case let .gitTooOld(found, required):
            "Git \(found) is too old. Jit needs Git \(required) or newer."
        case .notARepository:
            "This folder isn't a Git repository."
        case .pathNotFound:
            "This folder no longer exists."
        case .permissionDenied:
            "Jit doesn't have permission to read this folder."
        case .unsafeRepository:
            "Git refused to open this repository because it is owned by another user."
        case .cancelled:
            "The operation was cancelled."
        case let .timedOut(seconds):
            "Git didn't respond within \(seconds) seconds."
        case .outputTooLarge:
            "Git produced more output than Jit allows for this operation."
        case let .processFailed(_, summary, _):
            summary
        case let .launchFailed(code):
            "Git couldn't be started (\(String(cString: strerror(code))))."
        case let .io(summary), let .internalError(summary):
            summary
        }
    }

    /// Redacted raw diagnostic text, if any, for a "Details" disclosure.
    public var detail: String? {
        if case let .processFailed(_, _, detail) = self, !detail.isEmpty { return detail }
        return nil
    }
}

enum Redaction {
    /// Removes credential-shaped parts from text that may contain URLs:
    /// `https://user:token@host` → `https://***@host`, and `token=…`/`password=…` values.
    static func redact(_ text: String) -> String {
        var result = text
        result.replace(/(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*:\/\/)[^\s\/@]+@/) { match in
            "\(match.output.scheme)***@"
        }
        result.replace(/(?i)(?<key>token|password|passwd|secret)=[^\s&]+/) { match in
            "\(match.output.key)=***"
        }
        return result
    }
}
