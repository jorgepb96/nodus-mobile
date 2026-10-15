import Foundation

/// Preconditions are captured from the exact consulted relation set, including
/// canonical IDs and target vaults. Retries reuse the mutation's stable ID.
public enum CompanionDatabaseLinks {
    public static func relation(id: String, rowId: String, columnId: String, databaseId: String, columnRevision: Int,
        current: [Row], targetKind: String? = nil, targetId: String? = nil, targetVaultId: String? = nil, label: String? = nil) throws -> [String: JSONValue] {
        guard !id.isEmpty, !rowId.isEmpty, !columnId.isEmpty, !databaseId.isEmpty, columnRevision >= 0 else { throw DesktopBridgeError.malformedResponse }
        var seen: Set<String> = []
        let baseline: [JSONValue] = try current.filter { $0.string("row_id") == rowId && $0.string("column_id") == columnId }.sorted { ($0.string("id") ?? "") < ($1.string("id") ?? "") }.map { row in
            guard let identity = row.string("id"), seen.insert(identity).inserted, let kind = row.string("target_kind"), let target = row.string("target_id") else { throw DesktopBridgeError.malformedResponse }
            return .object(["id": .string(identity), "target_kind": .string(kind), "target_id": .string(target), "target_vault_id": .string(row.string("target_vault_id") ?? "")])
        }
        let encoded = try JSONEncoder.nodus.encode(JSONValue.array(baseline))
        guard let json = String(data: encoded, encoding: .utf8) else { throw DesktopBridgeError.malformedResponse }
        var result: [String: JSONValue] = ["id": .string(id), "row_id": .string(rowId), "column_id": .string(columnId), "database_id": .string(databaseId), "_mobileExpectedColumnRevision": .int(Int64(columnRevision)), "_mobileExpectedRelationsJSON": .string(json)]
        if let targetKind {
            guard ["db_row", "work", "idea", "gap", "author", "person"].contains(targetKind), let targetId, !targetId.isEmpty else { throw DesktopBridgeError.malformedResponse }
            if targetKind != "db_row" { guard targetVaultId?.isEmpty == false else { throw DesktopBridgeError.permissionDenied } }
            result["target_kind"] = .string(targetKind); result["target_id"] = .string(targetId); result["target_vault_id"] = targetVaultId.map(JSONValue.string) ?? .null
            if let label { result["label"] = .string(label) }
        } else { guard seen.contains(id) else { throw DesktopBridgeError.malformedResponse } }
        return result
    }
}
