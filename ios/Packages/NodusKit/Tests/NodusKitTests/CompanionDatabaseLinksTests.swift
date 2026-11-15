import Foundation
import Testing
@testable import NodusKit

@Suite("Canonical relation preconditions") struct CompanionDatabaseLinksTests {
    @Test func exactSetAndTargetVaultSurviveOfflineQueue() throws {
        let existing = [Row(["id":.string("drel_old"),"row_id":.string("row"),"column_id":.string("column"),"target_kind":.string("work"),"target_id":.string("source-42"),"target_vault_id":.string("academic-vault")])]
        let value = try CompanionDatabaseLinks.relation(id: "drel_new", rowId: "row", columnId: "column", databaseId: "db", columnRevision: 7, current: existing, targetKind: "work", targetId: "source-81", targetVaultId: "academic-vault", label: "Actual source")
        #expect(value["target_id"] == .string("source-81")); #expect(value["target_vault_id"] == .string("academic-vault")); #expect(value["_mobileExpectedColumnRevision"] == .int(7))
        let json = try #require(value["_mobileExpectedRelationsJSON"]?.stringValue)
        let baseline = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(json.utf8))
        #expect(baseline == .array([.object(["id":.string("drel_old"),"target_kind":.string("work"),"target_id":.string("source-42"),"target_vault_id":.string("academic-vault")])]))
        #expect(throws: DesktopBridgeError.self) { try CompanionDatabaseLinks.relation(id: "drel_new", rowId: "row", columnId: "column", databaseId: "db", columnRevision: 7, current: existing, targetKind: "work", targetId: "source-81") }
        #expect(throws: DesktopBridgeError.self) { try CompanionDatabaseLinks.relation(id: "missing", rowId: "row", columnId: "column", databaseId: "db", columnRevision: 7, current: existing) }
    }
}
