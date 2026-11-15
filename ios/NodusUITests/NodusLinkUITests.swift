import XCTest

final class NodusLinkUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testLinkHasReadersAndRestoresOldAuthoringRouteToHome() throws {
        XCUIDevice.shared.orientation = .portrait
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
            XCTAssertTrue(app.buttons["nodus-nav-\(route)"].waitForExistence(timeout: 10), "The drawer must expose reader \(route) after opening")
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
        if switcher.exists {
            switcher.tap()
            let manage = app.buttons["nodus-manage-connections"]
            XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        }
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
        let reports = app
        let report = reports.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Informe profundo · ciencia del aprendizaje")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 45)); report.tap()
        XCTAssertTrue(app.descendants(matching: .any)["report-native-reader"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.images["link-report-cover"].waitForExistence(timeout: 20), "The isolated report's real stored cover must appear, not a placeholder")
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "El corpus respalda la recuperación", "El corpus respalda la recuperación")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30))
        capture(app, "link-deep-research-native-content")
        for _ in 0..<6 { if body.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(body.isHittable)
        body.press(forDuration: 1.2)
        XCTAssertTrue(app.descendants(matching: .any)["nodus-selection-copy"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["nodus-selection-ask"].firstMatch.exists, "Link's reader must not offer an unavailable AI conversation")
        capture(app, "link-native-reading-selection-without-generation")
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
        if play.isSelected {
            play.tap()
            let stopped = expectation(for: NSPredicate { _, _ in !play.isSelected }, evaluatedWith: play)
            XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        }
        // Resume is persistent between launches. Establish enough audio ahead of
        // this play/pause check; a previous test may have left this short fixture
        // one second from its end. Reopening at the chosen position is checked below.
        app.sliders["saved-audio-seek"].adjust(toNormalizedSliderPosition: 0)
        let atStart = expectation(for: NSPredicate { [self] _, _ in
            seconds(app.staticTexts["saved-audio-elapsed"].label) <= 1
        }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [atStart], timeout: 10), .completed)
        let initialElapsed = app.staticTexts["saved-audio-elapsed"].label
        let stoppedValue = play.isSelected
        play.tap()
        let playing = expectation(for: NSPredicate { _, _ in play.isSelected != stoppedValue }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let elapsed = app.staticTexts["saved-audio-elapsed"]
        let advancing = expectation(for: NSPredicate { _, _ in elapsed.label != initialElapsed }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 10), .completed)
        play.tap()
        let paused = expectation(for: NSPredicate { _, _ in play.isSelected == stoppedValue }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        let slider = app.sliders["saved-audio-seek"]
        slider.adjust(toNormalizedSliderPosition: 0.6)
        // XCTest documents this gesture as best effort. Check its actual position
        // against the playback clock, rather than assuming pixel-perfect dragging.
        let actual = slider.normalizedSliderPosition
        print("[link-audio-seek] normalized:\(actual) value:\(String(describing: slider.value)) clock:\(elapsed.label)")
        XCTAssertEqual(actual, 0.6, accuracy: 0.11)
        // SwiftUI exposes the range value in seconds (localized in this run).
        // normalizedSliderPosition is geometric and is not that range value.
        let seeked = expectation(for: NSPredicate { [self] _, _ in
            guard let value = sliderSeconds(slider) else { return false }
            return abs(seconds(elapsed.label) - value) <= 1
        }, evaluatedWith: elapsed)
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
        let mini = app.buttons["podcast-mini-open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10)); mini.tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 20))
        let restored = expectation(for: NSPredicate { [self] _, _ in abs(seconds(elapsed.label) - seekPosition) <= 1 }, evaluatedWith: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed, "Reopening keeps this device's actual position")
        capture(app, "link-podcast-restored-position")
    }

    @MainActor
    func testLinkedPodcastTranscriptSourcesAndChapter() throws {
        let app = try existing(route: "podcast")
        defer { app.terminate() }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let transcript = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcripción")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 20)); transcript.tap()
        XCTAssertTrue(app.staticTexts["Transcripción ficticia para verificar la consulta desde Nodus Link."].waitForExistence(timeout: 10))
        let sources = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fuentes")).firstMatch
        XCTAssertTrue(sources.exists); sources.tap()
        XCTAssertTrue(app.staticTexts["El efecto de prueba refuerza la retención"].waitForExistence(timeout: 10))
        capture(app, "link-podcast-transcript-and-sources")
        let chapter = app.buttons["Segunda parte"]
        XCTAssertTrue(chapter.isHittable); chapter.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let positioned = expectation(for: NSPredicate { _, _ in
            play.isEnabled && (15...20).contains(self.seconds(app.staticTexts["saved-audio-elapsed"].label))
        }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 25), .completed)
        capture(app, "link-podcast-chapter-at-fifteen-seconds")
    }

    @MainActor
    func testPodcastContinuesPlayingInBackground() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try existing(route: "podcast")
        defer { app.terminate() }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let firstChapter = app.buttons["Primera parte"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 20)); firstChapter.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate { _, _ in play.isEnabled }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        if play.isSelected {
            play.tap()
            let stopped = expectation(for: NSPredicate { _, _ in !play.isSelected }, evaluatedWith: play)
            XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        }
        let pausedValue = play.isSelected; play.tap()
        let started = expectation(for: NSPredicate { _, _ in play.isSelected != pausedValue }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
        let elapsed = app.staticTexts["saved-audio-elapsed"]
        let before = seconds(elapsed.label)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        // The native metadata/artwork/commands have their own API-level test.
        // System Control Center modules are empty in this simulator runtime;
        // their visual appearance remains explicitly pending on the owner's device.
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let continued = expectation(for: NSPredicate { [self] _, _ in
            play.isSelected != pausedValue && seconds(elapsed.label) >= before + 2
        }, evaluatedWith: play)
        XCTAssertEqual(XCTWaiter.wait(for: [continued], timeout: 10), .completed, "Playback must continue while the application is in the background")
        play.tap()
        capture(app, "link-podcast-after-background-playback")
    }

    @MainActor
    func testPodcastKeepsPlayingAcrossSectionsWithMiniPlayer() throws {
        let app = try existing(route: "podcast")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let firstChapter = app.buttons["Primera parte"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 20)); firstChapter.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let elapsed = app.staticTexts["saved-audio-elapsed"]
        let before = seconds(elapsed.label)
        app.buttons["Cerrar"].firstMatch.tap()
        XCTAssertTrue(app.buttons["podcast-mini-play"].waitForExistence(timeout: 10))
        select("ideas", in: app)
        XCTAssertTrue(app.buttons["podcast-mini-open"].waitForExistence(timeout: 10))
        select("dictionary", in: app)
        XCTAssertTrue(app.otherElements["shared-desktop-dictionary"].webViews.firstMatch.waitForExistence(timeout: 30))
        let mini = app.buttons["podcast-mini-open"]
        XCTAssertTrue(mini.isHittable); mini.tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(seconds(elapsed.label), before)
        XCTAssertTrue(play.isSelected)
        capture(app, "podcast-after-reading-other-sections")
    }

    @MainActor
    func testPodcastControlsFitTheSheetWithLargeTextInBothOrientations() throws {
        let app = try existing(route: "podcast", dynamicType: "accessibility3")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let chapter = app.buttons["Primera parte"]
        if !chapter.isHittable { app.swipeUp() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 20) && chapter.isHittable); chapter.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        if play.isSelected { play.tap() }
        let sheet = app.descendants(matching: .any)["podcast-player-sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let turned = expectation(for: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }, evaluatedWith: app)
            XCTAssertEqual(XCTWaiter.wait(for: [turned], timeout: 15), .completed)
            for identifier in ["saved-audio-play", "saved-audio-back", "saved-audio-forward"] {
                let button = app.buttons[identifier]
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertTrue(sheet.frame.insetBy(dx: -1, dy: -1).contains(button.frame), "The complete \(identifier) button must fit inside the actual player sheet")
                XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(button.frame), "The complete \(identifier) button must also fit inside the screen")
            }
            capture(app, "podcast-controls-accessible-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    @MainActor
    func testPhoneBottomNavigationOpensReadersWithoutTheDrawer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launch()
        defer { app.terminate() }
        let ideas = app.buttons["nodus-bottom-ideas"]
        XCTAssertTrue(ideas.waitForExistence(timeout: 30) && ideas.isHittable)
        ideas.tap()
        let more = app.buttons["nodus-bottom-more"]
        XCTAssertTrue(more.isHittable); more.tap()
        XCTAssertTrue(app.buttons["Biblioteca"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Ajustes"].exists)
        let search = app.buttons["Buscar"].firstMatch
        XCTAssertTrue(search.isHittable); search.tap()
        XCTAssertTrue(app.textFields["nodus-search-field"].waitForExistence(timeout: 10))
        let home = app.buttons["nodus-bottom-home"]
        XCTAssertTrue(home.isHittable); home.tap()
        XCTAssertTrue(app.buttons["link-home-ideas"].waitForExistence(timeout: 10))
        capture(app, "phone-native-bottom-navigation")
    }

    @MainActor
    func testDemoRoutesDoNotReportAComputerConnectionFailure() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["link-home-ideas"].waitForExistence(timeout: 30))
        for route in ["graph", "dictionary", "deepResearch", "podcast", "graph", "dictionary"] {
            select(route, in: app)
            XCTAssertFalse(app.staticTexts["podcasts-error"].exists)
            let loading = app.descendants(matching: .any)["shared-surface-loading"].firstMatch
            if loading.exists { XCTAssertTrue(loading.waitForNonExistence(timeout: 35)) }
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
            capture(app, "demo-reader-\(route)")
        }
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


    @MainActor
    func testWorkspaceChooserIsAPopoverAndKeepsBottomNavigation() throws {
        let app = try existing(route: "home")
        defer { app.terminate() }
        app.buttons["nodus-workspace-switch"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["vault-switcher-popover"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["nodus-bottom-home"].exists || app.buttons["nodus-nav-home"].exists)
        XCTAssertFalse(app.buttons["nodus-add-server"].exists)
        capture(app, "workspace-popover-keeps-navigation")
    }

    @MainActor
    func testLinkedSectionsDownloadAndRemoveLocally() throws {
        let app = try existing(route: "home")
        defer { app.terminate() }
        for route in ["ideas", "authors", "dictionary", "deepResearch", "graph", "argument", "library", "podcast"] {
            select(route, in: app)
            let indicator = app.buttons["section-download-\(route)"].firstMatch
            XCTAssertTrue(indicator.waitForExistence(timeout: 40) && indicator.isHittable)
            indicator.tap()
            let download = app.buttons["section-download-start"]
            XCTAssertTrue(download.waitForExistence(timeout: 10)); download.tap()
            let saved = expectation(for: NSPredicate(format: "value CONTAINS %@", "Descargado"), evaluatedWith: indicator)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 60), .completed, route)
            capture(app, "downloaded-section-\(route)")
            indicator.tap()
            let remove = app.buttons["section-download-remove"]
            XCTAssertTrue(remove.waitForExistence(timeout: 10)); remove.tap()
            let removed = expectation(for: NSPredicate(format: "NOT value CONTAINS %@", "Descargado"), evaluatedWith: indicator)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
        }
    }


    @MainActor
    func testSelectedReadersAndPodcastReopenAfterMacDisconnects() throws {
        executionTimeAllowance = 360
        let app = try existing(route: "home")
        defer { app.terminate() }
        for route in ["deepResearch", "dictionary", "graph", "podcast"] {
            select(route, in: app)
            let indicator = app.buttons["section-download-\(route)"].firstMatch
            XCTAssertTrue(indicator.waitForExistence(timeout: 40)); indicator.tap()
            let start = app.buttons["section-download-start"]
            XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
            let saved = expectation(for: NSPredicate(format: "value CONTAINS %@", "Descargado"), evaluatedWith: indicator)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 60), .completed)
        }
        let audio = app.buttons["podcast-download-link-podcast-fixture"].firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 30)); audio.tap()
        app.buttons["Descargar podcast"].tap()
        let savedAudio = expectation(for: NSPredicate(format: "value CONTAINS %@", "Descargado"), evaluatedWith: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [savedAudio], timeout: 60), .completed)
        print("NODUS_LINK_SELECTED_COPIES_READY")
        // The harness stops only its own marked laboratory process at this milestone.
        let gone = expectation(for: NSPredicate(format: "value CONTAINS %@", "Sin conexión"), evaluatedWith: app.buttons["section-download-podcast"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 70), .completed)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 30))
        select("dictionary", in: app)
        let dictionary = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        XCTAssertTrue(dictionary.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Aprendizaje · Nodus Link")).firstMatch.waitForExistence(timeout: 45))
        capture(app, "selected-dictionary-offline-after-relaunch")
        select("deepResearch", in: app)
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Informe profundo · ciencia del aprendizaje")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 35)); report.tap()
        XCTAssertTrue(app.descendants(matching: .any)["report-native-reader"].firstMatch.waitForExistence(timeout: 30))
        capture(app, "selected-report-offline-after-relaunch")
        select("graph", in: app)
        let graph = app.otherElements["shared-desktop-graph"].webViews.firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 30))
        XCTAssertTrue(graph.textFields.firstMatch.waitForExistence(timeout: 45))
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "selected-graph-offline-after-relaunch")
        select("podcast", in: app)
        let episode = app.buttons["podcast-link-podcast-fixture"]
        XCTAssertTrue(episode.waitForExistence(timeout: 35)); episode.tap()
        let listen = app.buttons["podcast-listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 20)); listen.tap()
        XCTAssertTrue(app.buttons["saved-audio-play"].waitForExistence(timeout: 40))
        capture(app, "selected-podcast-playing-offline")
        print("NODUS_LINK_SELECTED_COPIES_PASSED")
    }

    @MainActor private func existing(route: String, dynamicType: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_START_ROUTE"] = route
        if let dynamicType { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = dynamicType }
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchEnvironment["NODUS_INTERFACE_STYLE"] = style
        }
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_AUDIO_TRACE"] == "1" {
            app.launchEnvironment["NODUS_ACCEPTANCE_AUDIO_TRACE"] = "1"
        }
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
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func seconds(_ clock: String) -> Double {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return -.infinity }
        return parts[0] * 60 + parts[1]
    }
    @MainActor private func sliderSeconds(_ slider: XCUIElement) -> Double? {
        if let value = slider.value as? NSNumber { return value.doubleValue }
        guard let text = slider.value as? String else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES"); formatter.numberStyle = .decimal
        let percent = text.contains("%")
        guard let value = formatter.number(from: text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))?.doubleValue else { return nil }
        return percent ? value * 30 / 100 : value
    }
}
