import XCTest
import UIKit

/// Actual native workspaces and their long demo document titles. WebKit surfaces
/// have their own acceptance; an Electron component fixture is not this test.
final class WorkspaceTabLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNativeWorkspaceTabsKeepTitlesAndCloseControlsInsideTheirRow() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for style in ["light", "dark"] {
            for route in ["ideas", "authors", "argument"] {
                let app = launch(route: route, style: style)
                defer { app.terminate() }
                try verifyBothOrientations(app, route: route, capturePrefix: "tabs-\(route)-\(style)")
                let active = try activeTab(app, section: route)
                let closeID = active.identifier.replacingOccurrences(of: "workspace-tab-", with: "workspace-close-")
                app.buttons[closeID].tap()
                XCTAssertFalse(app.buttons[closeID].exists, "Closing a document must remove that tab.")
                let catalogue = app.buttons["workspace-catalogue-\(route)"]
                catalogue.tap()
                XCTAssertTrue(catalogue.isSelected)
                XCTAssertGreaterThanOrEqual(catalogue.frame.width, 150, "The selected catalogue shows its title again.")
                app.terminate()
            }
        }
    }

    @MainActor
    func testNativeWorkspaceTabsFitAccessibleTextWithoutCoveringContent() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(route: "ideas", style: "dark", accessible: true)
        defer { app.terminate() }
        try verifyBothOrientations(app, route: "ideas", capturePrefix: "tabs-accessibility3")
    }

    @MainActor
    func testAuthorCatalogueActionsAndRelatedDossiersAreReachable() throws {
        let app = launch(route: "authors", style: "light")
        defer { app.terminate() }
        _ = try activeTab(app, section: "authors")
        app.buttons["workspace-catalogue-authors"].tap()
        let search = app.textFields["nodus-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.tap(); search.typeText("Mill\n")
        let select = app.buttons["workspace-author-select-demo-a-mill"]
        XCTAssertTrue(select.waitForExistence(timeout: 10)); select.tap()
        let export = app.buttons["authors-export-selection"]
        XCTAssertTrue(export.waitForExistence(timeout: 5) && export.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(export.frame))
        XCTAssertFalse(search.frame.intersects(export.frame), "Selection actions must not cover the search field.")
        app.buttons["workspace-open-author-row-demo-a-mill"].tap()
        let work = app.buttons["author-open-work-demo-w-mill-liberty"]
        try reveal(work, in: app)
        work.tap()
        XCTAssertTrue(app.staticTexts["On Liberty"].waitForExistence(timeout: 15), app.debugDescription)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.exists && back.isHittable); back.tap()
        let related = app.buttons["author-open-related-demo-a-tocqueville"]
        try reveal(related, in: app)
        related.tap()
        XCTAssertTrue(app.buttons["workspace-tab-authors-authors-demo-a-tocqueville"].waitForExistence(timeout: 10))
        let selected = try activeTab(app, section: "authors")
        XCTAssertEqual(selected.identifier, "workspace-tab-authors-authors-demo-a-tocqueville")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    @MainActor
    private func launch(route: String, style: String, accessible: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment = ["NODUS_UI_TEST_DEMO": "1", "NODUS_START_ROUTE": route,
            "NODUS_VAULT_TYPE_OVERRIDE": "academic", "NODUS_SHOW_TAB_DEMO": "1", "NODUS_INTERFACE_STYLE": style]
        if accessible { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = "accessibility3" }
        app.launch()
        XCTAssertTrue(app.buttons["workspace-catalogue-\(route)"].waitForExistence(timeout: 25), app.debugDescription)
        return app
    }

    @MainActor
    private func activeTab(_ app: XCUIApplication, section: String) throws -> XCUIElement {
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-tab-\(section)-"))
        let selected = NSPredicate { _, _ in tabs.allElementsBoundByIndex.contains { $0.isSelected && $0.isHittable } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: nil)], timeout: 15), .completed,
            "The selected document must remain reachable.\n" + app.debugDescription)
        return try XCTUnwrap(tabs.allElementsBoundByIndex.first { $0.isSelected })
    }

    @MainActor
    private func verifyBothOrientations(_ app: XCUIApplication, route: String, capturePrefix: String) throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let oriented = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: oriented, object: nil)], timeout: 15), .completed)
            let active = try activeTab(app, section: route)
            let chooser = app.buttons["nodus-workspace-switch"]
            let navigation = app.buttons["nodus-navigation-toggle"]
            let firstAction = app.buttons["nodus-top-command"].exists ? app.buttons["nodus-top-command"] : app.buttons["nodus-top-sparkles"]
            XCTAssertTrue(chooser.isHittable && firstAction.isHittable)
            XCTAssertGreaterThanOrEqual(chooser.frame.minX, navigation.frame.maxX - 1)
            XCTAssertLessThanOrEqual(chooser.frame.maxX, firstAction.frame.minX + 1, "The workspace name cannot cover the action rail.")
            let closeID = active.identifier.replacingOccurrences(of: "workspace-tab-", with: "workspace-close-")
            let close = app.buttons[closeID], catalogue = app.buttons["workspace-catalogue-\(route)"]
            let strip = app.descendants(matching: .any)["workspace-tab-strip-\(route)"].firstMatch
            XCTAssertTrue(strip.exists && close.exists && catalogue.isHittable, app.debugDescription)
            for target in [active, close, catalogue] {
                XCTAssertTrue(target.isHittable)
                XCTAssertGreaterThanOrEqual(target.frame.height, 44)
                XCTAssertGreaterThanOrEqual(target.frame.minY, strip.frame.minY - 1)
                XCTAssertLessThanOrEqual(target.frame.maxY, strip.frame.maxY + 1)
                XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(target.frame))
            }
            XCTAssertGreaterThanOrEqual(close.frame.width, 44)
            XCTAssertGreaterThanOrEqual(close.frame.minX, active.frame.maxX - 1, "The title cannot cover its close control.")
            XCTAssertGreaterThanOrEqual(active.frame.minX, catalogue.frame.maxX - 1, "The catalogue cannot cover the active document.")
            let picture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            picture.name = capturePrefix + (orientation == .portrait ? "-portrait" : "-landscape")
            picture.lifetime = .keepAlways; add(picture)
        }
    }
}
