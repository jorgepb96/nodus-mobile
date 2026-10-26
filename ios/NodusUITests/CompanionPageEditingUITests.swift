import XCTest

/// Writes only to the explicitly named disposable row-page fixture.
final class CompanionPageEditingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testManualParagraphPersistsAfterRestart() throws {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TYPED_DATABASES"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key] as? String) }
        let databaseID = try value("databaseId"), rowID = try value("rowId"), pageID = try value("pageId")
        XCTAssertTrue(databaseID.hasPrefix("db_lab18_")); XCTAssertTrue(rowID.hasPrefix("drow_lab18_"))
        XCTAssertEqual(pageID, "row:" + rowID)
        let marker = "MobilePageQA-" + UUID().uuidString
        let identity = XCTAttachment(string: marker); identity.name = "manual-paragraph-marker"; identity.lifetime = .keepAlways; add(identity)

        for attempt in 0..<2 {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["Cambiar de espacio"].waitForExistence(timeout: 45))
            app.buttons["Cambiar de espacio"].tap()
            let space = app.buttons["space-" + (try value("vaultId"))]
            XCTAssertTrue(space.waitForExistence(timeout: 20)); reveal(space, app: app); space.tap()
            let route = app.buttons["nodus-nav-databases"]
            if !route.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
            XCTAssertTrue(route.waitForExistence(timeout: 15)); reveal(route, app: app); route.tap()
            let database = app.buttons["database-open-" + databaseID]
            XCTAssertTrue(database.waitForExistence(timeout: 30)); reveal(database, app: app); database.tap()
            let row = app.buttons["database-row-" + rowID]
            XCTAssertTrue(row.waitForExistence(timeout: 30)); reveal(row, app: app); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["database-row-inspector"].firstMatch.waitForExistence(timeout: 20))
            app.segmentedControls.buttons["Página"].firstMatch.tap()
            let openPage = app.buttons["database-row-page-open"]
            XCTAssertTrue(openPage.waitForExistence(timeout: 15)); reveal(openPage, app: app); openPage.tap()
            let web = app.otherElements["shared-desktop-page"].webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 20))
            let original = web.textViews.matching(NSPredicate(format: "value CONTAINS %@", try value("pageBodySnippet"))).firstMatch
            XCTAssertTrue(original.waitForExistence(timeout: 30), "The original paragraph must remain readable.")
            if attempt == 0 {
                let paragraphs = web.textViews.matching(NSPredicate(format: "label == %@", "Párrafo"))
                let before = paragraphs.count
                let addBlock = web.buttons["Añadir bloque"].firstMatch
                reveal(addBlock, app: app); addBlock.tap()
                // WebKit exposes role=menuitem as a menu item, not a button; the existing
                // paragraph editor is a text view with the same accessible name.
                let paragraph = web.menuItems.matching(NSPredicate(format: "label == %@", "Párrafo")).firstMatch
                XCTAssertTrue(paragraph.waitForExistence(timeout: 10), "The paragraph block type must be present in the add menu")
                XCTAssertTrue(paragraph.isHittable, "The first block type must be visible when the menu opens")
                paragraph.tap()
                let added = NSPredicate { _, _ in paragraphs.count == before + 1 }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: added, object: nil)], timeout: 10), .completed)
                let empty = paragraphs.element(boundBy: before)
                XCTAssertTrue(empty.waitForExistence(timeout: 10)); reveal(empty, app: app); empty.tap(); empty.typeText(marker)
                // The visible "Guardado" pulse lasts 1.5 s and is an aria-live hint, not the
                // persistence contract. Let the debounce flush, then prove the text stays in
                // the editor; the restart below is the authoritative persistence check.
                sleep(3)
                XCTAssertFalse(web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "no se pudo guardar")).firstMatch.exists)
                XCTAssertTrue(web.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch.exists)
            }
            let saved = web.textViews.matching(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 30)); reveal(saved, app: app)
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "manual-paragraph-\(attempt)"; image.lifetime = .keepAlways; add(image)
            app.terminate()
        }
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<20 {
            if element.exists && element.isHittable { return }
            (app.scrollViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch).swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
