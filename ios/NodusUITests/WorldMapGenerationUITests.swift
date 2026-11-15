import XCTest
import UIKit

/// Requires an already paired, isolated lab with a REAL downloaded source and saved
/// image. Native checks prove visible bytes/identity and real typed-job persistence.
/// Core journal regression separately proves paid checkpoint reuse; these UI tests
/// do not measure provider calls across Mac/device and do not claim that evidence.
/// No bootstrap, synthetic journal or provider credentials are injected into the app.
final class WorldMapGenerationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPaidMapBytesAndIdentitySurviveReopenAndRestart() throws {
        let env = ProcessInfo.processInfo.environment
        let id = try XCTUnwrap(env["NODUS_ACCEPTANCE_WORLD_GENERATION_ID"])
        XCTAssertNotNil(UUID(uuidString: id))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for launch in 0..<2 {
            app.launch()
            try prepareWorkspace(app, autonomous: true)
            try openJobs(app)
            let result = app.buttons["world-saved-result-" + id]
            XCTAssertTrue(result.waitForExistence(timeout: 30), "A real provider-free publication ledger must already contain the paid result.")
            reveal(result, app: app); result.tap()
            let image = app.images["world-paid-image-" + id]
            XCTAssertTrue(image.waitForExistence(timeout: 20), "The same paid image must survive reopening and a process restart.")
            let controls = app.buttons["world-device-generation-controls"]
            reveal(controls, app: app); controls.tap()
            XCTAssertTrue(app.buttons["world-generation-close"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "El dispositivo usa su propio proveedor")).firstMatch.exists)
            let mode = app.buttons["world-generation-mode"]
            XCTAssertTrue(mode.exists); mode.tap()
            let variant = app.buttons["Otra interpretación"]
            XCTAssertTrue(variant.waitForExistence(timeout: 10)); variant.tap()
            XCTAssertFalse(app.buttons["Borde"].exists, "Canonical Desktop variants are text-only; reference geometry belongs to expansion/restyling.")
            let submit = app.buttons["world-generation-submit"]
            XCTAssertTrue(submit.exists)
            XCTAssertGreaterThanOrEqual(submit.frame.height, 44)
            // Merely opening controls or choosing an operation must never regenerate.
            app.buttons["world-generation-close"].tap()
            XCTAssertTrue(image.waitForExistence(timeout: 15))
            capture(app, "world-paid-reopen-\(launch)")
            app.terminate()
        }
    }

    @MainActor
    func testLiveMapFormUsesMacConfigurationAndFitsPhoneRotation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        try prepareWorkspace(app, autonomous: false)
        try navigate(app, route: "map")
        try selectExpectedMap(app)
        XCTAssertTrue(app.buttons["world-map-options"].waitForExistence(timeout: 35))
        app.buttons["world-map-options"].tap()
        let generation = app.buttons["Generar o ampliar mapa"]
        XCTAssertTrue(generation.waitForExistence(timeout: 10)); generation.tap()
        XCTAssertTrue(app.buttons["world-generation-close"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "El Mac usará su proveedor y modelo")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Descargar fuentes e imagen para llevar"].exists)
        let mode = app.buttons["world-generation-mode"]
        mode.tap(); app.buttons["Ampliar geografía"].tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Borde")).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Ampliación")).firstMatch.exists)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            let close = app.buttons["world-generation-close"]
            XCTAssertTrue(close.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(close.frame))
            capture(app, "world-live-form-\(orientation.rawValue)")
        }
    }

    @MainActor
    func testLiveNativeSubmitPersistsRealTypedJob() throws {
        let enabled = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_WORLD_SUBMIT"], "Final runner must configure its copied lab for this write test.")
        XCTAssertEqual(enabled, "1")
        guard enabled == "1" else { throw SetupError.submissionNotEnabled }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch(); defer { app.terminate() }
        try prepareWorkspace(app, autonomous: false)
        try navigate(app, route: "map")
        try selectExpectedMap(app)
        let options = app.buttons["world-map-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 35)); options.tap()
        app.buttons["Generar o ampliar mapa"].tap()
        let close = app.buttons["world-generation-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "El Mac usará su proveedor y modelo")).firstMatch.exists)
        let generate = app.buttons["world-generation-submit"]
        reveal(generate, app: app); XCTAssertTrue(generate.isEnabled); generate.tap()
        let saved = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Mapa guardado en el vault")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 180), "Actual typed Mac job must finish; a local-only preview cannot satisfy persistence.")
        capture(app, "world-live-native-submit-saved")
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["world-map-shared-canvas"].waitForExistence(timeout: 30))
    }

    private enum SetupError: Error { case submissionNotEnabled, missingFixture }
    @MainActor private func openJobs(_ app: XCUIApplication) throws {
        try navigate(app, route: "settings")
        let jobs = app.buttons["companion-jobs-results"]
        XCTAssertTrue(jobs.waitForExistence(timeout: 20)); reveal(jobs, app: app); jobs.tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-job-ledger"].waitForExistence(timeout: 20))
    }
    @MainActor private func prepareWorkspace(_ app: XCUIApplication, autonomous: Bool) throws {
        let vaultId = try required("NODUS_ACCEPTANCE_WORLD_VAULT")
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45), "A real previously paired laboratory must reopen.")
        let changeSpace = app.buttons["Cambiar de espacio"]
        XCTAssertTrue(changeSpace.waitForExistence(timeout: 15)); changeSpace.tap()
        let space = app.buttons["space-" + vaultId]
        XCTAssertTrue(space.waitForExistence(timeout: 20), "The exact supplied world vault must be linked.")
        reveal(space, app: app); space.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        try navigate(app, route: "settings")
        let execution = app.buttons["ai-execution-mode"]
        XCTAssertTrue(execution.waitForExistence(timeout: 20)); reveal(execution, app: app); execution.tap()
        let option = app.buttons[autonomous ? "Autónomo · este dispositivo" : "Live · modelos del Mac"]
        XCTAssertTrue(option.waitForExistence(timeout: 10)); XCTAssertTrue(option.isEnabled); option.tap()
        let selected = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", autonomous ? "Autónomo" : "Live", autonomous ? "Autónomo" : "Live")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: execution)], timeout: 15), .completed, "Execution mode must change through the actual settings control.")
    }
    @MainActor private func selectExpectedMap(_ app: XCUIApplication) throws {
        let mapId = try required("NODUS_ACCEPTANCE_WORLD_MAP_ID")
        let title = try required("NODUS_ACCEPTANCE_WORLD_MAP_TITLE")
        let chooser = app.buttons["world-map-chooser"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 35)); reveal(chooser, app: app); chooser.tap()
        let map = app.buttons[title]
        XCTAssertTrue(map.waitForExistence(timeout: 15), "The exact map title from the real ID/title metadata probe must be present.")
        XCTAssertEqual(app.buttons.matching(identifier: title).count, 1, "Fixture map titles must uniquely identify the requested map ID.")
        reveal(map, app: app); map.tap()
        let canvas = app.descendants(matching: .any)["world-map-shared-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 35))
        XCTAssertEqual(canvas.label, "Mapa: " + title)
        let selection = XCTAttachment(string: "Selected fixture map ID: " + mapId + "\nVerified native canvas title: " + title)
        selection.name = "world-map-selected-fixture"; selection.lifetime = .keepAlways; add(selection)
    }
    private func required(_ key: String) throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Missing required isolated fixture configuration: " + key)
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SetupError.missingFixture }
        return value
    }
    @MainActor private func navigate(_ app: XCUIApplication, route: String) throws {
        let target = app.buttons["nodus-nav-" + route]
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        if !target.isHittable { navigation.tap() }
        XCTAssertTrue(target.waitForExistence(timeout: 15)); reveal(target, app: app); target.tap()
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<16 {
            if element.isHittable { break }
            if element.frame.isEmpty || element.frame.maxY > app.windows.firstMatch.frame.maxY - 30 { app.swipeUp() }
            else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
