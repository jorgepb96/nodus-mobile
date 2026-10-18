import XCTest
import UIKit

/// Explicit write acceptance against a previously paired COPIED lab. No demo/bootstrap,
/// provider, extraction or indexing. The final runner supplies values read from its SQLite oracle.
final class StudyIdeasAcceptanceUITests: XCTestCase {
    private enum SetupError: Error { case missingConfiguration }
    override func setUpWithError() throws { continueAfterFailure = false }
    private func required(_ key: String) throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Required copied-lab configuration: " + key)
        guard !value.isEmpty else { throw SetupError.missingConfiguration }; return value
    }
    @MainActor func testConnectedChosenCopyCreatesStructuredNoteAndReopens() throws { try runCopy(phase: "connected") }
    @MainActor func testPrepareChosenSubjectForOwningMacOfflinePhase() throws { try runCopy(phase: "prepare") }
    @MainActor func testActuallyOfflineChosenSubjectCreatesStructuredNoteAndReopens() async throws {
        try await verifyOwningMacUnavailable()
        try runCopy(phase:"offline")
    }
    /// Recheck the actual prior save without issuing a second create after a driver failure.
    @MainActor func testExistingOfflineAuthoredNoteReopensInBothOrientations() async throws {
        try await verifyOwningMacUnavailable()
        let id = try required("NODUS_ACCEPTANCE_STUDY_CREATED_NOTE_ID")
        XCTAssertNotNil(UUID(uuidString: id))
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch(); defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout:10))
        let current = try notes(app, course: required("NODUS_ACCEPTANCE_STUDY_COURSE"), title: required("NODUS_ACCEPTANCE_STUDY_IDEA_LABEL"))
        let rowID = "study-local-document-" + id
        XCTAssertEqual(current, Set([rowID]))
        let row = app.buttons[rowID]; reveal(row,app); row.tap()
        try verifyAuthoredReader(app, statement: required("NODUS_ACCEPTANCE_STUDY_IDEA_STATEMENT"))
    }
    @MainActor func testDeletingChosenSubjectCopyRetainsAuthoredNote() async throws {
        try await verifyOwningMacUnavailable()
        let enabled=try required("NODUS_ACCEPTANCE_STUDY_IDEAS_MUTATION");XCTAssertEqual(enabled,"1");guard enabled == "1" else { throw SetupError.missingConfiguration }
        let pack=try required("NODUS_ACCEPTANCE_STUDY_COPY_ID"),note=try required("NODUS_ACCEPTANCE_STUDY_CREATED_NOTE_ID"),statement=try required("NODUS_ACCEPTANCE_STUDY_IDEA_STATEMENT")
        let app=XCUIApplication();app.launchArguments=["-AppleLanguages","(es)","-AppleLocale","es_ES"];app.launch();defer{app.terminate()}
        try navigate(app,"settings")
        let remove=app.buttons["companion-download-remove-"+pack]
        let list=app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout:10))
        // List virtualizes rows below the viewport. Scroll the actual settings
        // list before asking whether its selected-pack control exists.
        for _ in 0..<20 {
            if remove.exists && remove.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(remove.exists && remove.isHittable)
        remove.tap();XCTAssertTrue(remove.waitForNonExistence(timeout:20))
        app.terminate();app.launch();try navigate(app,"studyCourses");let catalogue=app.buttons["workspace-catalogue-studyCourses"];XCTAssertTrue(catalogue.waitForExistence(timeout:20));reveal(catalogue,app);catalogue.tap()
        let own=app.buttons["study-local-document-"+note];XCTAssertTrue(own.waitForExistence(timeout:30));reveal(own,app);own.tap()
        try verifyAuthoredReader(app, statement: statement)
    }
    /// Run only after resuming the same owning Mac/profile/grant. No new pairing input.
    @MainActor func testReconnectedChosenNoteKeepsIdentityAndMacAcknowledgementAfterReopen() throws {
        let env = ProcessInfo.processInfo.environment
        for key in ["NODUS_UI_TEST_DEMO", "NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] {
            XCTAssertNil(env[key], "Use the previously linked grant without importing another source.")
        }
        let id = try required("NODUS_ACCEPTANCE_STUDY_CREATED_NOTE_ID")
        XCTAssertNotNil(UUID(uuidString: id), "Pass the UUID, without the study-local-document- AX prefix.")
        let course = try required("NODUS_ACCEPTANCE_STUDY_COURSE")
        let title = try required("NODUS_ACCEPTANCE_STUDY_IDEA_LABEL")
        let statement = try required("NODUS_ACCEPTANCE_STUDY_IDEA_STATEMENT")
        let rowID = "study-local-document-" + id
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        defer { app.terminate() }
        for pass in 1...2 {
            app.launch()
            // SpaceShell.monitorPublishedContent performs a real direct probe and
            // synchronizeCompanionChanges, even when the publication revision is unchanged.
            let current = try notes(app, course: course, title: title)
            XCTAssertEqual(current, Set([rowID]), "Reconnection must retain the exact authored note identity.")
            let row = app.buttons[rowID]; reveal(row, app); row.tap()
            let edit = app.buttons["study-document-edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 30)); edit.tap()
            let web = app.otherElements["shared-desktop-studyDocument"].webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 30))
            XCTAssertTrue(web.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", statement, statement)).firstMatch.waitForExistence(timeout: 30))
            let acknowledged = NSPredicate { _, _ in
                web.staticTexts["Guardado"].exists &&
                !web.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Guardado en este dispositivo")).firstMatch.exists
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: acknowledged, object: nil)], timeout: 60), .completed,
                "Only the editor's confirmed Mac state is an acknowledgement; local persistence alone is insufficient.")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "study-reconnected-same-note-mac-ack-\(pass)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    private func verifyOwningMacUnavailable() async throws {
        let origin=try required("NODUS_ACCEPTANCE_OFFLINE_ORIGIN")
        let url=try XCTUnwrap(URL(string:origin + "/bridge/v2/capabilities"))
        let probe=URLSession(configuration:.ephemeral);defer{probe.invalidateAndCancel()}
        var request=URLRequest(url:url);request.timeoutInterval=8
        do { _ = try await probe.data(for:request);XCTFail("The copied owning Mac must actually be unavailable.");throw SetupError.missingConfiguration }
        catch let error as URLError { XCTAssertTrue([.cannotConnectToHost,.networkConnectionLost,.notConnectedToInternet,.timedOut].contains(error.code));guard [.cannotConnectToHost,.networkConnectionLost,.notConnectedToInternet,.timedOut].contains(error.code) else { throw error } }
    }
    @MainActor private func runCopy(phase:String) throws {
        let enabled = try required("NODUS_ACCEPTANCE_STUDY_IDEAS_MUTATION")
        XCTAssertEqual(enabled, "1"); guard enabled == "1" else { throw SetupError.missingConfiguration }
        let vault = try required("NODUS_ACCEPTANCE_STUDY_VAULT")
        let subject = try required("NODUS_ACCEPTANCE_STUDY_SUBJECT_NAME")
        let course = try required("NODUS_ACCEPTANCE_STUDY_COURSE")
        let idea = try required("NODUS_ACCEPTANCE_STUDY_IDEA_LABEL")
        let statement = try required("NODUS_ACCEPTANCE_STUDY_IDEA_STATEMENT")
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch(); defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.buttons["Cambiar de espacio"].waitForExistence(timeout: phase == "offline" ? 10 : 45),
                      "Saved work must open without waiting for the disconnected Mac's catalogue timeout.")
        app.buttons["Cambiar de espacio"].tap()
        let owning = app.buttons["space-" + vault]; XCTAssertTrue(owning.waitForExistence(timeout:20)); reveal(owning,app); owning.tap()
        var before=Set<String>()
        do {
            let encoded=try required("NODUS_ACCEPTANCE_STUDY_BASELINE_JSON")
            let baseline=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any])
            XCTAssertEqual(baseline["vaultId"] as? String,vault);XCTAssertEqual(baseline["courseId"] as? String,course);XCTAssertEqual(baseline["ideaLabel"] as? String,idea)
            guard baseline["vaultId"] as? String == vault,baseline["courseId"] as? String == course,baseline["ideaLabel"] as? String == idea else { throw SetupError.missingConfiguration }
            before=Set(try XCTUnwrap(baseline["noteIdentifiers"] as? [String]))
        }
        if phase != "offline" {
        try requireLiveMode(app)
        try navigate(app,"studyIdeas")
        let selector = app.webViews.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "Asignatura")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout:30)); selector.tap()
        if app.pickerWheels.firstMatch.waitForExistence(timeout:3) {
            app.pickerWheels.firstMatch.adjust(toPickerWheelValue:subject)
            let done = app.buttons.matching(NSPredicate(format:"label IN %@", ["Done","Aceptar","Listo"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout:5)); done.tap()
        } else {
            // iOS exposes the native HTML select popover as labelled buttons,
            // rather than static text (captured in the actual copied-lab run).
            let option = app.buttons[subject].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout:5)); option.tap()
        }
        let download = app.buttons["Descargar 7 días"]; XCTAssertTrue(download.waitForExistence(timeout:15)); download.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "Disponible en este dispositivo durante 7")).firstMatch.waitForExistence(timeout:60))
        // Downloaded reading and manual writing remain available without a
        // phone-side AI mode. The beta keeps all model execution on the Mac.
        try requireLiveMode(app)
        if phase == "prepare" {
            let baseline:[String:Any]=["vaultId":vault,"courseId":course,"ideaLabel":idea,"noteIdentifiers":before.sorted()]
            let data=try JSONSerialization.data(withJSONObject:baseline,options:[.sortedKeys]);let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="study-ideas-offline-baseline.json";attachment.lifetime = .keepAlways;add(attachment);return
        }
        }
        app.terminate(); app.launch(); try navigate(app,"studyIdeas")
        let row = app.buttons.containing(NSPredicate(format:"label CONTAINS %@",idea)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:30)); reveal(row,app); row.tap()
        let save = app.buttons["Guardar en notas"]; XCTAssertTrue(save.waitForExistence(timeout:20)); reveal(save,app)
        XCTAssertGreaterThanOrEqual(save.frame.height,44); save.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Apunte guardado en este dispositivo")).firstMatch.waitForExistence(timeout:20))
        app.terminate(); app.launch()
        let after = try notes(app,course:course,title:idea)
        let created = after.subtracting(before);
        let receipt=XCTAttachment(string:created.sorted().joined(separator:"\n"));receipt.name="study-ideas-created-note-identifiers";receipt.lifetime = .keepAlways;add(receipt)
        XCTAssertEqual(created.count,1,"One explicit save creates exactly one discoverable document after restart.")
        let id = try XCTUnwrap(created.first); let note = app.buttons[id]; reveal(note,app); note.tap()
        try verifyAuthoredReader(app, statement: statement)
    }
    @MainActor private func verifyAuthoredReader(_ app: XCUIApplication, statement: String) throws {
        let reader = app.otherElements["study-evidence-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout:30))
        for orientation in [UIDeviceOrientation.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _,_ in let f=app.windows.firstMatch.frame;return orientation == .portrait ? f.height>f.width : f.width>f.height }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:turned,object:nil)],timeout:15),.completed)
            // CorpusProse renders native UITextViews; a retained WebView from
            // the Ideas route must never stand in for the opened note reader.
            let paragraph = reader.textViews.matching(NSPredicate(format:"label == %@ OR value == %@",statement,statement)).firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout:20),"The actual native reader must retain the saved source statement.")
            XCTAssertTrue(paragraph.isHittable)
            XCTAssertGreaterThanOrEqual(paragraph.frame.minX, reader.frame.minX - 1)
            XCTAssertLessThanOrEqual(paragraph.frame.maxX, reader.frame.maxX + 1)
            let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="study-idea-offline-note-\(orientation.rawValue)";attachment.lifetime = .keepAlways;add(attachment)
        }
    }
    @MainActor private func notes(_ app:XCUIApplication,course:String,title:String) throws -> Set<String> {
        try navigate(app,"studyCourses")
        let catalogue=app.buttons["workspace-catalogue-studyCourses"];XCTAssertTrue(catalogue.waitForExistence(timeout:20));reveal(catalogue,app);catalogue.tap()
        let local=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","study-local-document-",title))
        XCTAssertTrue(local.firstMatch.waitForExistence(timeout:30),"Authored notes must be reachable without a consulted global snapshot or retained subject copy.")
        return Set(local.allElementsBoundByIndex.map(\.identifier))
    }
    @MainActor private func requireLiveMode(_ app:XCUIApplication) throws {
        try navigate(app,"settings")
        let control=app.descendants(matching:.any)["ai-execution-mode"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout:20));reveal(control,app)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@","Live","Live"),object:control)],timeout:15),.completed)
        XCTAssertFalse(app.buttons["Autónomo · este dispositivo"].exists)
    }
    @MainActor private func navigate(_ app:XCUIApplication,_ route:String) throws {
        let toggle=app.buttons["nodus-navigation-toggle"];XCTAssertTrue(toggle.waitForExistence(timeout:45));let target=app.buttons["nodus-nav-"+route]
        if !target.exists || !target.isHittable { toggle.tap() };XCTAssertTrue(target.waitForExistence(timeout:15));reveal(target,app);target.tap()
    }
    @MainActor private func reveal(_ element:XCUIElement,_ app:XCUIApplication) {
        for _ in 0..<16 { if element.exists && element.isHittable { break };app.swipeUp() };XCTAssertTrue(element.exists && element.isHittable)
    }
}
