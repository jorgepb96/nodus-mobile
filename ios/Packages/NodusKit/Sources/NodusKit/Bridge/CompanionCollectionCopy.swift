import CryptoKit
import Foundation

/// Complete selected public dossiers, not a projection of the entire vault.
/// Linked summaries are retained inside their owning dossier and never become
/// independently downloaded neighbours merely because they appear there.
public struct CompanionCollectionCopy: Sendable {
    public let collection: CollectionDescriptor
    private let entries: [JSONValue]
    private let revision: String

    public static func recordId(path: String) throws -> String {
        guard Collections[path] != nil else { throw DesktopBridgeError.permissionDenied }
        return "companion:collection:v1:\(path)"
    }

    public init(path: String, copies: [JSONValue]) throws {
        guard let collection = Collections[path], !copies.isEmpty else { throw DesktopBridgeError.malformedResponse }
        var seen = Set<String>(), entries: [JSONValue] = []
        for copy in copies {
            guard let value = copy.objectValue, value["version"] == .int(1), value["path"] == .string(path),
                  let rows = value["entries"]?.arrayValue, !rows.isEmpty else { throw DesktopBridgeError.malformedResponse }
            var ownIds = Set<String>()
            for row in rows {
                guard let summary = row.objectValue?["summary"]?.objectValue,
                      let id = summary[collection.idField]?.stringValue, !id.isEmpty, ownIds.insert(id).inserted,
                      let detail = row.objectValue?["detail"]?.objectValue,
                      let primary = Self.primaryRow(collection, detail: detail),
                      primary[collection.idField]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
                if path == "databases" {
                    guard let databaseRows = detail["rows"]?.arrayValue, let total = detail["total"]?.intValue,
                          total >= 0, databaseRows.count == total, detail["hasMore"] == .bool(false),
                          detail["offset"] == .int(0),
                          ["columns", "views", "options", "cells", "relations", "attachments"].allSatisfy({ detail[$0]?.arrayValue != nil })
                    else { throw DesktopBridgeError.malformedResponse }
                    var rowIds = Set<String>()
                    for item in databaseRows {
                        guard let rowId = item.objectValue?["id"]?.stringValue, !rowId.isEmpty,
                              item.objectValue?["database_id"]?.stringValue == id, rowIds.insert(rowId).inserted else { throw DesktopBridgeError.malformedResponse }
                    }
                    for field in ["cells", "relations", "attachments"] {
                        guard detail[field]!.arrayValue!.allSatisfy({ item in
                            guard let owner = item.objectValue?["row_id"]?.stringValue else { return false }
                            return rowIds.contains(owner)
                        }) else { throw DesktopBridgeError.malformedResponse }
                    }
                }
                if seen.insert(id).inserted { entries.append(row) }
            }
        }
        self.collection = collection; self.entries = entries
        let hash = SHA256.hash(data: try JSONEncoder.nodus.encode(JSONValue.array(entries))).map { String(format: "%02x", $0) }.joined()
        revision = "companion:\(path):\(hash)"
    }

    public static func primaryRow(_ collection: CollectionDescriptor, detail: [String: JSONValue]) -> [String: JSONValue]? {
        detail[collection.detailKey]?.objectValue
            ?? (collection.path == "study-materials" ? detail["document"]?.objectValue : nil)
    }

    public static func downloaded(cache: PrivateBridgeCache, vaultId: String, path: String) async throws -> Self? {
        let data = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: recordId(path: path))
        return data.isEmpty ? nil : try Self(path: path, copies: data.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) })
    }

    public func nativeResponse(path: String, query: [URLQueryItem], percentEncoded: Bool) throws -> DesktopBridgeResponse? {
        let parts = try path.split(separator: "/").map { part -> String in
            guard !percentEncoded || String(part).removingPercentEncoding != nil else { throw DesktopBridgeError.invalidOrigin }
            return percentEncoded ? String(part).removingPercentEncoding! : String(part)
        }
        guard parts.first == collection.path, (1...2).contains(parts.count),
              Set(query.map(\.name)).count == query.count else { return nil }
        func argument(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let offset = PageBounds.clampedOffset(argument("offset").flatMap(Int.init))
        let limit = PageBounds.clampedLimit(argument("limit").flatMap(Int.init))
        let result: JSONValue
        if parts.count == 1 {
            guard query.allSatisfy({ ["limit", "offset", "q"].contains($0.name) }) else { return nil }
            let needle = (argument("q") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rows = entries.compactMap { $0.objectValue?["summary"] }.filter { row in
                needle.isEmpty || row.objectValue!.values.contains { value in
                    guard case .string(let text) = value else { return false }
                    return text.lowercased().contains(needle)
                }
            }
            let start = min(offset, rows.count), end = min(rows.count, start + limit)
            result = .object([collection.listKey: .array(Array(rows[start..<end])), "total": .int(Int64(rows.count)),
                "limit": .int(Int64(limit)), "offset": .int(Int64(offset)), "hasMore": .bool(end < rows.count), "revision": .string(revision)])
        } else {
            guard let entry = entries.first(where: { $0.objectValue?["summary"]?.objectValue?[collection.idField] == .string(parts[1]) }),
                  var detail = entry.objectValue?["detail"]?.objectValue else {
                throw CopyError.dossierNotDownloaded
            }
            if collection.path == "databases" {
                guard query.allSatisfy({ ["limit", "offset"].contains($0.name) }) else { return nil }
                let rows = detail["rows"]!.arrayValue!, start = min(offset, rows.count), end = min(rows.count, start + limit)
                let page = Array(rows[start..<end]), ids = Set(page.compactMap { $0.objectValue?["id"]?.stringValue })
                detail["rows"] = .array(page)
                for field in ["cells", "relations", "attachments"] {
                    detail[field] = .array(detail[field]!.arrayValue!.filter { ids.contains($0.objectValue?["row_id"]?.stringValue ?? "") })
                }
                detail["limit"] = .int(Int64(limit)); detail["offset"] = .int(Int64(offset)); detail["hasMore"] = .bool(end < rows.count)
            } else if !query.isEmpty { return nil }
            detail["revision"] = .string(revision); result = .object(detail)
        }
        return DesktopBridgeResponse(data: try JSONEncoder.nodus.encode(result), status: 200, headers: ["x-nodus-device-copy": "selected"])
    }

    public enum CopyError: LocalizedError, Sendable {
        case dossierNotDownloaded
        public var errorDescription: String? { "Este dossier no está descargado. Vuelve a conectar con Nodus para consultarlo o llevarlo contigo." }
    }
}
