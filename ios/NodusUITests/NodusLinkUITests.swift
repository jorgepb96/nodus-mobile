import XCTest

final class NodusLinkUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testLinkHasReadersAndRestoresOldAuthoringRouteToHome() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "writing"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.descendants(matching: .any)["link-home"].firstMatch.waitForExistence(timeout: 30))
        for route in ["ideas", "graph", "argument", "dictionary", "deepResearch", "podcast"] {
            XCTAssertTrue(app.buttons["link-home-\(route)"].exists, "Missing primary reader \(route)")
        }
        XCTAssertFalse(app.buttons["nodus-top-sparkles"].exists)
        app.buttons["nodus-navigation-toggle"].tap()
        for route in ["ideas", "graph", "argument", "dictionary", "deepResearch", "podcast"] {
            XCTAssertTrue(app.buttons["nodus-nav-\(route)"].exists)
        }
        for route in ["writing", "workspace", "researchChat", "browser", "radar", "immersion"] {
            XCTAssertFalse(app.buttons["nodus-nav-\(route)"].exists)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "nodus-link-reader-navigation"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testTypedCodeLinksAndReopensWorkspace() throws {
        let code = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PAIRING_CODE"], "A fresh isolated Desktop code is required")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["nodus-add-server"]
        let switcher = app.buttons["nodus-workspace-switch"]
        let ready = expectation(for: NSPredicate { _, _ in add.exists || switcher.exists }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        if switcher.exists { switcher.tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 15)); add.tap()
        let input = app.textFields["pairing-code"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["nodus-server-address"].exists)
        XCTAssertFalse(app.textFields["SHA-256 certificate fingerprint"].exists)
        input.tap(); input.typeText(code + "\n")
        XCTAssertTrue(input.waitForNonExistence(timeout: 45))
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["link-home-podcast"].exists)
        capture(app, "link-code-connected-home")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.textFields["pairing-code"].exists)
        capture(app, "link-code-restored-home")
    }

    @MainActor
    func testLinkedDictionaryAndReportReadStoredContent() throws {
        let app = try existing(route: "dictionary")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35))
        let entry = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Aprendizaje · Nodus Link")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 45)); entry.tap()
        let definition = web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Definición manual de prueba, versión 2.")).firstMatch
        XCTAssertTrue(definition.waitForExistence(timeout: 30))
        XCTAssertFalse(web.buttons["Nueva entrada"].exists)
        XCTAssertFalse(web.buttons["Generar"].exists)
        web.buttons["Evidencia"].tap()
        XCTAssertTrue(web.buttons["Ver fuente"].waitForExistence(timeout: 20))
        capture(app, "link-dictionary-evidence")
        web.buttons["Ver fuente"].tap()
        let sourceClose = app.buttons["nodus-modal-close"].firstMatch
        XCTAssertTrue(sourceClose.waitForExistence(timeout: 25))
        capture(app, "link-dictionary-native-source")
        sourceClose.tap()
        XCTAssertTrue(sourceClose.waitForNonExistence(timeout: 10))
        web.buttons["Versiones"].tap()
        let versions = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Versión "))
        let versionLabels = Set(versions.allElementsBoundByIndex.map(\.label))
        XCTAssertEqual(versionLabels.count, 2, "Two distinct stored version headings must be available")
        for label in versionLabels.sorted() {
            let heading = versions.matching(NSPredicate(format: "label == %@", label)).firstMatch
            heading.tap()
            let versionNumber = label.hasPrefix("Versión 1:") ? "2" : "1"
            let content = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Definición manual de prueba, versión \(versionNumber).")).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 10))
            heading.tap()
        }
        capture(app, "link-dictionary-versions")
        web.buttons["Relaciones"].tap()
        XCTAssertTrue(web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recuperación · Nodus Link")).firstMatch.waitForExistence(timeout: 10))
        select("deepResearch", in: app)
        let reports = app.otherElements["shared-desktop-deepResearch"].webViews.firstMatch
        let report = reports.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Informe profundo · ciencia del aprendizaje")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 45)); report.tap()
        XCTAssertTrue(app.descendants(matching: .any)["report-native-reader"].firstMatch.waitForExistence(timeout: 30))
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "El corpus respalda la recuperación", "El corpus respalda la recuperación")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        capture(app, "link-deep-research-native-content")
    }

    @MainActor
    func testLinkedPodcastPlaysSeeksAndReopens() throws {
        let app = try existing(route: "podcast")
        defer { app.terminate() }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let listen = app.buttons["podcast-listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 20)); listen.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let prepared = expectation(for: NSPredicate { _, _ in play.isEnabled }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 25), .completed)
        let initialElapsed = app.staticTexts["saved-audio-elapsed"].label
        let stoppedLabel = play.label
        play.tap()
        let playing = expectation(for: NSPredicate { _, _ in play.label != stoppedLabel }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let elapsed = app.staticTexts["saved-audio-elapsed"]
        let advancing = expectation(for: NSPredicate { _, _ in elapsed.label != initialElapsed }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 10), .completed)
        play.tap()
        let paused = expectation(for: NSPredicate { _, _ in play.label == stoppedLabel }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        let slider = app.sliders["saved-audio-seek"]
        slider.adjust(toNormalizedSliderPosition: 0.6)
        // XCTest documents this gesture as best effort. Check its actual position
        // against the playback clock, rather than assuming pixel-perfect dragging.
        let actual = slider.normalizedSliderPosition
        XCTAssertEqual(actual, 0.6, accuracy: 0.11)
        let seeked = expectation(for: NSPredicate { [self] _, _ in abs(seconds(elapsed.label) - Double(actual) * 30) <= 1 }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 10), .completed)
        let seekPosition = seconds(elapsed.label)
        app.buttons["saved-audio-back"].tap()
        let back = expectation(for: NSPredicate { [self] _, _ in abs(seconds(elapsed.label) - max(0, seekPosition - 15)) <= 1 }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 10), .completed)
        app.buttons["saved-audio-forward"].tap()
        let forward = expectation(for: NSPredicate { [self] _, _ in abs(seconds(elapsed.label) - seekPosition) <= 1 }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [forward], timeout: 10), .completed)
        capture(app, "link-podcast-playback-seek")
        app.buttons["Cerrar"].firstMatch.tap()
        XCTAssertTrue(listen.waitForExistence(timeout: 10)); listen.tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 20))
        let restored = expectation(for: NSPredicate { [self] _, _ in abs(seconds(elapsed.label) - seekPosition) <= 1 }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed, "Reopening keeps this device's actual position")
        capture(app, "link-podcast-restored-position")
    }

    @MainActor
    func testDesktopRestartRecoversWithoutAnotherCode() throws {
        executionTimeAllowance = 240
        let app = try existing(route: "podcast")
        defer { app.terminate() }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35))
        print("NODUS_LINK_RECONNECT_READY")
        let issue = app.staticTexts["podcasts-error"]
        XCTAssertTrue(issue.waitForExistence(timeout: 65), "The isolated host must stop after the ready milestone")
        capture(app, "link-desktop-offline-visible")
        print("NODUS_LINK_RECONNECT_OFFLINE")
        XCTAssertTrue(issue.waitForNonExistence(timeout: 65), "Restarting the same Desktop must recover the actual catalogue")
        XCTAssertTrue(episode.isHittable)
        XCTAssertFalse(app.textFields["pairing-code"].exists)
        episode.tap()
        XCTAssertTrue(app.buttons["podcast-listen"].waitForExistence(timeout: 20))
        capture(app, "link-desktop-reconnected-without-code")
    }

    @MainActor private func existing(route: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_START_ROUTE"] = route
        app.launch()
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 30), "Pair the isolated workspace first")
        return app
    }
    @MainActor private func select(_ route: String, in app: XCUIApplication) {
        let destination = app.buttons["nodus-nav-\(route)"]
        if !destination.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
        XCTAssertTrue(destination.waitForExistence(timeout: 10)); destination.tap()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func seconds(_ clock: String) -> Double {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return -.infinity }
        return parts[0] * 60 + parts[1]
    }
}
