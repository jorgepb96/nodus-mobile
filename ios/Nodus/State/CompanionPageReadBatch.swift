import Foundation
import NodusKit

/// Read only explicit page identities, preserving order and the Mac's bounded cursor.
enum CompanionPageReadBatch {
    @MainActor static func read(vault: String, pageIds: [String], maximumBytes: Int,
        fetch: (JSONValue) async throws -> JSONValue) async throws -> [String: JSONValue] {
        guard Set(pageIds).count == pageIds.count, pageIds.allSatisfy({ !$0.isEmpty && $0.count <= 1024 }) else { throw DesktopBridgeError.malformedResponse }
        var documents: [String: JSONValue] = [:], bytes = 0
        for start in stride(from: 0, to: pageIds.count, by: 2000) {
            let ids = Array(pageIds[start..<min(start + 2000, pageIds.count)])
            var cursor = 0
            repeat {
                try Task.checkCancellation()
                let response = try await fetch(.object(["pageIds": .array(ids.map(JSONValue.string)), "cursor": .int(Int64(cursor)), "limit": .int(20)]))
                guard response.objectValue?["version"] == .int(1), response.objectValue?["vaultId"] == .string(vault),
                      response.objectValue?["totalCount"]?.intValue == ids.count,
                      let part = response.objectValue?["documents"]?.arrayValue, !part.isEmpty, part.count <= 20,
                      part.count <= ids.count - cursor else { throw DesktopBridgeError.malformedResponse }
                for (offset, source) in part.enumerated() {
                    let id = ids[cursor + offset]
                    _ = try CompanionPageDocuments.document(source, vaultId: vault, pageId: id)
                    guard documents[id] == nil else { throw DesktopBridgeError.malformedResponse }
                    let count = try JSONEncoder.nodus.encode(source).count
                    guard count <= maximumBytes - bytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    bytes += count; documents[id] = source
                }
                cursor += part.count
                guard response.objectValue?["nextCursor"] == (cursor < ids.count ? .int(Int64(cursor)) : .null) else { throw DesktopBridgeError.malformedResponse }
            } while cursor < ids.count
        }
        return documents
    }
}
