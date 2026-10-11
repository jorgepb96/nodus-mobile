import XCTest
import UIKit

/// Native input and history, with no provider request or modification of a real vault.
final class NativeChatMobileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPhoneDraftKeepsKeyboardAndSurvivesRotationAndHistoryInBothThemes() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for style in ["light", "dark"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(style: style)
            defer { app.terminate() }
            XCTAssertLessThan(app.windows.firstMatch.frame.width, 600, "Use an iPhone for this acceptance scenario.")
            let composer = app.descendants(matching: .any)["nodus-chat-composer"].firstMatch
            let history = app.buttons["nodus-chat-history"]
            let send = app.buttons["nodus-chat-send"]
            XCTAssertTrue(composer.waitForExistence(timeout: 25)); XCTAssertTrue(composer.isHittable)
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            if let previous = composer.value as? String, previous != "Haz una pregunta", !previous.isEmpty {
                composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            let draft = "Consulta sin enviar\nSegunda linea"
            composer.typeText(draft)
            XCTAssertEqual(composer.value as? String, draft)
            XCTAssertTrue(app.keyboards.firstMatch.exists, "Typing must not dismiss the keyboard.")
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let turned = NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
                XCTAssertEqual(composer.value as? String, draft)
                XCTAssertTrue(composer.isHittable); XCTAssertTrue(send.isHittable); XCTAssertTrue(history.isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(composer.frame))
                capture(app, "native-chat-\(style)-\(orientation == .portrait ? "portrait" : "landscape")")
            }
            history.tap()
            let close = app.buttons["nodus-modal-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10)); XCTAssertTrue(close.isHittable)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
            capture(app, "native-chat-history-\(style)")
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 10))
            XCTAssertEqual(composer.value as? String, draft)
            composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            composer.typeText("x")
            let edited = try XCTUnwrap(composer.value as? String)
            XCTAssertEqual(edited.replacingOccurrences(of: "x", with: ""), draft)
            XCTAssertEqual(edited.count, draft.count + 1)
            app.terminate(); app.launch()
            XCTAssertTrue(composer.waitForExistence(timeout: 25))
            XCTAssertEqual(composer.value as? String, edited, "The unsent question must survive a real process restart.")
            capture(app, "native-chat-durable-composer-\(style)")
        }
    }
    @MainActor private func launch(style: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment = ["NODUS_UI_TEST_DEMO": "1", "NODUS_START_ROUTE": "researchChat", "NODUS_VAULT_TYPE_OVERRIDE": "academic", "NODUS_INTERFACE_STYLE": style]
        app.launch()
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
