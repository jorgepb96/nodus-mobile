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
    @MainActor func testChosenSubjectCopyCreatesStructuredNoteAndReopensOffline() throws {
        let enabled = try required("NODUS_ACCEPTANCE_STUDY_IDEAS_MUTATION")
        XCTAssertEqual(enabled, "1"); guard enabled == "1" else { throw SetupError.missingConfiguration }
        let vault = try required("NODUS_ACCEPTANCE_STUDY_VAULT")
        let subject = try required("NODUS_ACCEPTANCE_STUDY_SUBJECT_NAME")
        let course = try required("NODUS_ACCEPTANCE_STUDY_COURSE")
        let idea = try required("NODUS_ACCEPTANCE_STUDY_IDEA_LABEL")
        let statement = try required("NODUS_ACCEPTANCE_STUDY_IDEA_STATEMENT")
        let app = XCUIApplication(); app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch(); defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.buttons["Cambiar de espacio"].waitForExistence(timeout:45)); app.buttons["Cambiar de espacio"].tap()
        let owning = app.buttons["space-" + vault]; XCTAssertTrue(owning.waitForExistence(timeout:20)); reveal(owning,app); owning.tap()
        try mode(app, autonomous:false)
        let before = try notes(app, course:course, title:idea)
        try navigate(app,"studyIdeas")
        let selector = app.webViews.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "Asignatura")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout:30)); selector.tap()
        if app.pickerWheels.firstMatch.waitForExistence(timeout:3) {
            app.pickerWheels.firstMatch.adjust(toPickerWheelValue:subject)
            let done = app.buttons.matching(NSPredicate(format:"label IN %@", ["Done","Aceptar","Listo"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout:5)); done.tap()
        } else { let option = app.staticTexts[subject]; XCTAssertTrue(option.waitForExistence(timeout:5)); option.tap() }
        let download = app.buttons["Descargar 7 días"]; XCTAssertTrue(download.waitForExistence(timeout:15)); download.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@", "Disponible en este dispositivo durante 7")).firstMatch.waitForExistence(timeout:60))
        try mode(app, autonomous:true)
        app.terminate(); app.launch(); try navigate(app,"studyIdeas")
        let row = app.buttons.containing(NSPredicate(format:"label CONTAINS %@",idea)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:30)); reveal(row,app); row.tap()
        let save = app.buttons["Guardar en notas"]; XCTAssertTrue(save.waitForExistence(timeout:20)); reveal(save,app)
        XCTAssertGreaterThanOrEqual(save.frame.height,44); save.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Apunte guardado en este dispositivo")).firstMatch.waitForExistence(timeout:20))
        app.terminate(); app.launch()
        let after = try notes(app,course:course,title:idea)
        let created = after.subtracting(before); XCTAssertEqual(created.count,1,"One explicit save creates exactly one discoverable document after restart.")
        let id = try XCTUnwrap(created.first); let note = app.buttons[id]; reveal(note,app); note.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:30))
        for orientation in [UIDeviceOrientation.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation = orientation
            let turned = NSPredicate { _,_ in let f=app.windows.firstMatch.frame;return orientation == .portrait ? f.height>f.width : f.width>f.height }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:turned,object:nil)],timeout:15),.completed)
            XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format:"label CONTAINS %@",statement)).firstMatch.waitForExistence(timeout:20),"The real source statement must remain readable in the structured editor.")
            let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="study-idea-offline-note-\(orientation.rawValue)";attachment.lifetime = .keepAlways;add(attachment)
        }
    }
    @MainActor private func notes(_ app:XCUIApplication,course:String,title:String) throws -> Set<String> {
        try navigate(app,"studyCourses");let open=app.buttons["study-course-open-"+course];XCTAssertTrue(open.waitForExistence(timeout:30));reveal(open,app);open.tap()
        XCTAssertTrue(app.descendants(matching:.any)["study-course-detail-"+course].firstMatch.waitForExistence(timeout:20))
        return Set(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","study-course-document-",title)).allElementsBoundByIndex.map(\.identifier))
    }
    @MainActor private func mode(_ app:XCUIApplication,autonomous:Bool) throws {
        try navigate(app,"settings");let control=app.buttons["ai-execution-mode"];XCTAssertTrue(control.waitForExistence(timeout:20));reveal(control,app);control.tap()
        let option=app.buttons[autonomous ? "Autónomo · este dispositivo":"Live · modelos del Mac"];XCTAssertTrue(option.waitForExistence(timeout:10));option.tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@",autonomous ? "Autónomo":"Live",autonomous ? "Autónomo":"Live"),object:control)],timeout:15),.completed)
    }
    @MainActor private func navigate(_ app:XCUIApplication,_ route:String) throws {
        let toggle=app.buttons["nodus-navigation-toggle"];XCTAssertTrue(toggle.waitForExistence(timeout:45));let target=app.buttons["nodus-nav-"+route]
        if !target.isHittable { toggle.tap() };XCTAssertTrue(target.waitForExistence(timeout:15));reveal(target,app);target.tap()
    }
    @MainActor private func reveal(_ element:XCUIElement,_ app:XCUIApplication) {
        for _ in 0..<16 { if element.isHittable { break };app.swipeUp() };XCTAssertTrue(element.isHittable)
    }
}
