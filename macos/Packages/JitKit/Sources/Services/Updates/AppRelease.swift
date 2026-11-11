import Foundation

/// A release version: `MAJOR.MINOR.PATCH` (ADR-0049), with or without a leading `v`. Anything else — a
/// pre-release suffix, text, more than four parts — is not a version Jit updates to.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        components = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// One published release of Jit, as the change log and the updater see it (ADR-0051).
public struct AppRelease: Codable, Sendable, Identifiable, Equatable {
    /// Normalized version ("0.0.5").
    public let version: String
    public let title: String
    /// The release notes (Markdown, as written on the release page).
    public let notes: String
    public let publishedAt: Date?
    public let isPrerelease: Bool
    /// The release's page on GitHub (built by Jit from the tag, not taken from the feed).
    public let pageURL: URL
    /// `Jit-<version>.dmg` and its `.sha256`; both are needed for Jit to install the release itself.
    public let diskImageURL: URL?
    public let checksumURL: URL?

    public var id: String { version }
    public var parsedVersion: AppVersion? { AppVersion(version) }
    public var isInstallable: Bool { diskImageURL != nil && checksumURL != nil }

    public init(
        version: String, title: String, notes: String, publishedAt: Date?, isPrerelease: Bool, pageURL: URL,
        diskImageURL: URL?, checksumURL: URL?
    ) {
        self.version = version
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
        self.diskImageURL = diskImageURL
        self.checksumURL = checksumURL
    }
}

/// Reads the GitHub "list releases" response of Jit's own repository.
public enum ReleaseFeed {
    public struct Repository: Sendable, Equatable {
        public let owner: String
        public let name: String

        public init(owner: String, name: String) {
            self.owner = owner
            self.name = name
        }

        public static let jit = Repository(owner: "ashkanRmk", name: "jit")

        public var feedURL: URL {
            Self.url("https://api.github.com/repos/\(owner)/\(name)/releases?per_page=\(ReleaseFeed.maxReleases)")
        }

        public var releasesPageURL: URL { Self.url("https://github.com/\(owner)/\(name)/releases") }

        func pageURL(tag: String) -> URL { Self.url("https://github.com/\(owner)/\(name)/releases/tag/\(tag)") }

        /// Owner, name and tag are plain ASCII (the tag is a parsed version), so these always form a URL.
        private static func url(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/") }

        /// Only this repository's own release downloads, over HTTPS, are ever fetched.
        func isAssetURL(_ url: URL) -> Bool {
            url.scheme == "https" && url.host == "github.com" && url.user == nil && url.port == nil
                && url.path.hasPrefix("/\(owner)/\(name)/releases/download/") && !url.path.contains("..")
        }
    }

    public static let maxReleases = 20

    private struct Entry: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let publishedAt: Date?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case name, body, draft, prerelease, assets
            case tagName = "tag_name"
            case publishedAt = "published_at"
        }
    }

    /// Releases newest first. Drafts and tags that are not plain versions are left out; pre-releases count
    /// (Jit's test builds are published as pre-releases).
    public static func parse(_ data: Data, repository: Repository = .jit) throws -> [AppRelease] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Entry].self, from: data) else { throw UpdateError.unreadableFeed }
        var releases: [(AppVersion, AppRelease)] = []
        for entry in entries where entry.draft != true {
            guard let version = AppVersion(entry.tagName), !releases.contains(where: { $0.0 == version }) else {
                continue
            }
            let imageName = "Jit-\(version).dmg"
            func asset(_ name: String) -> URL? {
                guard let asset = entry.assets?.first(where: { $0.name == name }),
                    let url = URL(string: asset.downloadURL), repository.isAssetURL(url)
                else { return nil }
                return url
            }
            let title = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            releases.append(
                (
                    version,
                    AppRelease(
                        version: version.description, title: title.isEmpty ? "Jit \(version)" : title,
                        notes: String((entry.body ?? "").prefix(60_000)), publishedAt: entry.publishedAt,
                        isPrerelease: entry.prerelease ?? false,
                        pageURL: repository.pageURL(tag: entry.tagName.trimmingCharacters(in: .whitespaces)),
                        diskImageURL: asset(imageName), checksumURL: asset(imageName + ".sha256"))
                ))
        }
        return releases.sorted { $0.0 > $1.0 }.map(\.1)
    }
}

/// Release notes as the few block kinds the change log draws: headings, paragraphs and bullets. The text of a
/// block keeps its inline Markdown (bold, code, links).
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String, level: Int)
        case paragraph(String)
        case bullet(String, indent: Int)
    }

    /// - Parameter droppingTitle: leaves out a leading `# Title` (the change log shows the release's title itself).
    public static func blocks(from markdown: String, droppingTitle: Bool = true) -> [Block] {
        var blocks: [Block] = []
        var open: Block?

        func flush() {
            if let block = open { blocks.append(block) }
            open = nil
        }

        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ $0 == "-" }) && line.count >= 3 {
                flush()
                continue
            }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
                flush()
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !(droppingTitle && hashes == 1 && blocks.isEmpty) {
                    blocks.append(.heading(text, level: hashes))
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                let indent = raw.prefix { $0 == " " }.count / 2
                open = .bullet(line.dropFirst(2).trimmingCharacters(in: .whitespaces), indent: min(indent, 3))
                continue
            }
            switch open {
            case .paragraph(let text): open = .paragraph(text + " " + line)
            case .bullet(let text, let indent): open = .bullet(text + " " + line, indent: indent)
            case .heading, nil:
                flush()
                open = .paragraph(line)
            }
        }
        flush()
        return blocks
    }
}

/// Why a check or an update did not happen, in words for the change log.
public enum UpdateError: Error, Equatable, Sendable {
    case offline
    case http(Int)
    case unreadableFeed
    case notInstallable
    case cannotUpdateThisBuild
    case translocated
    case cannotReplace(String)
    case checksumMismatch
    case unreadableDiskImage
    case wrongApplication(String)
    case tooLarge

    public var message: String {
        switch self {
        case .offline: "Jit couldn't reach GitHub. Check the connection and try again."
        case .http(403), .http(429): "GitHub is limiting requests from this network. Try again in an hour."
        case .http(404): "Jit's releases weren't found on GitHub. They may not be public yet."
        case .http(let code): "GitHub answered with an error (HTTP \(code)). Try again later."
        case .unreadableFeed: "The list of releases couldn't be read."
        case .notInstallable:
            "This release has no download that Jit can install by itself. Get it from the release page."
        case .cannotUpdateThisBuild:
            "This is a development build, which doesn't replace itself. Get the release from the release page."
        case .translocated:
            "Jit is running from a temporary, read-only location. Move it to the Applications folder, open it again, then update."
        case .cannotReplace(let folder):
            "Jit can't replace itself in “\(folder)”. Move Jit to a folder you can change, or get the new version from the release page."
        case .checksumMismatch: "The download didn't match its published checksum and was thrown away."
        case .unreadableDiskImage: "The downloaded disk image couldn't be opened."
        case .wrongApplication(let reason): "The download was not installed: \(reason)."
        case .tooLarge: "The download was larger than expected and was thrown away."
        }
    }
}
