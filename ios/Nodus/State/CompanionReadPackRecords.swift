import Foundation
import NodusKit

/// Explicit page references can share a database. Merge their scoped dossiers;
/// never drop the later page's dependencies because its envelope key repeats.
enum CompanionReadPackRecords {
    /// A nested capture may return a shared envelope already retained by its
    /// parent. Allow reading that overlap; the parent's merge still charges
    /// only the actual final union and enforces the unchanged storage ceiling.
    static func readBudget(records: [PrivateBridgeCache.ReadPackRecord], vault: String, remaining: Int) throws -> Int {
        guard remaining >= 0, remaining <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let envelopes = records.filter { $0.domain == .corpus && $0.recordId == CompanionPageDownload.linkedDatabaseKey }
        guard envelopes.count <= 1 else { throw DesktopBridgeError.malformedResponse }
        guard let envelope = envelopes.first else { return remaining }
        guard envelope.data.count <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: envelope.data)
        guard value.objectValue?["version"] == .int(1), value.objectValue?["vaultId"] == .string(vault),
              let databases = value.objectValue?["databases"]?.objectValue,
              databases.allSatisfy({ $0.value.objectValue?["database"]?.objectValue?["id"] == .string($0.key) }) else { throw DesktopBridgeError.malformedResponse }
        return min(PrivateBridgeCache.maximumSelectedCopyBytes, remaining + envelope.data.count)
    }
    static func merge(_ record: PrivateBridgeCache.ReadPackRecord, into records: inout [PrivateBridgeCache.ReadPackRecord],
        vault: String, bytes: inout Int, maximumBytes: Int) throws {
        func databases(_ data: Data) throws -> [String: JSONValue] {
            let value = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
            guard value.objectValue?["version"] == .int(1), value.objectValue?["vaultId"] == .string(vault),
                  let databases = value.objectValue?["databases"]?.objectValue,
                  databases.allSatisfy({ $0.value.objectValue?["database"]?.objectValue?["id"] == .string($0.key) }) else { throw DesktopBridgeError.malformedResponse }
            return databases
        }
        let addition = record.recordId == CompanionPageDownload.linkedDatabaseKey ? try databases(record.data) : nil
        if let index = records.firstIndex(where: { $0.domain == record.domain && $0.recordId == record.recordId }) {
            let previous = records[index]
            if previous.data == record.data { return }
            guard record.recordId == CompanionPageDownload.linkedDatabaseKey, record.domain == .corpus else { throw DesktopBridgeError.malformedResponse }
            var merged = try databases(previous.data)
            for (id, value) in addition! {
                guard merged[id] == nil || merged[id] == value else {
                    throw APIError(status: 409, code: "page_dependency_changed", message: "La base de datos cambió durante la descarga. Vuelve a intentarlo.")
                }
                merged[id] = value
            }
            let data = try JSONEncoder.nodus.encode(JSONValue.object(["version": .int(1), "vaultId": .string(vault), "databases": .object(merged)]))
            let next = bytes - previous.data.count + data.count
            guard next <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            bytes = next; records[index] = .init(domain: record.domain, recordId: record.recordId, data: data)
        } else {
            guard record.data.count <= maximumBytes - bytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            bytes += record.data.count; records.append(record)
        }
    }
}
