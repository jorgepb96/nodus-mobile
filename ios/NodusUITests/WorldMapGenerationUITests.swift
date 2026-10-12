import XCTest
import UIKit

/// Requires an already paired, isolated lab with a REAL downloaded source and saved
/// image. The final runner supplies a provider spy HTTP endpoint returning {"calls":N}.
/// No bootstrap, synthetic journal or provider credentials are injected into the app.
final class WorldMapGenerationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPaidMapReopensAndRestartsWithoutAnotherProviderCall() async throws {
        let env = ProcessInfo.processInfo.environment
        let id = try XCTUnwrap(env["NODUS_ACCEPTANCE_WORLD_GENERATION_ID"])
        XCTAssertNotNil(UUID(uuidString: id))
        let before = try await providerCalls()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for launch in 0..<2 {
            app.launch()
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
        let after = try await providerCalls()
        XCTAssertEqual(after, before, "Reopening saved bytes must not incur another paid provider request or silently fall back to Mac generation.")
    }

    @MainActor
    func testLiveMapFormUsesMacConfigurationAndFitsPhoneRotation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        try navigate(app, route: "map")
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
    func testLiveNativeSubmitUsesRealJobAndPersistsWithoutDeviceFallback() async throws {
        guard ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_WORLD_SUBMIT"] == "1" else {
            throw XCTSkip("Final runner must explicitly enable generation against its copied lab/provider fixture.")
        }
        let before = try await providerCalls()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch(); defer { app.terminate() }
        try navigate(app, route: "map")
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
        let after = try await providerCalls()
        XCTAssertEqual(after, before + 1, "Exactly the configured lab provider must receive the native request.")
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["world-map-shared-canvas"].waitForExistence(timeout: 30))
    }

    private func providerCalls() async throws -> Int {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_WORLD_PROVIDER_PROBE_URL"], "Final runner must supply its isolated provider-call counter; no zero-call assumption is allowed.")
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertTrue(["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), "Probe must belong to the isolated local lab.")
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["calls"] as? Int)
    }
    @MainActor private func openJobs(_ app: XCUIApplication) throws {
        try navigate(app, route: "settings")
        let jobs = app.buttons["Trabajos y resultados"]
        XCTAssertTrue(jobs.waitForExistence(timeout: 20)); reveal(jobs, app: app); jobs.tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-job-ledger"].waitForExistence(timeout: 20))
    }
    @MainActor private func navigate(_ app: XCUIApplication, route: String) throws {
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45), "Final runner must first select the existing paired worldbuilding lab and required execution mode.")
        if app.windows.firstMatch.frame.width < 600 { navigation.tap() }
        let target = app.buttons["nodus-nav-" + route]
        XCTAssertTrue(target.waitForExistence(timeout: 15)); reveal(target, app: app); target.tap()
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 { if element.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
