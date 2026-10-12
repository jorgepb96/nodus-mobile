import XCTest
import UIKit

/// Prepared native coverage. Run only in the isolated AcceptanceLab installation;
/// missing marker/grant/retained result is an assertion failure, never a skip.
final class AuthoringRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSavedWorkExportsWithoutAnyLinkedSpaceAndSurvivesColdRestart() throws {
        let id = UUID().uuidString
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] = id
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for restart in 0..<2 {
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            let saved = app.buttons["saved-local-work"]
            XCTAssertTrue(saved.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(app.staticTexts["recovery-fixture-error"].exists)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "space-")).count, 0,
                "The export path must be reachable with no connections, not through a demo vault.")
            XCTAssertTrue(saved.isHittable); saved.tap()
            let export = app.buttons["recovered-work-export"]
            XCTAssertTrue(export.waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons.matching(identifier: "recovered-work-export").count, 1,
                "A cold restart must not create a second archive.")
            XCUIDevice.shared.orientation = restart == 0 ? .portrait : .landscapeLeft
            XCTAssertTrue(export.isHittable)
            XCTAssertGreaterThanOrEqual(export.frame.height, 44)
            export.tap()
            let filename = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "LP.CaptionBar.TopCaption", "Nodus-local-work")).firstMatch
            XCTAssertTrue(filename.waitForExistence(timeout: 15), "A real file must reach the native share sheet.\n" + app.debugDescription)
            let copy = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", "Copiar", "Copy")).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 10), "The native export activity must be available.")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "offline-authoring-export-\(restart)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }

    /// Uses a real lab link produced by unlink -> same-Mac/new-grant QR/code.
    /// Merely opening the recovered output must leave it pending explicit review,
    /// including after a cold restart; this test never approves or generates it.
    @MainActor
    func testNewGrantRetainedResultStaysInExplicitReviewAcrossColdRestart() throws {
        let env = ProcessInfo.processInfo.environment
        let vault = try XCTUnwrap(env["NODUS_ACCEPTANCE_RECOVERY_VAULT"])
        let title = try XCTUnwrap(env["NODUS_ACCEPTANCE_RECOVERY_TITLE"])
        let kind = try XCTUnwrap(env["NODUS_ACCEPTANCE_RECOVERY_KIND"])
        XCTAssertFalse(vault.isEmpty)
        XCTAssertFalse(title.isEmpty)
        XCTAssertTrue(["text", "image"].contains(kind))
        for forbidden in ["NODUS_UI_TEST_DEMO", "NODUS_ACCEPTANCE_AUTHORING_RECOVERY", "NODUS_ACCEPTANCE_PAIRING_LINK", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] {
            XCTAssertNil(env[forbidden], "This scenario requires the actual already relinked laboratory connection.")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        for restart in 0..<2 {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
            app.launch()
            defer { app.terminate() }
            let navigation = app.buttons["nodus-navigation-toggle"]
            if navigation.waitForExistence(timeout: 15) { app.buttons["Cambiar de espacio"].tap() }
            let space = app.buttons["space-" + vault]
            XCTAssertTrue(space.waitForExistence(timeout: 20), "The real relinked vault is required.")
            for _ in 0..<12 { if space.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(space.isHittable); space.tap()
            XCTAssertTrue(navigation.waitForExistence(timeout: 45))
            if app.windows.firstMatch.frame.width < 600 { navigation.tap() }
            let settings = app.buttons["nodus-nav-settings"]
            for _ in 0..<12 { if settings.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(settings.isHittable); settings.tap()
            let review = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "recovered-work-review", title)).firstMatch
            for _ in 0..<16 { if review.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(review.waitForExistence(timeout: 20), "No automatic send may remove the review requirement.")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "recovered-work-review", title)).count, 1, "The fixture must identify one exact retained result.")
            XCTAssertTrue(review.isHittable); review.tap()
            if kind == "image" {
                XCTAssertTrue(app.images["recovered-work-image"].waitForExistence(timeout: 15), "The retained real image must render, not a base64 dump.")
            } else {
                let snippet = try XCTUnwrap(env["NODUS_ACCEPTANCE_RECOVERY_SNIPPET"])
                XCTAssertFalse(snippet.isEmpty, "An empty excerpt would not prove the retained result.")
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", snippet)).firstMatch.waitForExistence(timeout: 15), "The retained real text must render.")
            }
            let publish = app.buttons["recovered-work-publish"]
            for _ in 0..<16 { if publish.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(publish.waitForExistence(timeout: 10))
            XCTAssertTrue(publish.isHittable)
            XCTAssertEqual(publish.label, "Guardar este resultado en el Mac")
            XCTAssertGreaterThanOrEqual(publish.frame.height, 44)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "new-grant-explicit-result-review-\(restart)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
}
