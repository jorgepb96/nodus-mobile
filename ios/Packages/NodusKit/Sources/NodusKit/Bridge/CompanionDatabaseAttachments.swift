import CryptoKit
import Foundation

/// Authored files use encrypted cache records per 512 KiB, independently of the
/// disposable reading cache. A process interruption keeps every confirmed chunk.
public actor CompanionDatabaseAttachments {
    public static let chunkBytes = 512 * 1024
    public static let indexKey = "companion:database-file-index:v1"
    public struct Transfer: Codable, Sendable, Identifiable {
        public var version = 1
        public let id: UUID
        public let vaultId: String
        public let rowId: String
        public let columnId: String
        public let filename: String
        public let mimeType: String
        public let byteCount: Int64
        public let expectedRowRevision: Int64
        public let expectedColumnRevision: Int64
        public var sha256: String?
        public var chunkHashes: [String] = []
        public var state = "importing"
        public var received: Set<Int> = []
        public var result: JSONValue?
        public var issue: String?
        public var recoveryReviewRequired: Bool?
        public var discardComplete: Bool?
        public var importedBytes: Int64 { min(byteCount, Int64(chunkHashes.count) * Int64(CompanionDatabaseAttachments.chunkBytes)) }
        public var uploadedBytes: Int64 { if state == "available" { return byteCount }; return received.reduce(0) { $0 + min(Int64(CompanionDatabaseAttachments.chunkBytes), byteCount - Int64($1) * Int64(CompanionDatabaseAttachments.chunkBytes)) } }
    }
    struct Index: Codable { var version = 1; let vaultId: String; var ids: [UUID] }
    struct Chunk: Codable { var version = 1; let id: UUID; let index: Int; let bytes: String }
    public typealias Transport = @Sendable (UUID, String, JSONValue) async throws -> JSONValue
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var active: Set<UUID> = []
    public init(cache: PrivateBridgeCache, vaultId: String) { self.cache = cache; self.vaultId = vaultId }
    public static func recordId(_ id: UUID) -> String { "companion:database-file:v1:" + id.uuidString.lowercased() }
    public static func chunkId(_ id: UUID, _ index: Int) -> String { "companion:database-file-chunk:v1:\(id.uuidString.lowercased()):\(index)" }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validHash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func index() async throws -> Index {
        guard let bytes = try await cache.data(vaultId: vaultId, domain: .writing, recordId: Self.indexKey) else { return Index(vaultId: vaultId, ids: []) }
        let value = try JSONDecoder.nodus.decode(Index.self, from: bytes)
        guard value.version == 1, value.vaultId == vaultId, Set(value.ids).count == value.ids.count else { throw DesktopBridgeError.malformedResponse }
        return value
    }
    private func persist(_ transfer: Transfer) async throws {
        _ = try await cache.store(JSONEncoder.nodus.encode(transfer), vaultId: vaultId, domain: .writing, recordId: Self.recordId(transfer.id))
    }
    public func transfer(_ id: UUID) async throws -> Transfer? {
        guard let data = try await cache.data(vaultId: vaultId, domain: .writing, recordId: Self.recordId(id)) else { return nil }
        let value = try JSONDecoder.nodus.decode(Transfer.self, from: data)
        guard value.version == 1, value.id == id, value.vaultId == vaultId, !value.rowId.isEmpty, !value.columnId.isEmpty,
              value.byteCount >= 0, value.byteCount <= Int64(Int.max) - Int64(Self.chunkBytes), value.chunkHashes.count <= Int((value.byteCount + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes)),
              value.chunkHashes.allSatisfy(Self.validHash), value.received.allSatisfy(value.chunkHashes.indices.contains),
              ["importing", "ready", "uploading", "staged", "available", "paused", "discarded"].contains(value.state),
              value.sha256 == nil || Self.validHash(value.sha256!) else { throw DesktopBridgeError.malformedResponse }
        return value
    }
    public func all() async throws -> [Transfer] {
        var result: [Transfer] = []
        for id in try await index().ids { guard let value = try await transfer(id) else { throw DesktopBridgeError.malformedResponse }; if value.state != "discarded" || value.discardComplete != true { result.append(value) } }
        return result.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
    private func begin(_ id: UUID) throws {
        guard active.isEmpty, active.insert(id).inserted else { throw APIError(status: 409, code: "database_file_busy", message: "Este archivo ya se está procesando.") }
    }
    /// Reselecting the same original can finish an interrupted import. Existing
    /// confirmed chunks must match; an ID never silently changes its authored bytes.
    public func importFile(url: URL, filename: String? = nil, mimeType: String, rowId: String, columnId: String,
        expectedRowRevision: Int64, expectedColumnRevision: Int64, uploadId: UUID = UUID()) async throws -> Transfer {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw DesktopBridgeError.malformedResponse }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        return try await importStream(size: Int64(size), filename: filename ?? url.lastPathComponent, mimeType: mimeType, rowId: rowId, columnId: columnId, expectedRowRevision: expectedRowRevision, expectedColumnRevision: expectedColumnRevision, uploadId: uploadId) { try file.read(upToCount: Self.chunkBytes) ?? Data() }
    }
    public func importData(_ data: Data, filename: String, mimeType: String, rowId: String, columnId: String,
        expectedRowRevision: Int64, expectedColumnRevision: Int64, uploadId: UUID, allowRestoringDiscarded: Bool = false) async throws -> Transfer {
        var offset = 0
        return try await importStream(size: Int64(data.count), filename: filename, mimeType: mimeType, rowId: rowId, columnId: columnId, expectedRowRevision: expectedRowRevision, expectedColumnRevision: expectedColumnRevision, uploadId: uploadId, restoringHash: allowRestoringDiscarded ? Self.hash(data) : nil) {
            let end = min(data.count, offset + Self.chunkBytes); defer { offset = end }; return Data(data[offset..<end])
        }
    }
    private func importStream(size: Int64, filename: String, mimeType: String, rowId: String, columnId: String,
        expectedRowRevision: Int64, expectedColumnRevision: Int64, uploadId: UUID, restoringHash: String? = nil, read: () throws -> Data) async throws -> Transfer {
        guard size >= 0, size <= Int64(Int.max) - Int64(Self.chunkBytes), !rowId.isEmpty, !columnId.isEmpty,
              !filename.isEmpty, ![".", ".."].contains(filename), !filename.contains("/"), !filename.contains("\\"), !mimeType.isEmpty else { throw DesktopBridgeError.malformedResponse }
        try begin(uploadId); defer { active.remove(uploadId) }
        try cache.beginAuthoringActivity(); defer { cache.endAuthoringActivity() }
        var item = try await transfer(uploadId) ?? Transfer(id: uploadId, vaultId: vaultId, rowId: rowId, columnId: columnId, filename: filename, mimeType: mimeType, byteCount: size, expectedRowRevision: expectedRowRevision, expectedColumnRevision: expectedColumnRevision)
        if item.state == "discarded" {
            guard let restoringHash, item.sha256 == restoringHash, item.recoveryReviewRequired != true else { throw DesktopBridgeError.permissionDenied }
            item.chunkHashes = []; item.received = []; item.result = nil; item.state = "importing"; item.discardComplete = nil
        }
        guard item.rowId == rowId, item.columnId == columnId, item.filename == filename, item.mimeType == mimeType, item.byteCount == size,
              item.expectedRowRevision == expectedRowRevision, item.expectedColumnRevision == expectedColumnRevision,
              item.recoveryReviewRequired != true else { throw DesktopBridgeError.permissionDenied }
        let available = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber
        let remaining = max(0, size - item.importedBytes), budget = max(0, (available?.int64Value ?? 0) - 32 * 1024 * 1024)
        guard remaining <= (budget / 4) * 3 else { throw APIError(status: 413, code: "database_file_device_storage", message: "No hay espacio suficiente para conservar este archivo cifrado. El original no se ha modificado.") }
        // Manifest and discoverable index commit together before the first chunk.
        var listing = try await index()
        if !listing.ids.contains(uploadId) { listing.ids.append(uploadId) }
        try await cache.storeAuthoredBatch(vaultId: vaultId, records: [
            .init(domain: .writing, recordId: Self.recordId(uploadId), data: try JSONEncoder.nodus.encode(item)),
            .init(domain: .writing, recordId: Self.indexKey, data: try JSONEncoder.nodus.encode(listing))])
        var digest = SHA256(), total: Int64 = 0, index = 0
        do {
            while total < size {
                try Task.checkCancellation()
                let bytes = try read(), expected = min(Int64(Self.chunkBytes), size - total)
                guard Int64(bytes.count) == expected else { throw DesktopBridgeError.malformedResponse }
                let hash = Self.hash(bytes)
                if item.chunkHashes.indices.contains(index) {
                    guard item.chunkHashes[index] == hash else { throw APIError(status: 409, code: "database_file_original_changed", message: "El archivo original cambió. Conserva la copia anterior y elige un archivo nuevo.") }
                } else {
                    var next = item; next.chunkHashes.append(hash)
                    try await cache.storeAuthoredBatch(vaultId: vaultId, records: [
                        .init(domain: .writing, recordId: Self.chunkId(uploadId, index), data: try JSONEncoder.nodus.encode(Chunk(id: uploadId, index: index, bytes: bytes.base64EncodedString()))),
                        .init(domain: .writing, recordId: Self.recordId(uploadId), data: try JSONEncoder.nodus.encode(next))])
                    item = next
                }
                digest.update(data: bytes); total += Int64(bytes.count); index += 1
            }
            guard try read().isEmpty else { throw DesktopBridgeError.malformedResponse }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard item.sha256 == nil || item.sha256 == hash else { throw DesktopBridgeError.malformedResponse }
            item.sha256 = hash; if item.state == "importing" { item.state = "ready" }; item.issue = nil; try await persist(item); return item
        } catch {
            var retained = try await transfer(uploadId) ?? item
            retained.issue = error.localizedDescription; try await persist(retained); throw error
        }
    }
    private func chunk(_ transfer: Transfer, index: Int) async throws -> Data {
        guard transfer.chunkHashes.indices.contains(index), let bytes = try await cache.data(vaultId: vaultId, domain: .writing, recordId: Self.chunkId(transfer.id, index)) else { throw DesktopBridgeError.malformedResponse }
        let record = try JSONDecoder.nodus.decode(Chunk.self, from: bytes)
        guard record.version == 1, record.id == transfer.id, record.index == index, let data = Data(base64Encoded: record.bytes), data.base64EncodedString() == record.bytes,
              data.count == min(Self.chunkBytes, Int(transfer.byteCount) - index * Self.chunkBytes), Self.hash(data) == transfer.chunkHashes[index] else { throw DesktopBridgeError.malformedResponse }
        return data
    }
    /// A transport failure leaves authored chunks intact. Resume reconciles the
    /// server's exact chunk hashes, including an acknowledgement lost in transit.
    public func upload(_ id: UUID, commit: Bool, transport: Transport) async throws -> Transfer {
        try begin(id); defer { active.remove(id) }
        try cache.beginAuthoringActivity(); defer { cache.endAuthoringActivity() }
        guard var item = try await transfer(id), let hash = item.sha256, item.state != "importing", item.state != "discarded", item.recoveryReviewRequired != true else { throw APIError(status: 409, code: "database_file_not_ready", message: "El archivo necesita terminar su importación o revisar su destino.") }
        if item.state == "available" { return item }
        let manifest: JSONValue = .object(["rowId": .string(item.rowId), "columnId": .string(item.columnId), "fileName": .string(item.filename), "mimeType": .string(item.mimeType), "size": .int(item.byteCount), "sha256": .string(hash), "expectedRowRevision": .int(item.expectedRowRevision), "expectedColumnRevision": .int(item.expectedColumnRevision)])
        do {
            let response = try await transport(id, "begin", manifest)
            try reconcile(response, into: &item)
            if item.result != nil { item.state = "available"; try await persist(item); return item }
            item.state = "uploading"; try await persist(item)
            for index in item.chunkHashes.indices where !item.received.contains(index) {
                try Task.checkCancellation()
                let bytes = try await chunk(item, index: index)
                let response = try await transport(id, "chunk", .object(["index": .int(Int64(index)), "bytes": .string(bytes.base64EncodedString()), "sha256": .string(item.chunkHashes[index])]))
                try reconcile(response, into: &item)
                guard item.received.contains(index) else { throw DesktopBridgeError.malformedResponse }
                try await persist(item)
            }
            item.state = "staged"; try await persist(item)
            if commit {
                let response = try await transport(id, "commit", .object([:]))
                try reconcile(response, into: &item)
                guard item.result != nil else { throw DesktopBridgeError.malformedResponse }
                item.state = "available"; try await persist(item)
            }
            return item
        } catch { item.issue = error.localizedDescription; if item.state != "available" { item.state = "paused" }; try await persist(item); throw error }
    }
    private func reconcile(_ response: JSONValue, into item: inout Transfer) throws {
        guard let value = response.objectValue, value["version"] == .int(1), value["id"]?.stringValue?.lowercased() == item.id.uuidString.lowercased(), value["chunkBytes"] == .int(Int64(Self.chunkBytes)),
              let received = value["received"]?.arrayValue, ["pending", "available"].contains(value["state"]?.stringValue ?? "") else { throw DesktopBridgeError.malformedResponse }
        var indexes: Set<Int> = []
        for raw in received {
            guard let number = raw.objectValue?["index"]?.intValue, number >= 0, number < item.chunkHashes.count,
                  raw.objectValue?["sha256"] == .string(item.chunkHashes[Int(number)]), indexes.insert(Int(number)).inserted else { throw DesktopBridgeError.malformedResponse }
        }
        item.received = indexes
        if let result = value["result"], result != .null {
            guard let record = result.objectValue, record["rowId"] == .string(item.rowId), record["columnId"] == .string(item.columnId), record["bytes"] == .int(item.byteCount), record["sha256"] == item.sha256.map(JSONValue.string), record["fileName"] == .string(item.filename), record["mimeType"] == .string(item.mimeType), record["id"] == .string("datt_" + item.id.uuidString.lowercased()) else { throw DesktopBridgeError.malformedResponse }
            item.result = result
        }
    }
    /// Review authorizes only the retained file and original target/preconditions.
    /// A changed row still fails CAS on Mac; approval never rewrites its baseline.
    public func approveRecovered(_ id: UUID) async throws {
        try begin(id); defer { active.remove(id) }
        try cache.beginAuthoringActivity(); defer { cache.endAuthoringActivity() }
        guard var item = try await transfer(id), item.recoveryReviewRequired == true else { throw DesktopBridgeError.permissionDenied }
        item.recoveryReviewRequired = nil; item.received = []; item.result = nil
        if item.state != "discarded" { item.state = item.sha256 == nil ? "importing" : "ready" }; try await persist(item)
    }
    /// Only acknowledged files can release their duplicate device bytes. The
    /// durable tombstone is written before deletion so interruption/revocation
    /// still accounts for every qualified chunk without resurrecting it.
    public func discardDeviceCopy(_ id: UUID) async throws {
        try begin(id); defer { active.remove(id) }
        try cache.beginAuthoringActivity(); defer { cache.endAuthoringActivity() }
        guard var item = try await transfer(id), ["available", "discarded"].contains(item.state) else { throw DesktopBridgeError.permissionDenied }
        item.state = "discarded"; item.discardComplete = false; try await persist(item)
        for index in item.chunkHashes.indices { try await cache.remove(vaultId: vaultId, domain: .writing, recordId: Self.chunkId(id, index)) }
        item.discardComplete = true; item.issue = nil; try await persist(item)
    }
    public func export(_ id: UUID, limitBytes: Int = Int.max) async throws -> PrivateBridgeFileLease {
        try begin(id); defer { active.remove(id) }
        try cache.beginAuthoringActivity(); defer { cache.endAuthoringActivity() }
        guard let item = try await transfer(id), item.state != "discarded", let hash = item.sha256, limitBytes >= 0, item.byteCount <= Int64(limitBytes) else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let available = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber
        guard let free = available?.int64Value, item.byteCount <= max(0, free - 32 * 1024 * 1024) else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        return try await PrivateBridgeFileLease.create(filename: item.filename, reservedBytes: item.byteCount, limitBytes: min(limitBytes, Int(min(Int64(Int.max), free)))) { target in
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            var digest = SHA256(), count: Int64 = 0
            for index in item.chunkHashes.indices {
                try Task.checkCancellation(); let bytes = try await self.chunk(item, index: index)
                try output.write(contentsOf: bytes); digest.update(data: bytes); count += Int64(bytes.count)
            }
            try output.synchronize()
            guard count == item.byteCount, digest.finalize().map({String(format: "%02x", $0)}).joined() == hash else { throw DesktopBridgeError.malformedResponse }
        }
    }
    public func uploadForPublication(data: Data, filename: String, mimeType: String, rowId: String, columnId: String, expectedRowRevision: Int64, expectedColumnRevision: Int64, uploadId: UUID, bridge: DesktopBridgeClient) async throws -> JSONValue {
        _ = try await importData(data, filename: filename, mimeType: mimeType, rowId: rowId, columnId: columnId, expectedRowRevision: expectedRowRevision, expectedColumnRevision: expectedColumnRevision, uploadId: uploadId, allowRestoringDiscarded: true)
        let vault = vaultId
        let value = try await upload(uploadId, commit: false) { id, action, body in try await bridge.databaseFileUpload(vaultId: vault, uploadId: id, action: action, body: body) }
        guard let hash = value.sha256 else { throw DesktopBridgeError.malformedResponse }
        return .object(["blobUploadId": .string(uploadId.uuidString.lowercased()), "sha256": .string(hash), "mimeType": .string(value.mimeType)])
    }
}


/// All app surfaces share one actor per grant/vault so concurrent imports cannot
/// race the authored index. Revoked store instances retain their original epoch.
public actor CompanionDatabaseAttachmentStores {
    public static let shared = CompanionDatabaseAttachmentStores()
    private var stores: [String: CompanionDatabaseAttachments] = [:]
    public func store(pairingId: String, vaultId: String) throws -> CompanionDatabaseAttachments {
        let key = pairingId + ":" + vaultId
        if let store = stores[key] { return store }
        let value = CompanionDatabaseAttachments(cache: try PrivateBridgeCache(pairingId: pairingId), vaultId: vaultId)
        stores[key] = value; return value
    }
}
