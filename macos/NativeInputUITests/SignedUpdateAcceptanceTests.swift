import AppKit
import XCTest

final class SignedUpdateAcceptanceTests: XCTestCase {
    @MainActor func testTamperedImageIsRejectedAndSignedImageRestarts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JIT_SIGNED_UPDATE_ACCEPTANCE"] else {
            throw XCTSkip("Run scripts/testing/signed-update-acceptance.sh with a staged Release Jit.app")
        }
        let bundleID = try XCTUnwrap(environment["JIT_SIGNED_UPDATE_BUNDLE"])
        let version = try XCTUnwrap(environment["JIT_SIGNED_UPDATE_VERSION"])
        let fixture = URL(fileURLWithPath: path, isDirectory: true)
        let installed = fixture.appendingPathComponent("installed/Jit.app")
        let plist = installed.appendingPathComponent("Contents/Info.plist")
        let seal = installed.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        let originalInfo = try Data(contentsOf: plist)
        let originalSeal = try Data(contentsOf: seal)
        defer {
            for process in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                process.terminate()
            }
        }

        let tampered = launch(installed, fixture: fixture, feed: "tampered")
        try requestInstall(in: tampered)
        let rejection = tampered.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND (label == %@ OR value == %@)", "update-status-message",
                "The download didn't match its signed checksum. The update was rejected.",
                "The download didn't match its signed checksum. The update was rejected."
            )
        ).firstMatch
        XCTAssertTrue(rejection.waitForExistence(timeout: 20))
        XCTAssertEqual(try Data(contentsOf: plist), originalInfo)
        XCTAssertEqual(try Data(contentsOf: seal), originalSeal)
        XCTAssertFalse(tampered.buttons["Restart Now"].exists)
        XCTAssertFalse(tampered.buttons["Open Release Page"].exists)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.appendingPathComponent("state-tampered/Updates/staged").path)
        )
        tampered.terminate()

        let permit = FileManager.default.temporaryDirectory.appendingPathComponent("jit-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: permit) }
        let valid = launch(installed, fixture: fixture, feed: "valid", downloadPermit: permit)
        let originalPID = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier)
        try requestInstall(in: valid)
        XCTAssertTrue(valid.progressIndicators["update-download-progress"].waitForExistence(timeout: 5))
        try Data().write(to: permit)
        let predicate = NSPredicate { _, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { process in
                process.processIdentifier != originalPID
                    && process.isFinishedLaunching
                    && process.bundleURL?.resolvingSymlinksInPath() == installed.resolvingSymlinksInPath()
            }
        }
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 30)

        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil)
                as? [String: Any])
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, version)
        XCTAssertNotEqual(try Data(contentsOf: seal), originalSeal)
    }

    @MainActor private func launch(
        _ appURL: URL, fixture: URL, feed: String, downloadPermit: URL? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication(url: appURL)
        app.launchEnvironment["JIT_APP_SUPPORT"] = fixture.appendingPathComponent("state-\(feed)").path
        app.launchArguments = ["-JitUpdateFixtureDirectory", fixture.appendingPathComponent(feed).path]
        if let downloadPermit { app.launchArguments += ["-JitUpdateDownloadPermit", downloadPermit.path] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func requestInstall(in app: XCUIApplication) throws {
        let bell = app.buttons["What's New"].firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.click()
        let install = app.buttons["install-update-and-restart"].firstMatch
        _ = try XCTUnwrap(install.waitForExistence(timeout: 15) ? install : nil, "The update fixture did not load")
        install.click()
    }
}
