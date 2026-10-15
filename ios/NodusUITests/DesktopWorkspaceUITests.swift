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

    /// Root configures this exact model through actual Mac settings after linking,
    /// stops the Mac and restarts it with either its saved port or an occupied-port
    /// fallback. This test supplies no new grant, address or response data.
    @MainActor
    func testReconnectedMacReadsCurrentModelsWithoutNewCode() throws {
        let expected = try required("NODUS_ACCEPTANCE_EXPECTED_MAC_MODEL")
        let env = ProcessInfo.processInfo.environment
        for forbidden in ["NODUS_UI_TEST_DEMO", "NODUS_ACCEPTANCE_PAIRING_LINK", "NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] {
            XCTAssertNil(env[forbidden], "Reconnection must use the actual previously linked grant.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_START_ROUTE"] = "settings"
        let deadline = Date().addingTimeInterval(60)
        app.launch(); defer { capture(app, "reconnected-mac-current-model-no-new-code"); app.terminate() }
        let settings = app.descendants(matching: .any)["settings-workspace"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription)
        let model = app.staticTexts[expected].firstMatch
        var scrolls = 0
        while Date() < deadline {
            if model.exists && model.isHittable { break }
            XCTAssertFalse(app.textFields["pairing-code"].exists, "No new code may be needed during recovery.")
            if scrolls % 16 < 8 { app.swipeUp() } else { app.swipeDown() }
            scrolls += 1
            if model.waitForExistence(timeout: 0.5) && model.isHittable { break }
        }
        XCTAssertTrue(model.exists && model.isHittable, "The current model configured on the actual Mac must reach the still-open native settings.\n" + app.debugDescription)
        XCTAssertFalse(app.staticTexts["mac-live-settings-error"].exists, "A canceled obsolete diagnostic must not overwrite successful recovery.")
        let mode = app.buttons["ai-execution-mode"].firstMatch
        XCTAssertTrue(mode.exists, app.debugDescription)
        let selectedMode = mode.label + " " + (mode.value as? String ?? "")
        XCTAssertTrue(selectedMode.contains("Live"), "Disconnection must not change execution mode: " + selectedMode)
        let published = app.descendants(matching: .any)["mac-embedding-published"].firstMatch
        let noVectors = app.descendants(matching: .any)["mac-embedding-no-vectors"].firstMatch
        var embeddingScrolls = 0
        while Date() < deadline && !(published.exists || noVectors.exists) {
            if embeddingScrolls % 16 < 8 { app.swipeUp() } else { app.swipeDown() }
            embeddingScrolls += 1
            _ = published.waitForExistence(timeout: 0.5)
        }
        XCTAssertTrue(published.exists || noVectors.exists, "A real successful semantic identity response must replace the obsolete transport failure.\n" + app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["mac-embedding-error"].firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.textFields["pairing-code"].exists)
    }

    /// Uses the existing real grant. Root runs this before the destructive revocation test.
    @MainActor
    func testRenewExistingMacConnectionStaysLiveAfterReopeningWithoutCode() throws {
        let expected = try required("NODUS_ACCEPTANCE_EXPECTED_MAC_MODEL")
        let app = try launchExistingMacSettings()
        defer { capture(app, "existing-mac-renewal-final"); app.terminate() }
        let renewal = app.buttons["renew-mac-connection"].firstMatch
        reveal(renewal, in: app)
        XCTAssertTrue(renewal.isEnabled); renewal.tap()
        let result = app.staticTexts["mac-connection-result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertEqual(result.label, "Conexión renovada. Se conservan las copias, los borradores y las solicitudes.")
        XCTAssertTrue(renewal.isEnabled)
        assertLiveMacModel(expected, in: app)
        capture(app, "existing-mac-renewal-success")
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        assertLiveMacModel(expected, in: app)
        XCTAssertFalse(app.textFields["pairing-code"].exists)
    }

    /// Destructive only to the already linked isolated lab grant supplied by Root.
    @MainActor
    func testRevokeExistingMacConnectionCancelPreservesThenConfirmRemovesAllVaults() throws {
        let ids = try JSONDecoder().decode([String].self, from: Data(required("NODUS_ACCEPTANCE_REVOKED_VAULT_IDS").utf8))
        XCTAssertFalse(ids.isEmpty); XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        let app = try launchExistingMacSettings()
        defer { capture(app, "existing-mac-revocation-final"); app.terminate() }
        let settings = app.descendants(matching: .any)["settings-workspace"].firstMatch
        let revoke = app.buttons["revoke-mac-connection"].firstMatch
        reveal(revoke, in: app); XCTAssertTrue(revoke.isEnabled); revoke.tap()
        let cancel = app.buttons["Cancelar"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(settings.exists); XCTAssertTrue(revoke.isEnabled)
        let mode = app.buttons["ai-execution-mode"].firstMatch
        reveal(mode, in: app)
        XCTAssertTrue((mode.label + " " + (mode.value as? String ?? "")).contains("Live"))
        XCTAssertFalse(app.textFields["pairing-code"].exists)
        capture(app, "existing-mac-revocation-cancel-preserves-live")
        reveal(revoke, in: app); revoke.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Revocar conexión con el Mac", "revoke-mac-connection")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); XCTAssertTrue(confirm.isHittable)
        capture(app, "existing-mac-revocation-confirmation"); confirm.tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 45), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["nodus-add-server"].waitForExistence(timeout: 30), app.debugDescription)
        for id in ids { XCTAssertFalse(app.buttons["space-" + id].exists, "Revoked vault remains: " + id) }
        capture(app, "existing-mac-revocation-removed")
        app.terminate()
        let reopened = try launchLinkedPicker()
        defer { reopened.terminate() }
        for id in ids { XCTAssertFalse(reopened.buttons["space-" + id].exists, "Revoked vault returned after restart: " + id) }
        XCTAssertFalse(reopened.buttons["revoke-mac-connection"].exists)
        capture(reopened, "existing-mac-revocation-after-restart")
    }

    @MainActor private func launchExistingMacSettings() throws -> XCUIApplication {
        for forbidden in ["NODUS_UI_TEST_DEMO", "NODUS_ACCEPTANCE_PAIRING_LINK", "NODUS_ACCEPTANCE_LINK", "NODUS_ACCEPTANCE_PAIRING_CODE", "NODUS_ACCEPTANCE_SNAPSHOT_FILENAME", "NODUS_ACCEPTANCE_AUTHORING_RECOVERY"] {
            XCTAssertNil(ProcessInfo.processInfo.environment[forbidden], "The existing real grant is required.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launchEnvironment["NODUS_START_ROUTE"] = "settings"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["settings-workspace"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.textFields["pairing-code"].exists)
        return app
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for step in 0..<32 {
            if element.exists && element.isHittable { return }
            if step % 16 < 8 { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    @MainActor private func assertLiveMacModel(_ expected: String, in app: XCUIApplication) {
        let model = app.staticTexts[expected].firstMatch
        let deadline = Date().addingTimeInterval(35)
        var step = 0
        while Date() < deadline && !(model.exists && model.isHittable) {
            if step % 16 < 8 { app.swipeUp() } else { app.swipeDown() }
            step += 1
            _ = model.waitForExistence(timeout: 0.5)
        }
        XCTAssertTrue(model.exists && model.isHittable, "The actual Mac settings must answer after renewal.\n" + app.debugDescription)
        XCTAssertFalse(app.staticTexts["mac-live-settings-error"].exists)
        let mode = app.buttons["ai-execution-mode"].firstMatch
        reveal(mode, in: app)
        XCTAssertTrue((mode.label + " " + (mode.value as? String ?? "")).contains("Live"))
        XCTAssertFalse(app.textFields["pairing-code"].exists)
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
