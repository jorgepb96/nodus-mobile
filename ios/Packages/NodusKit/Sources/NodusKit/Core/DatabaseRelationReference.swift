import Foundation

/// Actual Desktop relation kinds. A row ID is never guessed to be a database
/// ID, and the target vault is never replaced with the currently open vault.
public struct DatabaseRelationReference: Sendable {
    public let kind: String
    public let id: String
    public let vaultId: String?
    public let label: String
    public var collection: CollectionDescriptor? {
        let paths = ["work": "works", "idea": "ideas", "gap": "gaps", "author": "authors", "person": "persons"]
        return paths[kind].flatMap { Collections[$0] }
    }
    public init(_ row: Row) throws {
        guard let kind = row.string("target_kind") ?? row.string("targetKind"),
              ["db_row", "work", "idea", "gap", "author", "person"].contains(kind),
              let id = row.string("target_id") ?? row.string("targetId"), !id.isEmpty, id.utf8.count <= 2048 else { throw DesktopBridgeError.malformedResponse }
        let vault = row.string("target_vault_id") ?? row.string("targetVaultId")
        guard vault == nil || (!vault!.isEmpty && vault!.utf8.count <= 1024) else { throw DesktopBridgeError.malformedResponse }
        self.kind = kind; self.id = id; self.vaultId = vault
        self.label = row.text("label") ?? row.text("last_known_label") ?? row.text("lastKnownLabel") ?? "Registro vinculado"
    }
}
