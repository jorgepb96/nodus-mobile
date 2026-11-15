import Foundation

/// Metadata-only operations use real downloaded tree rows. Native document
/// bodies and annotation arrays never appear in these packets.
public enum CompanionWorkspaceOrganization {
    private static func failure(_ code: String) -> APIError { APIError(status: 409, code: code, message: "La organización cambió o no está descargada. Revisa la operación conservada en el móvil.") }
    public static func ancestry(_ id: String?, tree: JSONValue) throws -> JSONValue {
        let folders = tree.objectValue?["folders"]?.arrayValue ?? []
        var cursor = id, seen = Set<String>(), rows: [JSONValue] = []
        while let key = cursor {
            guard seen.insert(key).inserted, seen.count <= 256, let folder = folders.first(where: { $0.objectValue?["id"] == .string(key) })?.objectValue else { throw failure("placement_unavailable") }
            rows.append(.object(["id": .string(key), "parentId": folder["parentId"] ?? .null, "name": folder["name"] ?? .null]))
            cursor = folder["parentId"]?.stringValue
        }
        return .array(rows)
    }
    public static func subtree(_ id: String, tree: JSONValue) throws -> JSONValue {
        let folders = tree.objectValue?["folders"]?.arrayValue ?? [], notes = tree.objectValue?["notes"]?.arrayValue ?? []
        guard folders.contains(where: { $0.objectValue?["id"] == .string(id) }) else { throw failure("folder_unavailable") }
        var ids = Set([id])
        for _ in 0...folders.count {
            let before = ids
            for row in folders { if let parent = row.objectValue?["parentId"]?.stringValue, ids.contains(parent), let key = row.objectValue?["id"]?.stringValue { ids.insert(key) } }
            if ids == before { break }
        }
        func sorted(_ rows: [JSONValue]) -> [JSONValue] { rows.sorted { ($0.objectValue?["id"]?.stringValue ?? "") < ($1.objectValue?["id"]?.stringValue ?? "") } }
        return .object(["folders": .array(sorted(folders.filter { ids.contains($0.objectValue?["id"]?.stringValue ?? "") }.map { .object(["id": $0.objectValue?["id"] ?? .null, "parentId": $0.objectValue?["parentId"] ?? .null, "name": $0.objectValue?["name"] ?? .null]) })), "notes": .array(sorted(notes.filter { ids.contains($0.objectValue?["folderId"]?.stringValue ?? "") }.map { .object(["id": $0.objectValue?["id"] ?? .null, "folderId": $0.objectValue?["folderId"] ?? .null, "trashedAt": $0.objectValue?["trashedAt"] ?? .null]) }))])
    }
    public static func operation(type: String, id: String, arguments: JSONValue, tree: JSONValue) throws -> JSONValue {
        let args = arguments.objectValue ?? [:], note = tree.objectValue?["notes"]?.arrayValue?.first { $0.objectValue?["id"] == .string(id) }?.objectValue
        let folder = tree.objectValue?["folders"]?.arrayValue?.first { $0.objectValue?["id"] == .string(id) }?.objectValue
        var value: [String: JSONValue] = ["type": .string(type), "id": .string(id)]
        switch type {
        case "move":
            guard let note, note["trashedAt"] == nil || note["trashedAt"] == .null else { throw failure("document_unavailable") }
            let target = args["folderId"] ?? .null
            value["expectedFolderId"] = note["folderId"] ?? .null; value["targetFolderId"] = target
            value["targetAncestry"] = try ancestry(target.stringValue, tree: tree)
        case "tags":
            guard let note, note["trashedAt"] == nil || note["trashedAt"] == .null else { throw failure("document_unavailable") }
            for key in ["add", "remove"] {
                let tags = args[key]?.arrayValue ?? []
                guard tags.count <= 100, tags.allSatisfy({ ($0.stringValue?.count ?? 81) <= 80 }) else { throw failure("invalid_workspace_organization") }
                value[key] = .array(tags)
            }
        case "restore":
            guard let note, let stamp = note["trashedAt"]?.stringValue else { throw failure("restore_conflict") }
            value["expectedTrashedAt"] = .string(stamp); value["expectedFolderId"] = note["folderId"] ?? .null
        case "folderCreate":
            guard UUID(uuidString: id) != nil, folder == nil, let name = args["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 4096 else { throw failure("invalid_workspace_organization") }
            value["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)); value["parentId"] = args["parentId"] ?? .null
            value["parentAncestry"] = try ancestry(value["parentId"]?.stringValue, tree: tree)
        case "folderRename":
            guard let folder, let name = args["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 4096 else { throw failure("folder_unavailable") }
            value["expectedName"] = folder["name"]; value["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        case "folderTrash": value["expectedSubtree"] = try subtree(id, tree: tree)
        default: throw failure("invalid_workspace_organization")
        }
        return .object(value)
    }
    public static func project(_ operation: JSONValue, onto tree: JSONValue, timestamp: String, state: String = "pending") -> JSONValue {
        guard let op = operation.objectValue, let id = op["id"]?.stringValue, let type = op["type"]?.stringValue, var result = tree.objectValue else { return tree }
        var notes = result["notes"]?.arrayValue ?? [], folders = result["folders"]?.arrayValue ?? []
        if type == "folderCreate", !folders.contains(where: { $0.objectValue?["id"] == .string(id) }) { folders.append(.object(["id": .string(id), "name": op["name"] ?? .null, "parentId": op["parentId"] ?? .null, "orderIdx": .int(Int64(folders.count)), "summary": .null, "createdAt": .string(timestamp), "updatedAt": .string(timestamp), "mobileSyncState": .string(state)])) }
        else if type == "folderRename" { folders = folders.map { row in guard var value = row.objectValue, value["id"] == .string(id) else { return row }; value["name"] = op["name"]; value["mobileSyncState"] = .string(state); return .object(value) } }
        else if type == "folderTrash" {
            let subtree = op["expectedSubtree"]?.objectValue ?? [:]
            let folderIDs = Set((subtree["folders"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }), noteIDs = Set((subtree["notes"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue })
            folders.removeAll { folderIDs.contains($0.objectValue?["id"]?.stringValue ?? "") }
            notes = notes.map { row in guard var value = row.objectValue, noteIDs.contains(value["id"]?.stringValue ?? "") else { return row }; value["folderId"] = .null; value["trashedAt"] = .string(timestamp); value["mobileSyncState"] = .string(state); return .object(value) }
        } else {
            notes = notes.map { row in
                guard var value = row.objectValue, value["id"] == .string(id) else { return row }
                if type == "move" { value["folderId"] = op["targetFolderId"] }
                if type == "restore" { value["trashedAt"] = .null }
                if type == "tags" {
                    let remove = Set((op["remove"]?.arrayValue ?? []).compactMap { $0.stringValue?.lowercased() })
                    var tags = (value["tags"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !remove.contains($0.lowercased()) }, seen = Set(tags.map { $0.lowercased() })
                    for tag in (op["add"]?.arrayValue ?? []).compactMap(\.stringValue) { let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines); if !clean.isEmpty, seen.insert(clean.lowercased()).inserted { tags.append(clean) } }
                    value["tags"] = .array(tags.map(JSONValue.string))
                }
                value["mobileSyncState"] = .string(state); return .object(value)
            }
        }
        result["folders"] = .array(folders); result["notes"] = .array(notes); return .object(result)
    }
}
