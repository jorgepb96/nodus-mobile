import XCTest
import UIKit

/// Actual paired laboratories only. Inputs are generated from owning SQLite rows
/// through a read-only oracle; no demo bootstrap, provider or synthetic UI response.
final class SpecializedWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private enum FixtureError: Error { case missing(String), invalid(String) }

    @MainActor
    func testGenealogyTreeFindsOwningPersonParentAndFullDossierAfterRestart() throws {
        let fixture = try input("NODUS_ACCEPTANCE_GENEALOGY")
        let tree = try object(fixture, "tree")
        let personId = try string(tree, "personId"), name = try string(tree, "personName")
        for attempt in 0..<2 {
            let app = try open(vault: string(fixture, "vaultId"), route: "tree")
            defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
            let search = app.descendants(matching: .any)["family-tree-search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 45))
            let field = search.elementType == .textField ? search : (search.textFields.firstMatch.exists ? search.textFields.firstMatch : app.textFields["nodus-search-field"])
            XCTAssertTrue(field.exists); field.tap(); field.typeText(name + "\n")
            let result = app.buttons["family-tree-search-result-" + personId]
            XCTAssertTrue(result.waitForExistence(timeout: 15)); reveal(result, app: app); result.tap()
            XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
            let parent = app.staticTexts[try string(tree, "parentName")].firstMatch
            reveal(parent, app: app); XCTAssertTrue(parent.exists)
            let pedigree = app.segmentedControls["family-tree-mode"].buttons.element(boundBy: 1)
            XCTAssertTrue(pedigree.exists, "The real genealogy pedigree control must exist.")
            reveal(pedigree, app: app); pedigree.tap()
            let node = app.buttons["family-tree-person-" + personId]
            XCTAssertTrue(node.waitForExistence(timeout: 15))
            try rotateAndCapture(app, required: node, name: "genealogy-tree-\(attempt)")
            let record = app.buttons["Ver la ficha completa"].firstMatch
            reveal(record, app: app); record.tap()
            let content = containsText(try string(tree, "dossierSnippet"), app: app)
            XCTAssertTrue(content.waitForExistence(timeout: 20)); reveal(content, app: app)
            capture(app, "genealogy-owning-dossier-\(attempt)")
            app.terminate()
        }
    }

    @MainActor
    func testGenealogyLocatedMapOpensExactPersonLocationAfterRestart() throws {
        let fixture = try input("NODUS_ACCEPTANCE_GENEALOGY"), map = try object(fixture, "map")
        let placeName = try string(map, "placeName")
        // The oracle must establish a real owned place ID and finite coordinates.
        _ = try string(map, "placeId")
        let latitude = try number(map, "latitude"), longitude = try number(map, "longitude")
        XCTAssertTrue((-90...90).contains(latitude)); XCTAssertTrue((-180...180).contains(longitude))
        for attempt in 0..<2 {
            let app = try open(vault: string(fixture, "vaultId"), route: "map")
            defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
            let canvas = app.descendants(matching: .any)["genealogy-map-canvas"].firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 45), "Missing located fixture must fail, never pass as an empty map.")
            let location = app.buttons[placeName].firstMatch
            XCTAssertTrue(location.waitForExistence(timeout: 20)); reveal(location, app: app)
            try rotateAndCapture(app, required: app.buttons["genealogy-map-person-filter"], name: "genealogy-map-\(attempt)")
            reveal(location, app: app); location.tap()
            let person = app.buttons[try string(map, "personName")].firstMatch
            XCTAssertTrue(person.waitForExistence(timeout: 20))
            let date = containsText(try string(map, "date"), app: app)
            XCTAssertTrue(date.waitForExistence(timeout: 15)); reveal(date, app: app)
            capture(app, "genealogy-owned-location-dossier-\(attempt)")
            app.terminate()
        }
    }

    @MainActor
    func testGenealogyTimelineExactEventParticipantAndEvidenceAfterRestart() throws {
        let fixture = try input("NODUS_ACCEPTANCE_GENEALOGY"), event = try object(fixture, "timeline")
        for attempt in 0..<2 {
            let app = try open(vault: string(fixture, "vaultId"), route: "timeline")
            defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
            let row = app.descendants(matching: .any)["genealogy-timeline-event-" + (try string(event, "eventId"))].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 45)); reveal(row, app: app)
            XCTAssertTrue(containsText(try string(event, "date"), app: app).exists)
            XCTAssertTrue(containsText(try string(event, "label"), app: app).exists)
            try rotateAndCapture(app, required: app.buttons["genealogy-timeline-person-filter"], name: "genealogy-timeline-\(attempt)")
            reveal(row, app: app); row.buttons.firstMatch.tap()
            for key in ["date", "placeName", "evidenceQuote", "evidenceLocation"] {
                let text = containsText(try string(event, key), app: app)
                XCTAssertTrue(text.waitForExistence(timeout: 20)); reveal(text, app: app)
            }
            XCTAssertTrue(app.buttons[try string(event, "personName")].exists)
            capture(app, "genealogy-owned-event-evidence-\(attempt)")
            app.terminate()
        }
    }

    @MainActor
    func testTypedDatabaseAll29StoredPropertiesRelationsFilesAndRichPageAfterRestart() throws {
        let fixture = try input("NODUS_ACCEPTANCE_TYPED_DATABASES")
        let properties = try XCTUnwrap(fixture["properties"] as? [[String: Any]])
        XCTAssertEqual(properties.count, 29)
        XCTAssertEqual(Set(try properties.map { try string($0, "type") }).count, 29)
        guard properties.count == 29 else { throw FixtureError.invalid("canonical 29 property types") }
        for attempt in 0..<2 {
            let app = try open(vault: string(fixture, "vaultId"), route: "databases")
            defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
            let database = app.buttons["database-open-" + (try string(fixture, "databaseId"))]
            XCTAssertTrue(database.waitForExistence(timeout: 45)); reveal(database, app: app); database.tap()
            let row = app.buttons["database-row-" + (try string(fixture, "rowId"))]
            XCTAssertTrue(row.waitForExistence(timeout: 25)); reveal(row, app: app); row.tap()
            let inspector = app.descendants(matching: .any)["database-row-inspector"].firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts[try string(fixture, "rowTitle")].firstMatch.exists)
            for property in properties {
                let name = try string(property, "name"), expected = try XCTUnwrap(property["expected"] as? String, "A stored-value oracle is required even for an intentionally empty cell.")
                let label = app.staticTexts[name].firstMatch
                reveal(label, app: app); XCTAssertTrue(label.exists, "Missing stored property: " + name)
                switch try string(property, "control") {
                case "field":
                    let field = app.textFields[name].exists ? app.textFields[name] : app.textViews[name]
                    XCTAssertTrue(field.exists); reveal(field, app: app)
                    XCTAssertEqual(field.value as? String, expected, "The actual saved value must arrive in its property control.")
                case "choice":
                    let choice = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
                    XCTAssertTrue(choice.exists); reveal(choice, app: app); XCTAssertTrue(choice.label.contains(expected))
                case "toggle":
                    let toggle = app.switches["Marcadas"].firstMatch
                    XCTAssertTrue(toggle.exists); reveal(toggle, app: app); XCTAssertEqual(toggle.value as? String, expected)
                case "computed":
                    let value = exactText(expected, app: app)
                    XCTAssertTrue(value.exists); reveal(value, app: app)
                default: throw FixtureError.invalid("property control")
                }
            }
            let links = app.segmentedControls.buttons["Enlaces"].firstMatch
            reveal(links, app: app); links.tap()
            let related = containsText(try string(fixture, "relatedTitle"), app: app)
            XCTAssertTrue(related.waitForExistence(timeout: 20)); reveal(related, app: app)
            let file = app.buttons["bridge-file-databaseAttachment-" + (try string(fixture, "attachmentId"))]
            XCTAssertTrue(file.waitForExistence(timeout: 20)); reveal(file, app: app)
            XCTAssertTrue(containsText(try string(fixture, "attachmentName"), app: app).exists)
            try rotateAndCapture(app, required: file, name: "typed-database-relations-files-\(attempt)")
            app.segmentedControls.buttons["Página"].firstMatch.tap()
            let page = app.buttons["database-row-page-open"]
            XCTAssertTrue(page.waitForExistence(timeout: 15)); reveal(page, app: app); page.tap()
            let document = app.descendants(matching: .any)["page-document-" + (try string(fixture, "pageId"))].firstMatch
            XCTAssertTrue(document.waitForExistence(timeout: 20))
            let body = containsText(try string(fixture, "pageBodySnippet"), app: app)
            XCTAssertTrue(body.waitForExistence(timeout: 20)); reveal(body, app: app)
            capture(app, "typed-database-owning-rich-row-page-\(attempt)")
            app.terminate()
        }
    }

    private func input(_ key: String) throws -> [String: Any] {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Missing actual read-only fixture: " + key)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    private func object(_ input: [String: Any], _ key: String) throws -> [String: Any] { try XCTUnwrap(input[key] as? [String: Any], "Missing canonical fixture object: " + key) }
    private func string(_ input: [String: Any], _ key: String) throws -> String {
        let value = try XCTUnwrap(input[key] as? String, "Missing canonical fixture value: " + key)
        XCTAssertFalse(value.isEmpty); guard !value.isEmpty else { throw FixtureError.missing(key) }; return value
    }
    private func number(_ input: [String: Any], _ key: String) throws -> Double { try XCTUnwrap(input[key] as? Double) }
    @MainActor private func open(vault: String, route: String) throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let env = ProcessInfo.processInfo.environment
        for key in ["NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_START_ROUTE", "NODUS_UI_TEST_DEMO"] { XCTAssertNil(env[key], "Actual existing paired vaults are required.") }
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]; app.launch()
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        app.buttons["Cambiar de espacio"].tap()
        let space = app.buttons["space-" + vault]
        XCTAssertTrue(space.waitForExistence(timeout: 20)); reveal(space, app: app); space.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        let target = app.buttons["nodus-nav-" + route]
        if !target.isHittable { navigation.tap() }
        XCTAssertTrue(target.waitForExistence(timeout: 15)); reveal(target, app: app); target.tap(); return app
    }
    @MainActor private func containsText(_ value: String, app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch }
    @MainActor private func exactText(_ value: String, app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", value, value)).firstMatch }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<24 {
            if element.exists && element.isHittable { break }
            let scroll = app.scrollViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
            if element.frame.isEmpty || element.frame.maxY > app.windows.firstMatch.frame.maxY - 30 { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor private func rotateAndCapture(_ app: XCUIApplication, required: XCUIElement, name: String) throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in let frame = app.windows.firstMatch.frame; return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            reveal(required, app: app)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(required.frame))
            capture(app, name + "-" + String(orientation.rawValue))
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
