import Foundation

/// Deterministic GitLab REST v4 stub: version, user, personal_access_tokens/self, projects (search + pagination).
struct GitLabAPI: Sendable {
    let users: [RigUser]
    let denied: Set<String>
    let sshBase: String?
    let projects: [FakeProject] = FakeProject.all

    func handle(_ request: HTTPRequest, route: String, baseURL: String) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return json(405, ["message": "405 Method Not Allowed"])
        }
        if route == "/version" { return json(200, ["version": "17.5.0", "revision": "rig"]) }

        let token =
            request.header("PRIVATE-TOKEN")
            ?? request.header("Authorization").flatMap { header -> String? in
                let parts = header.split(separator: " ", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
            }
        guard let token, let user = users.first(where: { $0.token == token }) else {
            return json(401, ["message": "401 Unauthorized"])
        }
        if denied.contains(user.name) { return json(403, ["message": "403 Forbidden"]) }

        switch route {
        case "/user":
            return json(
                200,
                [
                    "id": user.id, "username": user.name, "name": user.name.capitalized, "avatar_url": NSNull(),
                    "web_url": "\(baseURL)/\(user.name)", "state": "active",
                ])
        case "/personal_access_tokens/self":
            return json(
                200,
                [
                    "id": 1, "name": "rig", "scopes": ["read_api", "read_repository", "write_repository"],
                    "expires_at": "2030-01-01", "active": true, "revoked": false, "user_id": user.id,
                ])
        case "/projects":
            return projectsPage(request: request, baseURL: baseURL)
        default:
            return json(404, ["message": "404 Not Found"])
        }
    }

    private func projectsPage(request: HTTPRequest, baseURL: String) -> HTTPResponse {
        let items = URLComponents(string: "http://rig/?" + request.query)?.queryItems ?? []
        func value(_ name: String) -> String? { items.last { $0.name == name }?.value }
        let perPage = min(100, max(1, Int(value("per_page") ?? "") ?? 20))
        let page = max(1, Int(value("page") ?? "") ?? 1)
        var matches = projects
        if let search = value("search")?.lowercased(), !search.isEmpty {
            matches = matches.filter {
                $0.name.lowercased().contains(search) || $0.pathWithNamespace.lowercased().contains(search)
                    || $0.description.lowercased().contains(search)
            }
        }
        let total = matches.count
        let totalPages = max(1, (total + perPage - 1) / perPage)
        let slice = matches.dropFirst((page - 1) * perPage).prefix(perPage)
        let body = slice.map { $0.json(baseURL: baseURL, sshBase: sshBase) }

        func link(_ target: Int) -> String {
            var query = items.filter { $0.name != "page" && $0.name != "per_page" }
            query.append(URLQueryItem(name: "page", value: String(target)))
            query.append(URLQueryItem(name: "per_page", value: String(perPage)))
            var components = URLComponents()
            components.queryItems = query
            return "<\(baseURL)/api/v4/projects?\(components.percentEncodedQuery ?? "")>"
        }
        var links: [String] = []
        if page > 1 { links.append("\(link(page - 1)); rel=\"prev\"") }
        if page < totalPages { links.append("\(link(page + 1)); rel=\"next\"") }
        links.append("\(link(1)); rel=\"first\"")
        links.append("\(link(totalPages)); rel=\"last\"")

        return json(
            200, body,
            headers: [
                ("X-Total", String(total)), ("X-Total-Pages", String(totalPages)), ("X-Page", String(page)),
                ("X-Per-Page", String(perPage)), ("X-Next-Page", page < totalPages ? String(page + 1) : ""),
                ("X-Prev-Page", page > 1 ? String(page - 1) : ""), ("Link", links.joined(separator: ", ")),
            ])
    }

    private func json(_ status: Int, _ object: Any, headers: [(String, String)] = []) -> HTTPResponse {
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: data)
    }
}

struct FakeProject: Sendable {
    let id: Int
    let name: String
    let namespacePath: String
    let namespaceName: String
    let description: String
    let visibility: String
    let defaultBranch: String
    let lastActivity: String

    var pathWithNamespace: String { "\(namespacePath)/\(name)" }

    /// 120 projects ordered by last activity (newest first). Index 0, `rig/project`, is the real repository
    /// served at `/git/project.git`; the others are listing-only.
    static let all: [FakeProject] = {
        let namespaces = [
            ("platform", "Platform"), ("platform/infra", "Platform / Infra"), ("mobile", "Mobile"),
            ("data/pipelines", "Data / Pipelines"), ("tools", "Tools"),
        ]
        let areas = [
            "billing", "search", "auth", "gateway", "ledger", "catalog", "notify", "reports", "scheduler",
            "inventory", "metrics", "profile",
        ]
        let kinds = ["service", "api", "web", "worker", "cli", "sdk", "docs", "infra", "ios", "android"]
        let visibilities = ["private", "internal", "public"]
        let epoch = 1_793_534_400  // 2026-11-01T12:00:00Z
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [FakeProject] = []
        for index in 0..<120 {
            let stamp = Date(timeIntervalSince1970: TimeInterval(epoch - index * 3600))
            let activity = formatter.string(from: stamp)  // e.g. 2026-11-01T12:00:00.000Z
            if index == 0 {
                result.append(
                    FakeProject(
                        id: 1000, name: "project", namespacePath: "rig", namespaceName: "Rig",
                        description: "The rig's real repository (served by git http-backend).",
                        visibility: "private", defaultBranch: "main", lastActivity: activity))
                continue
            }
            let name = "\(areas[index % areas.count])-\(kinds[(index / areas.count) % kinds.count])"
            let namespace = namespaces[index % namespaces.count]
            result.append(
                FakeProject(
                    id: 1000 + index, name: name, namespacePath: namespace.0, namespaceName: namespace.1,
                    description: index % 7 == 0 ? "" : "Fake \(name) project for listing tests.",
                    visibility: visibilities[index % visibilities.count],
                    defaultBranch: index % 9 == 0 ? "master" : "main", lastActivity: activity))
        }
        return result
    }()

    func json(baseURL: String, sshBase: String?) -> [String: Any] {
        let host = URLComponents(string: baseURL)?.host ?? "127.0.0.1"
        let ssh: String
        if namespacePath == "rig", let sshBase {
            ssh = "\(sshBase)/\(name).git"
        } else {
            ssh = "git@\(host):\(pathWithNamespace).git"
        }
        let http = namespacePath == "rig" ? "\(baseURL)/git/\(name).git" : "\(baseURL)/git/\(pathWithNamespace).git"
        return [
            "id": id, "name": name, "path": name, "path_with_namespace": pathWithNamespace,
            "name_with_namespace": "\(namespaceName) / \(name)",
            "description": description.isEmpty ? NSNull() : description, "visibility": visibility,
            "default_branch": defaultBranch, "http_url_to_repo": http, "ssh_url_to_repo": ssh,
            "web_url": "\(baseURL)/\(pathWithNamespace)", "last_activity_at": lastActivity,
        ]
    }
}
