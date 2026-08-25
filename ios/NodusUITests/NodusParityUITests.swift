import XCTest

final class NodusParityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDeterministicDemoOpensRequestedRoute() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "ideas"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launch()

        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 20))
        app.buttons["Navigation"].tap()
        XCTAssertTrue(app.buttons["nodus-nav-ideas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nodus-nav-ideas"].isSelected)
    }

    @MainActor
    func testEveryVisibleDestinationUsesTheSharedShell() throws {
        let routes = [
            "home", "search", "library", "argument", "ideas", "authors", "research",
            "hypothesis", "reading", "deepResearch", "workspace", "writing", "projects",
        ]
        for route in routes {
            let app = XCUIApplication()
            app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
            app.launchEnvironment["NODUS_START_ROUTE"] = route
            app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
            app.launch()
            XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 20), "Missing shared shell for \(route)")
            app.terminate()
        }
    }

    @MainActor
    func testAcademicSidebarMatchesCurrentDesktopHierarchy() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_INTERFACE_STYLE"] = "dark"
        app.launch()

        let search = app.buttons["nodus-nav-search"]
        if !search.waitForExistence(timeout: 10) { app.buttons["nodus-navigation-toggle"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        let orderedRoutes = [
            "home", "library", "search", "ideas", "authors", "argument",
            "research", "immersion", "deepResearch", "workspace", "browser", "radar", "toolkit",
        ]
        for route in orderedRoutes {
            XCTAssertTrue(app.buttons["nodus-nav-\(route)"].exists, "Desktop sidebar row is missing: \(route)")
        }
        for hidden in ["hypothesis", "reading", "writing", "projects"] {
            XCTAssertFalse(app.buttons["nodus-nav-\(hidden)"].exists, "Desktop-default hidden route leaked into the sidebar: \(hidden)")
        }

        let visibleOrder = orderedRoutes.prefix(11).map { app.buttons["nodus-nav-\($0)"].frame.minY }
        XCTAssertEqual(visibleOrder, visibleOrder.sorted(), "Academic sidebar order drifted from Desktop")
        XCTAssertTrue(app.buttons["nodus-nav-group-explore"].exists)
        XCTAssertTrue(app.buttons["nodus-nav-group-analyze"].exists)
        XCTAssertTrue(app.buttons["nodus-nav-group-create"].exists)
        XCTAssertTrue(app.buttons["nodus-nav-group-tools"].exists)
        if app.windows.firstMatch.frame.width > 700 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(search.waitForExistence(timeout: 5))
        }
        attachScreenshot(named: "academic-sidebar-desktop-hierarchy")
    }

    @MainActor
    func testWorkspaceTabsAndCatalogueStateSurviveSectionChanges() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "ideas"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 20))
        let ideaTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-ideas-'"))
        XCTAssertTrue(ideaTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Ideas should expose two simultaneous dossiers")

        app.buttons["workspace-catalogue-ideas"].tap()
        let search = app.textFields["workspace-ideas"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("power")

        openRoute("authors", in: app)
        XCTAssertTrue(app.buttons["workspace-catalogue-authors"].waitForExistence(timeout: 15))
        openRoute("ideas", in: app)

        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 10))
        XCTAssertTrue(ideaTabs.element(boundBy: 1).exists, "Ideas tabs were destroyed by a route change")
        XCTAssertTrue((app.textFields["workspace-ideas"].value as? String)?.contains("power") == true,
                      "The catalogue filter was not retained")
    }

    @MainActor
    func testWorkspaceCatalogueSelectionFillsTheTabInBothAppearanceModes() throws {
        for (style, screenshotName) in [("light", "workspace-tab-selection-light"), ("dark", "workspace-tab-selection-dark")] {
            let app = XCUIApplication()
            app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
            app.launchEnvironment["NODUS_START_ROUTE"] = "ideas"
            app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
            app.launchEnvironment["NODUS_INTERFACE_STYLE"] = style
            app.launch()

            let catalogue = app.buttons["workspace-catalogue-ideas"]
            XCTAssertTrue(catalogue.waitForExistence(timeout: 20))
            XCTAssertTrue(catalogue.isSelected)
            XCTAssertGreaterThan(catalogue.frame.width, 150)
            attachScreenshot(named: screenshotName)
            app.terminate()
        }
    }

    @MainActor
    func testWorkspaceTabsRemainReachableAfterRotation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "ideas"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width)
    }

    @MainActor
    func testAcademicWorkspacesOpenMultipleTabsAndCloseToTheirNeighbour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "ideas"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-ideas"].waitForExistence(timeout: 20))
        let ideaTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-ideas-'"))
        let ideaClosers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-close-ideas-'"))
        XCTAssertTrue(ideaTabs.element(boundBy: 1).waitForExistence(timeout: 10))
        ideaTabs.element(boundBy: 1).tap()
        ideaClosers.element(boundBy: 1).tap()
        XCTAssertTrue(ideaTabs.element(boundBy: 0).isSelected, "Closing the active dossier must select its neighbour")

        openRoute("authors", in: app)
        XCTAssertTrue(app.buttons["workspace-catalogue-authors"].waitForExistence(timeout: 15))
        let authorTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-authors-'"))
        XCTAssertTrue(authorTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Authors should expose simultaneous dossiers")

        openRoute("argument", in: app)
        XCTAssertTrue(app.buttons["workspace-catalogue-argument"].waitForExistence(timeout: 15))
        let argumentTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-argument-'"))
        XCTAssertTrue(argumentTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Argument Map should expose simultaneous grounded maps")
    }

    @MainActor
    func testSavedAuthorsRemainADeviceLocalCataloguePreference() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "authors"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_RESET_SAVED_AUTHORS"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-authors"].waitForExistence(timeout: 20))
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save author' OR label == 'Guardar autor'" )).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label == 'Remove saved author' OR label == 'Quitar autor guardado'" )).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))

        openRoute("ideas", in: app)
        openRoute("authors", in: app)
        XCTAssertTrue(saved.exists,
                      "Saved authors must survive section changes without entering the cloud record")
    }

    @MainActor
    func testAccountLibraryKeepsMultipleReadersAndClosesToItsNeighbour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "library"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-library"].waitForExistence(timeout: 20))
        let readers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-library-'"))
        let closers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-close-library-'"))
        XCTAssertTrue(readers.element(boundBy: 1).waitForExistence(timeout: 15), "Library should keep two readers resident")
        readers.element(boundBy: 1).tap()
        closers.element(boundBy: 1).tap()
        XCTAssertTrue(readers.element(boundBy: 0).isSelected, "Closing the active reader should select its neighbour")
        app.buttons["workspace-catalogue-library"].tap()
        XCTAssertTrue(app.textFields["nodus-search-field"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLibraryReaderTabsScrollAndActionsStayLegible() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "library"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launchEnvironment["NODUS_INTERFACE_STYLE"] = "dark"
        app.launch()

        XCTAssertTrue(app.buttons["workspace-catalogue-library"].waitForExistence(timeout: 20))
        let readers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-library-'"))
        XCTAssertTrue(readers.element(boundBy: 1).waitForExistence(timeout: 15))
        readers.element(boundBy: 1).tap()

        let read = app.buttons["library-reader-pane-read"]
        let metadata = app.buttons["library-reader-pane-metadata"]
        let notes = app.buttons["library-reader-pane-notes"]
        let relations = app.buttons["library-reader-pane-relations"]
        let history = app.buttons["library-reader-pane-history"]
        let export = app.buttons.matching(identifier: "library-reader-export").firstMatch
        for (name, control) in [("read", read), ("metadata", metadata), ("notes", notes), ("relations", relations), ("history", history), ("export", export)] {
            XCTAssertTrue(control.waitForExistence(timeout: 10), "Missing \(name) reader action")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        XCTAssertLessThanOrEqual(export.frame.width, 48, "Export must remain an icon-only action")
        XCTAssertTrue(read.isSelected)
        metadata.tap()
        XCTAssertTrue(metadata.isSelected)
        XCTAssertFalse(read.isSelected)

        let strip = app.scrollViews["workspace-tabs-library"]
        XCTAssertTrue(strip.exists)
        strip.swipeLeft()
        XCTAssertTrue(readers.element(boundBy: 1).exists, "Document tabs must remain reachable after horizontal scrolling")
        attachScreenshot(named: "library-reader-compact-actions")
    }

    @MainActor
    func testDeepResearchGalleryQueueAndReaderToolsMatchDesktopWorkflow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["deep-research-new"].waitForExistence(timeout: 20))
        if app.windows.firstMatch.frame.width > 700 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.buttons["deep-research-new"].waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.descendants(matching: .any)["deep-research-queue"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Networks of correspondence in the early modern Atlantic"].waitForExistence(timeout: 10))
        attachScreenshot(named: "deep-research-gallery")

        app.staticTexts["Networks of correspondence in the early modern Atlantic"].tap()
        XCTAssertTrue(app.buttons["report-tool-outline"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["report-tool-sources"].exists)
        XCTAssertTrue(app.buttons["report-tool-translations"].exists)
        XCTAssertTrue(app.buttons["report-tool-image"].exists)
        attachScreenshot(named: "deep-research-reader")

        app.buttons["report-tool-outline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["report-outline-sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Evidence and method"].exists)
    }

    @MainActor
    func testResearchStateUsesCompactEqualDestinationCards() throws {
        for style in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
            app.launchEnvironment["NODUS_START_ROUTE"] = "research"
            app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
            app.launchEnvironment["NODUS_INTERFACE_STYLE"] = style
            app.launch()

            let gaps = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Huecos", "Gaps")
            ).firstMatch
            XCTAssertTrue(gaps.waitForExistence(timeout: 20))
            XCTAssertFalse(gaps.label.contains("investigación"))
            XCTAssertGreaterThan(gaps.frame.height, 40)

            let themes = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Temas", "Themes")
            ).firstMatch
            XCTAssertTrue(themes.waitForExistence(timeout: 5))
            // SwiftUI reports the accessibility frame with small style-dependent rounding;
            // the card itself uses the fixed height declared by ResearchStateView.
            XCTAssertEqual(themes.frame.height, gaps.frame.height, accuracy: 5)
            attachScreenshot(named: "research-state-destination-cards-\(style)")
            app.terminate()
        }
    }

    @MainActor
    func testChatModalUsesTopDoneInEnglishAndSpanish() throws {
        for (language, locale, expectedLabel) in [("en", "en_US", "Done"), ("es", "es_ES", "Listo")] {
            let app = XCUIApplication()
            app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
            app.launchEnvironment["NODUS_START_ROUTE"] = "authors"
            app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
            app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()

            let author = app.buttons.matching(
                NSPredicate(format: "identifier == %@", "workspace-open-author-row-demo-a-darwin")
            ).firstMatch
            XCTAssertTrue(author.waitForExistence(timeout: 20))
            author.tap()

            let assistant = app.buttons.matching(
                NSPredicate(format: "label == %@", language == "es" ? "Asistente" : "Assistant")
            ).firstMatch
            XCTAssertTrue(assistant.waitForExistence(timeout: 20))
            assistant.tap()

            XCTAssertTrue(app.buttons[expectedLabel].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Close"].exists)
            attachScreenshot(named: "chat-modal-top-done-\(language)")
            app.terminate()
        }
    }

    @MainActor
    func testAuthorSynthesisQueuesInsteadOfReturningMethodNotAllowed() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "authors"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_UI_TEST_ACTIONS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()

        let author = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "workspace-open-author-row-demo-a-darwin")
        ).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 20))
        author.tap()

        let generate = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Generar síntesis", "Regenerar síntesis")
        ).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 20))
        generate.tap()

        let queued = app.staticTexts["La síntesis se ha puesto en cola para Desktop."]
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["method_not_allowed"].exists)
        attachScreenshot(named: "author-synthesis-queued")
    }

    /// A deterministic review atlas for the complete academic sidebar on both size classes.
    /// The same test runs on iPad and iPhone so every image is backed by the same fixture and
    /// navigation sequence instead of two hand-built mock states drifting apart.
    @MainActor
    func testCaptureAcademicReviewSurfaces() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launchEnvironment["NODUS_INTERFACE_STYLE"] = "dark"
        app.launch()

        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 20))
        let isPad = app.windows.firstMatch.frame.width > 700
        if isPad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 8))
        } else {
            XCUIDevice.shared.orientation = .portrait
        }
        let device = isPad ? "ipad" : "iphone"

        attachScreenshot(named: "\(device)-academic-01-home")

        openRoute("library", in: app)
        XCTAssertTrue(app.buttons["workspace-catalogue-library"].waitForExistence(timeout: 15))
        attachScreenshot(named: "\(device)-academic-02-library")

        openRoute("search", in: app)
        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 5))
        attachScreenshot(named: "\(device)-academic-03-search")

        openRoute("ideas", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-ideas"].waitForExistence(timeout: 15))
        attachScreenshot(named: "\(device)-academic-04-ideas")

        openRoute("authors", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-authors"].waitForExistence(timeout: 15))
        attachScreenshot(named: "\(device)-academic-05-authors")

        openRoute("argument", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["workspace-argument"].waitForExistence(timeout: 15))
        attachScreenshot(named: "\(device)-academic-07-argument-map")

        openRoute("research", in: app)
        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 5))
        attachScreenshot(named: "\(device)-academic-08-state-of-the-art")

        openRoute("immersion", in: app)
        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 5))
        attachScreenshot(named: "\(device)-academic-09-immersion")

        openRoute("deepResearch", in: app)
        XCTAssertTrue(app.buttons["deep-research-new"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Networks of correspondence in the early modern Atlantic"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(device)-academic-10-deep-research-gallery")

        app.buttons["deep-research-new"].tap()
        XCTAssertTrue(app.navigationBars["New research"].waitForExistence(timeout: 8))
        attachScreenshot(named: "\(device)-academic-11-deep-research-composer")
        let closeComposer = app.buttons.matching(
            NSPredicate(format: "label == 'Close' OR label == 'Cerrar'")
        ).firstMatch
        XCTAssertTrue(closeComposer.waitForExistence(timeout: 5))
        closeComposer.tap()

        XCTAssertTrue(app.staticTexts["Networks of correspondence in the early modern Atlantic"].waitForExistence(timeout: 8))
        app.staticTexts["Networks of correspondence in the early modern Atlantic"].tap()
        XCTAssertTrue(app.buttons["Report outline"].waitForExistence(timeout: 10))
        attachScreenshot(named: "\(device)-academic-12-deep-research-reader")

        openRoute("workspace", in: app)
        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 5))
        attachScreenshot(named: "\(device)-academic-13-workspace")
    }

    @MainActor
    func testResidentRoutesAndSidebarToggleStayWithinTheDeviceBounds() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "home"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_INTERFACE_STYLE"] = "light"
        app.launch()

        XCTAssertTrue(app.otherElements["nodus-space-shell"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .portrait

        // Populate the resident-route stack: this is the sequence that used to give an
        // inactive route the whole window width, pushing the selected route off-screen.
        for route in ["library", "ideas", "authors", "research", "deepResearch"] {
            openRoute(route, in: app)
        }

        let window = app.windows.firstMatch
        let research = app.buttons["deep-research-new"]
        XCTAssertTrue(research.waitForExistence(timeout: 15))

        func assertContentFits(_ phase: String) {
            XCTAssertGreaterThanOrEqual(research.frame.minX, window.frame.minX - 2, phase)
            XCTAssertLessThanOrEqual(research.frame.maxX, window.frame.maxX + 2, phase)
        }

        assertContentFits("Deep Research must fit before the sidebar toggle")
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        navigation.tap()
        assertContentFits("Deep Research must fit with the sidebar collapsed")
        navigation.tap()
        assertContentFits("Deep Research must fit after the sidebar reopens")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(research.waitForExistence(timeout: 8))
        assertContentFits("Deep Research must fit after rotating to landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(research.waitForExistence(timeout: 8))
        assertContentFits("Deep Research must fit after rotating back to portrait")
        attachScreenshot(named: "sidebar-toggle-adaptive-layout")
    }

    @MainActor
    func testAcademicReadingHypothesisWritingAndProjectsAreNativeRoutes() throws {
        let expectations = [
            ("hypothesis", "academic-hypothesis"),
            ("reading", "academic-reading-path"),
            ("writing", "academic-writing"),
            ("projects", "academic-projects"),
        ]
        for (route, identifier) in expectations {
            let app = XCUIApplication()
            app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
            app.launchEnvironment["NODUS_START_ROUTE"] = route
            app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 20), "Missing native academic route \(route)")
            app.terminate()
        }
    }

    @MainActor
    func testWorldbuildingWorkspacesContinuityAndManuscriptAreNative() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "scenes"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "worldbuilding"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["world-workspace-scenes"].waitForExistence(timeout: 20))
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-scenes-'"))
        let closers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-close-scenes-'"))
        XCTAssertTrue(tabs.element(boundBy: 1).waitForExistence(timeout: 10), "Scenes should keep multiple dossiers open")
        tabs.element(boundBy: 1).tap()
        closers.element(boundBy: 1).tap()
        XCTAssertTrue(tabs.element(boundBy: 0).isSelected)
        attachScreenshot(named: "world-scenes")

        openRoute("continuity", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["world-continuity"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The story moves backwards in world time"].exists)

        openRoute("manuscript", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["world-manuscript"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Arrival at the flooded gate"].exists)
        if app.windows.firstMatch.frame.width < 700 {
            let scenePane = app.buttons["Scene"]
            XCTAssertTrue(scenePane.waitForExistence(timeout: 5), "iPhone must retain the Desktop manuscript rail")
            scenePane.tap()
        }
        XCTAssertTrue(app.staticTexts["What moves here"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rules in play"].exists)
        let writtenScene = app.staticTexts["The written scene"]
        if !writtenScene.exists { app.swipeUp() }
        XCTAssertTrue(writtenScene.waitForExistence(timeout: 5))
        attachScreenshot(named: "world-manuscript")
    }

    @MainActor
    func testPagesAndDatabasesKeepDesktopWorkspacesAndTypedViews() throws {
        let pages = XCUIApplication()
        pages.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        pages.launchEnvironment["NODUS_START_ROUTE"] = "pages"
        pages.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "databases"
        pages.launch()

        XCTAssertTrue(pages.descendants(matching: .any)["pages-workspace"].waitForExistence(timeout: 20))
        let researchPage = pages.buttons["page-open-page-research"].firstMatch
        XCTAssertTrue(researchPage.waitForExistence(timeout: 5))
        researchPage.tap()
        XCTAssertTrue(pages.buttons["workspace-tab-pages-page-research"].waitForExistence(timeout: 8))
        pages.buttons["workspace-catalogue-pages"].tap()
        let sourcePage = pages.buttons["page-open-page-sources"].firstMatch
        XCTAssertTrue(sourcePage.waitForExistence(timeout: 5)); sourcePage.tap()
        XCTAssertTrue(pages.buttons["workspace-tab-pages-page-research"].exists)
        XCTAssertTrue(pages.buttons["workspace-tab-pages-page-sources"].exists)
        pages.buttons["workspace-close-pages-page-sources"].tap()
        XCTAssertTrue(pages.buttons["workspace-tab-pages-page-research"].isSelected)
        pages.terminate()

        let databases = XCUIApplication()
        databases.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        databases.launchEnvironment["NODUS_START_ROUTE"] = "databases"
        databases.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "databases"
        databases.launch()

        XCTAssertTrue(databases.descendants(matching: .any)["databases-workspace"].waitForExistence(timeout: 20))
        let evidence = databases.buttons["database-open-db-evidence"].firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 5)); evidence.tap()
        XCTAssertTrue(databases.buttons["workspace-tab-databases-db-evidence"].waitForExistence(timeout: 8))
        XCTAssertTrue(databases.staticTexts["Weighted"].exists, "Formula columns must remain visible")
        let board = databases.buttons["Review board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 5)); board.tap()
        XCTAssertTrue(databases.staticTexts["In review"].waitForExistence(timeout: 5))
        databases.buttons["workspace-catalogue-databases"].tap()
        let reading = databases.buttons["database-open-db-reading"].firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 5)); reading.tap()
        XCTAssertTrue(databases.buttons["workspace-tab-databases-db-evidence"].exists)
        XCTAssertTrue(databases.buttons["workspace-tab-databases-db-reading"].exists)
        databases.buttons["workspace-close-databases-db-reading"].tap()
        XCTAssertTrue(databases.buttons["workspace-tab-databases-db-evidence"].isSelected)
        attachScreenshot(named: "pages-databases")
    }

    @MainActor
    func testStudyTeachingParityKeepsTabsGradesAndPrivateRecordings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "studyCourses"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "docencia"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["study-courses-workspace"].waitForExistence(timeout: 20))
        if app.windows.firstMatch.frame.width > 700 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.descendants(matching: .any)["study-courses-workspace"].waitForExistence(timeout: 5))
        }
        let courseTabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-studyCourses-'"))
        let courseClosers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-close-studyCourses-'"))
        XCTAssertTrue(courseTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Study must keep simultaneous course dossiers")
        courseTabs.element(boundBy: 1).tap()
        courseClosers.element(boundBy: 1).tap()
        XCTAssertTrue(courseTabs.element(boundBy: 0).isSelected, "Closing the active course must select its neighbour")

        openRoute("teachingGrades", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["teaching-gradebook-workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ada Lovelace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8.60"].exists, "The local projection must match Desktop's weighted grade")
        XCTAssertTrue(app.staticTexts["Private Bridge"].exists || app.staticTexts["Computed locally from a versioned assessment plan"].exists)
        attachScreenshot(named: "teaching-gradebook")

        openRoute("studyRecordings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["study-recordings-workspace"].waitForExistence(timeout: 10))
        let recording = app.staticTexts["Seminar · conflicting witnesses"].firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        recording.tap()
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'We model disagreement'" )).firstMatch.exists)
        attachScreenshot(named: "study-private-recording")
    }

    @MainActor
    func testSensitiveRecordsStayPrivateAndKeepDesktopDossierTabs() throws {
        let archive = XCUIApplication()
        archive.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        archive.launchEnvironment["NODUS_START_ROUTE"] = "archive"
        archive.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "primary_sources"
        archive.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        archive.launch()

        XCTAssertTrue(archive.descendants(matching: .any)["primary-sources-archive-workspace"].waitForExistence(timeout: 20))
        if archive.windows.firstMatch.frame.width > 700 {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(archive.descendants(matching: .any)["primary-sources-archive-workspace"].waitForExistence(timeout: 5))
        }
        let archiveTabs = archive.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-archive-'"))
        let archiveClosers = archive.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-close-archive-'"))
        XCTAssertTrue(archiveTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Primary Sources must keep simultaneous dossiers")
        XCTAssertTrue(archive.staticTexts["Mutual aid committee minutes"].waitForExistence(timeout: 5))
        archiveClosers.element(boundBy: 1).tap()
        XCTAssertTrue(archiveTabs.element(boundBy: 0).isSelected, "Closing a source must select the adjacent dossier")
        XCTAssertTrue(archive.staticTexts["Letter on rent support"].waitForExistence(timeout: 5))
        attachScreenshot(named: "primary-sources-private-dossier")
        archive.terminate()

        let prosopography = XCUIApplication()
        prosopography.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        prosopography.launchEnvironment["NODUS_START_ROUTE"] = "prosopPersons"
        prosopography.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "prosopography"
        prosopography.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        prosopography.launch()

        XCTAssertTrue(prosopography.descendants(matching: .any)["prosopography-prosopPersons-workspace"].waitForExistence(timeout: 20))
        let personTabs = prosopography.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-prosopPersons-'"))
        XCTAssertTrue(personTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Prosopography must keep simultaneous person dossiers")
        XCTAssertTrue(prosopography.staticTexts["James Okafor"].waitForExistence(timeout: 5))
        openRoute("prosopNetworks", in: prosopography)
        XCTAssertTrue(prosopography.descendants(matching: .any)["prosopography-prosopNetworks-workspace"].waitForExistence(timeout: 10))
        prosopography.swipeUp()
        XCTAssertTrue(prosopography.descendants(matching: .any)["prosop-network-edge-edge-ada-james-explicit"].waitForExistence(timeout: 5), "Network edges must expose their provenance")
        XCTAssertTrue(prosopography.descendants(matching: .any)["prosop-network-edge-edge-james-zora-derived"].exists)
        attachScreenshot(named: "prosopography-private-network")
        prosopography.terminate()

        let testimonies = XCUIApplication()
        testimonies.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        testimonies.launchEnvironment["NODUS_START_ROUTE"] = "testimonyInterviews"
        testimonies.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "testimonios"
        testimonies.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        testimonies.launch()

        XCTAssertTrue(testimonies.descendants(matching: .any)["testimonies-testimonyInterviews-workspace"].waitForExistence(timeout: 20))
        let interviewTabs = testimonies.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace-tab-testimonyInterviews-'"))
        XCTAssertTrue(interviewTabs.element(boundBy: 1).waitForExistence(timeout: 10), "Testimonies must keep simultaneous interview dossiers")
        XCTAssertTrue(testimonies.descendants(matching: .any)["testimony-access-restricted-documented"].waitForExistence(timeout: 5), "The current versioned access agreement must govern the dossier")
        XCTAssertTrue(testimonies.staticTexts["INT-01-SES-01.wav"].exists)
        openRoute("testimonyContrasts", in: testimonies)
        XCTAssertTrue(testimonies.descendants(matching: .any)["testimonies-testimonyContrasts-workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(testimonies.staticTexts["Formal eligibility and lived access"].waitForExistence(timeout: 5))
        attachScreenshot(named: "testimonies-private-contrast")
    }

    @MainActor
    func testBrowserRadarToolkitAndSettingsMatchDesktopTools() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "browser"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["browser-workspace"].waitForExistence(timeout: 20))
        let omnibox = app.descendants(matching: .any)["browser-omnibox"]
        XCTAssertTrue(omnibox.waitForExistence(timeout: 5))
        let browserHome = app.descendants(matching: .any)["browser-home"]
        XCTAssertTrue(browserHome.waitForExistence(timeout: 5))
        browserHome.tap()
        let atlasLoaded = NSPredicate(format: "value CONTAINS[c] %@", "nodusresearch.com/research-atlas")
        expectation(for: atlasLoaded, evaluatedWith: omnibox)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["Nodus blocked a local address or unsupported scheme."].exists)
        let tabs = app.buttons.matching(identifier: "browser-tab")
        let before = tabs.count
        app.buttons["browser-new-tab"].tap()
        XCTAssertEqual(tabs.count, before + 1, "Browser must keep simultaneous isolated tabs")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.55)))
        XCTAssertTrue(app.buttons["nodus-nav-home"].waitForExistence(timeout: 5), "The sidebar must open from a left-edge swipe without stealing ordinary page gestures")
        app.buttons["nodus-nav-browser"].tap()
        attachScreenshot(named: "platform-browser")

        openRoute("radar", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["radar-view"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Knowledge graphs for historical research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["radar-check-now"].exists)
        XCTAssertTrue(app.buttons["radar-follow-open"].exists)
        attachScreenshot(named: "platform-radar")

        openRoute("toolkit", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["toolkit-home"].waitForExistence(timeout: 10))
        for card in ["apps", "convert", "protect", "translate", "presenter", "ocr"] {
            XCTAssertTrue(app.buttons["toolkit-card-\(card)"].exists, "Missing native Toolkit card \(card)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["toolkit-run-on-mac"].exists)
        attachScreenshot(named: "platform-toolkit")

        app.buttons["toolkit-card-convert"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolkit-convert-page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolkit-run"].exists)

        openRoute("settings", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testReportSelectionMenuUsesNodusRibbonForPointerSecondaryClick() throws {
        let app = XCUIApplication()
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        app.launchEnvironment["NODUS_SHOW_TAB_DEMO"] = "1"
        app.launch()

        let report = app.staticTexts["Networks of correspondence in the early modern Atlantic"]
        XCTAssertTrue(report.waitForExistence(timeout: 20))
        report.tap()

        let prose = app.textViews.firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 10))

        let start = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
        let end = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.75))
        start.click(forDuration: 0.1, thenDragTo: end)
        end.rightClick()

        let ribbonItems = [
            app.descendants(matching: .any)["nodus-selection-copy"],
            app.descendants(matching: .any)["nodus-selection-bookmark"],
            app.descendants(matching: .any)["nodus-selection-ask"],
            app.descendants(matching: .any)["nodus-selection-more"],
        ]
        for item in ribbonItems {
            XCTAssertTrue(item.waitForExistence(timeout: 5), "The pointer menu must expose the Nodus ribbon")
        }
        let ribbonMidY = ribbonItems[0].frame.midY
        for item in ribbonItems.dropFirst() {
            XCTAssertEqual(item.frame.midY, ribbonMidY, accuracy: 3, "Pointer actions must stay in one row")
        }
        let expandedSystemAction = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label == %@", "Look Up", "Consultar")
        ).firstMatch
        XCTAssertFalse(expandedSystemAction.isHittable, "System actions must remain collapsed under More actions")
        attachScreenshot(named: "report-selection-pointer-nodus-ribbon")

        ribbonItems.last?.tap()
        XCTAssertTrue(expandedSystemAction.waitForExistence(timeout: 5))
        XCTAssertTrue(expandedSystemAction.isHittable, "More actions must expose the system menu on demand")
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openRoute(_ route: String, in app: XCUIApplication) {
        let destination = app.buttons["nodus-nav-\(route)"]
        if !destination.exists {
            app.buttons["nodus-navigation-toggle"].tap()
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 5), "Missing route \(route)")
        destination.tap()
    }
}
