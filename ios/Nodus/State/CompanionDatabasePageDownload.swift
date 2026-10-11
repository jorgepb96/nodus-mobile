import Foundation
import NodusKit

/// Row-associated pages commit with their selected database, never as a vault backup.
enum CompanionDatabasePageDownload {
    static func key(_ database: String) -> String { "companion:database-pages:v1:\(database)" }
    @MainActor static func resources(client: DesktopBridgeClient, vault: String, databaseId: String, dossier: JSONValue, presentation: JSONValue,
        domains: Set<DesktopBridgeDomain>, images: Bool, files: Bool, existing: Set<String>, maximumBytes: Int,
        database: (String, Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        guard dossier.objectValue?["database"]?.objectValue?["id"] == .string(databaseId),
              presentation.objectValue?["databaseId"] == .string(databaseId) else { throw DesktopBridgeError.malformedResponse }
        let originals = try await CompanionDossierDownload.records(client: client, vault: vault, domains: domains,
            collection: "databases", id: databaseId, detail: dossier, images: images, files: files, existing: existing, maximumBytes: maximumBytes)
        let seen = existing.union(originals.map(\.recordId)), remaining = maximumBytes - originals.reduce(0, { $0 + $1.data.count })
        let pages = try await records(client: client, vault: vault, presentation: presentation, domains: domains,
            images: images, files: files, existing: seen, maximumBytes: remaining, database: database)
        return originals + pages
    }
    @MainActor static func records(client: DesktopBridgeClient, vault: String, presentation: JSONValue,
        domains: Set<DesktopBridgeDomain>, images: Bool, files: Bool, existing: Set<String>, maximumBytes: Int,
        database: (String, Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        let supportsBatch = try await client.liveCapabilities().operations.contains("getMobilePageDocuments")
        let batch: (([String]) async throws -> [String: JSONValue])? = supportsBatch ? { ids in
            try await CompanionPageReadBatch.read(vault: vault, pageIds: ids, maximumBytes: PrivateBridgeCache.maximumSelectedCopyBytes) { input in
                try await client.operation(vaultId: vault, method: "getMobilePageDocuments", args: [input])
            }
        } : nil
        return try await capture(vault: vault, presentation: presentation, existing: existing, maximumBytes: maximumBytes,
            batch: batch,
            fetch: { id in try await client.operation(vaultId: vault, method: "getMobilePageDocument", args: [.string(id)]) },
            dependencies: { source, seen, remaining in
                try await CompanionPageDownload.records(client: client, vault: vault, root: source, domains: domains,
                    images: images, files: files, existing: seen, maximumBytes: remaining, recheckRoot: false, database: database)
            })
    }

    @MainActor static func capture(vault: String, presentation: JSONValue, existing: Set<String>, maximumBytes: Int,
        batch: (([String]) async throws -> [String: JSONValue])? = nil,
        fetch: (String) async throws -> JSONValue,
        dependencies: (JSONValue, Set<String>, Int) async throws -> [PrivateBridgeCache.ReadPackRecord]) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        guard presentation.objectValue?["version"] == .int(1), presentation.objectValue?["vaultId"] == .string(vault),
              let database = presentation.objectValue?["databaseId"]?.stringValue,
              presentation.objectValue?["database"]?.objectValue?["id"] == .string(database),
              let rows = presentation.objectValue?["rows"]?.arrayValue, let pages = presentation.objectValue?["pages"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
        let rowIds = Set(rows.compactMap { $0.objectValue?["id"]?.stringValue })
        guard rowIds.count == rows.count, !rowIds.contains(""), rows.allSatisfy({ $0.objectValue?["databaseId"] == .string(database) }),
              pages.keys.allSatisfy(rowIds.contains) else { throw DesktopBridgeError.malformedResponse }
        var pageIds = Set<String>()
        let order = try pages.keys.sorted().map { rowId -> String in
            guard let id = pages[rowId]?.objectValue?["id"]?.stringValue, !id.isEmpty, pageIds.insert(id).inserted else { throw DesktopBridgeError.malformedResponse }
            return id
        }
        let prefetched = try await batch?(order)
        if let prefetched { guard Set(prefetched.keys) == pageIds else { throw DesktopBridgeError.malformedResponse } }
        var output: [PrivateBridgeCache.ReadPackRecord] = [], seen = existing, bytes = 0, metadata: [JSONValue] = [], originals: [String: JSONValue] = [:]
        func retain(_ record: PrivateBridgeCache.ReadPackRecord) throws {
            guard record.recordId == CompanionPageDownload.linkedDatabaseKey || seen.insert(record.recordId).inserted else { return }
            try CompanionReadPackRecords.merge(record, into: &output, vault: vault, bytes: &bytes, maximumBytes: maximumBytes)
            seen.insert(record.recordId)
        }
        for rowId in pages.keys.sorted() {
            try Task.checkCancellation()
            let entry = pages[rowId]!
            let id = entry.objectValue!["id"]!.stringValue!
            let source: JSONValue
            if let cached = prefetched?[id] { source = cached } else { source = try await fetch(id) }
            let document = try CompanionPageDocuments.document(source, vaultId: vault, pageId: id)
            originals[id] = source
            guard let page = document.objectValue?["page"]?.objectValue, page["rowId"] == .string(rowId), page["state"] == .string("active") else { throw DesktopBridgeError.malformedResponse }
            guard page["updatedAt"] == entry.objectValue?["updatedAt"], page["title"] == entry.objectValue?["title"] else {
                throw APIError(status: 409, code: "database_page_changed", message: "Una página de esta base de datos cambió durante la descarga. Vuelve a intentarlo.")
            }
            try retain(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string(id)]), data: JSONEncoder.nodus.encode(source)))
            for record in try await dependencies(source, seen, maximumBytes - bytes) { try retain(record) }
            metadata.append(.object([
                "id": .string(id), "row_id": .string(rowId), "title": page["title"] ?? .string(""), "state": page["state"] ?? .string("active"),
                "parent_page_id": page["parentPageId"] ?? .null, "icon": page["icon"] ?? .null, "cover_blob_hash": page["coverBlobHash"] ?? .null,
                "created_at": page["createdAt"] ?? .null, "updated_at": page["updatedAt"] ?? .null,
                "created_by": page["createdBy"] ?? .null, "updated_by": page["updatedBy"] ?? .null,
                "locked": page["locked"] ?? .bool(false), "full_width": page["fullWidth"] ?? .bool(false), "revision": page["revision"] ?? .int(1)
            ]))
        }
        let final = try await batch?(order)
        if let final { guard final == originals else { throw APIError(status: 409, code: "database_page_changed", message: "Una página de esta base de datos cambió durante la descarga. Vuelve a intentarlo.") } }
        else {
            for id in order {
                guard try await fetch(id) == originals[id] else { throw APIError(status: 409, code: "database_page_changed", message: "Una página de esta base de datos cambió durante la descarga. Vuelve a intentarlo.") }
            }
        }
        if !metadata.isEmpty {
            try retain(.init(domain: .corpus, recordId: key(database), data: JSONEncoder.nodus.encode(JSONValue.object([
                "version": .int(1), "vaultId": .string(vault), "databaseId": .string(database), "pages": .array(metadata)
            ]))))
        }
        return output
    }
}
