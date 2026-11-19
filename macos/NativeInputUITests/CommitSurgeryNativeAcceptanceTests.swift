import Foundation
import XCTest

@MainActor final class CommitSurgeryNativeAcceptanceTests: XCTestCase {
    func testDirectMessageDropAndRecoveryLight() throws { try verifyActions(appearance: "light") }
    func testDirectMessageDropAndRecoveryDark() throws { try verifyActions(appearance: "dark") }

    private func verifyActions(appearance: String) throws {
        continueAfterFailure = false
        let fixture = try NativeGitFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        let initialHead = try fixture.git("rev-parse", "HEAD")
        let initialTree = try fixture.git("rev-parse", "HEAD^{tree}")
        let app = try fixture.application(appearance: appearance)
        addTeardownBlock { @MainActor in app.terminate() }
        try fixture.launch(app)
        let graph = app.tables["Commit history"]
        XCTAssertTrue(graph.descendants(matching: .tableRow).element(boundBy: 6).waitForExistence(timeout: 15))
        func openAction(_ name: String, row: Int) {
            graph.descendants(matching: .tableRow).element(boundBy: row).coordinate(
                withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)
            ).rightClick()
            let item = app.menuItems[name]
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(item.isEnabled)
            item.click()
        }
        func capture(_ stage: String) {
            let attachment = XCTAttachment(screenshot: app.windows["main"].screenshot())
            attachment.name = "Commit surgery \(stage) — \(appearance)"
            attachment.lifetime = .keepAlways; add(attachment)
        }

        openAction("Edit Message…", row: 1)
        let editor = app.textViews["Commit message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.hasPrefix("Echo") == true)
        editor.click(); app.typeKey("a", modifierFlags: .command)
        let literal = "Echo clarified\n\n# literal presfd '$()' and `text`"
        app.typeText(literal)
        XCTAssertEqual(editor.value as? String, literal)
        capture("message")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Save Message"].waitForExistence(timeout: 5))
        capture("message-review")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, literal)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), initialHead)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Save Message"].waitForExistence(timeout: 5))
        app.buttons["Save Message"].click()
        XCTAssertTrue(app.staticTexts["Edit Message — Succeeded"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%B", "HEAD~1"), literal)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD^{tree}"), initialTree)

        XCTAssertTrue(app.staticTexts["Edit Message — Succeeded"].waitForNonExistence(timeout: 7))
        let parents = try fixture.git("log", "-1", "--format=%P")
        openAction("Edit Message…", row: 0)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.hasPrefix("Foxtrot") == true)
        editor.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Foxtrot clarified")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["Save Message"].waitForExistence(timeout: 5))
        app.buttons["Save Message"].click()
        XCTAssertTrue(app.staticTexts["Edit Message — Succeeded"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%s"), "Foxtrot clarified")
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%P"), parents)
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD^{tree}"), initialTree)

        XCTAssertTrue(app.staticTexts["Edit Message — Succeeded"].waitForNonExistence(timeout: 7))
        let beforeDrop = try fixture.git("rev-parse", "HEAD")
        openAction("Drop Commit…", row: 4)
        XCTAssertTrue(app.buttons["Drop Commit"].waitForExistence(timeout: 5))
        capture("drop-review")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        XCTAssertEqual(try fixture.git("rev-parse", "HEAD"), beforeDrop)
        openAction("Drop Commit…", row: 4)
        XCTAssertTrue(app.buttons["Drop Commit"].waitForExistence(timeout: 5))
        app.buttons["Drop Commit"].click()
        XCTAssertTrue(app.staticTexts["Drop Commit — Succeeded"].waitForExistence(timeout: 15))
        XCTAssertEqual(try fixture.git("rev-list", "--count", fixture.base + "..HEAD"), "5")
        XCTAssertEqual(try fixture.git("diff", "--name-status", beforeDrop, "HEAD"), "D\tBravo.txt")
        XCTAssertEqual(try fixture.git("log", "-1", "--format=%an|%cn"), "Fixture Author|Native QA")
        XCTAssertTrue(try fixture.git("status", "--porcelain").isEmpty)
        capture("completed")

        XCTAssertTrue(app.staticTexts["Drop Commit — Succeeded"].waitForNonExistence(timeout: 7))
        app.buttons["Reflog"].click()
        let recover = app.descendants(matching: .menuButton)["Recover Before Drop Commit…"]
        XCTAssertTrue(recover.waitForExistence(timeout: 10), app.debugDescription)
        recover.click()
        app.menuItems["Create Branch at Previous State…"].click()
        let name = app.textFields["Branch name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeText("recovered-before-drop")
        let create = app.buttons["Create Branch"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        create.click()
        XCTAssertTrue(
            app.staticTexts["Create branch recovered-before-drop — Succeeded"].waitForExistence(timeout: 10),
            app.debugDescription)
        XCTAssertEqual(try fixture.git("rev-parse", "recovered-before-drop"), beforeDrop)
        XCTAssertEqual(try fixture.git("show", "recovered-before-drop:Bravo.txt"), "Bravo")
        capture("recovered")
    }
}
