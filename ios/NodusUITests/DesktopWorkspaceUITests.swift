import XCTest

/// Requires an actual Mac grant and canonical Desktop create/delete/revoke
/// operations performed between runs. Expectations alone never modify app data.
final class DesktopWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWholeWorkspaceDiscoversNewVaultWithoutAnotherCode() throws {
        let expected = try required("NODUS_ACCEPTANCE_NEW_VAULT")
        let name = try required("NODUS_ACCEPTANCE_NEW_VAULT_NAME")
        for restart in 0..<2 {
            let app = try launchLinkedPicker()
            defer { app.terminate() }
            let card = app.buttons["space-" + expected]
            XCTAssertTrue(card.waitForExistence(timeout: 45), "The vault created after linking must appear through the authenticated Mac catalogue.\n" + app.debugDescription)
            XCTAssertEqual(app.buttons.matching(identifier: "space-" + expected).count, 1)
            XCTAssertTrue(card.label.contains(name), "The actual Desktop name must reach the native card.")
            for _ in 0..<20 { if card.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(card.isHittable); card.tap()
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 45), app.debugDescription)
            XCTAssertFalse(app.textFields["pairing-code"].exists)
            XCTAssertFalse(app.staticTexts["shared-surface-error"].exists)
            capture(app, "whole-workspace-new-vault-open-\(restart)")
            app.terminate()
        }
    }

    @MainActor
    func testRemovedVaultDisappearsAndOtherLinkedVaultsStillOpen() throws {
        let removed = try required("NODUS_ACCEPTANCE_REMOVED_VAULT")
        let retained = try required("NODUS_ACCEPTANCE_RETAINED_VAULT")
        XCTAssertNotEqual(removed, retained)
        for restart in 0..<2 {
            let app = try launchLinkedPicker()
            defer { app.terminate() }
            let kept = app.buttons["space-" + retained]
            XCTAssertTrue(kept.waitForExistence(timeout: 45), app.debugDescription)
            XCTAssertFalse(app.buttons["space-" + removed].exists, "A removed vault must not remain an authorized connection after refresh.")
            XCTAssertEqual(app.buttons.matching(identifier: "space-" + retained).count, 1)
            for _ in 0..<20 { if kept.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(kept.isHittable); kept.tap()
            XCTAssertTrue(app.buttons["nodus-navigation-toggle"].waitForExistence(timeout: 45), app.debugDescription)
            XCTAssertFalse(app.textFields["pairing-code"].exists)
            capture(app, "whole-workspace-removed-other-vault-open-\(restart)")
            app.terminate()
        }
    }

    @MainActor
    func testMacRevokedGrantRemovesEveryLinkedVaultAndRetainsExport() throws {
        let ids = try JSONDecoder().decode([String].self, from: Data(required("NODUS_ACCEPTANCE_REVOKED_VAULT_IDS").utf8))
        let previousArchives = try XCTUnwrap(Int(required("NODUS_ACCEPTANCE_PREVIOUS_ARCHIVE_COUNT")))
        XCTAssertGreaterThanOrEqual(previousArchives, 0)
        XCTAssertFalse(ids.isEmpty); XCTAssertEqual(Set(ids).count, ids.count)
        for restart in 0..<2 {
            let app = try launchLinkedPicker()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["nodus-add-server"].waitForExistence(timeout: 45), app.debugDescription)
            for id in ids { XCTAssertFalse(app.buttons["space-" + id].exists, "The actual revoked grant must close every linked vault, including \(id).") }
            let saved = app.buttons["saved-local-work"]
            XCTAssertTrue(saved.waitForExistence(timeout: 30), "Actual authored work must survive the Mac-originated revocation, without an injected recovery fixture.\n" + app.debugDescription)
            for _ in 0..<12 { if saved.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(saved.isHittable); saved.tap()
            let export = app.buttons["recovered-work-export"].firstMatch
            XCTAssertTrue(export.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertEqual(app.buttons.matching(identifier: "recovered-work-export").count, previousArchives + 1,
                "An older archive must not mask failure to preserve this grant's actual authored work; a restart must not archive it twice.")
            XCTAssertTrue(export.isHittable)
            // Archives are displayed newest first. Root also checks this exported
            // file's grant ID and exact authored marker in the simulator container.
            export.tap()
            let file = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "LP.CaptionBar.TopCaption", "Nodus-local-work")).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 20), "The newly retained work must reach the actual native file share sheet.\n" + app.debugDescription)
            capture(app, "mac-revoked-grant-authoring-export-\(restart)")
            app.terminate()
        }
    }

    private func required(_ key: String) throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Actual isolated Desktop acceptance input is required: \(key)")
        XCTAssertFalse(value.isEmpty); return value
    }

    @MainActor private func launchLinkedPicker() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        for forbidden in ["NODUS_UI_TEST_DEMO", "NODUS_ACCEPTANCE_PAIRING_LINK", "NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] {
            XCTAssertNil(env[forbidden], "This test requires the actual previously linked workspace.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()
        let picker = app.buttons["nodus-add-server"]
        let switchSpace = app.buttons["Cambiar de espacio"]
        let ready = expectation(for: NSPredicate { _, _ in picker.exists || switchSpace.exists }, evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, app.debugDescription)
        if switchSpace.exists { switchSpace.tap() }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.textFields["pairing-code"].exists)
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
