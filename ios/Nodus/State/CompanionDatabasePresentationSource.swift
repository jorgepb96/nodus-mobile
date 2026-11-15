import Foundation
import CryptoKit
import NodusKit

/// Selected complete canonical rows plus page dates and real dependency targets.
/// The protected read pack owns their expiry and aggregate size limit.
enum CompanionDatabasePresentationSource {
    static func key(_ database: String) -> String { "companion:database-presentation:v1:\(database)" }
    static func value(_ response: JSONValue, vault: String, database: String, action: String) throws -> JSONValue {
        guard response.objectValue?["version"] == .int(1), response.objectValue?["vaultId"] == .string(vault),
              response.objectValue?["databaseId"] == .string(database), response.objectValue?["action"] == .string(action),
              let data = response.objectValue?["data"] else { throw DesktopBridgeError.malformedResponse }
        return data
    }
    @MainActor static func download(client: DesktopBridgeClient, vault: String, database: String, maximumBytes: Int) async throws -> PrivateBridgeCache.ReadPackRecord {
        let source = try await captureGraph(vault: vault, database: database, maximumBytes: maximumBytes) { method, args in
            try await client.operation(vaultId: vault, method: method, args: args)
        }
        return .init(domain: .corpus, recordId: key(database), data: try JSONEncoder.nodus.encode(source))
    }
    @MainActor static func captureGraph(vault: String, database: String, maximumBytes: Int,
        fetch: (String, [JSONValue]) async throws -> JSONValue) async throws -> JSONValue {
        var sources: [String: JSONValue] = [:], pending = [database], visited = Set<String>(), bytes = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let id = pending.removeFirst(); guard visited.insert(id).inserted else { continue }
            let source = try await capture(vault: vault, database: id, maximumBytes: maximumBytes - bytes, fetch: fetch)
            bytes += try JSONEncoder.nodus.encode(source).count
            guard bytes <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            sources[id] = source
            for dependency in source.objectValue?["derivedDatabaseIds"]?.arrayValue ?? [] {
                guard let id = dependency.stringValue, !id.isEmpty else { throw DesktopBridgeError.malformedResponse }
                if !visited.contains(id) { pending.append(id) }
            }
        }
        // Recheck the entire dependency graph before publishing a selected copy.
        for (id, source) in sources {
            let response = try await fetch("getMobileDatabasePresentationRead", [.object(["action": .string("metadata"), "input": .object(["databaseId": .string(id)])])])
            let metadata = try value(response, vault: vault, database: id, action: "metadata")
            for field in ["database", "columns", "views", "revision", "columnRevisions", "derivedDatabaseIds"] {
                guard metadata.objectValue?[field] == source.objectValue?[field] else {
                    throw APIError(status: 409, code: "database_dependency_changed", message: "Una dependencia de cálculo cambió durante la descarga. Vuelve a intentarlo.")
                }
            }
        }
        guard var root = sources.removeValue(forKey: database)?.objectValue else { throw DesktopBridgeError.malformedResponse }
        root["relatedSources"] = .object(sources)
        let result = JSONValue.object(root)
        guard try JSONEncoder.nodus.encode(result).count <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        return result
    }
    @MainActor static func capture(vault: String, database: String, maximumBytes: Int, fetch: (String, [JSONValue]) async throws -> JSONValue) async throws -> JSONValue {
        func read(_ action: String, _ input: [String: JSONValue]) async throws -> JSONValue {
            try value(await fetch("getMobileDatabasePresentationRead", [.object([
                "action": .string(action), "input": .object(input)
            ])]), vault: vault, database: database, action: action)
        }
        let metadata = try await read("metadata", ["databaseId": .string(database)])
        guard var source = metadata.objectValue, source["database"]?.objectValue?["id"] == .string(database),
              source["columns"]?.arrayValue != nil, source["views"]?.arrayValue != nil, let revision = source["revision"]?.intValue else { throw DesktopBridgeError.malformedResponse }
        var rows: [JSONValue] = [], pages: [String: JSONValue] = [:], dependencies: [String: JSONValue] = [:], relations: [JSONValue] = []
        var relationFormat: Bool?, relationIDs = Set<String>()
        var cursor = JSONValue.null, seen = Set<String>(), cursors = Set<String>(), total: Int?, hash: String?, first: JSONValue?
        var budget = try JSONEncoder.nodus.encode(metadata).count
        repeat {
            try Task.checkCancellation()
            let page = try await read("sourceRows", ["databaseId": .string(database), "cursor": cursor, "limit": .int(200)])
            if first == nil { first = page }
            guard let part = page.objectValue?["rows"]?.arrayValue, part.count <= 200,
                  page.objectValue?["revision"]?.intValue == revision,
                  let count = page.objectValue?["totalCount"]?.intValue, count >= 0, total == nil || total == count,
                  let queryHash = page.objectValue?["queryHash"]?.stringValue, hash == nil || hash == queryHash,
                  let pageDates = page.objectValue?["pages"]?.objectValue, let targets = page.objectValue?["dependencies"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
            for row in part {
                guard row.objectValue?["databaseId"] == .string(database), let id = row.objectValue?["id"]?.stringValue,
                      seen.insert(id).inserted, row.objectValue?["cells"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
            }
            let partIDs = Set(part.compactMap { $0.objectValue?["id"]?.stringValue })
            guard pageDates.keys.allSatisfy(partIDs.contains), targets.keys.allSatisfy(partIDs.contains) else { throw DesktopBridgeError.malformedResponse }
            rows += part; pages.merge(pageDates) { _, new in new }; dependencies.merge(targets) { _, new in new }
            let links = page.objectValue?["relations"]?.arrayValue
            guard relationFormat == nil || relationFormat == (links != nil) else { throw DesktopBridgeError.malformedResponse }
            relationFormat = links != nil
            for link in links ?? [] {
                guard let fields = link.objectValue, let id = fields["id"]?.stringValue, !id.isEmpty, relationIDs.insert(id).inserted,
                      fields["row_id"]?.stringValue.map(partIDs.contains) == true, fields["column_id"]?.stringValue?.isEmpty == false,
                      fields["target_kind"]?.stringValue != nil, fields["target_id"]?.stringValue?.isEmpty == false,
                      fields["position"]?.doubleValue?.isFinite == true, fields["created_at"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
                relations.append(link)
            }
            budget += try JSONEncoder.nodus.encode(page).count
            guard budget <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            total = count; hash = queryHash; cursor = page.objectValue?["nextCursor"] ?? .null
            guard rows.count <= count, page.objectValue?["hasMore"]?.boolValue == (cursor != .null) else { throw DesktopBridgeError.malformedResponse }
            if let next = cursor.stringValue { guard !part.isEmpty, cursors.insert(next).inserted else { throw DesktopBridgeError.malformedResponse } }
            else { guard cursor == .null, rows.count == count else { throw DesktopBridgeError.malformedResponse } }
        } while cursor != .null
        guard try await read("metadata", ["databaseId": .string(database)]) == metadata,
              try await read("sourceRows", ["databaseId": .string(database), "cursor": .null, "limit": .int(200)]) == first else {
            throw APIError(status: 409, code: "database_changed", message: "La base de datos cambió durante la descarga. Vuelve a intentarlo.")
        }
        source["version"] = .int(1); source["vaultId"] = .string(vault); source["databaseId"] = .string(database)
        source["rows"] = .array(rows); source["pages"] = .object(pages); source["dependencies"] = .object(dependencies)
        if relationFormat == true { source["relations"] = .array(relations) }
        let data = try JSONEncoder.nodus.encode(JSONValue.object(source))
        guard data.count <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        return .object(source)
    }
    @MainActor static func downloaded(session: SpaceSession, database: String) async throws -> JSONValue {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        guard let data = try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: key(database)).first else {
            throw APIError(status: 404, code: "database_copy_missing", message: "Descarga esta base de datos para consultar sus vistas sin conexión. Si ya estaba descargada, renueva la copia.")
        }
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
        guard value.objectValue?["version"] == .int(1), value.objectValue?["vaultId"] == .string(vault),
              value.objectValue?["databaseId"] == .string(database), value.objectValue?["database"]?.objectValue?["id"] == .string(database),
              value.objectValue?["columns"]?.arrayValue != nil, value.objectValue?["views"]?.arrayValue != nil,
              value.objectValue?["rows"]?.arrayValue != nil, value.objectValue?["pages"]?.objectValue != nil,
              value.objectValue?["dependencies"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
        var root = try await overlay(value, session: session, database: database).objectValue!
        if let related = value.objectValue?["relatedSources"]?.objectValue {
            var projected: [String: JSONValue] = [:]
            for (id, source) in related {
                guard id != database, source.objectValue?["version"] == .int(1), source.objectValue?["vaultId"] == .string(vault),
                      source.objectValue?["databaseId"] == .string(id), source.objectValue?["database"]?.objectValue?["id"] == .string(id),
                      source.objectValue?["columns"]?.arrayValue != nil, source.objectValue?["views"]?.arrayValue != nil,
                      source.objectValue?["rows"]?.arrayValue != nil, source.objectValue?["pages"]?.objectValue != nil,
                      source.objectValue?["dependencies"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                projected[id] = try await overlay(source, session: session, database: id)
            }
            root["relatedSources"] = .object(projected)
            root["localRevision"] = .string(SHA256.hash(data: try JSONEncoder.nodus.encode(JSONValue.object(root))).map { String(format: "%02x", $0) }.joined())
        }
        return .object(root)
    }
    @MainActor private static func overlay(_ value: JSONValue, session: SpaceSession, database: String) async throws -> JSONValue {
        guard var source = value.objectValue, let rows = source["rows"]?.arrayValue, let columns = source["columns"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        var rawRows: [Row] = [], rawCells: [Row] = [], original: [String: [String: JSONValue]] = [:]
        var rawColumns: [Row] = [], originalColumns: [String: [String: JSONValue]] = [:]
        let revisions = source["columnRevisions"]?.objectValue ?? [:]
        for column in columns {
            guard let object = column.objectValue, let id = object["id"]?.stringValue, object["databaseId"] == .string(database) else { throw DesktopBridgeError.malformedResponse }
            originalColumns[id] = object
            rawColumns.append(Row(["id": .string(id), "database_id": .string(database), "name": object["name"] ?? .null,
                "type": object["type"] ?? .null, "position": object["position"] ?? .int(0), "revision": revisions[id] ?? .int(1),
                "config_json": .string(String(decoding: try JSONEncoder.nodus.encode(object["config"] ?? .object([:])), as: UTF8.self))]))
        }
        for row in rows {
            guard let object = row.objectValue, let id = object["id"]?.stringValue, object["databaseId"] == .string(database),
                  let cells = object["cells"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
            original[id] = object
            rawRows.append(Row(["id": .string(id), "database_id": .string(database), "position": object["position"] ?? .int(0),
                "revision": object["revision"] ?? .int(1), "created_at": object["createdAt"] ?? .null, "updated_at": object["updatedAt"] ?? .null,
                "created_by": object["createdBy"] ?? .null, "updated_by": object["updatedBy"] ?? .null, "unique_sequence": object["uniqueSequence"] ?? .null]))
            for (column, cell) in cells { rawCells.append(Row(["row_id": .string(id), "column_id": .string(column), "database_id": .string(database), "value_text": cell])) }
        }
        let queue = try await MutationOutbox.open(spaceId: session.connection.storageId, directory: URL.applicationSupportDirectory.appendingPathComponent("spaces", isDirectory: true))
        let rawRelations = (source["relations"]?.arrayValue ?? []).compactMap { $0.objectValue.map(Row.init) }
        let projection = try await queue.companionContentProjection(["db_rows": rawRows, "db_cells": rawCells, "db_columns": rawColumns, "db_relations": rawRelations])
        let local = PagesDatabasesParity.rows(databaseId: database, in: projection)
        var changed = (projection["db_rows"] ?? []).filter { $0.string("database_id") == database }.count != rawRows.count
        if source["relations"] != nil {
            let known = Set(local.map(\.id))
            let links = (projection["db_relations"] ?? []).filter { known.contains($0.string("row_id") ?? "") }
            if links != rawRelations { changed = true }
            source["relations"] = .array(links.map { .object($0.columns) })
            var dependencies: [String: [String: [JSONValue]]] = [:]
            for link in links.sorted(by: { left, right in
                let a = left.double("position") ?? 0, b = right.double("position") ?? 0
                return a == b ? (left.string("id") ?? "") < (right.string("id") ?? "") : a < b
            }) where link.string("target_kind") == "db_row" {
                guard let row = link.string("row_id"), let column = link.string("column_id"), let target = link.string("target_id") else { throw DesktopBridgeError.malformedResponse }
                dependencies[row, default: [:]][column, default: []].append(.string(target))
            }
            source["dependencies"] = .object(dependencies.mapValues { .object($0.mapValues(JSONValue.array)) })
        }
        source["columns"] = .array((projection["db_columns"] ?? []).filter { $0.string("database_id") == database }.sorted { ($0.double("position") ?? 0) < ($1.double("position") ?? 0) }.map { column in
            let id = column.string("id") ?? ""
            var object = originalColumns[id] ?? ["id": .string(id), "databaseId": .string(database), "options": .array([])]
            object["name"] = column.columns["name"]; object["type"] = column.columns["type"]; object["position"] = column.columns["position"]
            object["config"] = column.embeddedJSON("config_json") ?? .object([:])
            if column.string("mobileSyncState") != nil { changed = true }
            return .object(object)
        })
        source["rows"] = .array(local.map { row in
            var object = original[row.id] ?? ["id": .string(row.id), "databaseId": .string(database)]
            let captured = projection["db_rows"]?.first { $0.string("id") == row.id }
            if captured?.string("mobileSyncState") != nil || projection["db_cells"]?.contains(where: { $0.string("row_id") == row.id && $0.string("mobileSyncState") != nil }) == true { changed = true }
            object["position"] = .double(row.position); object["revision"] = .int(Int64(row.revision))
            object["cells"] = .object(row.cells.mapValues(JSONValue.string))
            object["createdAt"] = captured?.columns["created_at"] ?? object["createdAt"] ?? .null
            object["updatedAt"] = captured?.columns["updated_at"] ?? object["updatedAt"] ?? .null
            object["createdBy"] = captured?.columns["created_by"] ?? object["createdBy"] ?? .null
            object["updatedBy"] = captured?.columns["updated_by"] ?? object["updatedBy"] ?? .null
            object["uniqueSequence"] = captured?.columns["unique_sequence"] ?? object["uniqueSequence"] ?? .null
            if let latest = projection["db_cells"]?.filter({ $0.string("row_id") == row.id && $0.string("mobileSyncState") != nil }).max(by: { ($0.string("updated_at") ?? "") < ($1.string("updated_at") ?? "") }),
               let stamp = latest.string("updated_at"), stamp > (object["updatedAt"]?.stringValue ?? "") {
                object["updatedAt"] = .string(stamp); object["updatedBy"] = latest.columns["updated_by"] ?? object["updatedBy"]
            }
            return .object(object)
        })
        source["localChanges"] = .bool(changed)
        source["localRevision"] = .string(SHA256.hash(data: try JSONEncoder.nodus.encode(JSONValue.object(source))).map { String(format: "%02x", $0) }.joined())
        return .object(source)
    }
}
