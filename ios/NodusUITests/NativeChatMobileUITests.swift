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
            let model = app.buttons["nodus-chat-model"]
            XCTAssertTrue(composer.waitForExistence(timeout: 25)); XCTAssertTrue(composer.isHittable)
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            try clearNativeChatComposer(composer, in: app)
            let draft = "Consulta sin enviar\n" + String(repeating: "Una pregunta sobre las ideas y sus fuentes. ", count: 8)
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
                XCTAssertTrue(model.isHittable)
                XCTAssertGreaterThanOrEqual(model.frame.width, 44)
                XCTAssertGreaterThanOrEqual(model.frame.height, 44)
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

/// A tap in a restored multiline field can put the caret in the middle of the draft.
/// Clear with the real editing menu rather than assuming backspace starts at its end.
@MainActor func clearNativeChatComposer(_ composer: XCUIElement, in app: XCUIApplication) throws {
    guard let value = composer.value as? String, !value.isEmpty, value != composer.placeholderValue else { return }
    composer.press(forDuration: 1.1)
    func captureMenu(_ stage: String) {
        XCTContext.runActivity(named: "Native draft editing menu \(stage)") { activity in
            let picture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            picture.name = "native-composer-edit-menu-\(stage)"; picture.lifetime = .keepAlways; activity.add(picture)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "native-composer-edit-menu-\(stage)-accessibility"; tree.lifetime = .keepAlways; activity.add(tree)
        }
    }
    captureMenu("opened")
    // iOS 26 exposes the inline menu as MenuItems and its expanded grid as Buttons.
    let all = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Seleccionar todo", "Select All")).firstMatch
    for _ in 0..<5 {
        if all.exists && all.isHittable { break }
        let next = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Adelante", "Forward")).firstMatch
        guard next.waitForExistence(timeout: 2), next.isHittable else { break }
        next.tap()
        captureMenu("advanced")
    }
    XCTAssertTrue(all.waitForExistence(timeout: 8), "The native composer must support selecting its complete restored draft.\n" + app.debugDescription)
    all.tap()
    composer.typeText(XCUIKeyboardKey.delete.rawValue)
    XCTAssertTrue((composer.value as? String)?.isEmpty == true || composer.value as? String == composer.placeholderValue)
}
