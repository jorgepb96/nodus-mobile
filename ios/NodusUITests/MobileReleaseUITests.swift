import XCTest
import UIKit
import CryptoKit

final class MobileReleaseUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testExistingMacPhoneChatKeepsKeyboardDraftAndSeparateHistory() throws {
        let app = try openExistingPrincipal(destination: "researchChat")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 600, "Run this test on an iPhone.")
        let input = app.descendants(matching: .any)["nodus-chat-composer"].firstMatch
        let history = app.buttons["nodus-chat-history"]
        let send = app.buttons["nodus-chat-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 30)); XCTAssertTrue(input.isHittable)
        let draft = "Pregunta de prueba sin enviar\nSegunda línea"
        input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        try clearNativeChatComposer(input, in: app)
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            XCTAssertEqual(input.value as? String, draft)
            for control in [input, history, send] {
                XCTAssertTrue(control.isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), "The native control must fit completely inside the phone.")
            }
            capture(app, orientation == .portrait ? "phone-chat-keyboard-portrait" : "phone-chat-keyboard-landscape")
        }
        history.tap()
        let close = app.buttons["nodus-modal-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        capture(app, "phone-chat-separate-history")
        close.tap(); XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, draft)
        let options = app.buttons["nodus-chat-live-options"]
        XCTAssertTrue(options.isHittable); options.tap()
        XCTAssertTrue(app.buttons["Elegir modelo"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.switches["Búsqueda web"].exists)
        XCTAssertTrue(app.buttons["nodus-chat-options-close"].isHittable)
        capture(app, "phone-chat-native-live-options")
        app.buttons["nodus-chat-options-close"].tap()
        XCTAssertEqual(input.value as? String, draft, "Opening the Mac options must preserve the unsent question.")
    }
    @MainActor private func openExistingPrincipal(destination: String) throws -> XCUIApplication {
        try openExistingVault(destination: destination, vaultId: "default")
    }
    @MainActor private func openExistingVault(destination: String, vaultId: String) throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let env = ProcessInfo.processInfo.environment
        for key in ["NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_START_ROUTE"] {
            XCTAssertNil(env[key], "This regression must use the normally reopened Mac connection.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = env["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        app.launch()
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45), app.debugDescription)
        app.buttons["Cambiar de espacio"].tap()
        let principal = app.buttons["space-" + vaultId]
        XCTAssertTrue(principal.waitForExistence(timeout: 20), "The previously linked workspace must be available.")
        for _ in 0..<16 {
            if principal.isHittable { break }
            if principal.frame.isEmpty || principal.frame.maxY > app.windows.firstMatch.frame.maxY - 30 {
                app.swipeUp()
            } else { app.swipeDown() }
        }
        XCTAssertTrue(principal.isHittable, app.debugDescription); principal.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        if app.windows.firstMatch.frame.width < 600 { navigation.tap() }
        let route = app.buttons["nodus-nav-" + destination]
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        for _ in 0..<8 { if route.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(route.isHittable); route.tap()
        return app
    }
    @MainActor
    func testLiveProsopographyReadsCompletePersonIdentityAndReopens() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PERSON_DOSSIER"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key] as? String) }
        let vault = try value("vaultId"), person = try value("personId")
        let name = try value("name"), biography = try value("biographySnippet"), notes = try value("notes")
        let fields = try [value("birthDate"), value("deathDate"), value("nationalId")]
        for reopen in 0..<2 {
            let app = try openExistingVault(destination: "prosopPersons", vaultId: vault)
            defer { app.terminate() }
            let catalogue = app.buttons["workspace-catalogue-prosopPersons"]
            if catalogue.waitForExistence(timeout: 10), catalogue.isHittable { catalogue.tap() }
            let row = app.buttons["prosop-person-open-" + person]
            XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<10 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.isHittable); row.tap()
            XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15))
            for field in fields { XCTAssertTrue(app.staticTexts[field].waitForExistence(timeout: 15)) }
            for (identifier, text) in [("prosop-person-biography", biography), ("prosop-person-notes", notes)] {
                let section = app.descendants(matching: .any)[identifier].firstMatch
                XCTAssertTrue(section.waitForExistence(timeout: 15), app.debugDescription)
                let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", identifier, text, text)).firstMatch
                XCTAssertTrue(paragraph.waitForExistence(timeout: 15), "The actual saved text must load, not only its section heading.")
                for _ in 0..<10 { if paragraph.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(paragraph.isHittable)
                capture(app, "live-person-\(identifier)-reopen-\(reopen)")
            }
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
            app.terminate()
        }
    }
    @MainActor
    func testLiveProsopographyOpensDocumentedIdentityAndAuthoritySources() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PERSON_DOSSIER"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key] as? String) }
        let app = try openExistingVault(destination: "prosopPersons", vaultId: value("vaultId"))
        defer { app.terminate() }
        let catalogue = app.buttons["workspace-catalogue-prosopPersons"]
        if catalogue.waitForExistence(timeout: 10), catalogue.isHittable { catalogue.tap() }
        let row = app.buttons["prosop-person-open-" + (try value("personId"))]
        XCTAssertTrue(row.waitForExistence(timeout: 45))
        for _ in 0..<10 { if row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        let sources = app.buttons["prosop-person-sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        for _ in 0..<12 { if sources.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(sources.isHittable); XCTAssertGreaterThanOrEqual(sources.frame.height, 44); sources.tap()
        let reader = app.descendants(matching: .any)["private-corpus-source-prosop-person"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 45))
        let identity = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Estado de identidad", "provisional")).firstMatch
        for _ in 0..<10 { if identity.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(identity.exists && identity.isHittable, "The profile must render its actual identity state instead of an empty card.")
        capture(app, "prosopography-documented-identity")
        let picker = app.descendants(matching: .any)["private-source-group-picker"].firstMatch
        for _ in 0..<10 { if picker.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(picker.isHittable); picker.tap()
        let authorityGroup = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Identificadores de autoridad")).firstMatch
        XCTAssertTrue(authorityGroup.waitForExistence(timeout: 10)); authorityGroup.tap()
        let identifier = app.staticTexts[try value("authorityId")]
        for _ in 0..<10 { if identifier.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(identifier.exists && identifier.isHittable, "The complete saved authority identifier must remain readable.")
        XCTAssertTrue(app.staticTexts[try value("authorityScheme")].exists)
        capture(app, "prosopography-complete-authority-identifier")
    }
    @MainActor
    func testLiveProsopographySourceCatalogueOpensSavedCitationAndReopens() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PERSON_DOSSIER"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key] as? String) }
        let sourceId = try value("sourceId"), title = try value("sourceTitle"), citation = try value("sourceCitation")
        for reopen in 0..<2 {
            let app = try openExistingVault(destination: "prosopSources", vaultId: value("vaultId"))
            defer { app.terminate() }
            let catalogue = app.descendants(matching: .any)["prosopography-prosopSources-workspace"].firstMatch
            XCTAssertTrue(catalogue.waitForExistence(timeout: 45))
            let row = app.buttons["private-source-prosop-source-" + sourceId]
            XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<10 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.isHittable); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["private-corpus-source-prosop-source"].firstMatch.waitForExistence(timeout: 45))
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 15))
            let text = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", citation, citation)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 15), "The saved source citation must render instead of only a catalogue title.")
            for _ in 0..<10 { if text.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(text.isHittable)
            XCTAssertTrue(app.descendants(matching: .any)["private-source-group-picker"].firstMatch.exists)
            capture(app, "prosopography-source-saved-citation-reopen-\(reopen)")
            app.terminate()
        }
    }
    @MainActor
    func testLiveTestimonyInterviewReadsSavedObjectiveAndReopens() throws {
        try readSavedTestimony(kind: "interview", route: "testimonyInterviews")
    }
    @MainActor
    func testLiveTestimonyParticipantReadsSavedProfileAndReopens() throws {
        try readSavedTestimony(kind: "participant", route: "testimonyParticipants")
    }
    @MainActor
    func testLiveTestimonyContrastReadsSavedMemoAndReopens() throws {
        try readSavedTestimony(kind: "contrast", route: "testimonyContrasts")
    }
    @MainActor
    func testLiveWorldSceneTraversesStoredPlaceAndCharacterProfiles() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_WORLD_DOSSIERS"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key]) }
        let app = try openExistingVault(destination: "scenes", vaultId: value("vaultId"))
        defer { app.terminate() }
        let row = app.buttons["world-catalogue-world_scenes-" + (try value("scene_id"))]
        XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<12 { if row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        func revealBody(_ key: String) throws {
            let text = try value(key)
            let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", String(text.prefix(100)), String(text.prefix(100)))).firstMatch
            let route = key == "sceneBody" ? "scenes" : key == "placeBody" ? "places" : "characters"
            // The iPad sheet occupies only the centre of the window. A swipe on
            // the whole app can hit the underlying scene instead of its dossier.
            for _ in 0..<20 {
                if paragraph.exists && paragraph.isHittable { break }
                let readers = app.scrollViews.matching(identifier: "world-workspace-" + route).allElementsBoundByIndex
                let reader = try XCTUnwrap(readers.last)
                reader.swipeUp()
            }
            XCTAssertTrue(paragraph.exists && paragraph.isHittable, "The complete saved world dossier must load.\n" + app.debugDescription)
            capture(app, "live-world-" + key)
        }
        try revealBody("sceneBody")
        let place = app.buttons["world-field-link-place_id"]
        for _ in 0..<16 { if place.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(place.isHittable); XCTAssertTrue(place.label.contains(try value("placeTitle"))); place.tap()
        try revealBody("placeBody")
        let closePlace = app.buttons["world-connected-close-" + (try value("place_id"))]
        XCTAssertTrue(closePlace.isHittable); XCTAssertGreaterThanOrEqual(closePlace.frame.height, 44); closePlace.tap()
        let character = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "world-connected-record-scene_characters-", try value("characterTitle"))).firstMatch
        XCTAssertTrue(character.waitForExistence(timeout: 15))
        for _ in 0..<18 { if character.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(character.isHittable); character.tap()
        try revealBody("characterBody")
        let closeCharacter = app.buttons["world-connected-close-" + (try value("person_id"))]
        XCTAssertTrue(closeCharacter.isHittable); XCTAssertGreaterThanOrEqual(closeCharacter.frame.height, 44); closeCharacter.tap()
        XCTAssertTrue(app.buttons["workspace-tab-scenes-scenes-" + (try value("scene_id"))].exists)
        capture(app, "live-world-returns-to-original-scene")
    }
    @MainActor
    func testLiveStudyCourseDocumentReadsSavedBodyAndReturns() throws {
        try readSavedCourseDocument(kind: "estudio")
    }
    @MainActor
    func testLiveTeachingCourseDocumentReadsSavedBodyAndReturns() throws {
        try readSavedCourseDocument(kind: "docencia")
    }
    @MainActor
    func testLiveStudyEditorFlushesStructuredDraftOnCloseAndReopens() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_DOCUMENTS"])
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: [String: String]])
        let fixture = try XCTUnwrap(cases["estudio"])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key]) }
        let marker = "StudyMobile-" + UUID().uuidString.prefix(8)
        for reopen in 0..<2 {
            let app = try openExistingVault(destination: "studyCourses", vaultId: value("vaultId"))
            defer { app.terminate() }
            let course = app.buttons["study-course-open-" + (try value("courseId"))].firstMatch
            XCTAssertTrue(course.waitForExistence(timeout: 45)); course.tap()
            let document = app.buttons["study-course-document-" + (try value("documentId"))]
            XCTAssertTrue(document.waitForExistence(timeout: 20))
            for _ in 0..<10 { if document.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(document.isHittable); document.tap()
            let edit = app.buttons["study-document-edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 20))
            XCTAssertTrue(edit.isHittable); XCTAssertGreaterThanOrEqual(edit.frame.width, 44)
            XCTAssertGreaterThanOrEqual(edit.frame.height, 44)
            capture(app, "live-study-reader-edit-control-before-writing")
            edit.tap()
            let web = app.descendants(matching: .any)["shared-desktop-studyDocument"].firstMatch.webViews.firstMatch
            let editor = web.textViews["Editor del documento"]
            XCTAssertTrue(editor.waitForExistence(timeout: 45), app.debugDescription)
            if reopen == 0 {
                editor.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
                editor.typeText(" \(marker).")
                XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
            } else {
                XCTAssertTrue((editor.value as? String)?.contains(marker) == true, "The structured mobile edit must survive process restart.")
            }
            let close = app.buttons["study-editor-close"]
            XCTAssertTrue(close.isHittable); XCTAssertGreaterThanOrEqual(close.frame.height, 44)
            XCTAssertGreaterThanOrEqual(close.frame.width, 44)
            // Close before waiting for autosave: the native exit must flush the
            // editor into the durable queue rather than discarding its debounce.
            close.tap(); XCTAssertTrue(web.waitForNonExistence(timeout: 30), app.debugDescription)
            // Native headings apply the reader's uppercase typography. The
            // rendered text must match the edit regardless of that casing.
            let marked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", marker, marker)).firstMatch
            XCTAssertTrue(marked.waitForExistence(timeout: 20), "The reader must immediately show its saved local edit.\n" + app.debugDescription)
            let original = try value("lastBody")
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", original, original)).firstMatch.exists)
            capture(app, "live-study-editor-flushed-\(marker)-reopen-\(reopen)")
            app.terminate()
        }
    }
    @MainActor
    func testLiveArchiveReadsSavedDescriptionTextAndExcerpt() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_ARCHIVE_DOSSIER"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key]) }
        let app = try openExistingVault(destination: "archive", vaultId: value("vaultId"))
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let row = app.buttons["archive-open-" + (try value("itemId"))]
        XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<12 { if row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        func read(_ key: String) throws {
            let body = String(try value(key).prefix(100))
            let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", body, body)).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 20), "The actual saved archive \(key) must be available.\n" + app.debugDescription)
            XCTAssertTrue(paragraph.isHittable)
            capture(app, "live-archive-saved-" + key)
        }
        try read("description")
        for (section, key, spanish) in [("Text", "text", "Texto"), ("Excerpts", "excerpt", "Extractos")] {
            let menu = app.buttons["archive-detail-menu"]
            if menu.exists {
                XCTAssertTrue(menu.isHittable); XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(menu.frame)); menu.tap()
                let option = app.buttons["archive-detail-option-" + section]
                XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription); option.tap()
            } else {
                let option = app.segmentedControls.buttons[spanish]
                XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription); option.tap()
            }
            try read(key)
        }
        if app.windows.firstMatch.frame.width < 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            let turned = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            let menu = app.buttons["archive-detail-menu"]
            XCTAssertTrue(menu.isHittable); XCTAssertTrue(app.windows.firstMatch.frame.contains(menu.frame))
            XCTAssertFalse(app.descendants(matching: .any)["archive-hierarchy-rail"].exists, "The iPhone keeps its full-width reader in landscape.")
            try read("excerpt")
            capture(app, "live-archive-phone-landscape")
        }
    }
    @MainActor private func readSavedCourseDocument(kind: String) throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_DOCUMENTS"])
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: [String: String]])
        let fixture = try XCTUnwrap(cases[kind])
        func value(_ key: String) throws -> String { try XCTUnwrap(fixture[key]) }
        for reopen in 0..<2 {
            let app = try openExistingVault(destination: "studyCourses", vaultId: value("vaultId"))
            defer { app.terminate() }
            let course = app.buttons["study-course-open-" + (try value("courseId"))].firstMatch
            XCTAssertTrue(course.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<10 { if course.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(course.isHittable); course.tap()
            if app.windows.firstMatch.frame.width < 600 && reopen == 1 {
                XCUIDevice.shared.orientation = .landscapeLeft
                let turned = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
                XCTAssertFalse(app.descendants(matching: .any)["study-course-sidebar"].exists, "The iPhone keeps its full-width course in landscape.")
            }
            let document = app.buttons["study-course-document-" + (try value("documentId"))]
            XCTAssertTrue(document.waitForExistence(timeout: 20), app.debugDescription)
            for _ in 0..<10 { if document.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(document.isHittable); XCTAssertGreaterThanOrEqual(document.frame.height, 44); document.tap()
            let reader = app.descendants(matching: .any)["study-evidence-reader"].firstMatch
            XCTAssertTrue(reader.waitForExistence(timeout: 30), app.debugDescription)
            let body = try value("body")
            let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", body, body)).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 20), "The document must open its saved body rather than only its metadata.")
            XCTAssertTrue(paragraph.isHittable)
            capture(app, "live-\(kind)-course-document-reopen-\(reopen)")
            let close = app.buttons["nodus-modal-close"]
            XCTAssertTrue(close.isHittable); XCTAssertGreaterThanOrEqual(close.frame.height, 44); close.tap()
            XCTAssertTrue(reader.waitForNonExistence(timeout: 10))
            XCTAssertTrue(document.isHittable, "Closing the document must preserve its owning course.")
            app.terminate()
        }
    }
    @MainActor private func readSavedTestimony(kind: String, route: String) throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TESTIMONIES"])
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let vault = try XCTUnwrap(fixture["vaultId"] as? String)
        let saved = try XCTUnwrap(fixture[kind] as? [String: String])
        let id = try XCTUnwrap(saved["id"]), title = try XCTUnwrap(saved["title"]), body = try XCTUnwrap(saved["body"])
        for reopen in 0..<2 {
            let app = try openExistingVault(destination: route, vaultId: vault)
            defer { app.terminate() }
            let row = app.buttons["private-source-testimony-\(kind)-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<12 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.isHittable); XCTAssertGreaterThanOrEqual(row.frame.height, 44); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["private-corpus-source-testimony-" + kind].firstMatch.waitForExistence(timeout: 45))
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", body, body)).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 20), "The exact saved dossier text must load, not only its catalogue title.")
            for _ in 0..<12 { if paragraph.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(paragraph.isHittable)
            XCTAssertTrue(app.descendants(matching: .any)["private-source-group-picker"].firstMatch.exists)
            capture(app, "live-testimony-\(kind)-saved-body-reopen-\(reopen)")
            let close = app.buttons["private-source-close"]
            XCTAssertTrue(close.isHittable); XCTAssertGreaterThanOrEqual(close.frame.height, 44); close.tap()
            let closed = NSPredicate(format: "exists == false")
            let reader = app.descendants(matching: .any)["private-corpus-source-testimony-" + kind].firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: reader)], timeout: 10), .completed)
            XCTAssertTrue(row.isHittable, "Closing the native reader must return to the same catalogue.")
            capture(app, "live-testimony-\(kind)-returns-to-catalogue-\(reopen)")
            app.terminate()
        }
    }
    @MainActor
    func testLivePhoneChatStreamsCopiesAndReopensFromHistory() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<8 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.isHittable); mode.tap(); app.buttons["Live · modelos del Mac"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let chat = app.buttons["nodus-nav-researchChat"]
        for _ in 0..<8 { if chat.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(chat.isHittable); chat.tap()
        let input = app.descendants(matching: .any)["nodus-chat-composer"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 35))
        if app.buttons["nodus-chat-new"].exists { app.buttons["nodus-chat-new"].tap() }
        app.buttons["nodus-chat-live-options"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "deepseek-flash")).firstMatch.waitForExistence(timeout: 30), "The real Mac configuration must load its configured DeepSeek model.\n" + app.debugDescription)
        XCTAssertTrue(app.buttons["Elegir modelo"].exists)
        capture(app, "phone-chat-live-mac-configuration")
        app.buttons["nodus-chat-options-close"].tap()
        let marker = "QAChat-\(UUID().uuidString.prefix(8))"
        input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        try clearNativeChatComposer(input, in: app)
        input.typeText("\(marker). Explica en unas 250 palabras cómo el corpus relaciona propaganda turística y fotografía. Incluye dos ideas y sus fuentes. Empieza la respuesta con el marcador \(marker).")
        let send = app.buttons["nodus-chat-send"]
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: send)], timeout: 30), .completed)
        XCTAssertTrue(send.isHittable); send.tap()
        print("NODUS_CHAT_MARKER=\(marker)")
        let running = NSPredicate(format: "value == %@", "running")
        let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: running, object: send)], timeout: 15)
        capture(app, "phone-chat-live-submission")
        guard started == .completed else {
            XCTFail("The live request did not start.\n" + app.debugDescription)
            throw NSError(domain: "NodusAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "The actual live chat request was not running."])
        }
        let answer = app.descendants(matching: .any)["nodus-chat-answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        let activity = app.buttons["nodus-chat-activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 45), "Actual Mac activity must reach the native phone interface.")
        for _ in 0..<10 { if activity.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(activity.isHittable); activity.tap()
        let activityClose = app.buttons["nodus-chat-activity-close"]
        XCTAssertTrue(activityClose.waitForExistence(timeout: 10)); XCTAssertTrue(activityClose.isHittable)
        capture(app, "phone-chat-native-live-activity-sheet"); activityClose.tap()
        let finished = NSPredicate(format: "value == %@", "idle")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: send)], timeout: 240), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["nodus-chat-error"].exists, app.debugDescription)
        let originalText = answer.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(originalText.contains(marker)); XCTAssertGreaterThan(originalText.count, 120)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "nodus-chat-question").count, 1)
        let regenerate = answer.buttons["nodus-chat-regenerate"]
        for _ in 0..<15 { if regenerate.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(regenerate.isHittable); regenerate.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: running, object: send)], timeout: 15), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: send)], timeout: 240), .completed)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "nodus-chat-question").count, 1, "Regeneration must retain the original question without duplication.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "nodus-chat-answer").count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["nodus-chat-error"].exists, app.debugDescription)
        let text = answer.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(text.contains(marker)); XCTAssertGreaterThan(text.count, 120)
        capture(app, "phone-chat-native-live-regenerated")
        let copy = answer.buttons["nodus-chat-copy"]
        for _ in 0..<15 { if copy.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        for action in answer.buttons.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(action.frame.minX, answer.frame.minX - 1)
            XCTAssertLessThanOrEqual(action.frame.maxX, answer.frame.maxX + 1)
            if ["nodus-chat-copy", "nodus-chat-regenerate"].contains(action.identifier) {
                XCTAssertGreaterThanOrEqual(action.frame.width, 44)
                XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            }
        }
        XCTAssertTrue(answer.buttons["nodus-chat-regenerate"].exists)
        copy.tap()
        input.tap(); input.press(forDuration: 1.1)
        let paste = app.menuItems["Pegar"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10)); paste.tap()
        let copied = try XCTUnwrap(input.value as? String)
        XCTAssertTrue(copied.contains(marker)); XCTAssertGreaterThan(copied.count, 120)
        capture(app, "phone-chat-native-live-completed-copied")
        app.buttons["nodus-chat-history"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nodus-chat-history-conversation-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let savedRowId = row.identifier
        capture(app, "phone-chat-native-live-saved-history")
        app.terminate(); app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        XCTAssertTrue(app.buttons["nodus-chat-history"].waitForExistence(timeout: 35))
        app.buttons["nodus-chat-history"].tap()
        let saved = app.buttons[savedRowId]
        XCTAssertTrue(saved.waitForExistence(timeout: 20)); XCTAssertTrue(saved.isHittable); saved.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        XCTAssertEqual(answer.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"), text, "History must retain the actual complete response after restarting.")
        capture(app, "phone-chat-native-live-history-response-reopened")
    }
    @MainActor
    func testExistingMacPhoneReaderUsesOneSelectionRibbon() throws {
        let app = try openExistingPrincipal(destination: "deepResearch")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let gallery = app.descendants(matching: .any)["shared-desktop-deepResearch"].webViews.firstMatch
        let search = researchSearch(in: gallery)
        XCTAssertTrue(search.waitForExistence(timeout: 35), app.debugDescription)
        try focusResearchSearch(search, in: gallery, app: app)
        if let value = search.value as? String, value != "Buscar entre tus informes…", !value.isEmpty {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        search.typeText("La mirada extranjera"); try dismissResearchKeyboard(app)
        let read = gallery.buttons.containing(NSPredicate(format: "label CONTAINS %@", "La mirada extranjera sobre la España franquista")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 45), app.debugDescription)
        try revealResearchControl(read, in: gallery, upwards: true); read.tap()
        let reader = app.scrollViews["report-native-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30), app.debugDescription)
        let body = reader.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Este informe analiza")).firstMatch
        for _ in 0..<12 { if body.exists && body.isHittable { break }; reader.swipeUp() }
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(body.isHittable)
        body.press(forDuration: 1.2)
        for identifier in ["nodus-selection-copy", "nodus-selection-highlight", "nodus-selection-comment", "nodus-selection-bookmark", "nodus-selection-ask"] {
            let action = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 10), "Selecting text must present the single Nodus ribbon: " + identifier + "\n" + app.debugDescription)
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.minX, reader.frame.minX - 1)
            XCTAssertLessThanOrEqual(action.frame.maxX, reader.frame.maxX + 1)
        }
        XCTAssertEqual(app.menuItems.matching(identifier: "nodus-selection-copy").count, 1)
        let systemCopies = app.menuItems.matching(NSPredicate(format: "(label == %@ OR label == %@) AND identifier != %@", "Copiar", "Copy", "nodus-selection-copy"))
        XCTAssertEqual(systemCopies.count, 0, "A second system Copy action must not accompany the Nodus ribbon.")
        capture(app, "phone-native-reader-unified-selection-ribbon")
    }
    @MainActor
    func testExistingMacPhoneGraphDetailReturnsToTheSameCanvas() throws {
        try verifyExistingMacGraph(phone: true)
    }
    @MainActor
    func testExistingMacIPadGraphKeepsCanvasBesideDossier() throws {
        try verifyExistingMacGraph(phone: false)
    }
    @MainActor private func verifyExistingMacGraph(phone: Bool) throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_GRAPH_THEME"])
        let count = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_GRAPH_IDEAS"].flatMap(Int.init))
        let app = try openExistingPrincipal(destination: "graph")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertEqual(app.windows.firstMatch.frame.width < 600, phone, "Run the canvas audit on its intended device.")
        let web = app.otherElements["shared-desktop-graph"].webViews.firstMatch
        let back = web.buttons["Volver a los temas"].firstMatch
        if back.waitForExistence(timeout: 2) { back.tap() }
        let filter = web.searchFields["Filtrar temas"]
        XCTAssertTrue(filter.waitForExistence(timeout: 60), app.debugDescription)
        try focusResearchSearch(filter, in: web, app: app)
        filter.typeText(name)
        try dismissResearchKeyboard(app)
        let theme = web.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@ AND label ENDSWITH %@", "Tema ·", name)).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 30)); theme.tap()
        let status = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ideas del tema")).firstMatch
        let loaded = NSPredicate { _, _ in
            guard status.exists, let from = status.label.range(of: " de "), let to = status.label.range(of: " ideas del tema") else { return false }
            return Int(status.label[..<from.lowerBound].filter(\.isNumber)) == count && Int(status.label[from.upperBound..<to.lowerBound].filter(\.isNumber)) == count
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 120), .completed, app.debugDescription)
        let distributing = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Distribuyendo la constelación")).firstMatch
        XCTAssertTrue(distributing.waitForNonExistence(timeout: 90))
        let labels = web.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "fuente"))
        for _ in 0..<5 {
            if labels.allElementsBoundByIndex.contains(where: { $0.isHittable }) { break }
            web.buttons["Acercar"].firstMatch.tap()
        }
        if phone {
            let back = web.buttons["Volver a los temas"].firstMatch
            let search = web.textFields["Buscar una idea"].firstMatch
            XCTAssertTrue(back.isHittable); XCTAssertTrue(search.isHittable)
            XCTAssertLessThanOrEqual(search.frame.maxY - back.frame.minY, 110,
                                     "The phone theme header must leave room for the graph instead of repeating Desktop chrome.")
            let fullscreen = web.switches["Pantalla completa"].firstMatch
            XCTAssertTrue(fullscreen.isHittable)
            XCTAssertGreaterThanOrEqual(fullscreen.frame.width, 43.5)
            XCTAssertLessThanOrEqual(fullscreen.frame.width, 45, "The phone fullscreen action should use a compact labelled icon.")
            let stage = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Canvas de ideas.")).firstMatch
            // The accessible canvas announces its actual world-camera scale.
            // Captions can disappear when they collide after zooming, and
            // WebKit does not expose every empty node button to XCTest.
            let before = try XCTUnwrap(stage.label.components(separatedBy: "Zoom: ").last.flatMap { Int($0.filter(\.isNumber)) })
            let frame = stage.frame
            capture(app, "phone-graph-before-native-pinch")
            stage.pinch(withScale: 1.2, velocity: 1)
            capture(app, "phone-graph-after-native-pinch")
            let enlarged = NSPredicate { _, _ in
                let zoom = stage.label.components(separatedBy: "Zoom: ").last.flatMap { Int($0.filter(\.isNumber)) } ?? 0
                return zoom > before
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enlarged, object: nil)], timeout: 10), .completed,
                           "Two native touches must enlarge the actual graph camera, not just the page text.")
            XCTAssertEqual(stage.frame.width, frame.width, accuracy: 1)
            XCTAssertEqual(stage.frame.height, frame.height, accuracy: 1)
            XCTAssertFalse(web.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "cuadro de diálogo de web")).firstMatch.exists,
                           "Pinching the graph must not open an idea dossier.")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 5), .completed)
        }
        capture(app, "\(phone ? "phone" : "ipad")-graph-before-idea-selection")
        let idea = try XCTUnwrap(labels.allElementsBoundByIndex.first(where: { $0.isHittable }), "At least one idea must be readable and selectable on the phone.\n\(app.debugDescription)")
        if phone { try verifyPhoneIdeaSheet(app: app, web: web, idea: idea, name: "graph") }
        else { try verifyIPadIdeaPanel(app: app, web: web, idea: idea, name: "graph") }
    }
    @MainActor
    func testExistingMacPhoneArgumentDetailAndPinch() throws {
        try verifyExistingMacArgument(phone: true)
    }
    @MainActor
    func testExistingMacIPadArgumentKeepsCanvasBesideDossier() throws {
        try verifyExistingMacArgument(phone: false)
    }
    @MainActor private func verifyExistingMacArgument(phone: Bool) throws {
        let app = try openExistingPrincipal(destination: "argument")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertEqual(app.windows.firstMatch.frame.width < 600, phone, "Run the canvas audit on its intended device.")
        let web = app.otherElements["shared-desktop-argument"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35))
        let catalogue = web.buttons["Ideas"].firstMatch
        if catalogue.waitForExistence(timeout: 2) { catalogue.tap() }
        XCTAssertTrue(web.buttons["Automático"].firstMatch.waitForExistence(timeout: 40))
        let routes = web.buttons
        let ready = NSPredicate { _, _ in routes.allElementsBoundByIndex.contains(where: { $0.label.count > 100 && $0.isHittable }) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 60), .completed, app.debugDescription)
        capture(app, "\(phone ? "phone" : "ipad")-argument-route-catalogue")
        let route = try XCTUnwrap(routes.allElementsBoundByIndex.first(where: { $0.label.count > 100 && $0.isHittable }))
        if phone { XCTAssertLessThanOrEqual(route.frame.maxX, web.frame.maxX + 1, "Phone route cards must fit the width.") }
        route.tap()
        let central = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "IDEA CENTRAL")).firstMatch
        XCTAssertTrue(central.waitForExistence(timeout: 60), app.debugDescription)
        if phone { XCTAssertGreaterThanOrEqual(central.frame.width, 200, "The initial phone map must open at a readable scale.") }
        else {
            for _ in 0..<12 {
                if central.isHittable && central.frame.width >= 200 { break }
                web.buttons["Acercar"].firstMatch.tap()
            }
            XCTAssertTrue(central.isHittable, app.debugDescription)
        }
        capture(app, "\(phone ? "phone" : "ipad")-argument-map-before-pinch")
        if phone {
            // Automatic zoom intentionally reframes a selected card. Check
            // camera preservation while the user is exploring manually.
            let automatic = web.switches["Zoom automático"].firstMatch
            XCTAssertTrue(automatic.isHittable)
            if automatic.value as? String == "1" { automatic.tap() }
            XCTAssertEqual(automatic.value as? String, "0")
        }
        let stage = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Canvas de ideas.")).firstMatch
        XCTAssertTrue(stage.exists, app.debugDescription)
        let zoom = web.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Zoom:"))
        let before = try XCTUnwrap(zoom.allElementsBoundByIndex.first(where: { $0.isHittable }).flatMap { Int($0.label.filter(\.isNumber)) })
        stage.pinch(withScale: 1.5, velocity: 1)
        let enlarged = NSPredicate { _, _ in
            zoom.allElementsBoundByIndex.contains(where: { $0.isHittable && (Int($0.label.filter(\.isNumber)) ?? 0) > before })
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enlarged, object: nil)], timeout: 10), .completed, "A native two-finger gesture must change the map camera.")
        XCTAssertFalse(web.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "cuadro de diálogo de web")).firstMatch.exists, "Pinching must not accidentally select an idea.")
        if phone {
            web.buttons["Volver al inicio"].firstMatch.tap()
            let reset = NSPredicate { _, _ in
                zoom.allElementsBoundByIndex.contains(where: { $0.isHittable && Int($0.label.filter(\.isNumber)) == 100 })
            }
            let restored = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reset, object: nil)], timeout: 5)
            capture(app, "phone-argument-reset-after-native-pinch")
            XCTAssertEqual(restored, .completed, "Back to start must restore the actual phone camera scale.")
            try verifyPhoneIdeaSheet(app: app, web: web, idea: central, name: "argument")
        } else { try verifyIPadIdeaPanel(app: app, web: web, idea: central, name: "argument") }
    }
    @MainActor private func verifyPhoneIdeaSheet(app: XCUIApplication, web: XCUIElement, idea: XCUIElement, name: String) throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            if name == "graph" { try verifyGraphFiltersFit(web: web) }
            XCTAssertTrue(idea.isHittable, app.debugDescription)
            capture(app, "phone-\(name)-before-detail-\(orientation == .portrait ? "portrait" : "landscape")")
            let previous = idea.frame
            idea.tap()
            let sheet = web.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "cuadro de diálogo de web")).firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 20), app.debugDescription)
            let close = sheet.buttons["Cerrar"].firstMatch
            XCTAssertTrue(close.isHittable)
            XCTAssertGreaterThanOrEqual(close.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
            XCTAssertGreaterThanOrEqual(sheet.frame.width, web.frame.width - 2, "The phone dossier must fill the width instead of becoming a right sidebar.")
            let evidence = sheet.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Obras que la desarrollan")).firstMatch
            XCTAssertTrue(evidence.waitForExistence(timeout: 30), "The persisted dossier must load beyond its skeleton.\n\(app.debugDescription)")
            let statement = sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Enunciado de la idea")).firstMatch
            XCTAssertTrue(statement.exists, "The actual statement must load, not just the title.")
            XCTAssertFalse(statement.staticTexts.allElementsBoundByIndex.map(\.label).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            capture(app, "phone-\(name)-idea-\(orientation == .portrait ? "portrait" : "landscape")")
            close.tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
            capture(app, "phone-\(name)-after-detail-\(orientation == .portrait ? "portrait" : "landscape")")
            XCTAssertTrue(idea.isHittable)
            XCTAssertEqual(idea.frame.minX, previous.minX, accuracy: 2, "Closing the detail must keep the camera position.")
            XCTAssertEqual(idea.frame.minY, previous.minY, accuracy: 2)
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        }
    }
    @MainActor private func verifyGraphFiltersFit(web: XCUIElement) throws {
        for label in ["Mostrar ideas", "Conexiones por idea"] {
            let select = web.otherElements.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(select.exists, web.debugDescription)
            XCTAssertTrue(select.isHittable, "Both graph filters must remain usable in every orientation.")
            XCTAssertGreaterThanOrEqual(select.frame.minY, web.frame.minY - 1)
            XCTAssertLessThanOrEqual(select.frame.maxY, web.frame.maxY + 1, "The graph filter must not be clipped below the phone viewport.")
            XCTAssertGreaterThanOrEqual(select.frame.height, 43.5, "A graph filter needs a full 44-point touch target.")
        }
    }
    @MainActor private func verifyIPadIdeaPanel(app: XCUIApplication, web: XCUIElement, idea: XCUIElement, name: String) throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            let rotation = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15)
            if rotation != .completed {
                capture(app, "ipad-\(name)-rotation-failure")
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.02)).press(forDuration: 0.1,
                    thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)))
                capture(springboard, "ipad-\(name)-rotation-control-center")
            }
            XCTAssertEqual(rotation, .completed)
            XCTAssertTrue(idea.isHittable, app.debugDescription)
            capture(app, "ipad-\(name)-before-detail-\(orientation == .portrait ? "portrait" : "landscape")")
            idea.tap()
            let close = web.buttons["Cerrar"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertGreaterThanOrEqual(close.frame.width, 43.5, "The iPad dossier also needs touch-sized actions.")
            XCTAssertGreaterThanOrEqual(close.frame.height, 43.5)
            let works = web.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Obras que la desarrollan")).firstMatch
            XCTAssertTrue(works.waitForExistence(timeout: 30), "The saved dossier must load its evidence on iPad.")
            if name == "graph" {
                let status = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ideas del tema")).firstMatch
                XCTAssertTrue(status.exists)
                for control in [web.switches["Contexto"].firstMatch, web.buttons["Acercar"].firstMatch,
                                web.buttons["Alejar"].firstMatch, web.buttons["Encuadrar"].firstMatch] {
                    XCTAssertTrue(control.isHittable)
                    XCTAssertFalse(status.frame.intersects(control.frame),
                                   "Opening an iPad dossier must keep the graph status and its controls separate.")
                }
            }
            XCTAssertGreaterThan(close.frame.minX, web.frame.midX, "The iPad keeps the Desktop dossier at the right of the canvas.")
            XCTAssertFalse(web.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "cuadro de diálogo de web")).firstMatch.exists)
            XCTAssertTrue(web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Canvas de ideas.")).firstMatch.exists,
                          "The canvas remains alongside the iPad dossier.")
            capture(app, "ipad-\(name)-idea-\(orientation == .portrait ? "portrait" : "landscape")")
            XCTAssertTrue(close.isHittable); close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 10))
            XCTAssertTrue(idea.isHittable)
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        }
    }
    @MainActor
    func testSharedGraphLoadsRealDesktopCanvas() throws {
        for style in ["light", "dark"] {
            try verifyDesktopGraph(style: style)
        }
    }
    @MainActor private func verifyDesktopGraph(style: String) throws {
        let app = launch("graph", style: style)
        defer { app.terminate() }
        let screenReady = NSPredicate { _, _ in app.windows.firstMatch.frame.width >= 320 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: screenReady, object: nil)], timeout: 15), .completed,
            "The physical screen must be awake at its actual logical size before touching or capturing the canvas.")
        XCTAssertTrue(app.descendants(matching: .any)["shared-desktop-graph"].waitForExistence(timeout: 25))
        let dismiss = app.descendants(matching: .any)["nodus-navigation-dismiss"].firstMatch
        if dismiss.exists { dismiss.tap() }
        if app.windows.firstMatch.frame.width < 600 {
            XCTAssertFalse(app.buttons["nodus-nav-home"].isHittable, "The graph captures must show the canvas without an open drawer.")
        }
        let graph = app.webViews.firstMatch
        XCTAssertTrue(graph.waitForExistence(timeout: 10))
        let themes = graph.buttons["Temas"].firstMatch
        XCTAssertTrue(themes.waitForExistence(timeout: 10)); themes.tap()
        capture(app, "shared-desktop-graph-before-validation")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.staticTexts["shared-surface-error"].label)
        XCTAssertFalse(graph.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "missing")).firstMatch.exists)
        XCTAssertTrue(graph.buttons.firstMatch.waitForExistence(timeout: 20), "The Desktop graph must render its controls, not just an empty WKWebView.")
        // Layout errors arrive after the controls render. Check the actual canvas state.
        let failure = graph.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "calculate the layout", "calcular la distribución")).firstMatch
        XCTAssertFalse(failure.waitForExistence(timeout: 4), failure.label)
        capture(app, "shared-desktop-graph-\(style)")
        if app.windows.firstMatch.frame.width < 600 {
            let constellation = graph.buttons["Ver constelación"]
            XCTAssertTrue(constellation.waitForExistence(timeout: 10))
            let themeRows = graph.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tema · "))
            XCTAssertEqual(themeRows.count, 6, "The portrait directory must include every theme.")
            for row in themeRows.allElementsBoundByIndex {
                XCTAssertGreaterThanOrEqual(row.frame.minX, graph.frame.minX)
                XCTAssertLessThanOrEqual(row.frame.maxX, graph.frame.maxX)
                XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            }
            capture(app, "phone-graph-theme-directory-\(style)")
            constellation.tap()
            XCTAssertTrue(graph.buttons["Encuadrar"].waitForExistence(timeout: 10))
            capture(app, "phone-graph-theme-constellation-\(style)")
            graph.buttons["Ver temas"].tap()
        }
        let theme = graph.buttons["Tema · 5 ideas · Educación y formación del carácter"]
        XCTAssertTrue(theme.waitForExistence(timeout: 10)); theme.tap()
        XCTAssertTrue(graph.buttons["Cerrar grafo 2"].waitForExistence(timeout: 10), "Opening a theme must create its Desktop graph tab.")
        capture(app, "shared-desktop-theme-\(style)")
        let chrome = app.buttons["nodus-navigation-toggle"].exists ? app.buttons["nodus-navigation-toggle"] : app.buttons["nodus-nav-home"]
        graph.descendants(matching: .any)["Pantalla completa"].tap()
        XCTAssertTrue(graph.descendants(matching: .any)["Salir de pantalla completa"].waitForExistence(timeout: 10))
        XCTAssertFalse(chrome.exists)
        capture(app, "shared-desktop-graph-fullscreen-\(style)")
        graph.descendants(matching: .any)["Salir de pantalla completa"].tap()
        XCTAssertTrue(chrome.waitForExistence(timeout: 5))
    }
    @MainActor
    func testSidebarRespectsSafeAreaInBothThemes() throws {
        for style in ["light", "dark"] {
            let app = launch("home", style: style)
            let screenReady = NSPredicate { _, _ in app.windows.firstMatch.frame.width >= 320 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: screenReady, object: nil)], timeout: 15), .completed,
                "The physical display must expose its actual logical size before auditing the sidebar.")
            let toggle = app.buttons["nodus-navigation-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 20))
            if app.windows.firstMatch.frame.width < 600 { toggle.tap() }
            let home = app.buttons["nodus-nav-home"]
            XCTAssertTrue(home.waitForExistence(timeout: 10)); XCTAssertTrue(home.isHittable)
            XCTAssertGreaterThanOrEqual(home.frame.minY, toggle.frame.minY, "Home must stay below the system clock.")
            XCTAssertTrue(app.buttons["nodus-nav-settings"].isHittable, "Settings must remain reachable above the home indicator.")
            capture(app, "sidebar-safe-area-\(style)")
            app.terminate()
        }
    }
    @MainActor
    func testSidebarLongLabelsAndComingSoonToolsOnIPad() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        var standardLabelHeight: CGFloat?
        for style in ["light", "dark"] {
            for size in ["standard", "accessibility3"] {
                let app = launch("home", style: style, textSize: size)
                XCTAssertTrue(app.buttons["nodus-nav-home"].waitForExistence(timeout: 25))
                XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 600, "This test requires the persistent iPad sidebar.")
                for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                    XCUIDevice.shared.orientation = orientation
                    let turned = NSPredicate { _, _ in
                        let frame = app.windows.firstMatch.frame
                        return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
                    }
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
                    let argument = app.buttons["nodus-nav-argument"]
                    XCTAssertTrue(argument.waitForExistence(timeout: 10)); XCTAssertTrue(argument.isHittable)
                    let label = argument.staticTexts.firstMatch
                    XCTAssertTrue(label.exists)
                    XCTAssertLessThanOrEqual(label.frame.maxX, argument.frame.maxX + 1)
                    XCTAssertLessThanOrEqual(label.frame.maxY, argument.frame.maxY + 1)
                    // The longer label changes its line count when the accessible
                    // sidebar widens. Compare the single-line Home label instead.
                    let fontProbe = app.buttons["nodus-nav-home"].staticTexts.firstMatch
                    XCTAssertTrue(fontProbe.exists)
                    if size == "standard" { standardLabelHeight = fontProbe.frame.height }
                    else if let standardLabelHeight {
                        XCTAssertGreaterThan(fontProbe.frame.height, standardLabelHeight * 1.5, "The accessibility size must actually enlarge the navigation text.")
                    }
                    XCTAssertTrue(app.buttons["nodus-nav-settings"].isHittable)
                    capture(app, "sidebar-labels-\(style)-\(size)-\(orientation == .portrait ? "portrait" : "landscape")")
                }
                let browser = app.buttons["nodus-nav-browser"]
                let navigation = app.scrollViews.firstMatch
                for _ in 0..<8 { if browser.isHittable { break }; navigation.swipeUp() }
                XCTAssertTrue(browser.isHittable); browser.tap()
                XCTAssertTrue(app.descendants(matching: .any)["nodus-coming-soon-browser"].firstMatch.waitForExistence(timeout: 10))
                capture(app, "sidebar-browser-coming-soon-\(style)-\(size)")
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
        }
    }
    @MainActor
    func testLiveLargeGraphLoadsEveryPageAndKeepsControls() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_GRAPH_THEME"])
        let count = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_GRAPH_IDEAS"].flatMap(Int.init))
        XCTAssertGreaterThan(count, 1000, "This test must use the actual large laboratory corpus.")
        let app = try pairLive(route: "graph")
        try verifyLargeGraph(app: app, name: name, count: count)
    }
    @MainActor
    func testExistingMacLargeGraphLoadsEveryPageAndKeepsControls() throws {
        let env = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(env["NODUS_ACCEPTANCE_GRAPH_THEME"])
        let count = try XCTUnwrap(env["NODUS_ACCEPTANCE_GRAPH_IDEAS"].flatMap(Int.init))
        XCTAssertGreaterThan(count, 1000, "This test must use the actual large laboratory corpus.")
        XCTAssertNil(env["NODUS_ACCEPTANCE_LINK"])
        XCTAssertNil(env["NODUS_ACCEPTANCE_PAIRING_CODE"])
        XCTAssertNil(env["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = env["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        if let size = env["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launch()
        let navigation = app.buttons["nodus-navigation-toggle"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 45), "The persisted Mac workspace must reopen without a new pairing, demo, snapshot or injected route.\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["pairing-confirm"].exists)
        let switchSpace = app.buttons["Cambiar de espacio"]
        XCTAssertTrue(switchSpace.waitForExistence(timeout: 15), app.debugDescription)
        switchSpace.tap()
        let principal = app.buttons["space-default"]
        XCTAssertTrue(principal.waitForExistence(timeout: 20), "The previously linked Mac must remain in the ordinary workspace chooser.")
        for _ in 0..<8 { if principal.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(principal.isHittable, app.debugDescription)
        principal.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 45), app.debugDescription)
        capture(app, "existing-mac-principal-selected")
        navigation.tap()
        let graph = app.buttons["nodus-nav-graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 { if graph.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(graph.isHittable, app.debugDescription)
        graph.tap()
        capture(app, "existing-mac-large-graph-navigation")
        try verifyLargeGraph(app: app, name: name, count: count)
    }
    @MainActor private func verifyLargeGraph(app: XCUIApplication, name: String, count: Int) throws {
        let web = app.otherElements["shared-desktop-graph"].webViews.firstMatch
        let filter = web.searchFields["Filtrar temas"]
        XCTAssertTrue(filter.waitForExistence(timeout: 60), app.debugDescription)
        filter.tap(); filter.typeText(name + "\n")
        // A theme caption can remain visible while its dot is above the clipped
        // canvas. Tap the actual visible caption, not an offscreen AX hit target.
        let theme = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "TEMA ·", name)).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 60), app.debugDescription)
        capture(app, "live-large-graph-themes"); theme.tap()
        XCTAssertTrue(web.buttons["Cerrar grafo 2"].waitForExistence(timeout: 20), "The visible theme must actually open its canvas tab.")
        let status = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ideas del tema")).firstMatch
        let transportError = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "stellarPage:")).firstMatch
        let loaded = NSPredicate { _, _ in
            if transportError.exists || app.staticTexts["shared-surface-error"].exists { return true }
            guard status.exists else { return false }
            let label = status.label
            guard let from = label.range(of: " de "), let to = label.range(of: " ideas del tema") else { return false }
            let visible = Int(label[..<from.lowerBound].filter(\.isNumber))
            let total = Int(label[from.upperBound..<to.lowerBound].filter(\.isNumber))
            return total == count && visible == count
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 180), .completed, app.debugDescription)
        if transportError.exists || app.staticTexts["shared-surface-error"].exists {
            capture(app, "live-large-graph-load-failed")
            XCTAssertFalse(web.staticTexts["Este tema todavía no anida ninguna idea analizada."].exists, "A transport failure must never appear as an empty theme.")
            XCTFail(app.debugDescription)
            return
        }
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
        let layoutProgress = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Distribuyendo la constelación")).firstMatch
        XCTAssertTrue(layoutProgress.waitForNonExistence(timeout: 120), "Capture the settled layout, not an intermediate distribution.")
        capture(app, "live-large-graph-complete-theme")
        let fullscreen = web.descendants(matching: .any)["Pantalla completa"]
        XCTAssertTrue(fullscreen.exists); fullscreen.tap()
        XCTAssertTrue(web.descendants(matching: .any)["Salir de pantalla completa"].waitForExistence(timeout: 10))
        capture(app, "live-large-graph-fullscreen")
        web.descendants(matching: .any)["Salir de pantalla completa"].tap()
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 10))
    }
    @MainActor
    func testLiveStudyGraphSearchEvidenceAndSubjectSwitch() throws {
        let vault = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_VAULT_ID"])
        let subjectA = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_SUBJECT_A"])
        let subjectB = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_SUBJECT_B"])
        let last = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_LAST_LABEL"])
        let app = try pairLive(route: "studyGraph", vaultId: vault)
        verifyStudyGraph(app: app, subjectA: subjectA, subjectB: subjectB, last: last)
    }
    @MainActor
    func testPublishedStudyGraphSearchEvidenceAndSubjectSwitch() throws {
        let filename = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"])
        let subjectA = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_SUBJECT_A"])
        let subjectB = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_SUBJECT_B"])
        let last = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_STUDY_LAST_LABEL"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = filename
        app.launchEnvironment["NODUS_START_ROUTE"] = "studyGraph"
        app.launch()
        verifyStudyGraph(app: app, subjectA: subjectA, subjectB: subjectB, last: last)
    }
    @MainActor private func verifyStudyGraph(app: XCUIApplication, subjectA: String, subjectB: String, last: String) {
        let web = app.webViews.firstMatch
        let subject = web.descendants(matching: .any)["Asignatura"].firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 40), app.debugDescription)
        func selectSubject(_ name: String) {
            subject.tap()
            capture(app, "study-graph-subject-options")
            if app.pickerWheels.firstMatch.exists {
                app.pickerWheels.firstMatch.adjust(toPickerWheelValue: name)
                if app.buttons["OK"].exists { app.buttons["OK"].tap() }
                else if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            } else {
                let option = app.buttons[name].exists ? app.buttons[name] : app.staticTexts[name]
                XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
                option.tap()
            }
        }
        selectSubject(subjectA)
        let search = web.textFields["Buscar una idea"].exists ? web.textFields["Buscar una idea"] : web.searchFields["Buscar una idea"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap(); search.typeText(last)
        let result = web.buttons.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", last, "pertenece a este corpus")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "study-graph-search-beyond-first-page")
        result.tap()
        let node = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "CONCEPTO ·", last)).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 30), app.debugDescription); node.tap()
        XCTAssertTrue(web.buttons["Cerrar grafo 2"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(node.waitForExistence(timeout: 30), app.debugDescription); node.tap()
        let evidenceHeading = web.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "Evidencia anclada")).firstMatch
        XCTAssertTrue(evidenceHeading.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "study-graph-concept-evidence")
        let closeDetail = web.buttons["Cerrar"]
        XCTAssertTrue(closeDetail.exists, app.debugDescription); closeDetail.tap()
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: evidenceHeading), app.debugDescription)
        XCTAssertTrue(node.waitForExistence(timeout: 20), app.debugDescription); node.tap()
        XCTAssertTrue(evidenceHeading.waitForExistence(timeout: 20), app.debugDescription)
        let evidence = web.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sección 223")).firstMatch
        XCTAssertTrue(evidence.exists, app.debugDescription); evidence.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Evidencias del grafo A de aceptación")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let reader = app.descendants(matching: .any)["study-evidence-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 20), app.debugDescription)
        let citedParagraph = reader.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "La definición A 222 pertenece a este corpus de pruebas ficticio.")).firstMatch
        XCTAssertTrue(citedParagraph.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(citedParagraph.isHittable, "The evidence source must open at the cited paragraph, not the beginning.\n\(app.debugDescription)")
        capture(app, "study-graph-source-document")
        let close = app.buttons["nodus-modal-close"]
        XCTAssertTrue(close.exists, app.debugDescription); close.tap()
        selectSubject(subjectB)
        XCTAssertFalse(evidenceHeading.exists, "The previous subject's selected concept must close.")
        let nextSearch = web.textFields["Buscar una idea"].exists ? web.textFields["Buscar una idea"] : web.searchFields["Buscar una idea"]
        XCTAssertTrue(nextSearch.waitForExistence(timeout: 20)); nextSearch.tap(); nextSearch.typeText(last)
        XCTAssertTrue(web.staticTexts["No hay ideas que coincidan con la búsqueda."].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
        capture(app, "study-graph-subject-isolation")
    }
    @MainActor
    func testToolsAreExplicitlyComingSoon() throws {
        for route in ["browser", "radar", "compass", "studyFocus", "toolkit"] {
            let app = launch(route)
            XCTAssertTrue(app.descendants(matching: .any)["nodus-coming-soon-\(route)"].waitForExistence(timeout: 15))
            capture(app, "coming-soon-\(route)")
            app.terminate()
        }
    }
    @MainActor
    func testLinkingDoesNotAskForCertificateOrAddress() throws {
        let app = launch("home")
        defer { app.terminate() }
        let spaces = app.buttons["Cambiar de espacio"]
        XCTAssertTrue(spaces.waitForExistence(timeout: 20)); spaces.tap()
        let link = app.buttons["nodus-add-server"]
        XCTAssertTrue(link.waitForExistence(timeout: 15)); link.tap()
        XCTAssertTrue(app.buttons["pairing-scan-qr"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["pairing-code"].exists)
        XCTAssertTrue(app.buttons["pairing-find-mac"].exists)
        XCTAssertFalse(app.textFields["SHA-256 certificate fingerprint"].exists)
        XCTAssertFalse(app.textFields["nodus-server-address"].exists)
        XCTAssertFalse(app.buttons["pairing-advanced-connection"].exists)
        capture(app, "link-nodus")
    }
    @MainActor
    func testLiveLibraryReadsCleanMarkdownAndOriginalPDF() throws {
        let app = try pairLive(route: "library")
        let document = app.buttons["workspace-open-library-nodus-acceptance-report"]
        XCTAssertTrue(document.waitForExistence(timeout: 45), app.debugDescription)
        capture(app, "live-library-catalogue"); document.tap()
        let original = app.buttons["Original"]
        XCTAssertTrue(original.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["published-library-clean-reader"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "label CONTAINS[c] %@", "fotografía")).firstMatch.exists, "The clean reader must contain report paragraphs.")
        capture(app, "live-library-clean-markdown"); original.tap()
        XCTAssertTrue(app.descendants(matching: .any)["published-library-original-reader"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "live-library-original-pdf")
    }
    @MainActor
    func testRelayPairingAndPrivateLibraryWithDirectConnectionUnavailable() throws {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_LINK"])
        let encoded = try XCTUnwrap(URLComponents(string: link)?.queryItems?.first(where: { $0.name == "offer" })?.value)
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let offer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(offer["origins"] as? [String], ["https://127.0.0.1:1"], "The direct Mac endpoint must be inaccessible in this test.")
        XCTAssertNotNil(offer["relay"], "An actual encrypted Server relay is required.")
        try testLiveLibraryReadsCleanMarkdownAndOriginalPDF()
    }
    @MainActor
    func testLiveDictionaryCitationOpensOriginalAtStoredPage() throws {
        let environment = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_ENTRY"])
        let evidenceLabel = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_EVIDENCE"])
        let pageValue = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_PAGE_VALUE"])
        let app = try pairLive(route: "dictionary")
        try verifySourceCitation(app: app, name: name, evidenceLabel: evidenceLabel, pageValue: pageValue, downloaded: false)
    }
    @MainActor
    func testLiveSourceCleanExportOpensFilesDestination() throws {
        let environment = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_ENTRY"])
        let evidenceLabel = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_EVIDENCE"])
        let pageValue = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_PAGE_VALUE"])
        let app = try pairLive(route: "dictionary")
        try verifySourceCitation(app: app, name: name, evidenceLabel: evidenceLabel, pageValue: pageValue, downloaded: false)
        app.buttons["Markdown limpio"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-document-clean"].firstMatch.waitForExistence(timeout: 10))
        try saveSourceExport(app: app, kind: "clean", fileExtension: "md")
    }
    @MainActor
    func testLiveSourceExportsOriginalCleanAndAttachmentToFiles() throws {
        let environment = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_ENTRY"])
        let evidenceLabel = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_EVIDENCE"])
        let pageValue = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_PAGE_VALUE"])
        let app = try pairLive(route: "dictionary")
        try verifySourceCitation(app: app, name: name, evidenceLabel: evidenceLabel, pageValue: pageValue, downloaded: false)
        try saveSourceExport(app: app, kind: "original", fileExtension: "pdf")
        app.buttons["Markdown limpio"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-document-clean"].firstMatch.waitForExistence(timeout: 10))
        try saveSourceExport(app: app, kind: "clean", fileExtension: "md")
        app.buttons["Adjuntos"].tap()
        let attachment = app.buttons["Adjunto de aceptación"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 10)); attachment.tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-file-preview"].firstMatch.waitForExistence(timeout: 30))
        try saveSourceExport(app: app, kind: "attachment", fileExtension: "txt")
    }
    @MainActor private func saveSourceExport(app: XCUIApplication, kind: String, fileExtension: String, control: XCUIElement? = nil) throws {
        let export = control ?? app.buttons["Exportar"].firstMatch
        export.tap()
        let saveToFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label == %@", "Guardar en Archivos", "Save to Files")
        ).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "source-\(kind)-export-share-sheet")
        saveToFiles.tap()
        let save = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Guardar", "Save")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "source-\(kind)-export-files-destination")
        let filenameField = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filenameField.exists)
        let filename = "Nodus-acceptance-\(kind)-" + UUID().uuidString
        filenameField.tap()
        let focusedFilename = app.textFields.matching(NSPredicate(
            format: "identifier == %@ AND hasKeyboardFocus == true", "DOCPicker.filenameTextField"
        )).firstMatch
        if !focusedFilename.waitForExistence(timeout: 3) { filenameField.tap() }
        capture(app, "source-\(kind)-export-filename-editing")
        XCTAssertTrue(focusedFilename.waitForExistence(timeout: 5),
            "The native Files filename field must own keyboard focus before typing.")
        if let existing = filenameField.value as? String {
            filenameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        filenameField.typeText(filename + "\n")
        let expectedFile = XCTAttachment(string: filename + "." + fileExtension)
        expectedFile.name = "source-\(kind)-export-expected-filename"
        expectedFile.lifetime = .keepAlways
        add(expectedFile)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)], timeout: 15), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: export)], timeout: 15), .completed)
        capture(app, "source-\(kind)-export-saved")
    }
    @MainActor
    func testDownloadedDictionaryCitationOpensOriginalWithMacUnavailable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_ENTRY"])
        let evidenceLabel = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_EVIDENCE"])
        let pageValue = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_PAGE_VALUE"])
        let origin = try XCTUnwrap(environment["NODUS_ACCEPTANCE_OFFLINE_ORIGIN"])
        let address = try XCTUnwrap(URL(string: origin + "/bridge/v2/capabilities"))
        let probe = URLSession(configuration: .ephemeral)
        defer { probe.invalidateAndCancel() }
        var request = URLRequest(url: address); request.timeoutInterval = 10
        do {
            _ = try await probe.data(for: request)
            XCTFail("The Mac Bridge must actually be unavailable before testing the downloaded copy."); return
        } catch {
            let transport = try XCTUnwrap(error as? URLError)
            XCTAssertTrue([.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(transport.code),
                "A certificate or permission failure must not masquerade as Mac disconnection.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"
        app.launch()
        try verifySourceCitation(app: app, name: name, evidenceLabel: evidenceLabel, pageValue: pageValue, downloaded: true)
    }
    @MainActor private func verifySourceCitation(app: XCUIApplication, name: String, evidenceLabel: String, pageValue: String, downloaded: Bool) throws {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 90), app.debugDescription)
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 35)); search.tap(); search.typeText(name + "\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription); entry.tap()
        let evidence = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Evidencia")).firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 20))
        XCTAssertTrue(evidence.isHittable); evidence.tap()
        let citation = web.buttons[evidenceLabel]
        XCTAssertTrue(citation.waitForExistence(timeout: 25), app.debugDescription)
        capture(app, "live-source-dictionary-evidence"); citation.tap()
        let jump = web.buttons["Ver página 2"]
        XCTAssertTrue(jump.waitForExistence(timeout: 25), app.debugDescription)
        capture(app, "live-source-citation-before-jump"); jump.tap()
        let reader = app.descendants(matching: .any)["source-document-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 30), app.debugDescription)
        let pdf = app.descendants(matching: .any)["source-citation-pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 45), app.debugDescription)
        // PDFKit reports its actual current page; this value is not the requested locator.
        let atPage = NSPredicate(format: "value == %@", pageValue)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atPage, object: pdf)], timeout: 20), .completed,
            "The actual PDF page must match its saved citation: \(String(describing: pdf.value))")
        XCTAssertFalse(app.staticTexts["No se pudo abrir"].exists)
        capture(app, downloaded ? "offline-source-original-at-page-two" : "live-source-original-at-page-two")
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] == "accessibility3" {
            let title = app.staticTexts["source-document-title"]
            XCTAssertTrue(title.exists)
            // The iPad can fit this title on a single enlarged line. On the
            // narrower iPhone it occupies several lines; both must exceed the
            // standard-size fixture's measured height on the respective device.
            XCTAssertGreaterThan(title.frame.height, app.frame.width > 600 ? 40 : 80,
                "Accessible text must actually enlarge the rendered title in the native source sheet.")
        }
        for title in ["Markdown limpio", "Original", "Adjuntos", "Exportar", "Detalles de la fuente"] {
            let button = app.buttons[title].firstMatch
            XCTAssertTrue(button.isHittable, "The reader action must remain reachable: \(title)")
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, "Reader actions need a 44-point touch target: \(title)")
        }
        if downloaded { XCTAssertTrue(app.staticTexts["Copia descargada"].waitForExistence(timeout: 10)) }
        app.buttons["Markdown limpio"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-document-clean"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "live-source-clean-reading")
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] == "accessibility3" {
            let summary = app.descendants(matching: .any)["source-document-clean"].firstMatch.staticTexts["Resumen"]
            XCTAssertTrue(summary.exists, "The source's native Markdown heading must be rendered.")
            XCTAssertGreaterThan(summary.frame.height, 35,
                "Native Markdown must use the same accessible text size as the source controls.")
        }
        app.buttons["Original"].tap()
        XCTAssertTrue(pdf.waitForExistence(timeout: 45))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atPage, object: pdf)], timeout: 20), .completed)
        if downloaded { XCTAssertTrue(app.staticTexts["Copia descargada"].waitForExistence(timeout: 10)) }
        capture(app, downloaded ? "offline-source-original-page-restored" : "live-source-original-page-restored")
        app.buttons["Adjuntos"].tap()
        let attachment = app.buttons["Adjunto de aceptación"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 10), app.debugDescription); attachment.tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-file-preview"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let content = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Adjunto ficticio del laboratorio", "Adjunto ficticio del laboratorio")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(pdf.exists, "An attached text file must not claim the original PDF's cited page.")
        if downloaded { XCTAssertTrue(app.staticTexts["Copia descargada"].waitForExistence(timeout: 10)) }
        capture(app, downloaded ? "offline-source-attachment" : "live-source-attachment")
        app.buttons["Original"].tap()
        XCTAssertTrue(pdf.waitForExistence(timeout: 30))
        capture(app, downloaded ? "offline-source-return-from-attachment" : "live-source-return-from-attachment")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: atPage, object: pdf)], timeout: 20), .completed)
        capture(app, downloaded ? "offline-source-original-after-attachment" : "live-source-original-after-attachment")
    }
    @MainActor
    func testPhoneDictionaryCatalogueBadgesInBothOrientations() throws {
        let app = try openExistingPrincipal(destination: "dictionary")
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let web = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        let catalogue = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Diccionario (")).firstMatch
        if catalogue.waitForExistence(timeout: 20), catalogue.isHittable { catalogue.tap() }
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 25))
        let ready = NSPredicate { _, _ in !web.staticTexts["Cargando entradas…"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 40), .completed)
        search.tap(); search.typeText("Propaganda\n")
        XCTAssertTrue(web.staticTexts["ACTIVO"].waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "phone-dictionary-compact-badges-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(web.staticTexts["ACTIVO"].waitForExistence(timeout: 15))
        capture(app, "phone-dictionary-compact-badges-landscape")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
    }
    @MainActor
    func testLiveDictionarySearchEvidenceAndVersions() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_NAME"], "A saved definition with evidence and versions is required.")
        let relatedName = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_RELATED_NAME"], "The related entry must come from the actual lab.")
        let body = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_BODY_SNIPPET"], "A paragraph from the saved definition is required; entry headings alone do not verify reading.")
        let author = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_AUTHOR_NAME"], "An actual author from the saved version's evidence is required.")
        let work = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_WORK_TITLE"], "An actual work from the saved version's evidence is required.")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"
        for reopen in 0..<2 {
            app.launch()
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 45), "The already linked Mac must remain available after restart.\n\(app.debugDescription)")
            XCTAssertFalse(app.buttons["pairing-confirm"].exists)
            verifyDictionaryConsultation(app: app, name: name, relatedName: relatedName, expectedBody: body, expectedAuthor: author, expectedWork: work, prefix: "live-reopen-\(reopen)")
            app.terminate()
        }
    }
    @MainActor
    func testPublishedDictionaryConsultsEverySectionWithoutMac() throws {
        let filename = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"])
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_NAME"])
        let relatedName = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_RELATED_NAME"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = filename
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"
        app.launch()
        verifyDictionaryConsultation(app: app, name: name, relatedName: relatedName)
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["shared-desktop-dictionary"].waitForExistence(timeout: 90), app.debugDescription)
        verifyDictionaryConsultation(app: app, name: name, relatedName: relatedName)
    }
    @MainActor private func openDictionaryEntryOptions(in web: XCUIElement) {
        let options = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Opciones de la entrada")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 15), web.debugDescription)
        for _ in 0..<8 { if options.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(options.isHittable, web.debugDescription); options.tap()
    }
    @MainActor private func verifyDictionaryConsultation(app: XCUIApplication, name: String, relatedName: String, expectedBody: String? = nil, expectedAuthor: String? = nil, expectedWork: String? = nil, prefix: String = "published") {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 90), app.debugDescription)
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap(); search.typeText(name + "\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "\(prefix)-dictionary-catalogue"); entry.tap()
        if expectedBody != nil {
            openDictionaryEntryOptions(in: web)
            // WKWebView exposes summary as an outer button whose label combines
            // the accessible name and visible text. Match its full touch target.
            let model = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Modelo de síntesis de la entrada")).firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 15), app.debugDescription)
            for _ in 0..<8 { if model.isHittable { break }; web.swipeUp() }
            XCTAssertTrue(model.isHittable, app.debugDescription); model.tap()
            let regenerate = web.buttons["Regenerar"]
            let evidence = web.buttons.containing(NSPredicate(format: "label == %@ OR label == %@", "Buscar evidencia nueva", "Recuperar evidencia")).firstMatch
            XCTAssertTrue(regenerate.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(evidence.exists && web.buttons["Actualizar"].exists, app.debugDescription)
            for _ in 0..<8 { if regenerate.isHittable { break }; web.swipeUp() }
            XCTAssertTrue(regenerate.isHittable, app.debugDescription)
            capture(app, "\(prefix)-dictionary-entry-options")
            let options = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Opciones de la entrada")).firstMatch
            for _ in 0..<8 { if options.isHittable { break }; web.swipeDown() }
            XCTAssertTrue(options.isHittable, app.debugDescription); options.tap()
            XCTAssertFalse(regenerate.exists, "Entry actions must fold while the saved definition remains available.")
        }
        // WKWebView can report an element as hittable while it is covered by
        // the fixed section header. Touch only controls in the reading pane.
        let sectionHeader = web.otherElements["cabecera de sección"].firstMatch
        let visibleTop = sectionHeader.exists ? sectionHeader.frame.maxY : web.frame.minY
        func reveal(_ element: XCUIElement) {
            for _ in 0..<12 {
                if element.isHittable && element.frame.minY >= visibleTop && element.frame.maxY <= web.frame.maxY { break }
                if element.frame.minY < visibleTop { web.swipeDown() } else { web.swipeUp() }
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(element.frame.minY, visibleTop, "The target must be below the fixed header.")
            XCTAssertLessThanOrEqual(element.frame.maxY, web.frame.maxY + 1, "The whole target must fit the visible reading pane.")
        }
        for section in ["Resumen", "Evidencia", "Autores", "Obras", "Versiones", "Relaciones"] {
            let tab = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", section)).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15), app.debugDescription)
            reveal(tab)
            XCTAssertGreaterThanOrEqual(tab.frame.minX, web.frame.minX - 1, "Section controls must fit the actual mobile pane.")
            XCTAssertLessThanOrEqual(tab.frame.maxX, web.frame.maxX + 1, "A partly clipped control must not count as reachable.")
            XCTAssertTrue(tab.isHittable, app.debugDescription); tab.tap()
            if section == "Evidencia" { XCTAssertTrue(web.textFields["Buscar en la evidencia…"].waitForExistence(timeout: 20), app.debugDescription) }
            if let expectedAuthor, section == "Autores" {
                let author = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", expectedAuthor, " ideas · ")).firstMatch
                XCTAssertTrue(author.waitForExistence(timeout: 20), "Selecting Authors must render its actual card, not leave Evidence selected.\n\(app.debugDescription)")
                reveal(author)
            }
            if let expectedWork, section == "Obras" {
                let work = web.staticTexts.containing(NSPredicate(format: "label == %@", expectedWork)).firstMatch
                XCTAssertTrue(work.waitForExistence(timeout: 20), app.debugDescription)
                let library = web.buttons.containing(NSPredicate(format: "label == %@", "Nodus Library")).firstMatch
                XCTAssertTrue(library.exists, app.debugDescription)
                XCTAssertFalse(work.frame.intersects(library.frame), "A work title and its Library action must not overlap at the selected text size.")
                XCTAssertGreaterThanOrEqual(work.frame.minX, web.frame.minX)
                XCTAssertLessThanOrEqual(work.frame.maxX, web.frame.maxX)
                reveal(work)
            }
            if section == "Versiones" {
                let version = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Versión ·")).firstMatch
                XCTAssertTrue(version.waitForExistence(timeout: 20), app.debugDescription)
                reveal(version); version.tap()
            }
            if let expectedBody, section == "Resumen" || section == "Versiones" {
                let paragraph = web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", expectedBody)).firstMatch
                XCTAssertTrue(paragraph.waitForExistence(timeout: 20), "The actual saved definition must load in \(section).\n\(app.debugDescription)")
                reveal(paragraph)
                capture(app, "\(prefix)-dictionary-\(section)-visible-definition")
            }
            if section == "Relaciones" {
                let related = web.buttons["Abrir entrada relacionada: \(relatedName)"]
                XCTAssertTrue(related.waitForExistence(timeout: 20), app.debugDescription)
                reveal(related)
            }
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
            capture(app, "\(prefix)-dictionary-\(section)")
        }
        let related = web.buttons["Abrir entrada relacionada: \(relatedName)"]
        related.tap()
        XCTAssertTrue(web.staticTexts.containing(NSPredicate(format: "label == %@", relatedName)).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "\(prefix)-dictionary-related-entry")
    }
    @MainActor
    func testPublishedDictionarySourceDossiersAndWorkPaginationWithoutMac() throws {
        let environment = ProcessInfo.processInfo.environment
        let filename = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"])
        let name = try XCTUnwrap(environment["NODUS_ACCEPTANCE_DICTIONARY_NAME"])
        let citation = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_LABEL"])
        let work = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_WORK"])
        let lastIdea = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_LAST_IDEA"])
        let total = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_IDEAS"].flatMap(Int.init))
        let authorLink = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_AUTHOR_LINK"])
        let authorName = try XCTUnwrap(environment["NODUS_ACCEPTANCE_SOURCE_AUTHOR_NAME"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = filename
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"
        app.launch(); app.activate()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 90), app.debugDescription)
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap(); search.typeText(name + "\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30)); entry.tap()
        let evidence = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Evidencia")).firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 15)); evidence.tap()
        let evidenceSearch = web.textFields["Buscar en la evidencia…"]
        XCTAssertTrue(evidenceSearch.waitForExistence(timeout: 20), app.debugDescription)
        for _ in 0..<8 { if evidenceSearch.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(evidenceSearch.isHittable, app.debugDescription)
        evidenceSearch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        evidenceSearch.typeText(citation + "\n")
        let source = web.buttons.containing(NSPredicate(format: "label == %@", citation)).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<10 { if source.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(source.isHittable, app.debugDescription); source.tap()
        let modal = web.otherElements["Fuentes y contexto, cuadro de diálogo de web"]
        XCTAssertTrue(modal.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(modal.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "Idea citada")).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        capture(app, "published-source-idea")
        let workLink = modal.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", work)).firstMatch
        XCTAssertTrue(workLink.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<15 { if workLink.isHittable { break }; modal.swipeUp() }
        XCTAssertTrue(workLink.isHittable, app.debugDescription); workLink.tap()
        let more = modal.buttons["Cargar más"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<15 { if more.isHittable { break }; modal.swipeUp() }
        XCTAssertTrue(more.isHittable, app.debugDescription)
        var loaded = 50
        while loaded < total {
            XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
            more.tap(); loaded = min(total, loaded + 50)
            let predicate = NSPredicate { _, _ in loaded == total ? !more.exists : modal.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Se muestran \(loaded) ideas")).firstMatch.exists }
            expectation(for: predicate, evaluatedWith: nil)
            waitForExpectations(timeout: 30)
        }
        XCTAssertTrue(modal.buttons.containing(NSPredicate(format: "label CONTAINS %@", lastIdea)).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(more.exists, app.debugDescription)
        capture(app, "published-source-work-all-ideas")
        let author = modal.buttons[authorLink].firstMatch
        XCTAssertTrue(author.exists, app.debugDescription)
        for _ in 0..<20 { if author.isHittable { break }; modal.swipeDown() }
        XCTAssertTrue(author.isHittable, app.debugDescription); author.tap()
        XCTAssertTrue(modal.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "Ficha de autor")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(modal.staticTexts[authorName].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
        capture(app, "published-source-author")
    }
    @MainActor
    func testPublishedResearchOpensSavedReportWithoutMac() throws {
        let filename = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"])
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_REPORT_NAME"])
        let imageHash = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_REPORT_IMAGE_HASH"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES", "-deep-research.gallery-read", "all", "-deep-research.gallery-view", "list"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = filename
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        for attempt in 0..<2 {
            app.launch(); app.activate()
            let search = app.textFields["nodus-search-field"]
            XCTAssertTrue(search.waitForExistence(timeout: 90), app.debugDescription)
            search.tap(); search.typeText(name + "\n")
            let report = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<6 { if report.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(report.isHittable, app.debugDescription)
            capture(app, "published-research-catalogue-\(attempt)"); report.tap()
            let copy = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Copiar")).firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(app.images["published-image-\(imageHash)"].waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertFalse(app.descendants(matching: .any)["published-image-error"].exists, app.debugDescription)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "España")).firstMatch.exists, app.debugDescription)
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "demo_unavailable")).firstMatch.exists)
            let pdf = app.buttons["report-pdf-build"]
            XCTAssertTrue(pdf.waitForExistence(timeout: 15), app.debugDescription); pdf.tap()
            XCTAssertTrue(app.buttons["report-pdf-ready"].waitForExistence(timeout: 90), app.debugDescription)
            capture(app, "published-research-reader-\(attempt)")
            app.terminate()
        }
    }
    @MainActor
    func testLiveStudyRecordingDownloadsAndOpensPrivateAudio() throws {
        let vault = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_VAULT_ID"])
        let record = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_FILE_ID"])
        let app = try pairLive(route: "studyRecordings", vaultId: vault)
        let recording = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Aceptación audio privado 0.1.0")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 45), app.debugDescription)
        capture(app, "live-private-recordings-catalogue"); recording.tap()
        let file = app.buttons["bridge-file-studyRecording-\(record)"]
        XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "live-private-recording-dossier"); file.tap()
        let preview = app.descendants(matching: .any)["saved-audio-player-scroll"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "live-private-audio-preview")
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), app.debugDescription)
        play.tap()
        let elapsed = app.descendants(matching: .any)["saved-audio-seek"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), app.debugDescription)
        let clock = app.staticTexts["saved-audio-elapsed"]
        let advances = NSPredicate { _, _ in !clock.label.isEmpty && !clock.label.contains("0:00") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advances, object: nil)], timeout: 10), .completed,
            "Downloaded audio must actually play and advance its timeline.\n\(app.debugDescription)")
        capture(app, "live-private-audio-playback")
    }
    @MainActor
    func testLiveSavedResearchNarrationDownloadsAndActuallyPlays() throws {
        let app = try pairLive(route: "deepResearch")
        app.launchEnvironment["NODUS_ACCEPTANCE_AUDIO_TRACE"] = "1"
        try verifySavedResearchNarration(app, downloaded: false)
    }
    @MainActor
    func testDownloadedResearchNarrationPlaysWithMacUnavailable() async throws {
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_OFFLINE_ORIGIN"])
        let url = try XCTUnwrap(URL(string: origin + "/bridge/v2/capabilities"))
        let probe = URLSession(configuration: .ephemeral); defer { probe.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        do { _ = try await probe.data(for: request); XCTFail("The Mac must actually be unreachable for offline audio acceptance."); return }
        catch {
            let error = try XCTUnwrap(error as? URLError)
            XCTAssertTrue([.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size }
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"; app.launch()
        try verifySavedResearchNarration(app, downloaded: true)
    }
    @MainActor
    func testExistingMacWorkspaceStartsWithoutPairingOrRouteInjection() throws {
        let env = ProcessInfo.processInfo.environment
        let marker = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let snippet = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = env["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        if let size = env["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size }
        for reopen in 0..<2 {
            app.launch()
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 45), "The actual persisted workspace must reopen without a test pairing link, snapshot, demo or route.\n\(app.debugDescription)")
            XCTAssertFalse(app.buttons["pairing-find-mac"].exists)
            capture(app, "normal-linked-workspace-startup-\(reopen)")
            app.buttons["nodus-navigation-toggle"].tap()
            if reopen == 0 {
                let graph = app.buttons["nodus-nav-graph"]
                for _ in 0..<6 { if graph.isHittable { break }; app.swipeDown() }
                XCTAssertTrue(graph.isHittable, app.debugDescription); graph.tap()
                let graphWeb = app.otherElements["shared-desktop-graph"].webViews.firstMatch
                XCTAssertTrue(graphWeb.searchFields["Filtrar temas"].waitForExistence(timeout: 60),
                    "Load the real graph before leaving it, so hidden HTML input regression coverage cannot pass vacuously.\n\(app.debugDescription)")
                capture(app, "normal-linked-workspace-active-graph")
            }
            let settings = app.buttons["nodus-nav-settings"]
            let topSettings = app.buttons["nodus-top-gearshape"]
            if topSettings.isHittable {
                topSettings.tap()
            } else {
                if !settings.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
                for _ in 0..<6 { if settings.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(settings.isHittable, app.debugDescription); settings.tap()
            }
            let renew = app.buttons["renew-mac-connection"]
            XCTAssertTrue(renew.waitForExistence(timeout: 20), app.debugDescription)
            for _ in 0..<6 { if renew.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(renew.isHittable, "The primary connection controls must be reachable without expanding technical details.")
            capture(app, "normal-linked-workspace-settings-\(reopen)")
            let details = app.buttons["mac-workspace-details"]
            XCTAssertTrue(details.isHittable, app.debugDescription); details.tap()
            let permissions = app.staticTexts["Permisos"]
            for _ in 0..<8 { if permissions.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(permissions.isHittable, app.debugDescription)
            capture(app, "normal-linked-workspace-details-\(reopen)")
            for _ in 0..<8 { if details.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(details.isHittable, app.debugDescription)
            details.tap()
            app.buttons["nodus-navigation-toggle"].tap()
            let research = app.buttons["nodus-nav-deepResearch"]
            XCTAssertTrue(research.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(research.isHittable, app.debugDescription); research.tap()
            let inactiveGraph = app.otherElements["shared-desktop-graph"].webViews.firstMatch
            XCTAssertFalse(inactiveGraph.searchFields["Filtrar temas"].exists,
                "An inactive graph must not leave its HTML search controls in the accessibility tree.")
            XCTAssertFalse(inactiveGraph.isHittable, "A retained invisible view cannot receive touches.")
            let web = app.otherElements["shared-desktop-deepResearch"].webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 35), app.debugDescription)
            let back = web.buttons["Volver a la galería"].firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
            let search = web.textFields.firstMatch
            try focusResearchSearch(search, in: web, app: app)
            if let previous = search.value as? String, previous.contains("NodusQA-") {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            search.typeText(marker); try dismissResearchKeyboard(app)
            let read = web.buttons["Leer"].firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 45), app.debugDescription)
            try revealResearchControl(read, in: web, upwards: true); read.tap()
            let body = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", snippet)).firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 25), app.debugDescription)
            try revealResearchControl(body, in: web, upwards: true)
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
            capture(app, "normal-linked-workspace-report-\(reopen)")
            app.terminate()
        }
    }
    @MainActor private func verifySavedResearchNarration(_ app: XCUIApplication, downloaded: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let marker = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let snippet = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        let label = try XCTUnwrap(env["NODUS_ACCEPTANCE_AUDIO_LABEL"])
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 120, expectedBody: snippet)
        let web = app.webViews.firstMatch, clip = web.buttons["Escuchar \(label)"].firstMatch
        try revealResearchControl(clip, in: web, upwards: true)
        XCTAssertTrue(clip.isEnabled); capture(app, "saved-narration-reader-tracks"); clip.tap()
        let play = app.buttons["saved-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertFalse(app.staticTexts["saved-audio-error"].exists)
        if downloaded { XCTAssertTrue(app.staticTexts["saved-audio-offline"].exists || app.otherElements["saved-audio-offline"].exists, app.debugDescription) }
        capture(app, downloaded ? "saved-narration-offline-ready" : "saved-narration-live-ready")
        XCTAssertTrue(play.isEnabled); play.tap()
        let elapsed = app.staticTexts["saved-audio-elapsed"]
        let advanced = expectation(for: NSPredicate { _, _ in elapsed.exists && elapsed.label != "0:00" }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed, "Actual decoded audio must advance its timeline.")
        XCTAssertTrue(play.label.contains("Pausa"), play.label)
        // Pause before opening the menu: XCTest waits for idleness while the
        // playback clock updates, which can outlast a short narration fixture.
        try verifyNarrationPause(app, play: play, elapsed: elapsed)
        let speed = app.buttons["saved-audio-speed"]
        XCTAssertTrue(speed.exists); speed.tap()
        let faster = app.buttons["2×"].firstMatch
        XCTAssertTrue(faster.waitForExistence(timeout: 10), app.debugDescription); faster.tap()
        let menuClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: faster)
        XCTAssertEqual(XCTWaiter.wait(for: [menuClosed], timeout: 5), .completed)
        XCTAssertTrue(speed.label.contains("2"), speed.label)
        XCTAssertTrue(play.label.contains("Reproducir"), "Changing speed must preserve paused playback.")
        let seek = app.sliders["saved-audio-seek"]
        XCTAssertTrue(seek.exists); seek.adjust(toNormalizedSliderPosition: 0.5)
        let sought = expectation(for: NSPredicate { _, _ in elapsed.label.hasPrefix("0:1") }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
        XCTAssertTrue(play.label.contains("Reproducir"), "Seeking must preserve paused playback.")
        app.buttons["saved-audio-back"].tap()
        let rewound = expectation(for: NSPredicate { _, _ in elapsed.label == "0:00" }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rewound], timeout: 5), .completed)
        app.buttons["saved-audio-forward"].tap()
        let forwarded = expectation(for: NSPredicate { _, _ in elapsed.label == "0:15" }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [forwarded], timeout: 5), .completed)
        XCTAssertTrue(play.label.contains("Reproducir"), "Skip controls must preserve paused playback.")
        seek.adjust(toNormalizedSliderPosition: 0.1)
        let restartTime = elapsed.label
        play.tap()
        let resumed = expectation(for: NSPredicate { _, _ in elapsed.label != restartTime && play.label.contains("Pausa") }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed, "Playback must resume at the selected speed.")
        speed.tap()
        let liveSpeed = app.buttons["1,25×"].firstMatch
        XCTAssertTrue(liveSpeed.waitForExistence(timeout: 10), app.debugDescription); liveSpeed.tap()
        let liveMenuClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: liveSpeed)
        XCTAssertEqual(XCTWaiter.wait(for: [liveMenuClosed], timeout: 5), .completed)
        XCTAssertTrue(speed.label.contains("1,25"), speed.label)
        XCTAssertTrue(play.label.contains("Pausa"), "The speed menu must preserve active playback without waiting for the clip to end.")
        try verifyNarrationPause(app, play: play, elapsed: elapsed)
        XCTAssertFalse(app.staticTexts["saved-audio-error"].exists)
        let export = app.buttons["saved-audio-export"]
        let close = app.buttons["nodus-modal-close"]
        let scroll = app.descendants(matching: .any)["saved-audio-player-scroll"].firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<6 {
            if export.isHittable && export.frame.maxY + 8 <= close.frame.minY { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(export.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(export.frame.maxY + 8, close.frame.minY, "The export action must remain fully above the floating close button at the requested text size.")
        capture(app, downloaded ? "saved-narration-offline-controls" : "saved-narration-live-controls")
        try saveSourceExport(app: app, kind: "narration", fileExtension: "wav", control: export)
        app.buttons["nodus-modal-close"].tap()
        XCTAssertTrue(web.buttons["Volver a la galería"].waitForExistence(timeout: 10))
    }
    @MainActor private func verifyNarrationPause(_ app: XCUIApplication, play: XCUIElement, elapsed: XCUIElement) throws {
        XCTAssertTrue(play.label.contains("Pausa"), "The pause check requires active playback.")
        play.tap()
        let paused = expectation(for: NSPredicate { _, _ in play.label.contains("Reproducir") }, evaluatedWith: app)
        let pauseResult = XCTWaiter.wait(for: [paused], timeout: 5)
        if pauseResult != .completed { capture(app, "saved-narration-pause-failure") }
        XCTAssertEqual(pauseResult, .completed, play.label)
        let pausedTime = elapsed.label
        let changedWhilePaused = expectation(for: NSPredicate { _, _ in elapsed.label != pausedTime }, evaluatedWith: app)
        changedWhilePaused.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changedWhilePaused], timeout: 1.2), .completed, "Pause must actually stop the timeline.")
    }
    @MainActor
    func testAutonomousDictionaryConsultationAndModePersistence() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_NAME"], "A generated entry with evidence, versions and a relation is required.")
        let relatedName = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_RELATED_NAME"], "The related entry must be identified by the laboratory fixture.")
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20), app.debugDescription); mode.tap()
        let autonomous = app.buttons["Autónomo · este dispositivo"]
        XCTAssertTrue(autonomous.waitForExistence(timeout: 10), app.debugDescription); autonomous.tap()
        capture(app, "autonomous-mode-selected")
        app.buttons["nodus-navigation-toggle"].tap()
        let dictionary = app.buttons["nodus-nav-dictionary"]
        for _ in 0..<6 { if dictionary.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(dictionary.isHittable, app.debugDescription); dictionary.tap()
        let web = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35), app.debugDescription)
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30)); search.tap(); search.typeText(name + "\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "autonomous-dictionary-catalogue"); entry.tap()
        var previous = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Resumen")).firstMatch
        for section in ["Resumen", "Evidencia", "Autores", "Obras", "Versiones", "Relaciones"] {
            let tab = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", section)).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15), app.debugDescription)
            for _ in 0..<4 { if tab.isHittable { break }; previous.swipeLeft() }
            tab.tap()
            if section == "Versiones" {
                let version = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Versión ·")).firstMatch
                XCTAssertTrue(version.waitForExistence(timeout: 20), app.debugDescription)
                for _ in 0..<4 { if version.isHittable { break }; web.swipeUp() }
                XCTAssertTrue(version.isHittable); version.tap()
            }
            if section == "Relaciones" {
                XCTAssertTrue(web.buttons["Abrir entrada relacionada: \(relatedName)"].waitForExistence(timeout: 20), app.debugDescription)
            }
            capture(app, "autonomous-dictionary-\(section)")
            previous = tab
        }
        let overview = web.buttons["Resumen"]
        for _ in 0..<5 { if overview.isHittable { break }; previous.swipeRight() }
        overview.tap()
        let edit = web.buttons["Editar"]
        for _ in 0..<5 { if edit.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(edit.isHittable); edit.tap()
        XCTAssertTrue(web.staticTexts["Editar entrada"].waitForExistence(timeout: 15))
        capture(app, "autonomous-dictionary-options")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK")
        app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["shared-desktop-dictionary"].waitForExistence(timeout: 30))
        app.buttons["nodus-navigation-toggle"].tap(); app.buttons["nodus-nav-settings"].tap()
        let persistedMode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if persistedMode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(persistedMode.label.contains("Autónomo"), "Restart must preserve the explicitly selected execution mode.\n\(app.debugDescription)")
        capture(app, "autonomous-mode-after-restart")
    }
    @MainActor
    func testAutonomousDictionaryGeneratesWithPhoneProviderAndPersists() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DICTIONARY_NAME"])
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let dictionary = app.buttons["nodus-nav-dictionary"]
        for _ in 0..<6 { if dictionary.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(dictionary.isHittable); dictionary.tap()
        let web = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35))
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        let readyEntry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(readyEntry.waitForExistence(timeout: 90), "The real dictionary catalogue must finish loading before generation.\n\(app.debugDescription)")
        capture(app, "autonomous-dictionary-ready-before-keyboard")
        XCTAssertTrue(search.isHittable); search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The dictionary input must open the keyboard on touch.\n\(app.debugDescription)")
        search.typeText("\(name)\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription); entry.tap()
        openDictionaryEntryOptions(in: web)
        let generate = web.buttons.matching(NSPredicate(format: "label IN %@", ["Generar", "Regenerar"])).firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(generate.isEnabled)
        capture(app, "autonomous-dictionary-before-generation"); generate.tap()
        let running = web.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Generando")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 45), "The requested definition must actually enter generation.\n\(app.debugDescription)")
        capture(app, "autonomous-dictionary-generation-running")
        let regenerate = web.buttons["Regenerar"]
        let completed = NSPredicate { _, _ in
            let status = app.staticTexts["autonomous-job-status"]
            return (regenerate.exists && regenerate.isEnabled) || (status.exists && status.label.contains("Error")) || web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "requiere un proveedor web")).firstMatch.exists
                || web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "La generación no pudo completarse")).firstMatch.exists
        }
        let completion = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: app)], timeout: 600)
        capture(app, "autonomous-dictionary-after-generation-request")
        XCTAssertEqual(completion, .completed, app.debugDescription)
        XCTAssertTrue(regenerate.exists && regenerate.isEnabled, "A phone-owned generation must finish and become the current persisted version.\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "autonomous-dictionary-generated")
        web.buttons["Versiones"].tap()
        XCTAssertTrue(web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Versión ·")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "autonomous-dictionary-generated-version")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK")
        app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        let reopened = app.otherElements["shared-desktop-dictionary"].webViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 30))
        let reopenedSearch = reopened.textFields.firstMatch
        XCTAssertTrue(reopenedSearch.waitForExistence(timeout: 30)); reopenedSearch.tap(); reopenedSearch.typeText("\(name)\n")
        let saved = reopened.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 30)); saved.tap()
        openDictionaryEntryOptions(in: reopened)
        XCTAssertTrue(reopened.buttons["Regenerar"].waitForExistence(timeout: 30))
        capture(app, "autonomous-dictionary-generated-reopened")
    }
    @MainActor
    func testAutonomousImmersionGeneratesPersistsAndResumes() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let immersion = app.buttons["nodus-nav-immersion"]
        for _ in 0..<6 { if immersion.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(immersion.isHittable); immersion.tap()
        let web = app.otherElements["shared-desktop-immersion"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35))
        let create = web.buttons["Nueva inmersión"]
        XCTAssertTrue(create.waitForExistence(timeout: 30)); create.tap()
        let topic = web.textFields.containing(NSPredicate(format: "placeholderValue BEGINSWITH %@", "¿De qué quieres hacerte experto?")).firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 15)); topic.tap(); topic.typeText("propaganda turística")
        web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Exprés")).firstMatch.tap()
        capture(app, "autonomous-immersion-composer")
        let explore = web.buttons["Explorar el territorio"]
        XCTAssertTrue(explore.isEnabled); explore.tap()
        let generate = web.buttons["Generar inmersión"]
        XCTAssertTrue(generate.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(generate.isEnabled, "An autonomous scope requires the phone model and actual usable corpus.\n\(app.debugDescription)")
        capture(app, "autonomous-immersion-scope"); generate.tap()
        let start = web.buttons["Comenzar inmersión"]
        let completed = NSPredicate { _, _ in
            let status = app.staticTexts["autonomous-job-status"]
            return start.exists || (status.exists && status.label.contains("Error")) || app.staticTexts["shared-surface-error"].exists
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: app)], timeout: 900)
        capture(app, "autonomous-immersion-generation-result")
        XCTAssertEqual(result, .completed); XCTAssertTrue(start.exists, app.debugDescription)
        XCTAssertFalse(web.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "generación degradada")).firstMatch.exists)
        for _ in 0..<8 { if start.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(start.isHittable); start.tap()
        let next = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Siguiente:")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 20)); next.tap()
        capture(app, "autonomous-immersion-first-station")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK")
        app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        let reopened = app.otherElements["shared-desktop-immersion"].webViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 35))
        let search = reopened.textFields["Buscar entre tus inmersiones…"]
        XCTAssertTrue(search.waitForExistence(timeout: 25)); search.tap(); search.typeText("propaganda turística\n")
        let resume = reopened.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Continuar")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), app.debugDescription); resume.tap()
        XCTAssertTrue(reopened.buttons["Salir"].waitForExistence(timeout: 25))
        capture(app, "autonomous-immersion-resumed-after-restart")
    }
    @MainActor
    func testCompanionDeletesPreviouslyChosenDownloads() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let copies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "companion-download-remove-"))
        for _ in 0..<12 { if copies.firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertGreaterThan(copies.count, 0, "This recovery case requires actual previous downloads in the isolated simulator.")
        for _ in 0..<8 {
            let count = copies.count
            if count == 0 { break }
            XCTAssertTrue(copies.firstMatch.isHittable); copies.firstMatch.tap()
            let removed = NSPredicate { _, _ in copies.count < count }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 15), .completed)
        }
        XCTAssertEqual(copies.count, 0)
        capture(app, "companion-old-downloads-removed-through-settings")
    }
    @MainActor
    func testCompanionDownloadsChosenScriptorDocument() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let select = app.buttons["companion-download-select"]
        for _ in 0..<12 { if select.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(select.isHittable, app.debugDescription); select.tap()
        XCTAssertTrue(app.navigationBars["Descargar para llevar"].waitForExistence(timeout: 15), "The download selector must open above Settings.\n\(app.debugDescription)")
        try findCompanionScriptorDocument(app)
        let noteId = "71af4d2a-74d1-4761-86ad-7df8b10f387e"
        let note = app.buttons["companion-download-note-" + noteId]
        for _ in 0..<8 { if note.exists && note.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(note.exists, app.debugDescription)
        XCTAssertTrue(note.isHittable); note.tap()
        XCTAssertEqual(note.value as? String, "Seleccionado")
        capture(app, "companion-one-structured-document-selected")
        app.buttons["companion-download-start"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["companion-download-ready"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertFalse(app.staticTexts["companion-download-error"].exists)
        capture(app, "companion-selected-download-complete")
        app.buttons["Cerrar"].tap()
        let pack = app.staticTexts["1 documento de Scriptor"].firstMatch
        for _ in 0..<6 { if pack.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pack.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "companion-download-size-and-expiry")
        // Refresh the exact same selection. It must remain one complete copy.
        for _ in 0..<6 { if select.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(select.isHittable)
        select.tap()
        XCTAssertTrue(app.navigationBars["Descargar para llevar"].waitForExistence(timeout: 15))
        try findCompanionScriptorDocument(app)
        for _ in 0..<8 { if note.exists && note.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(note.exists && note.isHittable); note.tap()
        app.buttons["companion-download-start"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["companion-download-ready"].firstMatch.waitForExistence(timeout: 45))
        app.buttons["Cerrar"].tap()
        for _ in 0..<6 { if pack.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pack.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "1 documento de Scriptor")).count, 1)
        capture(app, "companion-repeated-selection-refreshes-one-copy")
        // Only disposable consulted copies are freed. The selected download
        // must remain available for the following actual offline run.
        let clear = app.buttons["companion-clear-read-copies"]
        for _ in 0..<6 { if clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        app.buttons["Liberar espacio"].tap()
        XCTAssertTrue(app.staticTexts["1 documento de Scriptor"].exists)
        capture(app, "companion-chosen-download-survives-consulted-cleanup")
    }
    @MainActor private func findCompanionScriptorDocument(_ app: XCUIApplication) throws {
        let search = app.searchFields["Buscar notas e ideas"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Aceptación Scriptor móvil 0.1.0\n")
        capture(app, "companion-document-search")
    }
    @MainActor
    func testCompanionSettingsReadsRealMacEmbeddingIdentity() throws {
        let model = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_EMBEDDING_MODEL"], "The owning Mac index identity must come from an actual isolated-vault query.")
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let identity = app.staticTexts[model]
        for _ in 0..<10 {
            if identity.isHittable && identity.frame.maxY < app.windows.firstMatch.frame.maxY - 50 { break }
            app.swipeUp()
        }
        XCTAssertTrue(identity.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "does not grant access")).firstMatch.exists)
        capture(app, "companion-settings-real-mac-index-identity")
    }
    @MainActor
    func testCompanionClearsConsultedCopiesAndKeepsChosenDownload() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let pack = app.staticTexts["1 documento de Scriptor"].firstMatch
        for _ in 0..<12 { if pack.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pack.exists, "A previously chosen download is required; missing setup is a failure.")
        let clear = app.buttons["companion-clear-read-copies"]
        for _ in 0..<6 { if clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.isHittable); clear.tap()
        app.buttons["Liberar espacio"].tap()
        XCTAssertTrue(pack.exists)
        capture(app, "companion-clear-consulted-before-real-offline-read")
    }
    @MainActor
    func testScriptorShowsRealCompanionConflictWithoutOverwriting() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"])
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if note.waitForExistence(timeout: 8) { note.tap() }
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
        let local = NSPredicate { _, _ in (editor.value as? String)?.contains(marker) == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: local, object: nil)], timeout: 30), .completed)
        let keep = web.buttons["Usar mi versión del móvil"]
        XCTAssertTrue(keep.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(web.buttons["Usar la versión del Mac"].exists)
        XCTAssertTrue(web.buttons["Descargar copia local"].exists)
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "scriptor-both-versions-preserved-before-choice")
    }
    @MainActor
    func testScriptorResolvesRealCompanionConflictWithMobileChoice() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"])
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if note.waitForExistence(timeout: 8) { note.tap() }
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let keep = web.buttons["Usar mi versión del móvil"]
        XCTAssertTrue(keep.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(keep.isHittable); XCTAssertGreaterThanOrEqual(keep.frame.height, 44); keep.tap()
        let saved = NSPredicate { _, _ in
            !web.buttons["Usar mi versión del móvil"].exists && web.staticTexts["Guardado"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 45), .completed, app.debugDescription)
        XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists)
        capture(app, "scriptor-explicit-mobile-choice-saved")
    }
    @MainActor
    func testScriptorResolvesRealCompanionConflictWithMacChoice() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"])
        let remote = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_MAC_CONFLICT_MARKER"])
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if note.waitForExistence(timeout: 8) { note.tap() }
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
        let keep = web.buttons["Usar la versión del Mac"]
        XCTAssertTrue(keep.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(keep.isHittable); XCTAssertGreaterThanOrEqual(keep.frame.height, 44); keep.tap()
        let saved = NSPredicate { _, _ in
            !web.buttons["Usar la versión del Mac"].exists && web.staticTexts["Guardado"].exists &&
            (editor.value as? String)?.contains(remote) == true
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 45), .completed, app.debugDescription)
        XCTAssertFalse((editor.value as? String)?.contains(marker) == true)
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists)
        capture(app, "scriptor-explicit-mac-choice-saved")
        app.terminate()
        let reopened = try openExistingPrincipal(destination: "workspace")
        defer { reopened.terminate() }
        let restoredWeb = reopened.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(restoredWeb.waitForExistence(timeout: 45))
        let catalogue = restoredWeb.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if catalogue.waitForExistence(timeout: 8) { catalogue.tap() }
        let restored = restoredWeb.textViews["Editor del documento"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30))
        XCTAssertTrue((restored.value as? String)?.contains(remote) == true)
        XCTAssertFalse((restored.value as? String)?.contains(marker) == true)
        XCTAssertFalse(restoredWeb.buttons["Usar la versión del Mac"].exists)
        capture(reopened, "scriptor-mac-choice-reopened")
    }
    @MainActor
    func testOfflineScriptorCreatesDocumentAndReopens() async throws {
        try await createOfflineCompanionItem(menuItem: "Nota", defaultTitle: "Nota sin título")
    }
    @MainActor
    func testOfflineScriptorCreatesManualIdeaAndReopens() async throws {
        try await createOfflineCompanionItem(menuItem: "Idea", defaultTitle: "Idea sin título")
    }
    @MainActor
    private func createOfflineCompanionItem(menuItem: String, defaultTitle: String) async throws {
        continueAfterFailure = true
        try await verifyOwningMacUnavailable()
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        guard web.waitForExistence(timeout: 45) else { XCTFail("Scriptor must be available offline."); return }
        let create = web.buttons["Crear"].firstMatch
        if !create.waitForExistence(timeout: 8) {
            let home = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Nodus Scriptor")).firstMatch
            guard home.exists, home.isHittable else { capture(app, "offline-creation-catalogue-unavailable"); XCTFail("The Scriptor catalogue must remain reachable."); return }
            home.tap()
        }
        guard create.waitForExistence(timeout: 30), create.isHittable else { capture(app, "offline-creation-action-unavailable"); XCTFail("The real Create action must be usable offline."); return }
        XCTAssertGreaterThanOrEqual(create.frame.width, 44); XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        create.tap()
        let note = web.buttons[menuItem].firstMatch
        guard note.waitForExistence(timeout: 10), note.isHittable else { XCTFail("The creation menu must offer the actual requested item."); return }
        XCTAssertGreaterThanOrEqual(note.frame.height, 44)
        capture(app, "scriptor-offline-create-menu")
        note.tap()
        let editor = web.textViews["Editor del documento"]
        guard editor.waitForExistence(timeout: 45), editor.isHittable else { capture(app, "offline-new-editor-unavailable"); XCTFail("A locally created document must open without the Mac.\n\(app.debugDescription)"); return }
        editor.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 10) else { XCTFail("The new document must accept native keyboard input."); return }
        let marker = "CompanionCreate-\(UUID().uuidString.prefix(8))"
        let body = "\(marker). Documento creado y escrito sin conexión al Mac. Debe conservarse al cerrar la app y sincronizarse con su misma identidad al volver a conectar."
        editor.typeText(body)
        print("NODUS_OFFLINE_CREATED_DOCUMENT_MARKER=\(marker)")
        let pending = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Guardado en este dispositivo")).firstMatch
        guard pending.waitForExistence(timeout: 20) else { capture(app, "offline-new-document-not-saved"); XCTFail("The new document must save on this device."); return }
        XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "scriptor-offline-new-document-saved")
        app.terminate()
        let reopened = try openExistingPrincipal(destination: "workspace")
        defer { reopened.terminate() }
        let restoredWeb = reopened.otherElements["shared-desktop-workspace"].webViews.firstMatch
        guard restoredWeb.waitForExistence(timeout: 45) else { XCTFail("Scriptor must reopen offline."); return }
        let restoredEditor = restoredWeb.textViews["Editor del documento"]
        if !restoredEditor.waitForExistence(timeout: 8) {
            let search = restoredWeb.textFields["Buscar en notas e ideas…"]
            guard search.waitForExistence(timeout: 30), search.isHittable else { XCTFail("The local new document must be discoverable after restarting."); return }
            search.tap()
            if let previous = search.value as? String, previous != search.placeholderValue {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            search.typeText(marker + "\n")
            let created = restoredWeb.buttons["Abrir \(defaultTitle)"]
            guard created.waitForExistence(timeout: 20), created.isHittable else { capture(reopened, "offline-created-row-unavailable"); XCTFail("The exact newly created note must remain in its catalogue."); return }
            XCTAssertEqual(restoredWeb.buttons.matching(NSPredicate(format: "label == %@", "Abrir \(defaultTitle)")).count, 1)
            created.tap()
        }
        guard restoredEditor.waitForExistence(timeout: 30) else { XCTFail("The complete new document must reopen offline."); return }
        XCTAssertTrue((restoredEditor.value as? String)?.contains(body) == true)
        XCTAssertTrue(restoredWeb.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Guardado en este dispositivo")).firstMatch.exists)
        XCTAssertFalse(reopened.staticTexts["shared-surface-error"].exists)
        capture(reopened, "scriptor-offline-new-document-reopened")
    }
    @MainActor
    func testCreatedCompanionDocumentSynchronizesAndReopens() throws {
        try createdCompanionItemSynchronizes(defaultTitle: "Nota sin título")
    }
    @MainActor
    func testCreatedCompanionManualIdeaSynchronizesAndReopens() throws {
        try createdCompanionItemSynchronizes(defaultTitle: "Idea sin título")
    }
    @MainActor
    private func createdCompanionItemSynchronizes(defaultTitle: String) throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_CREATED_DOCUMENT_MARKER"])
        XCTAssertTrue(marker.hasPrefix("CompanionCreate-"))
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let editor = web.textViews["Editor del documento"]
        if !editor.waitForExistence(timeout: 8) {
            let search = web.textFields["Buscar en notas e ideas…"]
            XCTAssertTrue(search.waitForExistence(timeout: 30)); search.tap()
            if let previous = search.value as? String, previous != search.placeholderValue {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            }
            search.typeText(marker + "\n")
            let row = web.buttons["Abrir \(defaultTitle)"]
            XCTAssertTrue(row.waitForExistence(timeout: 30)); XCTAssertTrue(row.isHittable); row.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let confirmed = NSPredicate { _, _ in
            (editor.value as? String)?.contains(marker) == true && web.staticTexts["Guardado"].exists &&
            !web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Guardado en este dispositivo")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: confirmed, object: nil)], timeout: 60), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "scriptor-created-document-confirmed-by-mac")
        app.terminate()
        let reopened = try openExistingPrincipal(destination: "workspace")
        defer { reopened.terminate() }
        let restoredWeb = reopened.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(restoredWeb.waitForExistence(timeout: 45))
        let restoredSearch = restoredWeb.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(restoredSearch.waitForExistence(timeout: 30))
        restoredSearch.tap(); restoredSearch.typeText(marker + "\n")
        let row = restoredWeb.buttons["Abrir \(defaultTitle)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertEqual(restoredWeb.buttons.matching(NSPredicate(format: "label == %@", "Abrir \(defaultTitle)")).count, 1)
        row.tap()
        let restored = restoredWeb.textViews["Editor del documento"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30))
        XCTAssertTrue((restored.value as? String)?.contains(marker) == true)
        XCTAssertTrue(restoredWeb.staticTexts["Guardado"].exists)
        XCTAssertFalse(restoredWeb.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Guardado en este dispositivo")).firstMatch.exists)
        capture(reopened, "scriptor-created-canonical-document-reopened")
    }
    @MainActor
    func testScriptorPreparesStructuredCompanionCopy() throws {
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let search = web.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30)); search.tap(); search.typeText("Aceptación Scriptor móvil 0.1.0\n")
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        XCTAssertTrue(note.waitForExistence(timeout: 30)); note.tap()
        XCTAssertTrue(web.textViews["Editor del documento"].waitForExistence(timeout: 30))
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists)
        capture(app, "scriptor-companion-copy-ready")
    }
    @MainActor
    func testOfflineScriptorSavesStructuredEditAndReopens() async throws {
        // XCTest's Objective-C interruption cannot unwind an async actor task.
        // Explicit guards end failed setup without attempting nonexistent UI.
        continueAfterFailure = true
        try await verifyOwningMacUnavailable()
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let editor = web.textViews["Editor del documento"]
        if !editor.exists {
            let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
            guard note.waitForExistence(timeout: 30) else {
                capture(app, "scriptor-offline-catalogue-unavailable")
                XCTFail("The selected offline document must appear in its catalogue.\n\(app.debugDescription)"); return
            }
            note.tap()
        }
        guard editor.waitForExistence(timeout: 30) else { XCTFail("The chosen offline document must open.\n\(app.debugDescription)"); return }
        let paragraph = web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Frase de prueba enviada desde Desktop al movil.")).firstMatch
        guard paragraph.exists else { XCTFail("The downloaded paragraph is missing."); return }
        for _ in 0..<8 { if paragraph.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(paragraph.isHittable); paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2)).tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 10) else { XCTFail("The offline editor must accept native keyboard input."); return }
        let marker = "MobileOffline-\(UUID().uuidString.prefix(8))"
        editor.typeText(" \(marker).")
        print("NODUS_OFFLINE_SCRIPTOR_MARKER=\(marker)")
        let pending = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pendiente de sincronizar")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 30), "The document must be saved locally while its Mac is unreachable.\n\(app.debugDescription)")
        XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
        capture(app, "offline-scriptor-saved-on-device")
        app.terminate()
        let relaunched = try openExistingPrincipal(destination: "workspace")
        defer { relaunched.terminate() }
        let restoredWeb = relaunched.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(restoredWeb.waitForExistence(timeout: 45))
        let catalogue = restoredWeb.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if catalogue.waitForExistence(timeout: 8) { catalogue.tap() }
        let restored = restoredWeb.textViews["Editor del documento"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30), relaunched.debugDescription)
        XCTAssertTrue((restored.value as? String)?.contains(marker) == true)
        XCTAssertTrue(restoredWeb.staticTexts["Libro"].firstMatch.exists && restoredWeb.staticTexts["Cita"].firstMatch.exists)
        XCTAssertTrue(restoredWeb.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pendiente de sincronizar")).firstMatch.exists)
        XCTAssertFalse(relaunched.staticTexts["shared-surface-error"].exists)
        capture(relaunched, "offline-scriptor-structured-document-reopened")
    }
    @MainActor
    func testOfflineStructuredEditSynchronizesAndReopens() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_OFFLINE_SCRIPTOR_MARKER"])
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let search = web.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap(); search.typeText("Aceptación Scriptor móvil 0.1.0\n")
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        XCTAssertTrue(note.waitForExistence(timeout: 30)); note.tap()
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let confirmed = NSPredicate { _, _ in
            (editor.value as? String)?.contains(marker) == true && web.staticTexts["Guardado"].exists &&
            !web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pendiente de sincronizar")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: confirmed, object: nil)], timeout: 60), .completed, app.debugDescription)
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "scriptor-offline-edit-confirmed-by-mac")
        app.terminate()
        let reopened = try openExistingPrincipal(destination: "workspace")
        defer { reopened.terminate() }
        let restoredWeb = reopened.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(restoredWeb.waitForExistence(timeout: 45))
        let catalogue = restoredWeb.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if catalogue.waitForExistence(timeout: 8) { catalogue.tap() }
        let restored = restoredWeb.textViews["Editor del documento"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30))
        XCTAssertTrue((restored.value as? String)?.contains(marker) == true)
        XCTAssertTrue(restoredWeb.staticTexts["Guardado"].exists)
        XCTAssertFalse(restoredWeb.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "pendiente de sincronizar")).firstMatch.exists)
        XCTAssertTrue(restoredWeb.staticTexts["Libro"].firstMatch.exists && restoredWeb.staticTexts["Cita"].firstMatch.exists)
        capture(reopened, "scriptor-synchronized-structured-edit-reopened")
    }
    @MainActor
    func testLiveScriptorReadsDesktopEditAndReopens() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"], "A marker written through the real Desktop editor is required.")
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let search = web.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap(); search.typeText("Aceptación Scriptor móvil 0.1.0\n")
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        XCTAssertTrue(note.waitForExistence(timeout: 30)); note.tap()
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertTrue((editor.value as? String)?.contains(marker) == true, "The actual Desktop edit must reach the native editor.")
        XCTAssertTrue(web.staticTexts["Libro"].firstMatch.exists && web.staticTexts["Cita"].firstMatch.exists, "Both preserved table cells must remain rendered.")
        let paragraph = web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 15))
        for _ in 0..<8 { if paragraph.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(paragraph.isHittable)
        capture(app, "live-scriptor-desktop-edit-visible")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK"); app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 10) { principal.tap() }
        let reopened = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 45))
        let catalogue = reopened.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if catalogue.waitForExistence(timeout: 8) { catalogue.tap() }
        let restored = reopened.textViews["Editor del documento"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30))
        XCTAssertTrue((restored.value as? String)?.contains(marker) == true)
        XCTAssertTrue(reopened.staticTexts["Libro"].firstMatch.exists && reopened.staticTexts["Cita"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "live-scriptor-desktop-edit-reopened")
    }
    @MainActor
    func testLiveScriptorEditsStructuredDocumentAndReopens() throws {
        let app = try openExistingPrincipal(destination: "workspace")
        defer { app.terminate() }
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 45))
        let search = web.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), app.debugDescription)
        search.tap(); search.typeText("Aceptación Scriptor móvil 0.1.0\n")
        let note = web.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "live-scriptor-catalogue"); note.tap()
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(editor.isHittable, app.debugDescription)
        for label in ["Contexto", "Foco"] {
            let control = web.switches[label].firstMatch
            XCTAssertTrue(control.exists, label)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, label)
        }
        for label in ["Deshacer", "Rehacer", "Citar fuente", "Añadir comentario"] {
            let control = web.buttons[label].firstMatch
            XCTAssertTrue(control.exists, label)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, label)
        }
        let prompts = web.switches["Prompts de mejora"]
        XCTAssertTrue(prompts.exists)
        XCTAssertGreaterThanOrEqual(prompts.frame.width, 44)
        capture(app, "live-scriptor-before-edit")
        let paragraph = web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Frase de prueba enviada desde Desktop al movil.")).firstMatch
        XCTAssertTrue(paragraph.exists, app.debugDescription)
        for _ in 0..<8 { if paragraph.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(paragraph.isHittable, app.debugDescription)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let edit = "Edición comprobada desde el iPhone \(UUID().uuidString.prefix(8))"
        editor.typeText(" \(edit).")
        print("NODUS_SCRIPTOR_EDIT=\(edit)")
        XCTAssertTrue(web.staticTexts["Guardado"].waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "live-scriptor-saved")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK"); app.launchEnvironment.removeValue(forKey: "NODUS_START_ROUTE"); app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 10) { principal.tap() }
        let reopened = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 30))
        let catalogue = reopened.buttons["Abrir Aceptación Scriptor móvil 0.1.0"]
        if catalogue.waitForExistence(timeout: 10) { catalogue.tap() }
        let persisted = reopened.textViews.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", edit, edit)).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "live-scriptor-reopened")
    }
    @MainActor
    func testAutonomousWritingImprovesAndReopensSavedDocument() throws {
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let scriptor = app.buttons["nodus-nav-workspace"]
        for _ in 0..<7 { if scriptor.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(scriptor.isHittable, app.debugDescription); scriptor.tap()
        let web = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        let search = web.textFields["Buscar en notas e ideas…"]
        XCTAssertTrue(search.waitForExistence(timeout: 35)); search.tap()
        search.typeText("Aceptación asistencia autónoma 0.1.0\n")
        let note = web.buttons["Abrir Aceptación asistencia autónoma 0.1.0"]
        XCTAssertTrue(note.waitForExistence(timeout: 30)); note.tap()
        let editor = web.textViews["Editor del documento"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
        let originalEditor = editor.value as? String ?? editor.label
        capture(app, "autonomous-writing-original")
        let prompts = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Prompts de mejora")).firstMatch
        XCTAssertTrue(prompts.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<4 { if prompts.isHittable { break }; web.swipeLeft() }; prompts.tap()
        let promptSearch = web.searchFields["Buscar prompts…"]
        XCTAssertTrue(promptSearch.waitForExistence(timeout: 15), app.debugDescription)
        promptSearch.tap(); promptSearch.typeText("Claro\n")
        let clear = web.switches["Claro"]
        XCTAssertTrue(clear.waitForExistence(timeout: 15), app.debugDescription); clear.tap()
        capture(app, "autonomous-writing-prompt")
        let improve = web.buttons["Mejorar con IA"]
        XCTAssertTrue(improve.waitForExistence(timeout: 15), app.debugDescription); improve.tap()
        let confirm = web.buttons["Mejorar documento completo"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "autonomous-writing-confirmation"); confirm.tap()
        capture(app, "autonomous-writing-generating")
        let undo = web.buttons["Deshacer mejora"]
        let completed = NSPredicate { _, _ in
            undo.exists || app.staticTexts["shared-surface-error"].exists ||
                web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "El original permanece intacto.")).firstMatch.exists ||
                (app.staticTexts["autonomous-job-status"].exists && app.staticTexts["autonomous-job-status"].label.contains("Error"))
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: nil)], timeout: 180), .completed, app.debugDescription)
        XCTAssertTrue(undo.exists, app.debugDescription)
        XCTAssertFalse(web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "El original permanece intacto.")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(web.staticTexts["Guardado"].waitForExistence(timeout: 30), app.debugDescription)
        let saved = editor.value as? String ?? editor.label
        XCTAssertNotEqual(saved, originalEditor, "The real provider must actually improve the document.")
        XCTAssertTrue(saved.contains("37") && saved.contains("2024") && saved.contains("García"), saved)
        capture(app, "autonomous-writing-saved")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK"); app.launchEnvironment.removeValue(forKey: "NODUS_START_ROUTE"); app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 10) { principal.tap() }
        let reopened = app.otherElements["shared-desktop-workspace"].webViews.firstMatch
        let catalogue = reopened.buttons["Abrir Aceptación asistencia autónoma 0.1.0"]
        if catalogue.waitForExistence(timeout: 10) { catalogue.tap() }
        let persisted = reopened.textViews["Editor del documento"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 30), app.debugDescription)
        let actual = persisted.value as? String ?? persisted.label
        XCTAssertEqual(actual, saved, "Reopening must preserve the exact generated document.")
        capture(app, "autonomous-writing-reopened")
    }
    @MainActor
    func testNativeReportPreparesCompanionConsultation() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TRANSLATION_REPORT_TITLE"])
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap(); app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let reports = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if reports.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reports.isHittable); reports.tap()
        try openNativeTranslation(app, title: title)
        let generate = app.buttons["report-translation-generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20)); XCTAssertTrue(generate.isEnabled)
        capture(app, "native-report-consultation-ready-for-offline-use")
    }
    @MainActor
    func testAutonomousTranslationWithMacUnavailable() async throws {
        try await verifyOwningMacUnavailable()
        try generateAutonomousTranslationAndReopen()
    }
    @MainActor
    func testOfflineSavedTranslationReopensWithoutRegeneration() async throws {
        try await verifyOwningMacUnavailable()
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TRANSLATION_REPORT_TITLE"])
        let expectedText = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TRANSLATION_BODY_SNIPPET"])
        XCTAssertGreaterThan(expectedText.count, 100)
        var rendered: String?
        for _ in 0..<2 {
            let app = try openExistingPrincipal(destination: "deepResearch")
            try openNativeTranslation(app, title: title)
            let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedText)).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 30), app.debugDescription)
            if let rendered { XCTAssertEqual(saved.label, rendered) } else { rendered = saved.label }
            XCTAssertFalse(app.descendants(matching: .any)["report-translation-error"].exists)
            XCTAssertTrue(app.buttons["Done"].exists || app.buttons["Listo"].exists)
            capture(app, "offline-existing-translation-reopened")
            app.terminate()
        }
    }
    @MainActor private func verifyOwningMacUnavailable() async throws {
        let origin = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_OFFLINE_ORIGIN"])
        let address = try XCTUnwrap(URL(string: origin + "/bridge/v2/capabilities"))
        let probe = URLSession(configuration: .ephemeral)
        defer { probe.invalidateAndCancel() }
        var request = URLRequest(url: address); request.timeoutInterval = 8
        do {
            _ = try await probe.data(for: request)
            throw NSError(domain: "NodusAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "The owning Mac must actually be unavailable."])
        } catch {
            let transport = try XCTUnwrap(error as? URLError)
            XCTAssertTrue([.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(transport.code))
        }
    }
    @MainActor
    func testAutonomousReportTranslationUsesPhoneAndReopens() throws {
        try generateAutonomousTranslationAndReopen()
    }
    @MainActor private func generateAutonomousTranslationAndReopen() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TRANSLATION_REPORT_TITLE"], "An actual saved lab report is required.")
        let app = try openExistingPrincipal(destination: "settings")
        defer { app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let reports = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if reports.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reports.isHittable); reports.tap()
        try openNativeTranslation(app, title: title)
        let generate = app.buttons["report-translation-generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20)); XCTAssertTrue(generate.isEnabled)
        let body = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Francoist")).firstMatch
        let previousTranslation = body.exists ? body.label : nil
        for _ in 0..<20 { if generate.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(generate.isHittable)
        capture(app, "autonomous-translation-before-generation")
        generate.tap()
        let generating = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [generating], timeout: 15), .completed, "The phone must actually start generation.")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 240), .completed, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["report-translation-error"].exists, app.debugDescription)
        let translated = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Francoist")).firstMatch
        XCTAssertTrue(translated.waitForExistence(timeout: 20), app.debugDescription)
        let result = translated.label
        XCTAssertGreaterThan(result.count, 120)
        if let previousTranslation { XCTAssertNotEqual(result, previousTranslation, "Regeneration must save the new validated result.") }
        for _ in 0..<20 { if app.buttons["report-translation-language"].isHittable { break }; app.swipeDown() }
        capture(app, "autonomous-translation-reader")
        app.terminate()
        let relaunched = try openExistingPrincipal(destination: "deepResearch")
        try openNativeTranslation(relaunched, title: title)
        let persisted = relaunched.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Francoist")).firstMatch
        XCTAssertTrue(persisted.waitForExistence(timeout: 30), relaunched.debugDescription)
        XCTAssertEqual(persisted.label, result, "Reopening must retain the exact generated translation.")
        capture(relaunched, "autonomous-translation-saved-reopened")
    }
    @MainActor private func openNativeTranslation(_ app: XCUIApplication, title: String) throws {
        let search = app.textFields["nodus-search-field"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 35), app.debugDescription)
        search.tap(); search.typeText(String(title.prefix(42)) + "\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 15), "Submitting the native search must dismiss the keyboard.")
        let report = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<6 { if report.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(report.isHittable); report.tap()
        let translations = app.buttons["report-tool-translations"].firstMatch
        XCTAssertTrue(translations.waitForExistence(timeout: 30), app.debugDescription)
        let ready = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: translations)], timeout: 30), .completed)
        translations.tap()
        let language = app.buttons["report-translation-language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15)); language.tap()
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 10), app.debugDescription); english.tap()
    }
    @MainActor private func pairLive(route: String, vaultId: String = "default") throws -> XCUIApplication {
        let link = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_LINK"], "A real HTTPS lab is required.")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            XCTAssertTrue(["light", "dark"].contains(style))
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_ACCEPTANCE_PAIRING_LINK"] = link
        app.launchEnvironment["NODUS_START_ROUTE"] = route
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            XCTAssertTrue(["standard", "accessibility3"].contains(size))
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launch()
        let pair = app.buttons["pairing-confirm"]
        XCTAssertTrue(pair.waitForExistence(timeout: 15))
        capture(app, "pairing-before-confirmation")
        let pairingInput = app.textFields["pairing-link"].exists ? app.textFields["pairing-link"] : app.textViews["pairing-link"]
        // The primary sheet intentionally keeps the advanced link field collapsed.
        // Never request a snapshot of a nonexistent TextView; the parsed code is visible.
        let code = app.textFields["pairing-code"]
        XCTAssertTrue(code.exists)
        XCTAssertEqual((code.value as? String)?.filter { $0.isLetter || $0.isNumber }.count, 10)
        if pairingInput.exists, let displayedLink = pairingInput.value as? String {
            XCTAssertEqual(displayedLink.count, link.count, "The link must reach the app without truncation.")
            XCTAssertTrue(displayedLink == link, "The native link field must preserve the complete payload.")
        }
        XCTAssertTrue(pair.isEnabled, app.staticTexts["pairing-error"].exists ? app.staticTexts["pairing-error"].label : "Pairing is unavailable without a displayed error.")
        pair.tap()
        let principal = app.buttons["space-\(vaultId)"]
        let dismissed = NSPredicate(format: "exists == false")
        let linked = expectation(for: dismissed, evaluatedWith: pair)
        let result = XCTWaiter.wait(for: [linked], timeout: 35)
        capture(app, "pairing-result")
        XCTAssertEqual(result, .completed, app.debugDescription)
        guard result == .completed else { throw NSError(domain: "NodusAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pairing did not complete"]) }
        if principal.exists {
            XCTAssertTrue(principal.isHittable, app.debugDescription); principal.tap()
        } else {
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 20), "Linking must enter the workspace automatically.")
            if vaultId != "default" {
                let switcher = app.buttons["Cambiar de espacio"]
                XCTAssertTrue(switcher.exists); switcher.tap()
                XCTAssertTrue(principal.waitForExistence(timeout: 20)); principal.tap()
            }
        }
        return app
    }
    @MainActor
    func testDownloadedResearchFormatErrorAndRepairNeverClaimEmptyLibrary() throws {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = "research-damaged-snapshot.json"
        app.launch()
        let failure = app.descendants(matching: .any)["deep-research-catalog-error"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["deep-research-catalog-empty"].firstMatch.exists)
        let retry = app.buttons["deep-research-catalog-retry"]
        XCTAssertTrue(retry.isHittable); capture(app, "downloaded-research-format-error")
        let assistant = app.buttons["nodus-top-sparkles"]
        XCTAssertTrue(assistant.isHittable)
        XCTAssertGreaterThanOrEqual(assistant.frame.width, 44)
        XCTAssertGreaterThanOrEqual(assistant.frame.height, 44)
        let heading = app.descendants(matching: .any)["nodus-page-heading"].firstMatch
        XCTAssertTrue(heading.exists)
        XCTAssertGreaterThanOrEqual(app.buttons["deep-research-new"].frame.minY, heading.frame.maxY,
                                    "The action must sit below the heading on phones and at accessibility sizes.")
        retry.tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["deep-research-catalog-empty"].firstMatch.exists)
        capture(app, "downloaded-research-format-retry-preserves-error")
        app.terminate()
        app.launchEnvironment["NODUS_ACCEPTANCE_SNAPSHOT_FILENAME"] = "research-repaired-snapshot.json"
        app.launch()
        let report = app.staticTexts["Informe reparado de aceptación"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(failure.exists)
        XCTAssertFalse(app.descendants(matching: .any)["deep-research-catalog-empty"].firstMatch.exists)
        for _ in 0..<10 { if report.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(report.isHittable); capture(app, "downloaded-research-repaired-catalogue")
        report.tap()
        let body = app.textViews.matching(NSPredicate(format: "label == %@", "Texto recuperado: la consulta vuelve a mostrar el informe completo tras reparar el registro.")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(body.isHittable, app.debugDescription)
        capture(app, "downloaded-research-repaired-reader")
    }
    @MainActor
    func testPrimaryConnectionUsesCodeAndKeepsAdvancedConnectionsHidden() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] { app.launchArguments += ["-nodus.prefs.interfaceStyle", style] }
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size }
        app.launch()
        let add = app.buttons["nodus-add-server"]
        let switchSpace = app.buttons["Cambiar de espacio"]
        let initial = expectation(for: NSPredicate { _, _ in add.exists || switchSpace.exists }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 20), .completed, app.debugDescription)
        if switchSpace.exists { switchSpace.tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<16 { if add.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(add.isHittable); XCTAssertTrue(add.label.contains("Vincular Nodus")); add.tap()
        let code = app.textFields["pairing-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "The primary connection must open the code directly.")
        let scan = app.buttons["pairing-scan-qr"]
        for _ in 0..<8 { if scan.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(scan.isHittable)
        XCTAssertFalse(app.textFields["nodus-server-address"].exists)
        XCTAssertFalse(app.textFields["Email"].exists)
        let connect = app.buttons["pairing-find-mac"]
        XCTAssertTrue(connect.exists); XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(app.buttons["pairing-confirm"].exists, "The primary flow needs only one connection action.")
        capture(app, "primary-connection-code-and-qr")
        scan.tap()
        let closeScanner = app.buttons["pairing-close-scanner"]
        XCTAssertTrue(closeScanner.waitForExistence(timeout: 15)); XCTAssertTrue(closeScanner.isHittable)
        capture(app, "primary-connection-qr-return-to-code")
        closeScanner.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 15)); XCTAssertFalse(connect.isEnabled)
        for _ in 0..<8 { if code.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(code.isHittable); code.tap(); code.typeText("ABCDE")
        XCTAssertFalse(connect.isEnabled)
        code.typeText("23456"); XCTAssertTrue(connect.isEnabled)
        app.swipeUp()
        let keyboardHidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["pairing-advanced-connection"].exists)
        XCTAssertFalse(app.textFields["nodus-server-address"].exists)
        capture(app, "primary-connection-advanced-connections-hidden")
    }
    @MainActor
    func testLinkMacByTypedCodeWithoutAddressOrFingerprint() throws {
        try linkMacByTypedCode(renewal: false)
    }
    @MainActor
    func testMacCodeLinksWorkspaceAndConsultsExistingReport() throws {
        try linkMacByTypedCode(renewal: false, consultExistingReport: true)
    }
    @MainActor
    func testRenewExistingMacConnectionByDesktopCode() throws {
        try linkMacByTypedCode(renewal: true)
    }
    @MainActor
    func testUnknownDesktopCodeCanBeReplacedAndConnectsWithoutRestart() throws {
        try linkMacByTypedCode(renewal: false, invalidCodeFirst: true)
    }
    @MainActor
    func testAcceptedMacCodeResumesAfterCapabilitiesFailureAndAppRestart() throws {
        try linkMacByTypedCode(renewal: false, capabilitiesFailureFirst: true)
    }
    @MainActor private func linkMacByTypedCode(renewal: Bool, invalidCodeFirst: Bool = false, capabilitiesFailureFirst: Bool = false, consultExistingReport: Bool = false) throws {
        executionTimeAllowance = 300
        let code = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PAIRING_CODE"], "A fresh Mac code is required.")
        XCTAssertNil(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_LINK"], "This test must discover the Mac, not receive an injected link.")
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        if capabilitiesFailureFirst { app.launchEnvironment["NODUS_ACCEPTANCE_FAIL_PAIRING_CAPABILITIES_ONCE"] = "1" }
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launch()
        let addServer = app.buttons["nodus-add-server"]
        let switchSpace = app.buttons["Cambiar de espacio"]
        let restoredReaderClose = app.buttons["nodus-modal-close"]
        if restoredReaderClose.waitForExistence(timeout: 2), restoredReaderClose.isHittable {
            capture(app, "code-link-startup-restored-reader")
            restoredReaderClose.tap()
            XCTAssertTrue(restoredReaderClose.waitForNonExistence(timeout: 10))
        }
        let initial = expectation(for: NSPredicate { _, _ in addServer.exists || switchSpace.exists }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 20), .completed)
        if switchSpace.exists { switchSpace.tap() }
        capture(app, "code-link-workspace-picker")
        XCTAssertTrue(addServer.waitForExistence(timeout: 15), app.debugDescription)
        if renewal {
            XCTAssertTrue(app.buttons["space-default"].waitForExistence(timeout: 15), "Renewal must start with the existing Mac vault, not create its first connection.")
        }
        XCTAssertTrue(addServer.isHittable, "Linking must stay visible without scrolling through every vault.\n" + app.debugDescription)
        XCTAssertTrue(addServer.isHittable); addServer.tap()
        XCTAssertFalse(app.textFields["nodus-server-address"].exists, "Server configuration is not part of the main connection flow.")
        let findMac = app.buttons["pairing-find-mac"]
        XCTAssertTrue(findMac.waitForExistence(timeout: 15)); XCTAssertFalse(findMac.isEnabled)
        let input = app.textFields["pairing-code"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        if invalidCodeFirst {
            input.tap(); input.typeText("1111111111\n") // '1' is excluded from every Desktop-generated code.
            let failure = app.staticTexts["pairing-discovery-error"]
            XCTAssertTrue(failure.waitForExistence(timeout: 25), "An unknown code must produce a visible network/discovery error.")
            XCTAssertTrue(input.isEnabled); XCTAssertTrue(findMac.isEnabled)
            capture(app, "unknown-desktop-code-retry-available")
            input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        } else { input.tap() }
        input.typeText(code)
        XCTAssertTrue(findMac.isEnabled)
        // Submit the code using the form's actual Search key. The iPad sheet
        // moves after typing, so a stale button activation point is unreliable.
        input.typeText("\n")
        if capabilitiesFailureFirst {
            XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 25), "The injected post-pairing network failure must stay visible.")
            XCTAssertTrue(app.staticTexts["pairing-error"].label.contains("Tu solicitud está guardada"), "The recovery message must explain the next action without an internal URL error code.")
            capture(app, "accepted-code-capabilities-failure")
            app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_FAIL_PAIRING_CAPABILITIES_ONCE")
            app.launch()
            let restarted = expectation(for: NSPredicate { _, _ in addServer.exists || switchSpace.exists }, evaluatedWith: app)
            XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 20), .completed)
            if switchSpace.exists { switchSpace.tap() }
            for _ in 0..<16 { if addServer.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(addServer.isHittable); addServer.tap()
            XCTAssertTrue(app.staticTexts["pairing-pending-notice"].waitForExistence(timeout: 15))
            XCTAssertTrue(input.exists)
            XCTAssertEqual((input.value as? String)?.filter { $0.isLetter || $0.isNumber }, code.filter { $0.isLetter || $0.isNumber })
            XCTAssertTrue(findMac.isEnabled)
            capture(app, "accepted-code-pending-after-restart")
            findMac.tap() // Resume the stored attempt; do not type or discover another code.
        }
        let completed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: input)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 45), .completed, app.debugDescription)
        // Both the pairing sheet and the connection sheet must dismiss after linking.
        XCTAssertFalse(app.buttons["nodus-link-mac"].exists)
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 20), "Entering the code must connect and enter the workspace without a second pairing or vault-selection step.")
        XCTAssertTrue(app.webViews.firstMatch.buttons["Nuevo informe"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "pairing-code-linked-research-loaded")
        if consultExistingReport {
            try verifyExistingResearchReport(app)
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 30))
            XCTAssertTrue(app.webViews.firstMatch.buttons["Nuevo informe"].waitForExistence(timeout: 60))
            XCTAssertFalse(app.textFields["pairing-code"].exists, "The linked workspace must reopen without another code.")
            capture(app, "pairing-code-workspace-restored-after-process-restart")
            return
        }
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let body = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 120, expectedBody: body)
        if renewal {
            let settings = app.buttons["nodus-nav-settings"].firstMatch
            if !settings.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
            for _ in 0..<12 { if settings.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(settings.isHittable); settings.tap()
            let mode = app.buttons["ai-execution-mode"].firstMatch
            for _ in 0..<12 { if mode.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(mode.isHittable); XCTAssertTrue(mode.label.contains("Live · modelos del Mac"))
            capture(app, "desktop-code-renewal-mode-after-restart")
        }
    }
    @MainActor
    func testLiveDeepResearchComposerAndMacModels() throws {
        let app = try liveDeepResearchComposerSelectingMacModel()
        defer { app.terminate() }
    }
    @MainActor private func liveDeepResearchComposerSelectingMacModel() throws -> XCUIApplication {
        let app = try openExistingPrincipal(destination: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        let live = app.buttons["Live · modelos del Mac"]
        XCTAssertTrue(live.waitForExistence(timeout: 10)); live.tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let research = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if research.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(research.isHittable); research.tap()
        let web = app.otherElements["shared-desktop-deepResearch"].webViews.firstMatch
        let newReport = web.buttons["Nuevo informe"].firstMatch
        XCTAssertTrue(newReport.waitForExistence(timeout: 60))
        let loaded = NSPredicate { _, _ in
            !web.staticTexts["Cargando informes…"].exists &&
                web.buttons["Descargar"].firstMatch.isEnabled
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 60), .completed, "The real saved report catalogue must finish loading before composing another report.")
        XCTAssertTrue(newReport.isHittable && web.frame.contains(newReport.frame))
        capture(app, "live-deep-research-new-report-before-touch")
        // WebKit supplied a stale activation point on iPad (inside Download),
        // despite the correct accessibility frame. Touch the observed button's
        // centre in the application's coordinate space and still require the editor.
        let reportFrame = newReport.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: reportFrame.midX, dy: reportFrame.midY)).tap()
        capture(app, "live-deep-research-composer-open-action")
        let objective = web.textViews.firstMatch
        XCTAssertTrue(objective.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "live-deep-research-composer")
        let model = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Modelo:")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 20), app.debugDescription)
        let usableBounds = web.frame.insetBy(dx: 12, dy: 110)
        for _ in 0..<8 {
            let center = CGPoint(x: model.frame.midX, y: model.frame.midY)
            if model.isHittable && usableBounds.contains(center) { break }
            web.swipeUp()
        }
        XCTAssertTrue(model.isHittable && usableBounds.contains(CGPoint(x: model.frame.midX, y: model.frame.midY)), app.debugDescription)
        capture(app, "live-deep-research-model-control-visible")
        model.tap()
        capture(app, "live-deep-research-model-menu-after-tap")
        let options = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Modelo")).firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "live-deep-research-mac-model-options")
        let modelSearch = web.searchFields["Buscar modelo…"].firstMatch
        XCTAssertTrue(modelSearch.waitForExistence(timeout: 10), app.debugDescription)
        modelSearch.tap(); modelSearch.typeText("DeepSeek")
        let deepseek = options.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "DeepSeek · deepseek-flash")).firstMatch
        XCTAssertTrue(deepseek.waitForExistence(timeout: 20), app.debugDescription)
        guard deepseek.exists && deepseek.isHittable else { throw NSError(domain: "NodusAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "The configured Mac model is unavailable for touch selection."]) }
        capture(app, "live-deep-research-mac-model-filtered")
        deepseek.tap()
        let selected = web.otherElements.matching(NSPredicate(format: "label == %@", "Modelo: DeepSeek · deepseek-flash")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "live-deep-research-mac-model-selected")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        return app
    }
    @MainActor private func revealResearchControl(_ element: XCUIElement, in web: XCUIElement, upwards: Bool = true) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        for _ in 0..<12 {
            let dialog = web.otherElements["Nuevo informe, cuadro de diálogo de web"].firstMatch
            let container = dialog.exists ? dialog : web
            let visible = container.frame.insetBy(dx: 10, dy: dialog.exists ? 110 : 70)
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            if element.isHittable && visible.contains(center) { return }
            let moveUp = center.y > visible.maxY || (visible.contains(center) && upwards)
            let from = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveUp ? 0.6 : 0.4))
            let to = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveUp ? 0.4 : 0.6))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTFail("The research control is outside the visible touch area: \(element.debugDescription)")
        throw NSError(domain: "NodusAcceptance", code: 3, userInfo: [NSLocalizedDescriptionKey: "Research control not reachable."])
    }
    @MainActor
    func testLiveDeepResearchGeneratesPersistsAndReopens() throws {
        executionTimeAllowance = 3600
        let app = try liveDeepResearchComposerSelectingMacModel()
        let web = app.webViews.firstMatch
        let marker = "NodusQA-" + UUID().uuidString
        let identity = XCTAttachment(string: marker); identity.name = "live-research-generation-marker"; identity.lifetime = .keepAlways; add(identity)
        let objective = web.textViews.firstMatch
        try revealResearchControl(objective, in: web, upwards: false)
        capture(app, "live-research-generation-objective-visible")
        objective.tap()
        capture(app, "live-research-generation-objective-focused")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        objective.typeText("\(marker). Explica cómo la propaganda turística del franquismo representó la autenticidad y el exotismo de España. Fundamenta la respuesta en las fuentes del corpus y conserva sus citas.")
        try dismissResearchKeyboard(app)
        let sections = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "ESTRUCTURA DEL INFORME")).firstMatch
        try revealResearchControl(sections, in: web); sections.tap()
        let single = app.buttons["Bloque único · sin secciones"].firstMatch
        XCTAssertTrue(single.waitForExistence(timeout: 15), app.debugDescription); single.tap()
        XCTAssertTrue((sections.value as? String)?.contains("Bloque único") == true, app.debugDescription)
        let length = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "EXTENSIÓN ORIENTATIVA DE CADA SECCIÓN")).firstMatch
        try revealResearchControl(length, in: web); length.tap()
        let custom = app.buttons["Personalizada"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 15), app.debugDescription); custom.tap()
        let words = web.textFields["Palabras por sección"].firstMatch
        try revealResearchControl(words, in: web); words.tap(); words.typeText("500")
        XCTAssertEqual(words.value as? String, "500")
        try dismissResearchKeyboard(app)
        let enqueue = web.buttons["Añadir a la cola"].firstMatch
        for _ in 0..<8 { if enqueue.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(enqueue.isHittable && enqueue.isEnabled, app.debugDescription)
        capture(app, "live-research-generation-configured"); enqueue.tap()
        let queued = web.staticTexts.matching(NSPredicate(format: "label == %@", "Informe añadido a la cola. Se generará en segundo plano.")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "live-research-generation-queued")
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 2400)
    }
    @MainActor
    func testLiveDeepResearchExistingJobFinishesAndReopens() throws {
        executionTimeAllowance = 1800
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKER"], "The marker of an existing native request is required; this test must not submit another report.")
        XCTAssertTrue(marker.hasPrefix("NodusQA-"))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        if let style = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchArguments += ["-nodus.prefs.interfaceStyle", style]
        }
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        if let size = ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] {
            app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = size
        }
        app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 10) { principal.tap() }
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        capture(app, "live-research-existing-request-resumed")
        let expectedBody = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"], "The existing-job check requires a paragraph from the persisted report.")
        XCTAssertGreaterThanOrEqual(expectedBody.count, 40)
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 1200, expectedBody: expectedBody)
    }
    @MainActor
    func testLiveDeepResearchSavedGeneratedReportAfterPairing() throws {
        executionTimeAllowance = 600
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let expectedBody = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        XCTAssertGreaterThanOrEqual(expectedBody.count, 40)
        let app = try pairLive(route: "deepResearch")
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 60, expectedBody: expectedBody)
    }
    @MainActor
    func testLiveRenewConnectionPreservesReportAndModeAfterRestart() throws {
        executionTimeAllowance = 600
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let body = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"].firstMatch
        for _ in 0..<10 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); XCTAssertTrue(mode.isHittable); mode.tap()
        let live = app.buttons["Live · modelos del Mac"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10)); live.tap()
        let renewal = app.buttons["renew-mac-connection"].firstMatch
        for _ in 0..<12 { if renewal.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(renewal.isHittable); XCTAssertTrue(renewal.isEnabled)
        XCTAssertGreaterThanOrEqual(renewal.frame.height, 44)
        capture(app, "live-connection-before-renewal")
        renewal.tap()
        let result = app.staticTexts["mac-connection-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 35))
        XCTAssertEqual(result.label, "Conexión renovada. Se conservan las copias, los borradores y las solicitudes.")
        XCTAssertTrue(renewal.isEnabled)
        capture(app, "live-connection-renewed")
        let research = app.buttons["nodus-nav-deepResearch"].firstMatch
        if !research.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
        for _ in 0..<8 { if research.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(research.isHittable); research.tap()
        XCTAssertTrue(app.descendants(matching: .any)["shared-desktop-deepResearch"].waitForExistence(timeout: 30))
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 60, expectedBody: body)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "live-connection-renewed-report-after-restart")
        let settings = app.buttons["nodus-nav-settings"].firstMatch
        if !settings.isHittable { app.buttons["nodus-navigation-toggle"].tap() }
        for _ in 0..<12 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable); settings.tap()
        let restoredMode = app.buttons["ai-execution-mode"].firstMatch
        for _ in 0..<12 { if restoredMode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(restoredMode.isHittable)
        capture(app, "live-connection-renewed-mode-after-restart")
        XCTAssertTrue(restoredMode.label.contains("Live · modelos del Mac"), "The native Picker exposes its selected mode in its label. Renewal and restart must not switch execution mode.")
    }
    @MainActor
    func testLiveMacRevocationCanCancelThenRemovesLinkedVaults() throws {
        executionTimeAllowance = 600
        let app = try pairLive(route: "settings")
        let settings = app.descendants(matching: .any)["settings-workspace"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        let revoke = app.buttons["revoke-mac-connection"].firstMatch
        for _ in 0..<12 { if revoke.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(revoke.waitForExistence(timeout: 20))
        XCTAssertTrue(revoke.isHittable); revoke.tap()
        let cancel = app.buttons["Cancelar"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(revoke.isHittable); XCTAssertTrue(revoke.isEnabled)
        capture(app, "live-connection-revocation-cancelled")
        revoke.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Revocar conexión con el Mac", "revoke-mac-connection")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); XCTAssertTrue(confirm.isHittable)
        capture(app, "live-connection-revocation-confirmation"); confirm.tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 35), .completed)
        XCTAssertFalse(app.buttons["space-default"].exists, "All vaults of the revoked grant must leave the connection chooser.")
        capture(app, "live-connection-revoked")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK"); app.launch()
        let destination = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["nodus-add-server", "nodus-navigation-toggle"])).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 20), "After revocation the app must open the chooser or an unrelated remaining space.")
        XCTAssertFalse(app.buttons["space-default"].exists)
        XCTAssertFalse(app.buttons["revoke-mac-connection"].exists)
        capture(app, "live-connection-revoked-after-restart")
    }
    @MainActor
    func testLiveResearchReaderFullTitleAndAccessibleOptions() throws {
        executionTimeAllowance = 600
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let expectedBody = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        let expectedTitle = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_TITLE"])
        let expectedMarkdownHash = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_RESEARCH_MARKDOWN_SHA256"])
        let app = try pairLive(route: "deepResearch")
        try verifyGeneratedResearchReport(app, marker: marker, timeout: 60, expectedBody: expectedBody)
        let web = app.webViews.firstMatch
        let title = web.buttons["Ver título completo"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15)); XCTAssertTrue(title.isHittable)
        capture(app, "live-reader-compact-header")
        title.tap()
        let dialog = web.otherElements["Título del informe, cuadro de diálogo de web"].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), app.debugDescription)
        let completeTitle = dialog.staticTexts.matching(NSPredicate(format: "label == %@", expectedTitle)).firstMatch
        XCTAssertTrue(completeTitle.waitForExistence(timeout: 10)); XCTAssertEqual(completeTitle.label, expectedTitle)
        XCTAssertTrue(completeTitle.isHittable)
        capture(app, "live-reader-full-title")
        dialog.swipeUp()
        capture(app, "live-reader-full-title-end")
        let close = dialog.buttons["Cerrar"].firstMatch
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertFalse(dialog.exists)
        let metadata = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Datos del informe")).firstMatch
        XCTAssertTrue(metadata.isHittable); metadata.tap()
        XCTAssertTrue(web.staticTexts["DeepSeek · deepseek-flash"].exists)
        capture(app, "live-reader-metadata-expanded")
        metadata.tap()
        let options = web.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Opciones del informe")).firstMatch
        XCTAssertTrue(options.isHittable); options.tap()
        let copy = web.buttons["Copiar"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10)); XCTAssertTrue(copy.isHittable)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        copy.tap()
        XCTAssertTrue(web.staticTexts["Borrador copiado."].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["nodus-top-sparkles"].tap()
        let chat = app.descendants(matching: .any)["shared-desktop-chat"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        let composer = chat.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20)); XCTAssertTrue(composer.isHittable)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        composer.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "Pegar", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), app.debugDescription); paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = composer.value as? String else { return false }
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() == expectedMarkdownHash
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 15), .completed,
                       "Pasting through iOS must retain the complete saved Markdown.\n\(app.debugDescription)")
        let copied = try XCTUnwrap(composer.value as? String)
        XCTAssertEqual(SHA256.hash(data: Data(copied.utf8)).map { String(format: "%02x", $0) }.joined(), expectedMarkdownHash,
                       "Copy must retain the complete Markdown saved on the Mac.")
        capture(app, "live-reader-copy-pasted-without-sending")
        app.buttons["nodus-chat-dismiss"].tap()
        XCTAssertFalse(chat.exists)
        let lastAction = web.buttons["Lectura a pantalla completa"].firstMatch
        XCTAssertTrue(lastAction.exists)
        for _ in 0..<12 {
            if lastAction.isHittable { break }
            let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.36))
            let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.12))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertTrue(lastAction.isHittable, app.debugDescription)
        capture(app, "live-reader-all-options-reachable")
        lastAction.tap()
        XCTAssertTrue(web.buttons["Salir de pantalla completa"].waitForExistence(timeout: 10))
        let navigation = app.buttons["nodus-navigation-toggle"].firstMatch
        let chromeHidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !navigation.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chromeHidden], timeout: 10), .completed,
                       "Fullscreen reading must remove the native top bar and sidebar.")
        capture(app, "live-reader-fullscreen-from-options")
        web.buttons["Salir de pantalla completa"].tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 10)); XCTAssertTrue(navigation.isHittable)
        XCTAssertTrue(app.buttons["nodus-top-sparkles"].isHittable)
        capture(app, "live-reader-navigation-restored")
    }
    @MainActor
    func testLiveDeepResearchCancelFromVisibleQueue() throws {
        executionTimeAllowance = 600
        let app = try liveDeepResearchComposerSelectingMacModel()
        let web = app.webViews.firstMatch
        let marker = "NodusQA-" + UUID().uuidString
        let identity = XCTAttachment(string: marker); identity.name = "live-research-cancellation-marker"; identity.lifetime = .keepAlways; add(identity)
        let objective = web.textViews.firstMatch
        try revealResearchControl(objective, in: web, upwards: false)
        objective.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        objective.typeText("\(marker). Explica cómo la propaganda turística del franquismo representó la autenticidad y el exotismo de España, distinguiendo la intención política, la función cultural y las evidencias conservadas en este corpus.")
        try dismissResearchKeyboard(app)
        let enqueue = web.buttons["Añadir a la cola"].firstMatch
        for _ in 0..<8 { if enqueue.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(enqueue.isHittable && enqueue.isEnabled); enqueue.tap()
        let planning = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Planificando")).firstMatch
        XCTAssertTrue(planning.waitForExistence(timeout: 180), "The real Mac job must reach its planning phase.")
        let cancel = web.buttons["Quitar de la cola"].firstMatch
        try revealResearchControl(cancel, in: web, upwards: false)
        capture(app, "live-research-queue-before-percentage-check")
        let percent = web.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{1,2}%")).firstMatch
        XCTAssertTrue(percent.waitForExistence(timeout: 10))
        XCTAssertTrue(percent.isHittable && planning.isHittable && cancel.isHittable, app.debugDescription)
        XCTAssertTrue(web.frame.contains(percent.frame) && web.frame.contains(cancel.frame), "The complete percentage and cancel control must fit in the mobile viewport.")
        capture(app, "live-research-visible-queue-before-cancellation")
        cancel.tap()
        let confirm = web.buttons["Eliminar"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(confirm.isHittable)
        capture(app, "live-research-queue-cancellation-confirmation")
        confirm.tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 60), .completed)
        XCTAssertTrue(web.staticTexts["Generación cancelada."].waitForExistence(timeout: 15))
        XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CancellationError")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "live-research-queue-cancelled")
    }
    @MainActor private func dismissResearchKeyboard(_ app: XCUIApplication) throws {
        let done = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "OK", "Ocultar teclado")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The actual device keyboard must expose its dismiss control.")
        XCTAssertTrue(done.isHittable); done.tap()
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 15), .completed)
    }
    @MainActor private func researchSearch(in web: XCUIElement) -> XCUIElement {
        web.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d",
            Int(XCUIElement.ElementType.searchField.rawValue), Int(XCUIElement.ElementType.textField.rawValue))).firstMatch
    }
    @MainActor private func focusResearchSearch(_ field: XCUIElement, in web: XCUIElement, app: XCUIApplication) throws {
        try revealResearchControl(field, in: web, upwards: false)
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            // WK's accessibility activation point can lag behind the queue strip's
            // initial layout. Observe the unfocused screen, then use its current bounds.
            capture(app, "live-research-search-without-keyboard")
            try revealResearchControl(field, in: web, upwards: false)
            XCTAssertTrue(web.frame.contains(field.frame), app.debugDescription)
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "Search must open its actual keyboard before typing.\n\(app.debugDescription)")
    }
    @MainActor private func verifyGeneratedResearchReport(_ app: XCUIApplication, marker: String, timeout: TimeInterval, expectedBody: String? = nil) throws {
        let web = app.webViews.firstMatch
        let existingReader = web.buttons["Volver a la galería"].firstMatch
        if existingReader.waitForExistence(timeout: 5) { existingReader.tap() }
        let search = researchSearch(in: web)
        try focusResearchSearch(search, in: web, app: app)
        if let previous = search.value as? String, previous.contains("NodusQA-") {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        search.typeText(marker)
        try dismissResearchKeyboard(app)
        let read = web.buttons["Leer"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: timeout), "The uniquely requested report must become available in the gallery.\n\(app.debugDescription)")
        for _ in 0..<12 { if read.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(read.isHittable, app.debugDescription)
        capture(app, "live-research-generation-saved-catalogue"); read.tap()
        let reader = web.buttons["Volver a la galería"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 25), app.debugDescription)
        let bodyCandidates = expectedBody.map { web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", $0)) } ?? web.staticTexts
        XCTAssertTrue(bodyCandidates.firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        let body = try XCTUnwrap(bodyCandidates.allElementsBoundByIndex.first(where: { $0.label.count > 200 && !$0.label.contains(marker) }), "The generated reader must contain a substantive paragraph distinct from its title.")
        let persistedParagraph = body.label
        capture(app, "live-research-reader-before-paragraph-reveal")
        for _ in 0..<12 {
            if body.isHittable { break }
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.88))
                .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        }
        XCTAssertTrue(body.isHittable, app.debugDescription)
        capture(app, "live-research-generation-reader")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK")
        app.launchEnvironment["NODUS_START_ROUTE"] = "deepResearch"
        app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60))
        let restoredWeb = app.webViews.firstMatch
        let back = restoredWeb.buttons["Volver a la galería"].firstMatch
        if back.waitForExistence(timeout: 8) { back.tap() }
        let restoredSearch = researchSearch(in: restoredWeb)
        try focusResearchSearch(restoredSearch, in: restoredWeb, app: app)
        if let previous = restoredSearch.value as? String, previous.contains("NodusQA-") {
            restoredSearch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        restoredSearch.typeText(marker)
        try dismissResearchKeyboard(app)
        let reopened = restoredWeb.buttons["Leer"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<12 { if reopened.isHittable { break }; restoredWeb.swipeUp() }
        XCTAssertTrue(reopened.isHittable); reopened.tap()
        XCTAssertTrue(restoredWeb.buttons["Volver a la galería"].waitForExistence(timeout: 25))
        let reopenedBody = restoredWeb.staticTexts.matching(NSPredicate(format: "label == %@", persistedParagraph)).firstMatch
        XCTAssertTrue(reopenedBody.waitForExistence(timeout: 25), "The reopened report must retain the exact substantive paragraph.")
        for _ in 0..<12 {
            if reopenedBody.isHittable { break }
            restoredWeb.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.88))
                .press(forDuration: 0.05, thenDragTo: restoredWeb.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        }
        XCTAssertTrue(reopenedBody.isHittable, app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "live-research-generation-reopened")
    }
    @MainActor
    func testLivePairingAndSavedReportsFromMac() throws {
        let app = try pairLive(route: "settings")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20), app.debugDescription)
        mode.tap()
        let live = app.buttons["Live · modelos del Mac"]
        XCTAssertTrue(live.waitForExistence(timeout: 10), app.debugDescription)
        live.tap()
        capture(app, "live-mac-mode-selected")
        app.buttons["nodus-navigation-toggle"].tap()
        let research = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if research.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(research.isHittable, app.debugDescription)
        research.tap()
        try verifyExistingResearchReport(app)
    }
    @MainActor private func verifyExistingResearchReport(_ app: XCUIApplication) throws {
        let reports = app.descendants(matching: .any)["shared-desktop-deepResearch"]
        XCTAssertTrue(reports.waitForExistence(timeout: 60), app.debugDescription)
        let web = reports.webViews.firstMatch
        let search = researchSearch(in: web)
        let searchable = search.waitForExistence(timeout: 30)
        capture(app, "live-deep-research-mounted")
        XCTAssertTrue(searchable, app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
        try focusResearchSearch(search, in: web, app: app)
        search.typeText("La mirada extranjera")
        try dismissResearchKeyboard(app)
        let report = web.buttons.containing(NSPredicate(format: "label CONTAINS %@", "La mirada extranjera sobre la España franquista")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 90), app.debugDescription)
        try revealResearchControl(report, in: web, upwards: true)
        capture(app, "live-deep-research-catalogue")
        report.tap()
        let reader = app.scrollViews["report-native-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30), app.debugDescription)
        let translations = app.buttons["report-tool-translations"]
        let loaded = NSPredicate(format: "exists == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: translations)], timeout: 30), .completed)
        let paragraph = reader.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Este informe analiza")).firstMatch
        for _ in 0..<12 { if paragraph.exists && paragraph.isHittable { break }; reader.swipeUp() }
        XCTAssertTrue(paragraph.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(paragraph.isHittable, app.debugDescription)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            for _ in 0..<12 { if paragraph.isHittable { break }; reader.swipeUp() }
            XCTAssertGreaterThanOrEqual(paragraph.frame.minX, reader.frame.minX - 1)
            XCTAssertLessThanOrEqual(paragraph.frame.maxX, reader.frame.maxX + 1)
            capture(app, orientation == .portrait ? "live-deep-research-native-reader-portrait" : "live-deep-research-native-reader-landscape")
        }
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "does not grant access")).firstMatch.exists)
    }
    @MainActor private func launch(_ route: String, style: String? = nil, textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // Start with an awake foreground screen. A physical device left in an idle
        // transition can expose a scaled AX tree while its display is still black.
        XCUIDevice.shared.press(.home)
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_UI_TEST_DEMO"] = "1"
        app.launchEnvironment["NODUS_START_ROUTE"] = route
        app.launchEnvironment["NODUS_VAULT_TYPE_OVERRIDE"] = "academic"
        if let textSize { app.launchEnvironment["NODUS_ACCEPTANCE_DYNAMIC_TYPE"] = textSize }
        if let style = style ?? ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_INTERFACE_STYLE"] {
            app.launchEnvironment["NODUS_INTERFACE_STYLE"] = style
        }
        app.launch()
        app.activate()
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(name)-accessibility"; tree.lifetime = .keepAlways; add(tree)
        // Read AX before capturing the main window, so both evidence items are
        // bound to this app. Whole-screen snapshots were sometimes blank or cropped.
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let appScreenshot = XCTAttachment(screenshot: app.screenshot()); appScreenshot.name = "\(name)-app-comparison"; appScreenshot.lifetime = .keepAlways; add(appScreenshot)
    }
}
