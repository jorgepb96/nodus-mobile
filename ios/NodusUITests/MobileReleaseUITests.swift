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
        let web = app.otherElements["shared-desktop-chat"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30), app.debugDescription)
        let input = web.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "operation_forbidden")).firstMatch.exists)
        let draft = "Pregunta de prueba sin enviar\nSegunda línea"
        XCTAssertTrue(input.isHittable); input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft, "Return must insert a line break without sending a live request.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Typing must not dismiss the iPhone keyboard.")
        capture(app, "phone-chat-keyboard-multiline-draft")
        let history = web.buttons["Historial de chats"].firstMatch
        XCTAssertTrue(history.isHittable); history.tap()
        let dialog = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Historial de chats,")).firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(dialog.buttons["Cerrar"].isHittable)
        XCTAssertGreaterThanOrEqual(dialog.frame.width, web.frame.width - 2)
        capture(app, "phone-chat-separate-history")
        dialog.buttons["Cerrar"].tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, draft)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            XCTAssertTrue(input.isHittable); input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(input.value as? String, draft)
            XCTAssertTrue(history.isHittable)
            let webSearch = web.switches["Búsqueda web"].firstMatch
            let effort = web.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Esfuerzo de thinking:")).firstMatch
            for control in [input, history, web.buttons["Enviar"].firstMatch, webSearch, effort] {
                XCTAssertTrue(control.exists, app.debugDescription)
                XCTAssertTrue(control.isHittable, "Every composer control must remain reachable above the keyboard.")
                XCTAssertGreaterThanOrEqual(control.frame.minY, web.frame.minY - 1)
                XCTAssertLessThanOrEqual(control.frame.maxY, web.frame.maxY + 1, "A partly clipped control must not count as mobile-friendly.\n\(app.debugDescription)")
            }
            XCTAssertFalse(web.staticTexts["para enviar"].exists, "Desktop keyboard instructions do not belong on the iPhone.")
            capture(app, orientation == .portrait ? "phone-chat-keyboard-portrait" : "phone-chat-keyboard-landscape")
        }
    }
    @MainActor private func openExistingPrincipal(destination: String) throws -> XCUIApplication {
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
        let principal = app.buttons["space-default"]
        XCTAssertTrue(principal.waitForExistence(timeout: 20), "The previously linked workspace must be available.")
        for _ in 0..<8 { if principal.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(principal.isHittable); principal.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 45))
        if app.windows.firstMatch.frame.width < 600 { navigation.tap() }
        let route = app.buttons["nodus-nav-" + destination]
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        for _ in 0..<8 { if route.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(route.isHittable); route.tap()
        return app
    }
    @MainActor
    func testExistingMacPhoneReaderUsesOneSelectionRibbon() throws {
        let env = ProcessInfo.processInfo.environment
        let marker = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_MARKER"])
        let snippet = try XCTUnwrap(env["NODUS_ACCEPTANCE_RESEARCH_BODY_SNIPPET"])
        let app = try openExistingPrincipal(destination: "deepResearch")
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let web = app.otherElements["shared-desktop-deepResearch"].webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35), app.debugDescription)
        let back = web.buttons["Volver a la galería"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap() }
        let search = web.textFields.firstMatch
        try focusResearchSearch(search, in: web, app: app)
        if let value = search.value as? String, value.contains("NodusQA-") {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        search.typeText(marker); try dismissResearchKeyboard(app)
        let read = web.buttons["Leer"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 45), app.debugDescription)
        try revealResearchControl(read, in: web, upwards: true); read.tap()
        let body = web.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", snippet)).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 25), app.debugDescription)
        try revealResearchControl(body, in: web, upwards: true)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "does not grant access")).firstMatch.exists)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            try revealResearchControl(body, in: web, upwards: true)
            XCTAssertGreaterThanOrEqual(body.frame.minX, web.frame.minX - 1)
            XCTAssertLessThanOrEqual(body.frame.maxX, web.frame.maxX + 1, "Reading text must fit the iPhone's width.")
            capture(app, orientation == .portrait ? "phone-reader-portrait" : "phone-reader-landscape")
        }
        XCUIDevice.shared.orientation = .portrait
        try revealResearchControl(body, in: web, upwards: true)
        body.press(forDuration: 1.2)
        let copy = web.buttons["Copiar"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Selecting a word must present the Nodus ribbon.\n\(app.debugDescription)")
        for label in ["Subrayar 1", "Subrayar 2", "Subrayar 3", "Subrayar 4", "Subrayar 5", "Subrayar 6", "Copiar", "Añadir comentario", "Citar en Nodi"] {
            let action = web.buttons[label].firstMatch
            XCTAssertTrue(action.exists, label)
            XCTAssertTrue(action.isHittable, "The unified ribbon must fit the phone: " + label)
            XCTAssertGreaterThanOrEqual(action.frame.minX, web.frame.minX - 1)
            XCTAssertLessThanOrEqual(action.frame.maxX, web.frame.maxX + 1)
        }
        XCTAssertFalse(app.menuItems["Copiar"].exists)
        XCTAssertFalse(app.menuItems["Copy"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Copiar")).count,
                       web.buttons.matching(NSPredicate(format: "label == %@", "Copiar")).count,
                       "There must not be a second native Copy action outside the Nodus ribbon.")
        capture(app, "phone-reader-unified-selection")
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
            let stage = web.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Canvas de ideas.")).firstMatch
            let visible = labels.allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertGreaterThanOrEqual(visible.count, 2, "A native graph pinch needs two visible idea captions to measure its scale.")
            let a = web.buttons[visible[0].label].firstMatch
            let b = web.buttons[visible[1].label].firstMatch
            let distance = hypot(a.frame.midX - b.frame.midX, a.frame.midY - b.frame.midY)
            XCTAssertGreaterThan(distance, 20)
            stage.pinch(withScale: 1.2, velocity: 1)
            let enlarged = NSPredicate { _, _ in
                guard a.exists, b.exists else { return false }
                return hypot(a.frame.midX - b.frame.midX, a.frame.midY - b.frame.midY) > distance * 1.05
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enlarged, object: nil)], timeout: 10), .completed,
                           "Two native touches must enlarge the actual graph camera, not just the page text.")
            XCTAssertFalse(web.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "cuadro de diálogo de web")).firstMatch.exists,
                           "Pinching the graph must not open an idea dossier.")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 5), .completed)
            capture(app, "phone-graph-after-native-pinch")
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
            XCTAssertGreaterThanOrEqual(sheet.frame.width, web.frame.width - 2, "The phone dossier must fill the width instead of becoming a right sidebar.")
            let evidence = sheet.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Obras que la desarrollan")).firstMatch
            XCTAssertTrue(evidence.waitForExistence(timeout: 30), "The persisted dossier must load beyond its skeleton.\n\(app.debugDescription)")
            XCTAssertTrue(sheet.staticTexts.allElementsBoundByIndex.contains(where: { $0.label.count > 80 }), "The actual statement must load, not just the title.")
            capture(app, "phone-\(name)-idea-\(orientation == .portrait ? "portrait" : "landscape")")
            close.tap()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
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
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: turned, object: nil)], timeout: 15), .completed)
            XCTAssertTrue(idea.isHittable, app.debugDescription)
            capture(app, "ipad-\(name)-before-detail-\(orientation == .portrait ? "portrait" : "landscape")")
            idea.tap()
            let close = web.buttons["Cerrar"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 20), app.debugDescription)
            let works = web.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Obras que la desarrollan")).firstMatch
            XCTAssertTrue(works.waitForExistence(timeout: 30), "The saved dossier must load its evidence on iPad.")
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
        capture(app, "shared-desktop-graph-before-validation")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.staticTexts["shared-surface-error"].label)
        XCTAssertFalse(graph.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "missing")).firstMatch.exists)
        XCTAssertTrue(graph.buttons.firstMatch.waitForExistence(timeout: 20), "The Desktop graph must render its controls, not just an empty WKWebView.")
        // Layout errors arrive after the controls render. Check the actual canvas state.
        let failure = graph.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "calculate the layout", "calcular la distribución")).firstMatch
        XCTAssertFalse(failure.waitForExistence(timeout: 4), failure.label)
        capture(app, "shared-desktop-graph-\(style)")
        let theme = graph.buttons["TEMA · 5 IDEAS Educación y formación del carácter"]
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
        let app = XCUIApplication(); app.launch()
        if app.buttons["Connections"].exists { app.buttons["Connections"].tap() }
        // This test enters the existing connection sheet through its user-facing control.
        let connect = app.buttons["Connect to a server"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        connect.tap()
        let link = app.buttons["Link Nodus"]
        XCTAssertTrue(link.waitForExistence(timeout: 10)); link.tap()
        XCTAssertTrue(app.buttons["Scan QR"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["SHA-256 certificate fingerprint"].exists)
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
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "acceptance-private-audio")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "live-private-audio-preview")
        let play = app.buttons["QLMediaItemViewControllerBarPlayButtonPlayingAccessibilityIdentifier"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), app.debugDescription)
        play.tap()
        let elapsed = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@ AND NOT label CONTAINS %@", "Tiempo transcurrido:", "0 segundos")).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Downloaded audio must actually play and advance its timeline.\n\(app.debugDescription)")
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
        let app = try pairLive(route: "settings")
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
        let web = app.webViews.firstMatch
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
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"; app.launch()
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
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let dictionary = app.buttons["nodus-nav-dictionary"]
        for _ in 0..<6 { if dictionary.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(dictionary.isHittable); dictionary.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 35))
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30)); search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "The dictionary input must open the keyboard on touch.\n\(app.debugDescription)")
        search.typeText("\(name)\n")
        let entry = web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription); entry.tap()
        openDictionaryEntryOptions(in: web)
        let generate = web.buttons["Generar"]
        XCTAssertTrue(generate.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "autonomous-dictionary-before-generation"); generate.tap()
        let regenerate = web.buttons["Regenerar"]
        let completed = NSPredicate { _, _ in
            let status = app.staticTexts["autonomous-job-status"]
            return regenerate.exists || (status.exists && status.label.contains("Error")) || web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "requiere un proveedor web")).firstMatch.exists
                || web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "La generación no pudo completarse")).firstMatch.exists
        }
        let completion = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: app)], timeout: 600)
        capture(app, "autonomous-dictionary-after-generation-request")
        XCTAssertEqual(completion, .completed, app.debugDescription)
        XCTAssertTrue(regenerate.exists, "A phone-owned generation must finish and become the current persisted version.\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        capture(app, "autonomous-dictionary-generated")
        web.buttons["Versiones"].tap()
        XCTAssertTrue(web.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Versión ·")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "autonomous-dictionary-generated-version")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "NODUS_ACCEPTANCE_PAIRING_LINK")
        app.launchEnvironment["NODUS_START_ROUTE"] = "dictionary"; app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        let reopened = app.webViews.firstMatch
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
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let immersion = app.buttons["nodus-nav-immersion"]
        for _ in 0..<6 { if immersion.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(immersion.isHittable); immersion.tap()
        let web = app.webViews.firstMatch
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
        app.launchEnvironment["NODUS_START_ROUTE"] = "immersion"; app.launch()
        let principal = app.buttons["space-default"]
        if principal.waitForExistence(timeout: 5) { principal.tap() }
        let reopened = app.webViews.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 35))
        let search = reopened.textFields["Buscar entre tus inmersiones…"]
        XCTAssertTrue(search.waitForExistence(timeout: 25)); search.tap(); search.typeText("propaganda turística\n")
        let resume = reopened.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Continuar")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), app.debugDescription); resume.tap()
        XCTAssertTrue(reopened.buttons["Salir"].waitForExistence(timeout: 25))
        capture(app, "autonomous-immersion-resumed-after-restart")
    }
    @MainActor
    func testLiveScriptorReadsDesktopEditAndReopens() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_SCRIPTOR_MARKER"], "A marker written through the real Desktop editor is required.")
        let app = try pairLive(route: "workspace")
        let web = app.webViews.firstMatch
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
        let reopened = app.webViews.firstMatch
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
        let app = try pairLive(route: "workspace")
        let web = app.webViews.firstMatch
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
        capture(app, "live-scriptor-before-edit")
        let paragraph = web.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Párrafo escrito en el Mac para comprobar la edición móvil.")).firstMatch
        XCTAssertTrue(paragraph.exists, app.debugDescription)
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
        let reopened = app.webViews.firstMatch
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
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let scriptor = app.buttons["nodus-nav-workspace"]
        for _ in 0..<7 { if scriptor.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(scriptor.isHittable, app.debugDescription); scriptor.tap()
        let web = app.webViews.firstMatch
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
        let reopened = app.webViews.firstMatch
        let catalogue = reopened.buttons["Abrir Aceptación asistencia autónoma 0.1.0"]
        if catalogue.waitForExistence(timeout: 10) { catalogue.tap() }
        let persisted = reopened.textViews["Editor del documento"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 30), app.debugDescription)
        let actual = persisted.value as? String ?? persisted.label
        XCTAssertEqual(actual, saved, "Reopening must preserve the exact generated document.")
        capture(app, "autonomous-writing-reopened")
    }
    @MainActor
    func testAutonomousReportTranslationUsesPhoneAndReopens() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_TRANSLATION_REPORT_TITLE"], "An actual saved lab report is required.")
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        app.buttons["Autónomo · este dispositivo"].tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let reports = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if reports.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reports.isHittable); reports.tap()
        let web = app.webViews.firstMatch
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 35)); search.tap(); search.typeText(String(title.prefix(42)) + "\n")
        let report = web.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 60), app.debugDescription)
        for _ in 0..<5 { if report.isHittable { break }; web.swipeUp() }; report.tap()
        let translate = web.buttons["Traducir"]
        XCTAssertTrue(translate.waitForExistence(timeout: 25), app.debugDescription)
        for _ in 0..<5 { if translate.isHittable { break }; web.swipeLeft() }; translate.tap()
        let generate = web.buttons["Generar traducción"]
        XCTAssertTrue(generate.waitForExistence(timeout: 15), app.debugDescription)
        let english = web.buttons["Leer traducción a English"]
        capture(app, "autonomous-translation-before-generation")
        let regenerate = web.buttons["Regenerar traducción a English"]
        if regenerate.exists { regenerate.tap() } else { generate.tap() }
        let pending = expectation(for: NSPredicate(format: "exists == true AND enabled == false"), evaluatedWith: english)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 45), .completed, "The requested English translation must actually enter generation.\n\(app.debugDescription)")
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        let completed = expectation(for: ready, evaluatedWith: english)
        let outcome = XCTWaiter.wait(for: [completed], timeout: 240)
        capture(app, "autonomous-translation-result")
        XCTAssertEqual(outcome, .completed, app.debugDescription)
        guard outcome == .completed else { return }
        english.tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: generate)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 45), .completed, "The translated document must load before the reader is accepted.\n\(app.debugDescription)")
        XCTAssertTrue(web.buttons["Aumentar texto"].waitForExistence(timeout: 20))
        XCTAssertTrue(web.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "Francoist")).firstMatch.exists, app.debugDescription)
        capture(app, "autonomous-translation-reader")
        translate.tap()
        XCTAssertTrue(english.waitForExistence(timeout: 15)); XCTAssertTrue(english.isEnabled)
        capture(app, "autonomous-translation-saved-reopened")
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
    func testPrimaryConnectionUsesCodeAndKeepsServerAdvanced() throws {
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
        let advanced = app.buttons["pairing-advanced-connection"]
        for _ in 0..<8 { if advanced.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(advanced.isHittable); advanced.tap()
        XCTAssertTrue(app.textFields["nodus-server-address"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "primary-connection-server-is-advanced")
    }
    @MainActor
    func testLinkMacByTypedCodeWithoutAddressOrFingerprint() throws {
        try linkMacByTypedCode(renewal: false)
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
    @MainActor private func linkMacByTypedCode(renewal: Bool, invalidCodeFirst: Bool = false, capabilitiesFailureFirst: Bool = false) throws {
        executionTimeAllowance = 300
        let code = try XCTUnwrap(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PAIRING_CODE"], "A fresh Mac code is required.")
        XCTAssertNil(ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_LINK"], "This test must discover the Mac, not receive an injected link.")
        let app = XCUIApplication()
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
        let initial = expectation(for: NSPredicate { _, _ in addServer.exists || switchSpace.exists }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 20), .completed)
        if switchSpace.exists { switchSpace.tap() }
        if renewal {
            XCTAssertTrue(app.buttons["space-default"].waitForExistence(timeout: 15), "Renewal must start with the existing Mac vault, not create its first connection.")
        }
        for _ in 0..<16 { if addServer.isHittable { break }; app.swipeUp() }
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
        _ = try liveDeepResearchComposerSelectingMacModel()
    }
    @MainActor private func liveDeepResearchComposerSelectingMacModel() throws -> XCUIApplication {
        let app = try pairLive(route: "settings")
        let mode = app.buttons["ai-execution-mode"]
        for _ in 0..<5 { if mode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 20)); mode.tap()
        let live = app.buttons["Live · modelos del Mac"]
        XCTAssertTrue(live.waitForExistence(timeout: 10)); live.tap()
        app.buttons["nodus-navigation-toggle"].tap()
        let research = app.buttons["nodus-nav-deepResearch"]
        for _ in 0..<6 { if research.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(research.isHittable); research.tap()
        let web = app.webViews.firstMatch
        let newReport = web.buttons["Nuevo informe"].firstMatch
        XCTAssertTrue(newReport.waitForExistence(timeout: 60))
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
        let search = web.textFields.firstMatch
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
        let restoredSearch = restoredWeb.textFields.firstMatch
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
        let reports = app.descendants(matching: .any)["shared-desktop-deepResearch"]
        XCTAssertTrue(reports.waitForExistence(timeout: 60), app.debugDescription)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.buttons.firstMatch.waitForExistence(timeout: 30))
        let search = web.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20)); search.tap()
        capture(app, "live-deep-research-search-focus")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        search.typeText("La mirada extranjera\n")
        let report = web.buttons.containing(NSPredicate(format: "label CONTAINS %@", "La mirada extranjera sobre la España franquista")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
        XCTAssertFalse(web.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "invalid_token")).firstMatch.exists)
        for _ in 0..<6 { if report.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(report.isHittable, app.debugDescription)
        capture(app, "live-deep-research-catalogue")
        report.tap()
        XCTAssertTrue(web.buttons["Aumentar texto"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(web.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "España")).firstMatch.exists)
        capture(app, "live-deep-research-reader")
        let paragraph = web.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Este informe analiza")).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 25), app.debugDescription)
        for _ in 0..<8 { if paragraph.isHittable { break }; web.swipeUp() }
        XCTAssertTrue(paragraph.isHittable, app.debugDescription)
        capture(app, "live-deep-research-body-visible")
        let readerError = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "operation_forbidden", "operation_unavailable", "Error:")).firstMatch
        XCTAssertFalse(readerError.waitForExistence(timeout: 3), readerError.label)
        XCTAssertFalse(app.staticTexts["shared-surface-error"].exists, app.debugDescription)
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
