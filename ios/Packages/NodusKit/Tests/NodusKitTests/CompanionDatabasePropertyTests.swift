import Foundation
import Testing
@testable import NodusKit

@Suite("Canonical database property edits")
struct CompanionDatabasePropertyTests {
    @Test("structured touch edits preserve untouched range, reminders, references and future fields")
    func structuredValues() throws {
        let date = #"{"start":"2026-10-13T08:00:00Z","end":"2026-10-14T08:00:00Z","includeTime":true,"timeZone":"Europe/Madrid","reminderMinutes":30,"recurrence":"weekly","future":{"version":2}}"#
        let patched = try CompanionDatabaseProperty.patchObject(date, legacyKey: "start", fields: ["start": .string("2026-10-15T08:00:00Z")])
        let object = CompanionDatabaseProperty.object(patched)
        #expect(object["end"] == .string("2026-10-14T08:00:00Z"))
        #expect(object["reminderMinutes"] == .int(30)); #expect(object["recurrence"] == .string("weekly"))
        #expect(object["future"] == .object(["version": .int(2)]))
        let legacy = try CompanionDatabaseProperty.patchObject("2026-10-13", legacyKey: "start", fields: ["timeZone": .string("UTC")])
        #expect(CompanionDatabaseProperty.object(legacy)["start"] == .string("2026-10-13"))
        let location = try CompanionDatabaseProperty.patchObject("Madrid", legacyKey: "name", fields: ["latitude": .double(40.4)])
        #expect(CompanionDatabaseProperty.object(location)["name"] == .string("Madrid"))
        #expect(CompanionDatabaseProperty.strings(try CompanionDatabaseProperty.encodeStrings(["dopt_original", "dopt_queued", "dopt_original"])) == ["dopt_original", "dopt_queued"])
    }
    @Test("config changes retain complete canonical formulas, approved model references and unknown schema")
    func configurationPreservation() throws {
        let config: [String: JSONValue] = ["formula": .object(["kind": .string("expression"), "source": .string("sum(property(\"dcol_original\"))"), "ast": .object(["type": .string("call"), "name": .string("sum"), "args": .array([.object(["type": .string("property"), "columnId": .string("dcol_original")])])])]), "aiModel": .object(["provider": .string("codex"), "model": .string("approved-on-mac")]), "futureDesktopField": .object(["version": .int(3)])]
        let updated = CompanionDatabaseProperty.object(try CompanionDatabaseProperty.configuration(config, patch: ["formulaDecimals": .int(4)]))
        #expect(updated["formula"] == config["formula"])
        #expect(updated["aiModel"] == config["aiModel"])
        #expect(updated["futureDesktopField"] == config["futureDesktopField"])
        #expect(updated["formulaDecimals"] == .int(4))
    }
}
