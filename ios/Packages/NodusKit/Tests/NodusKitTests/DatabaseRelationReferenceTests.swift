import Testing
@testable import NodusKit

@Suite("Database relation destination identities")
struct DatabaseRelationReferenceTests {
    @Test("Actual raw and Desktop DTO links preserve the target vault")
    func destination() throws {
        let raw = try DatabaseRelationReference(Row(["target_kind": .string("idea"), "target_id": .string("idea-a"), "target_vault_id": .string("vault-b"), "last_known_label": .string("Una idea")]))
        #expect(raw.vaultId == "vault-b"); #expect(raw.collection?.path == "ideas"); #expect(raw.id == "idea-a")
        let dto = try DatabaseRelationReference(Row(["targetKind": .string("work"), "targetId": .string("work-a"), "targetVaultId": .string("vault-b"), "label": .string("Un documento")]))
        #expect(dto.collection?.path == "works"); #expect(dto.vaultId == "vault-b")
    }
    @Test("Rows are not database IDs and unsupported kinds cannot become work links")
    func closedKinds() throws {
        let row = try DatabaseRelationReference(Row(["target_kind": .string("db_row"), "target_id": .string("row-a")]))
        #expect(row.kind == "db_row"); #expect(row.collection == nil)
        #expect(throws: DesktopBridgeError.self) { try DatabaseRelationReference(Row(["target_kind": .string("browser"), "target_id": .string("row-a")])) }
        #expect(throws: DesktopBridgeError.self) { try DatabaseRelationReference(Row(["target_kind": .string("person"), "target_id": .string("")])) }
        #expect(throws: DesktopBridgeError.self) { try DatabaseRelationReference(Row(["target_kind": .string("person"), "target_id": .string("person-a"), "target_vault_id": .string("")])) }
    }
}
