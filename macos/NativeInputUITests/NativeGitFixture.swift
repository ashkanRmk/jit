import AppKit
import Foundation
import XCTest

/// Real Git history and identity isolated from the user's repositories, configuration and app support.
struct NativeGitFixture {
    let root: URL
    let repo: URL
    let state: URL
    private let executable: String
    private(set) var ids: [String: String] = [:]
    private(set) var base = ""

    init() throws {
        executable = try XCTUnwrap(
            ProcessInfo.processInfo.environment["JIT_NATIVE_FIXTURE_GIT"],
            "Run scripts/testing/native-rebase-acceptance.sh to supply the actual Git executable")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jit-native-input-\(UUID())")
        repo = root.appendingPathComponent("repo")
        state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        do {
            _ = try git("init", "-q", "-b", "feature/native")
            _ = try git("commit", "--allow-empty", "-qm", "Base")
            base = try git("rev-parse", "HEAD")
            for subject in ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"] {
                try (subject + "\n").write(
                    to: repo.appendingPathComponent(subject + ".txt"), atomically: true, encoding: .utf8)
                _ = try git("add", "-A")
                _ = try git("commit", "-qm", subject)
                ids[subject] = try git("rev-parse", "HEAD")
            }
            let profileID = UUID().uuidString
            let profiles: [String: Any] = [
                "version": 2, "activeProfileID": profileID,
                "profiles": [
                    [
                        "id": profileID, "displayName": "Native QA", "colorIndex": 1,
                        "author": ["name": "Native QA", "email": "native@jit.invalid"],
                    ]
                ],
            ]
            try JSONSerialization.data(withJSONObject: profiles).write(
                to: state.appendingPathComponent("profiles.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func git(_ arguments: String...) throws -> String { try runGit(arguments) }
    func runGit(_ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = repo
        task.environment = [
            "PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Fixture Author",
            "GIT_AUTHOR_EMAIL": "author@jit.invalid",
            "GIT_COMMITTER_NAME": "Fixture Author", "GIT_COMMITTER_EMAIL": "author@jit.invalid",
        ]
        let output = Pipe()
        task.standardOutput = output; task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.terminationStatus == 0 else {
            throw NSError(
                domain: "GitFixture", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    /// Keep captures on the primary display; XCTest cannot capture this setup's secondary display.
    @MainActor func launch(_ app: XCUIApplication) throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let frame = window.frame
        guard !bounds.contains(frame) else { return }
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let destination = titleBar.withOffset(
            CGVector(
                dx: (bounds.width - frame.width) / 2 - frame.minX,
                dy: (bounds.height - frame.height) / 2 - frame.minY))
        titleBar.click(forDuration: 0.3, thenDragTo: destination)
        XCTAssertTrue(bounds.contains(window.frame), "The QA window must fit on the primary display for captures.")
    }

    @MainActor func application(appearance: String, arguments: [String] = []) throws -> XCUIApplication {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["JIT_NATIVE_APP"])
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchEnvironment["JIT_APP_SUPPORT"] = state.path
        app.launchArguments =
            ["-JitOpen", repo.path, "-JitAppearance", appearance, "-JitAssumeForeground", "YES"] + arguments
        return app
    }
}
