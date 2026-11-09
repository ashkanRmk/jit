import Foundation
import Testing

@testable import GitCore

/// P4.14 — remote URL → web URL (ADR-0034).
@Suite struct WebLinkTests {
    static let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test(arguments: [
        ("https://github.com/owner/repo.git", "https://github.com/owner/repo/commit/\(sha)"),
        ("https://github.com/owner/repo", "https://github.com/owner/repo/commit/\(sha)"),
        ("https://user@github.com/owner/repo.git/", "https://github.com/owner/repo/commit/\(sha)"),
        ("git@github.com:owner/repo.git", "https://github.com/owner/repo/commit/\(sha)"),
        ("ssh://git@github.com/owner/repo.git", "https://github.com/owner/repo/commit/\(sha)"),
        ("ssh://git@github.com:22/owner/repo", "https://github.com/owner/repo/commit/\(sha)"),
        ("https://gitlab.com/group/sub/project.git", "https://gitlab.com/group/sub/project/-/commit/\(sha)"),
        ("git@gitlab.com:group/sub/deeper/project.git", "https://gitlab.com/group/sub/deeper/project/-/commit/\(sha)"),
        ("ssh://git@gitlab.com:2222/group/project.git", "https://gitlab.com/group/project/-/commit/\(sha)"),
    ])
    func webLinkCommit(remote: String, expected: String) {
        #expect(WebLink.map(remoteURL: remote, target: .commit(Self.sha))?.absoluteString == expected)
    }

    @Test(arguments: [
        ("https://github.com/o/r.git", "feature/login", "https://github.com/o/r/tree/feature/login"),
        ("git@github.com:o/r.git", "fix #12 ü", "https://github.com/o/r/tree/fix%20%2312%20%C3%BC"),
        ("https://gitlab.com/g/p.git", "release/1.0", "https://gitlab.com/g/p/-/tree/release/1.0"),
    ])
    func webLinkBranchEncodesSegments(remote: String, branch: String, expected: String) {
        #expect(WebLink.map(remoteURL: remote, target: .branch(branch))?.absoluteString == expected)
    }

    @Test(arguments: [
        "https://example.com/owner/repo.git", "git@bitbucket.org:o/r.git", "/local/path/repo", "file:///tmp/r.git",
        "https://github.com/only-owner", "https://github.com/a/b/c", "ext::sh -c x", "",
    ])
    func webLinkUnknownHostsNil(remote: String) {
        #expect(WebLink.map(remoteURL: remote, target: .commit(Self.sha)) == nil)
    }
}
