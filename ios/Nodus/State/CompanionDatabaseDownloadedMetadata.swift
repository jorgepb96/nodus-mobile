import Foundation
import NodusKit

/// Selected linked dossiers and row pages retain their real physical owners.
enum CompanionDatabaseDownloadedMetadata {
    @MainActor static func projectedDossier(session: SpaceSession, database: String, payload: JSONValue) async throws -> JSONValue {
        guard var object = payload.objectValue, object["database"]?.objectValue?["id"] == .string(database) else { throw DesktopBridgeError.malformedResponse }
        var tables = ["db_databases": [Row(object["database"]!.objectValue!)]]
        let fields = ["columns":"db_columns", "rows":"db_rows", "cells":"db_cells", "views":"db_views", "options":"db_select_options", "relations":"db_relations", "attachments":"db_attachments"]
        for (field, table) in fields {
            guard let values = object[field]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            tables[table] = try values.map { value in guard let row = value.objectValue else { throw DesktopBridgeError.malformedResponse }; return Row(row) }
        }
        let queue = try await MutationOutbox.open(spaceId: session.connection.storageId, directory: URL.applicationSupportDirectory.appendingPathComponent("spaces", isDirectory: true))
        tables = try await queue.companionContentProjection(tables)
        guard let owner = tables["db_databases"]?.first(where: { $0.string("id") == database }) else { throw APIError(status: 404, code: "database_deleted_locally", message: "Esta base de datos se ha eliminado en el móvil.") }
        object["database"] = .object(owner.columns)
        let rows = (tables["db_rows"] ?? []).filter { $0.string("database_id") == database }
        let rowIds = Set(rows.compactMap { $0.string("id") })
        let columns = (tables["db_columns"] ?? []).filter { $0.string("database_id") == database }
        let columnIds = Set(columns.compactMap { $0.string("id") })
        tables["db_rows"] = rows; tables["db_columns"] = columns
        tables["db_cells"] = (tables["db_cells"] ?? []).filter { rowIds.contains($0.string("row_id") ?? "") && columnIds.contains($0.string("column_id") ?? "") }
        for table in ["db_relations", "db_attachments"] { tables[table] = (tables[table] ?? []).filter { rowIds.contains($0.string("row_id") ?? "") } }
        for (field, table) in fields { object[field] = .array((tables[table] ?? []).map { .object($0.columns) }) }
        object["total"] = .int(Int64(rows.count)); object["limit"] = .int(Int64(rows.count)); object["offset"] = .int(0); object["hasMore"] = .bool(false)
        return .object(object)
    }
    static func calculatedRow(payload: JSONValue, source: JSONValue, rowId: String) throws -> JSONValue {
        guard var result = payload.objectValue, let database = result["database"]?.objectValue?["id"],
              source.objectValue?["databaseId"] == database, let columns = source.objectValue?["columns"]?.arrayValue,
              let row = source.objectValue?["rows"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(rowId) }),
              row.objectValue?["databaseId"] == database, let values = row.objectValue?["cells"]?.objectValue,
              let cells = result["cells"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        let computed = Set(columns.filter { ["formula", "rollup"].contains($0.objectValue?["type"]?.stringValue ?? "") }.compactMap { $0.objectValue?["id"]?.stringValue })
        var retained = cells.filter { $0.objectValue?["row_id"] != .string(rowId) || !computed.contains($0.objectValue?["column_id"]?.stringValue ?? "") }
        for column in computed {
            let value = values[column] ?? .null, error = row.objectValue?["formulaErrors"]?.objectValue?[column], color = row.objectValue?["formulaColors"]?.objectValue?[column]
            if value != .null || error != nil {
                guard value == .null || value.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
                retained.append(.object(["row_id": .string(rowId), "column_id": .string(column), "database_id": database, "value_text": value, "error": error ?? .null, "color": color ?? .null]))
            }
        }
        result["cells"] = .array(retained)
        return .object(result)
    }
    @MainActor static func merge(session: SpaceSession, into original: [String: [Row]]) async throws -> [String: [Row]] {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        var result = original
        func append(_ rows: [Row], table: String) throws {
            guard let keys = MutableTable(rawValue: table)?.identityFields, !keys.isEmpty else { throw DesktopBridgeError.malformedResponse }
            for row in rows {
                guard keys.allSatisfy({ row.string($0)?.isEmpty == false }) else { throw DesktopBridgeError.malformedResponse }
                if result[table]?.contains(where: { current in keys.allSatisfy { current.string($0) == row.string($0) } }) != true { result[table, default: []].append(row) }
            }
        }
        for bytes in try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: CompanionPageDownload.linkedDatabaseKey) {
            let source = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
            guard source.objectValue?["version"] == .int(1), source.objectValue?["vaultId"] == .string(vault),
                  let databases = source.objectValue?["databases"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
            for (id, payload) in databases where result["db_databases"]?.contains(where: { $0.string("id") == id }) != true {
                guard let database = payload.objectValue?["database"]?.objectValue, database["id"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
                try append([Row(database)], table: "db_databases")
                for (field, table) in ["columns":"db_columns", "rows":"db_rows", "cells":"db_cells", "views":"db_views", "options":"db_select_options", "relations":"db_relations", "attachments":"db_attachments"] {
                    guard let values = payload.objectValue?[field]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
                    try append(values.map { value in guard let row = value.objectValue else { throw DesktopBridgeError.malformedResponse }; return Row(row) }, table: table)
                }
            }
        }
        for database in result["db_databases"] ?? [] {
            guard let id = database.string("id") else { throw DesktopBridgeError.malformedResponse }
            let rowIds = Set((result["db_rows"] ?? []).filter { $0.string("database_id") == id }.compactMap { $0.string("id") })
            guard let bytes = try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: CompanionDatabasePageDownload.key(id)).first else { continue }
            let source = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
            guard source.objectValue?["version"] == .int(1), source.objectValue?["vaultId"] == .string(vault),
                  source.objectValue?["databaseId"] == .string(id), let pages = source.objectValue?["pages"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            try append(pages.map { value in
                guard let row = value.objectValue, row["row_id"]?.stringValue.map(rowIds.contains) == true else { throw DesktopBridgeError.malformedResponse }
                return Row(row)
            }, table: "pages")
        }
        return result
    }
}
