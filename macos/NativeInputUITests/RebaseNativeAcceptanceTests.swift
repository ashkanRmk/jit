import Foundation
import XCTest

/// Launched against the isolated copy prepared by scripts/testing/native-rebase-acceptance.sh.
/// These use macOS input events through XCTest, not calls to the editor model.
@MainActor
final class RebaseNativeAcceptanceTests: XCTestCase {
    func testDragBothDirectionsAndKeyboardExecutionLight() throws { try verifyNativeInput(appearance: "light") }
    func testDragBothDirectionsAndKeyboardExecutionDark() throws { try verifyNativeInput(appearance: "dark") }

    private func verifyNativeInput(appearance: String) throws {
        continueAfterFailure = false
        let fixture = try NativeGitFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        func git(_ arguments: String...) throws -> String { try fixture.runGit(arguments) }
        let ids = fixture.ids
        let previousHead = try git("rev-parse", "HEAD")
        let previousTree = try git("rev-parse", "HEAD^{tree}")
        let app = try fixture.application(appearance: appearance, arguments: ["-JitInteractiveRebaseBase", "HEAD~6"])
        addTeardownBlock { @MainActor in app.terminate() }
        try fixture.launch(app)
        func row(_ position: Int, _ subject: String, action: String = "Pick") -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Commit \(position) of 6, \(action), \(subject)")
            ).firstMatch
        }
        func handle(_ subject: String) throws -> XCUIElement {
            let oid = try XCTUnwrap(ids[subject])
            return app.images["rebase-drag-" + oid]
        }
        XCTAssertTrue(row(1, "Alpha").waitForExistence(timeout: 15))
        let first = try handle("Alpha")
        let last = try handle("Foxtrot")
        XCTAssertTrue(last.isHittable)
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: row(6, "Foxtrot"))
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 10), .completed,
            "Click selects the handle without starting a drag")
        // Mouse interaction on macOS: press(forDuration:) synthesizes touch input instead.
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
            forDuration: 0.5, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 10, dy: 0.5)))
        XCTAssertTrue(row(1, "Foxtrot").waitForExistence(timeout: 15), app.debugDescription)
        try handle("Foxtrot").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(
            forDuration: 0.5,
            thenDragTo: try handle("Echo").coordinate(withNormalizedOffset: CGVector(dx: 10, dy: 0.5)))
        XCTAssertTrue(row(6, "Foxtrot").waitForExistence(timeout: 15), app.debugDescription)
        let dragCapture = XCTAttachment(screenshot: app.windows["main"].screenshot())
        dragCapture.name = "Native drag in both directions — \(appearance)"
        dragCapture.lifetime = .keepAlways
        add(dragCapture)

        first.coordinate(withNormalizedOffset: CGVector(dx: 10, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(row(1, "Bravo").waitForExistence(timeout: 3))
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(row(2, "Bravo").waitForExistence(timeout: 3))
        app.typeKey("r", modifierFlags: [])
        XCTAssertTrue(row(2, "Bravo", action: "Reword").waitForExistence(timeout: 3))
        let message = app.textViews["Reword message for " + String(try XCTUnwrap(ids["Bravo"]).prefix(7))]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("presfd literal typing\n\nNative keyboard acceptance.")
        XCTAssertEqual(message.value as? String, "presfd literal typing\n\nNative keyboard acceptance.")
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        XCTAssertTrue(row(2, "Bravo", action: "Reword").exists)
        let typingCapture = XCTAttachment(screenshot: app.windows["main"].screenshot())
        typingCapture.name = "Native keyboard and literal typing — \(appearance)"
        typingCapture.lifetime = .keepAlways
        add(typingCapture)
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(app.buttons["Rewrite History"].waitForExistence(timeout: 3))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row(2, "Bravo", action: "Reword").waitForExistence(timeout: 3))
        XCTAssertEqual(try git("rev-parse", "HEAD"), previousHead)
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(app.buttons["Rewrite History"].waitForExistence(timeout: 3))
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Interactive rebase — Succeeded"].waitForExistence(timeout: 15))
        XCTAssertEqual(
            try git("log", "--reverse", "--format=%s", "HEAD~6..HEAD"),
            "Alpha\npresfd literal typing\nCharlie\nDelta\nEcho\nFoxtrot")
        XCTAssertEqual(try git("rev-parse", "HEAD^{tree}"), previousTree)
        XCTAssertEqual(try git("log", "-1", "--format=%an|%cn"), "Fixture Author|Native QA")
        XCTAssertTrue(try git("status", "--porcelain").isEmpty)
        let completedCapture = XCTAttachment(screenshot: app.windows["main"].screenshot())
        completedCapture.name = "Native rebase completed — \(appearance)"
        completedCapture.lifetime = .keepAlways
        add(completedCapture)
    }
}
