import XCTest

/// Observes the simulator's own controls before attributing input failures to Nodus.
/// Run separately from the application's acceptance campaign.
final class SimulatorPreflightUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPhoneControlCenterOrientationState() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = springboard.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        defer { XCUIDevice.shared.press(.home) }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.015))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.50)))
        capture("phone-system-control-center", springboard)
        let rotation = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[cd] %@ OR label CONTAINS[cd] %@", "orientación", "Rotation Lock")).firstMatch
        XCTAssertTrue(rotation.waitForExistence(timeout: 10), springboard.debugDescription)
    }

    @MainActor
    func testIPadControlCenterAndPointerInput() throws {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.windows.firstMatch.waitForExistence(timeout: 10))
        defer { XCUIDevice.shared.press(.home) }
        let window = springboard.windows.firstMatch
        let topRight = window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.015))
        topRight.hover()
        capture("system-pointer-top-right", springboard)
        topRight.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.50)))
        capture("system-control-center", springboard)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
