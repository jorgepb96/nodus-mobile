import Foundation
import NodusKit

/// Only a selected page's explicit references are followed. Every record commits
/// with the parent read pack; cancellation or a changed revision leaves no copy.
enum CompanionPageDownload {
    static let linkedDatabaseKey = "companion:linked-databases:v1"
    @MainActor static func records(client: DesktopBridgeClient, vault: String, root: JSONValue,
        domains: Set<DesktopBridgeDomain>, images: Bool, files: Bool, existing: Set<String>, maximumBytes: Int,
        database: (String, Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        var output: [PrivateBridgeCache.ReadPackRecord] = [], seen = existing, used = 0
        var pending = [root], pages = Set<String>(), synced = Set<String>(), views = Set<String>()
        var queries:[([JSONValue],JSONValue)]=[]
        var documents: [(String, JSONValue)] = [], databases: [String: JSONValue] = [:]
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
            guard pages.count <= 256 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            _ = try CompanionPageDocuments.document(source, vaultId: vault, pageId: pageId)
            documents.append((pageId, source))
            try retain("getMobilePageDocument", [.string(pageId)], source)
            let resources = try await CompanionDossierDownload.records(client: client, vault: vault, domains: domains,
                collection: "pages", id: pageId, detail: .object([:]), images: images, files: files, existing: seen,
                maximumBytes: maximumBytes - used)
            output.append(contentsOf: resources); used += resources.reduce(0) { $0 + $1.data.count }; seen.formUnion(resources.map(\.recordId))
            guard let dependencies = source.objectValue?["dependencies"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            for dependency in dependencies {
                if dependency.objectValue?["kind"] == .string("syncedBlock"), let id = dependency.objectValue?["id"]?.stringValue {
                    guard synced.insert(id).inserted else { continue }
                    let original = try await client.operation(vaultId: vault, method: "getMobileSyncedBlockSource", args: [.string(id)])
                    guard original.objectValue?["version"] == .int(1), original.objectValue?["vaultId"] == .string(vault), let value = original.objectValue?["source"] else { throw DesktopBridgeError.malformedResponse }
                    try retain("getMobileSyncedBlockSource", [.string(id)], original)
                    if value != .null {
                        guard value.objectValue?["block"]?.objectValue?["id"] == .string(id), let owner = value.objectValue?["page"]?.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        if !pages.contains(owner) { pending.append(try await client.operation(vaultId: vault, method: "getMobilePageDocument", args: [.string(owner)])) }
                    }
                } else if dependency.objectValue?["kind"] == .string("linkedDatabase"), let view = dependency.objectValue?["viewId"]?.stringValue {
                    let localFilter = dependency.objectValue?["localFilter"] ?? .null
                    let dependencyKey = try CompanionDocumentOutbox.operationKey(view, [localFilter])
                    guard views.insert(dependencyKey).inserted else { continue }
                    let definitionArgs = [JSONValue.object(["action": .string("definition"), "input": .string(view)])]
                    let definition = try await client.operation(vaultId: vault, method: "getMobileLinkedDatabaseRead", args: definitionArgs)
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
                            if seen.insert(CompanionDatabasePresentationSource.key(databaseId)).inserted {
                                let presentation = try await CompanionDatabasePresentationSource.download(client: client, vault: vault, database: databaseId, maximumBytes: maximumBytes - used)
                                used += presentation.data.count; output.append(presentation)
                            }
                        }
                    }
                    for tab in tabs {
                        var cursor = JSONValue.null, cursors = Set<String>(), ids = Set<String>(), revision: String?, total: Int?
                        repeat {
                            try Task.checkCancellation()
                            let query = JSONValue.object(["viewId": .string(view), "sourceId": tab, "localFilter": localFilter, "cursor": cursor, "limit": .int(30)])
                            let args = [JSONValue.object(["action": .string("rows"), "input": query])]
                            let response = try await client.operation(vaultId: vault, method: "getMobileLinkedDatabaseRead", args: args)
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
                    let final = try await client.operation(vaultId: vault, method: "getMobileLinkedDatabaseRead", args: definitionArgs)
                    guard definition == final else { throw APIError(status: 409, code: "page_dependency_changed", message: "La vista enlazada cambió durante la descarga. Vuelve a intentarlo.") }
                } else { throw DesktopBridgeError.malformedResponse }
            }
        }
        for (args,first) in queries {
            let final=try await client.operation(vaultId:vault,method:"getMobileLinkedDatabaseRead",args:args)
            guard final == first else {throw APIError(status:409,code:"page_dependency_changed",message:"Los datos de la vista enlazada cambiaron durante la descarga. Vuelve a intentarlo.")}
        }
        for (id, source) in documents {
            let final = try await client.operation(vaultId: vault, method: "getMobilePageDocument", args: [.string(id)])
            guard final == source else { throw APIError(status: 409, code: "page_dependency_changed", message: "Una página cambió durante la descarga. Vuelve a intentarlo.") }
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
