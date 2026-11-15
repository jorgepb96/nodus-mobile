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
            // The shared field puts its identifier on the capsule, so the magnifier icon and
            // the text field both inherit it. Type in the text field itself, after it exists.
            let field = app.textFields["family-tree-search"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            field.tap(); field.typeText(name + "\n")
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
            node.tap()
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
            let row = app.buttons["genealogy-timeline-event-" + (try string(event, "eventId"))].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 45)); reveal(row, app: app)
            XCTAssertTrue(containsText(try string(event, "date"), app: app).exists)
            XCTAssertTrue(containsText(try string(event, "label"), app: app).exists)
            try rotateAndCapture(app, required: app.buttons["genealogy-timeline-person-filter"], name: "genealogy-timeline-\(attempt)")
            reveal(row, app: app)
            XCTAssertTrue(row.label.contains(try string(event, "date")))
            XCTAssertTrue(row.label.contains(try string(event, "label")))
            XCTAssertGreaterThanOrEqual(row.frame.height + 0.01, 44)
            XCTAssertGreaterThanOrEqual(row.frame.width + 0.01, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(row.frame))
            row.tap()
            // The timeline behind the sheet repeats the date and the title, so those values
            // must now appear twice; the quote and its location exist only in the dossier.
            let dossierTitle = try string(event, "label")
            XCTAssertTrue(app.navigationBars[dossierTitle].waitForExistence(timeout: 15), app.debugDescription)
            for key in ["evidenceQuote", "evidenceLocation"] {
                let value = try string(event, key)
                // The quote and its source/location are rendered as attributed prose lines,
                // so the saved value can be a substring of the announced label.
                let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
                XCTAssertTrue(text.waitForExistence(timeout: 20), "Missing " + key + " in the event dossier")
            }
            XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: try string(event, "date")).count, 2, "The dossier must show the saved event date")
            XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: try string(event, "placeName")).count, 2, "The dossier must show the saved event place")
            XCTAssertTrue(app.buttons[try string(event, "personName")].firstMatch.exists)
            capture(app, "genealogy-owned-event-evidence-\(attempt)")
            app.terminate()
        }
    }

    @MainActor
    func testTypedDatabaseRichPageOpensAndReopens() throws {
        let fixture = try input("NODUS_ACCEPTANCE_TYPED_DATABASES")
        for attempt in 0..<2 {
            let app = try open(vault: string(fixture, "vaultId"), route: "databases")
            defer { capture(app, "rich-page-diagnostic-\(attempt)"); app.terminate() }
            let database = app.buttons["database-open-" + (try string(fixture, "databaseId"))]
            XCTAssertTrue(database.waitForExistence(timeout: 45)); reveal(database, app: app); database.tap()
            let row = app.buttons["database-row-" + (try string(fixture, "rowId"))]
            XCTAssertTrue(row.waitForExistence(timeout: 25)); reveal(row, app: app); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["database-row-inspector"].firstMatch.waitForExistence(timeout: 20))
            app.segmentedControls.buttons["Página"].firstMatch.tap()
            let page = app.buttons["database-row-page-open"]
            XCTAssertTrue(page.waitForExistence(timeout: 15)); reveal(page, app: app); page.tap()
            let body = containsText(try string(fixture, "pageBodySnippet"), app: app)
            XCTAssertTrue(body.waitForExistence(timeout: 30)); reveal(body, app: app)
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
            for property in properties { try verifyStoredProperty(property, app: app) }
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

    /// Queries only: never executes AI/button actions or changes a stored property.
    @MainActor private func verifyStoredProperty(_ property: [String: Any], app: XCUIApplication) throws {
        let id = try string(property, "id"), name = try string(property, "name"), type = try string(property, "type")
        let expected = try XCTUnwrap(property["expected"] as? String)
        let container = app.descendants(matching: .any)["database-property-value-" + id].firstMatch
        reveal(container, app: app)
        XCTAssertTrue(container.exists, "Missing owning property " + id)
        XCTAssertTrue(container.staticTexts[name].firstMatch.exists, "The exact column name must remain visible.")
        func valueField(_ label: String, _ value: String) {
            let field = container.textFields[label].exists ? container.textFields[label] : container.textViews[label]
            XCTAssertTrue(field.exists, "Missing typed field " + label + " for " + type)
            reveal(field, app: app)
            // An empty TextField reports its placeholder as its value.
            let actual = (field.value as? String) == label ? "" : field.value as? String
            XCTAssertEqual(actual, value)
        }
        func touch(_ element: XCUIElement, systemControlRow: Bool = false) throws {
            reveal(element, app: app); XCTAssertTrue(element.exists && element.isHittable)
            settleInsideWindow(element, app: app)
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(window.contains(element.frame), "\(type) control \(element.frame) must be inside \(window)")
            let minimum = try XCTUnwrap(property["minimumTouchHeight"] as? Double)
            // A system DatePicker/Toggle/Picker keeps its intrinsic size even inside a taller
            // row; measure the labelled row those controls fill, while custom buttons are
            // measured exactly.
            let measured = systemControlRow ? container.frame : element.frame
            XCTAssertGreaterThanOrEqual(measured.height + 0.01, minimum, "Touch control too short for " + type)
            XCTAssertGreaterThanOrEqual(measured.width + 0.01, 44)
        }
        func shows(_ value: String) { XCTAssertTrue(container.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", value, value)).firstMatch.exists, "Missing saved value for " + type) }
        switch type {
        case "date", "time":
            let label = type == "date" ? "Inicio" : "Hora"
            let picker = container.datePickers[label].exists ? container.datePickers[label] : container.datePickers.firstMatch
            try touch(picker, systemControlRow: true)
            let raw = try string(property, "raw")
            // The compact DatePicker exposes its displayed date on the inner button, not on
            // the container element and not in `value` alone.
            let display = picker.buttons.firstMatch.exists ? picker.buttons.firstMatch : picker
            let value = display.value as? String ?? ""
            let actual = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? display.label : value
            let alternatives = try localizedDateValues(raw, timeOnly: type == "time")
            XCTAssertTrue(alternatives.contains { actual.contains($0) }, "Saved " + raw + " must be displayed, not a fallback current date; got " + actual)
            if type == "date" { XCTAssertEqual(container.switches["Incluir hora"].value as? String, "0"); XCTAssertEqual(container.switches["Fecha final"].value as? String, "0") }
        case "select", "status":
            let picker = container.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            try touch(picker, systemControlRow: true); XCTAssertTrue(picker.label.contains(expected) || (picker.value as? String) == expected)
        case "multi_select":
            let options = try XCTUnwrap(property["options"] as? [[String: Any]])
            for option in options { let toggle = container.switches[try string(option, "label")]; try touch(toggle, systemControlRow: true); XCTAssertEqual(toggle.value as? String, "1") }
        case "checkbox": let toggle = container.switches["Marcada"]; try touch(toggle, systemControlRow: true); XCTAssertEqual(toggle.value as? String, expected)
        case "person":
            valueField("Nombre", ""); XCTAssertTrue(container.segmentedControls["Tipo"].exists)
            XCTAssertFalse(container.buttons["Añadir"].isEnabled, "An empty saved people list must not become a new person.")
        case "location": for label in ["Lugar", "Dirección", "Latitud", "Longitud"] { valueField(label, "") }
        case "relation": shows("QA ficticio LAB18 · Fila relacionada"); try touch(container.buttons["database-relation-add-" + id])
        case "files", "attachment", "ai_image":
            try touch(container.buttons["database-file-import-" + id])
            let count = try XCTUnwrap(property["attachmentCount"] as? Int)
            XCTAssertEqual(container.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bridge-file-databaseAttachment-'")).count, count)
            if count > 0 { shows("qa-lab18.txt") }
            if type == "ai_image" { try touch(container.buttons["database-property-action-" + id]) }
        case "button": shows("Sin valor"); try touch(container.buttons["database-property-action-" + id])
        case "formula", "rollup", "comparison", "created_by", "last_edited_by", "unique_id": shows(expected)
        case "created_time", "last_edited_time":
            let alternatives = try localizedDateValues(try string(property, "raw"), timeOnly: false, includeTime: true)
            XCTAssertTrue(alternatives.contains { value in container.staticTexts[value].firstMatch.exists }, "Stored row metadata must match, never a fabricated timestamp.")
        default: valueField(name, expected)
        }
    }

    private func localizedDateValues(_ raw: String, timeOnly: Bool, includeTime: Bool = false) throws -> [String] {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = timeOnly ? "HH:mm" : "yyyy-MM-dd"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try XCTUnwrap(iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? parser.date(from: raw))
        var result = [raw]
        for style in [DateFormatter.Style.short, .medium, .long] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es_ES")
            formatter.dateStyle = timeOnly ? .none : style; formatter.timeStyle = timeOnly || includeTime ? .short : .none
            result.append(formatter.string(from: date))
        }
        return result
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
        if element.exists, element.identifier.hasPrefix("family-tree-person-") {
            revealTreeNode(element, app: app)
            return
        }
        for _ in 0..<28 {
            if !element.exists { app.swipeUp(); continue }
            if element.isHittable { return }
            let window = app.windows.firstMatch.frame, frame = element.frame
            let tree = app.scrollViews["genealogy-family-tree"].firstMatch
            // The inspector contains small horizontal text-field scrollers; the last of them
            // cannot move the sheet. Use the tallest vertical scroll view instead.
            let vertical = app.scrollViews.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.height > 200 && $0.frame.height >= $0.frame.width }
            // Prefer the innermost scroll view that actually hosts the control; the iPad
            // sidebar is taller than the inspector and would otherwise swallow the gesture.
            let hosting = vertical.filter { $0.frame.intersects(element.frame) }
            let inspector = app.scrollViews["database-row-inspector"].firstMatch
            let scroll = tree.exists ? tree
                : inspector.exists ? inspector
                : (hosting.min { $0.frame.height < $1.frame.height }
                   ?? vertical.max { $0.frame.height < $1.frame.height }
                   ?? app.scrollViews.firstMatch)
            let viewport = scroll.frame.intersection(window.insetBy(dx: 0, dy: 12))
            if tree.exists, !viewport.isEmpty {
                // Use the outside gutter so a vertical page gesture does not
                // accidentally pan the nested pedigree instead of its parent.
                let canvas = app.scrollViews["family-tree-pedigree"].firstMatch
                drag(scroll, viewport: viewport, dx: 0,
                     dy: frame.isEmpty || frame.maxY > viewport.maxY ? -viewport.height * 0.4 : viewport.height * 0.4,
                     gutterX: canvas.exists ? canvas.frame.maxX + 8 : nil)
            } else if frame.isEmpty || frame.maxY > viewport.maxY { scroll.swipeUp() }
            else { scroll.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor private func revealTreeNode(_ element: XCUIElement, app: XCUIApplication) {
        let tree = app.scrollViews["genealogy-family-tree"].firstMatch
        let canvas = app.scrollViews["family-tree-pedigree"].firstMatch
        for _ in 0..<28 {
            guard element.exists, tree.exists, canvas.exists else { break }
            let outerViewport = tree.frame.intersection(app.windows.firstMatch.frame.insetBy(dx: 0, dy: 12))
            let canvasFrame = canvas.frame
            guard !outerViewport.isEmpty, !canvasFrame.isEmpty else { continue }
            // First reveal the entire canvas with the outer scroll. A gesture
            // on a partly clipped canvas cannot reach a card below the window.
            if canvasFrame.minY < outerViewport.minY || canvasFrame.maxY > outerViewport.maxY {
                drag(tree, viewport: outerViewport, dx: 0,
                     dy: outerViewport.midY - canvasFrame.midY, gutterX: canvasFrame.maxX + 8)
                continue
            }
            let viewport = canvasFrame.intersection(outerViewport).insetBy(dx: 4, dy: 4)
            let frame = element.frame
            guard !frame.isEmpty else { continue }
            if viewport.contains(frame) {
                // AX can throw for clipped nodes, so only ask after checking
                // both the canvas and its parent scroll's visible bounds.
                if element.isHittable { return }
                continue
            }
            let dx = frame.minX < viewport.minX ? viewport.minX - frame.minX
                : frame.maxX > viewport.maxX ? viewport.maxX - frame.maxX : 0
            let dy = frame.minY < viewport.minY ? viewport.minY - frame.minY
                : frame.maxY > viewport.maxY ? viewport.maxY - frame.maxY : 0
            // Move only the measured distance, capped to keep the gesture inside
            // the canvas. Full swipes can jump over a card and oscillate forever.
            drag(canvas, viewport: viewport, dx: dx, dy: dy)
        }
        capture(app, "genealogy-tree-unreachable-node")
        XCTFail("The pedigree card must be fully visible and hittable: " + element.identifier)
    }

    /// Scrolling settles asynchronously; a control that is already hittable can still report
    /// the transient frame from before the final bounce.
    @MainActor private func settleInsideWindow(_ element: XCUIElement, app: XCUIApplication) {
        let inspector = app.scrollViews["database-row-inspector"].firstMatch
        let scroll = inspector.exists ? inspector : app.scrollViews.allElementsBoundByIndex.last ?? app.scrollViews.firstMatch
        for _ in 0..<5 {
            let window = app.windows.firstMatch.frame
            if element.exists && window.contains(element.frame) { return }
            // A control reported hittable at the very bottom can still be clipped by a few
            // points; nudge the hosting scroll view instead of accepting a partial target.
            if element.frame.isEmpty || element.frame.maxY > window.maxY { scroll.swipeUp() } else { scroll.swipeDown() }
            let inside = NSPredicate { _, _ in element.exists && app.windows.firstMatch.frame.contains(element.frame) }
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: inside, object: nil)], timeout: 2)
        }
    }

    @MainActor private func drag(_ scroll: XCUIElement, viewport: CGRect, dx: CGFloat, dy: CGFloat, gutterX: CGFloat? = nil) {
        let frame = scroll.frame
        let origin = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = CGPoint(x: min(viewport.maxX - 4, max(viewport.minX + 4, gutterX ?? viewport.midX)), y: viewport.midY)
        let end = CGPoint(x: start.x + max(-viewport.width * 0.4, min(viewport.width * 0.4, dx)),
                          y: start.y + max(-viewport.height * 0.4, min(viewport.height * 0.4, dy)))
        origin.withOffset(CGVector(dx: start.x - frame.minX, dy: start.y - frame.minY))
            .press(forDuration: 0.05,
                   thenDragTo: origin.withOffset(CGVector(dx: end.x - frame.minX, dy: end.y - frame.minY)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    @MainActor private func rotateAndCapture(_ app: XCUIApplication, required: XCUIElement, name: String) throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in let frame = app.windows.firstMatch.frame; return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15)
            if result != .completed { capture(app, name + "-rotation-failed") }
            XCTAssertEqual(result, .completed)
            reveal(required, app: app)
            settleInsideWindow(required, app: app)
            capture(app, name + "-" + String(orientation.rawValue))
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
