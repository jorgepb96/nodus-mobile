import Foundation
import NodusKit

/// Only a selected page's explicit references are followed. Every record commits
/// with the parent read pack; cancellation or a changed revision leaves no copy.
enum CompanionPageDownload {
    static let linkedDatabaseKey = "companion:linked-databases:v1"
    @MainActor static func records(client: DesktopBridgeClient, vault: String, root: JSONValue,
        domains: Set<DesktopBridgeDomain>, images: Bool, files: Bool, existing: Set<String>, maximumBytes: Int,
        recheckRoot: Bool = true, database: (String, Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        let supportsBatch = try await client.liveCapabilities().operations.contains("getMobilePageDocuments")
        return try await capture(vault: vault, root: root, existing: existing, maximumBytes: maximumBytes,
            recheckRoot: recheckRoot, supportsBatch: supportsBatch,
            operation: { method, args in try await client.operation(vaultId: vault, method: method, args: args) },
            resources: { collection, id, detail, catalogue, seen, remaining in
                try await CompanionDossierDownload.records(client: client, vault: vault, domains: domains, collection: collection,
                    id: id, detail: detail, images: images, files: files, existing: seen, maximumBytes: remaining, fileCatalogue: catalogue)
            },
            presentation: { id, remaining in try await CompanionDatabasePresentationSource.download(client: client, vault: vault, database: id, maximumBytes: remaining) },
            database: database)
    }

    /// The same selected dependency walk used by the real connection. Injected
    /// transports allow its complete closure and rejection paths to be verified.
    @MainActor static func capture(vault: String, root: JSONValue, existing: Set<String>, maximumBytes: Int,
        recheckRoot: Bool = true, supportsBatch: Bool,
        operation: @escaping (String, [JSONValue]) async throws -> JSONValue,
        resources: (String, String, JSONValue, JSONValue?, Set<String>, Int) async throws -> [PrivateBridgeCache.ReadPackRecord],
        presentation: (String, Int) async throws -> PrivateBridgeCache.ReadPackRecord,
        database: (String, Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        var output: [PrivateBridgeCache.ReadPackRecord] = [], seen = existing, used = 0
        var pending = [root], pages = Set<String>(), synced = Set<String>(), views = Set<String>()
        var queries:[([JSONValue],JSONValue)]=[]
        var documents: [(String, JSONValue)] = [], databases: [String: JSONValue] = [:]
        func readPages(_ ids: [String]) async throws -> [String: JSONValue] {
            if supportsBatch {
                return try await CompanionPageReadBatch.read(vault: vault, pageIds: ids, maximumBytes: PrivateBridgeCache.maximumSelectedCopyBytes) { input in
                    try await operation("getMobilePageDocuments", [input])
                }
            }
            var result: [String: JSONValue] = [:]
            for id in ids { result[id] = try await operation("getMobilePageDocument", [.string(id)]) }
            return result
        }
        func retainRecord(_ record: PrivateBridgeCache.ReadPackRecord) throws {
            guard record.recordId == linkedDatabaseKey || seen.insert(record.recordId).inserted else { return }
            try CompanionReadPackRecords.merge(record, into: &output, vault: vault, bytes: &used, maximumBytes: maximumBytes)
            seen.insert(record.recordId)
        }
        func retain(_ method: String, _ args: [JSONValue], _ value: JSONValue) throws {
            let key = try CompanionDocumentOutbox.operationKey(method, args)
            guard seen.insert(key).inserted else { return }
            let data = try JSONEncoder.nodus.encode(value)
            guard data.count <= maximumBytes - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            used += data.count; output.append(.init(domain: .corpus, recordId: key, data: data))
        }
        while !pending.isEmpty {
            try Task.checkCancellation()
            let source = pending.removeFirst()
            guard let pageId = source.objectValue?["document"]?.objectValue?["page"]?.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            guard pages.insert(pageId).inserted else { continue }
            _ = try CompanionPageDocuments.document(source, vaultId: vault, pageId: pageId)
            guard let assets = source.objectValue?["assets"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            documents.append((pageId, source))
            try retain("getMobilePageDocument", [.string(pageId)], source)
            let pageResources = try await resources("pages", pageId, .object([:]),
                .object(["version": .int(1), "collection": .string("pages"), "id": .string(pageId), "files": .array(assets)]), seen, maximumBytes - used)
            output.append(contentsOf: pageResources); used += pageResources.reduce(0) { $0 + $1.data.count }; seen.formUnion(pageResources.map(\.recordId))
            guard used <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            guard let dependencies = source.objectValue?["dependencies"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            for dependency in dependencies {
                if dependency.objectValue?["kind"] == .string("syncedBlock"), let id = dependency.objectValue?["id"]?.stringValue {
                    guard synced.insert(id).inserted else { continue }
                    let original = try await operation("getMobileSyncedBlockSource", [.string(id)])
                    guard original.objectValue?["version"] == .int(1), original.objectValue?["vaultId"] == .string(vault), let value = original.objectValue?["source"] else { throw DesktopBridgeError.malformedResponse }
                    try retain("getMobileSyncedBlockSource", [.string(id)], original)
                    if value != .null {
                        guard value.objectValue?["block"]?.objectValue?["id"] == .string(id), let owner = value.objectValue?["page"]?.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        if !pages.contains(owner) { pending.append(try await operation("getMobilePageDocument", [.string(owner)])) }
                    }
                } else if dependency.objectValue?["kind"] == .string("linkedDatabase"), let view = dependency.objectValue?["viewId"]?.stringValue {
                    let localFilter = dependency.objectValue?["localFilter"] ?? .null
                    let dependencyKey = try CompanionDocumentOutbox.operationKey(view, [localFilter])
                    guard views.insert(dependencyKey).inserted else { continue }
                    let definitionArgs = [JSONValue.object(["action": .string("definition"), "input": .string(view)])]
                    let definition = try await operation("getMobileLinkedDatabaseRead", definitionArgs)
                    guard definition.objectValue?["version"] == .int(1), definition.objectValue?["vaultId"] == .string(vault),
                        definition.objectValue?["data"]?.objectValue?["viewId"] == .string(view),
                        let sources = definition.objectValue?["data"]?.objectValue?["sources"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
                    try retain("getMobileLinkedDatabaseRead", definitionArgs, definition)
                    var tabs: [JSONValue] = [.null]
                    for source in sources {
                        guard let sourceId = source.objectValue?["sourceId"]?.stringValue, let databaseId = source.objectValue?["databaseId"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        tabs.append(.string(sourceId))
                        if databases[databaseId] == nil {
                            let payload = try await database(databaseId, maximumBytes - used)
                            guard payload.objectValue?["database"]?.objectValue?["id"] == .string(databaseId), payload.objectValue?["rows"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                            let count = try JSONEncoder.nodus.encode(payload).count
                            guard count <= maximumBytes - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                            used += count; databases[databaseId] = payload
                            let presentationKey = CompanionDatabasePresentationSource.key(databaseId)
                            let needsPresentation = !seen.contains(presentationKey)
                            if needsPresentation || !seen.contains(CompanionDatabasePageDownload.key(databaseId)) {
                                let presentation = try await presentation(databaseId, needsPresentation ? maximumBytes - used : PrivateBridgeCache.maximumSelectedCopyBytes)
                                if needsPresentation { seen.insert(presentationKey); used += presentation.data.count; output.append(presentation) }
                                let source = try JSONDecoder.nodus.decode(JSONValue.self, from: presentation.data)
                                let attachments = try await resources("databases", databaseId, payload, nil, seen, maximumBytes - used)
                                for record in attachments { try retainRecord(record) }
                                if !seen.contains(CompanionDatabasePageDownload.key(databaseId)) {
                                    let rowPages = try await CompanionDatabasePageDownload.capture(vault: vault, presentation: source, existing: seen,
                                        maximumBytes: maximumBytes - used, batch: readPages,
                                        fetch: { id in try await operation("getMobilePageDocument", [.string(id)]) },
                                        dependencies: { source, _, _ in
                                            guard let id = source.objectValue?["document"]?.objectValue?["page"]?.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                                            if !pages.contains(id) { pending.append(source) }
                                            return []
                                        })
                                    for record in rowPages { try retainRecord(record) }
                                }
                            }
                        }
                    }
                    for tab in tabs {
                        var cursor = JSONValue.null, cursors = Set<String>(), ids = Set<String>(), revision: String?, total: Int?
                        repeat {
                            try Task.checkCancellation()
                            let query = JSONValue.object(["viewId": .string(view), "sourceId": tab, "localFilter": localFilter, "cursor": cursor, "limit": .int(30)])
                            let args = [JSONValue.object(["action": .string("rows"), "input": query])]
                            let response = try await operation("getMobileLinkedDatabaseRead", args)
                            guard response.objectValue?["version"] == .int(1), response.objectValue?["vaultId"] == .string(vault), let page = response.objectValue?["data"]?.objectValue,
                                let current = page["revision"]?.stringValue, revision == nil || revision == current,
                                let count = page["totalCount"]?.intValue, count >= 0, total == nil || total == count,
                                let rows = page["rows"]?.arrayValue, rows.count <= 30 else { throw DesktopBridgeError.malformedResponse }
                            if revision == nil {queries.append((args,response))}
                            revision = current; total = count
                            for row in rows { guard let id = row.objectValue?["id"]?.stringValue, ids.insert(id).inserted else { throw DesktopBridgeError.malformedResponse } }
                            cursor = page["nextCursor"] ?? .null
                            guard page["hasMore"]?.boolValue == (cursor != .null), ids.count <= count else { throw DesktopBridgeError.malformedResponse }
                            if let next = cursor.stringValue { guard !rows.isEmpty, cursors.insert(next).inserted else { throw DesktopBridgeError.malformedResponse } }
                            else { guard cursor == .null, ids.count == count else { throw DesktopBridgeError.malformedResponse } }
                            try retain("getMobileLinkedDatabaseRead", args, response)
                        } while cursor != .null
                    }
                    let final = try await operation("getMobileLinkedDatabaseRead", definitionArgs)
                    guard definition == final else { throw APIError(status: 409, code: "page_dependency_changed", message: "La vista enlazada cambió durante la descarga. Vuelve a intentarlo.") }
                } else { throw DesktopBridgeError.malformedResponse }
            }
        }
        for (args,first) in queries {
            let final=try await operation("getMobileLinkedDatabaseRead",args)
            guard final == first else {throw APIError(status:409,code:"page_dependency_changed",message:"Los datos de la vista enlazada cambiaron durante la descarga. Vuelve a intentarlo.")}
        }
        let toVerify = documents.filter { recheckRoot || $0.0 != root.objectValue?["document"]?.objectValue?["page"]?.objectValue?["id"]?.stringValue }
        if !toVerify.isEmpty {
            let final = try await readPages(toVerify.map(\.0))
            for (id, source) in toVerify {
                guard final[id] == source else { throw APIError(status: 409, code: "page_dependency_changed", message: "Una página cambió durante la descarga. Vuelve a intentarlo.") }
            }
        }
        if !databases.isEmpty {
            let data = try JSONEncoder.nodus.encode(JSONValue.object(["version": .int(1), "vaultId": .string(vault), "databases": .object(databases)]))
            // The individual dossiers were reserved above; charge only the envelope.
            let reserved = try databases.values.reduce(0) { $0 + (try JSONEncoder.nodus.encode($1).count) }
            guard data.count - reserved <= maximumBytes - used else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            output.append(.init(domain: .corpus, recordId: linkedDatabaseKey, data: data))
        }
        return output
    }
}
