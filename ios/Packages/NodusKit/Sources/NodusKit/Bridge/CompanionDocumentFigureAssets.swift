import CryptoKit
import Foundation

/// Authored figure bytes are independently encrypted in 512 KiB records. A report
/// stores receipts, never a second base64 copy of every image in its call journal.
public actor CompanionDocumentFigureAssets {
    public static let chunkBytes = 512 * 1024
    public static let indexKey = "companion:document-figure-assets:index:v1"
    public struct Receipt: Codable, Sendable, Equatable, Identifiable {
        public var version = 1
        public let id: UUID
        public let vaultId: String
        public let parentRecordId: String
        public let generationId: UUID
        public let figureId: UUID
        public let owner: String
        public let ownerRevision: String
        public let targetId: String
        public let figureKey: String
        public let mimeType: String
        public let byteCount: Int64
        public let sha256: String
        public func jsonValue() throws -> JSONValue { try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(self)) }
        public init(value: JSONValue) throws { self = try JSONDecoder.nodus.decode(Self.self, from: JSONEncoder.nodus.encode(value)) }
        init(id: UUID, vaultId: String, parentRecordId: String, generationId: UUID, figureId: UUID, owner: String, ownerRevision: String, targetId: String, figureKey: String, mimeType: String, byteCount: Int64, sha256: String) {
            self.id = id; self.vaultId = vaultId; self.parentRecordId = parentRecordId; self.generationId = generationId
            self.figureId = figureId; self.owner = owner; self.ownerRevision = ownerRevision; self.targetId = targetId; self.figureKey = figureKey; self.mimeType = mimeType; self.byteCount = byteCount; self.sha256 = sha256
        }
    }
    struct Manifest: Codable, Sendable {
        var version = 1
        let receipt: Receipt
        var chunkHashes: [String] = []
        var state = "importing"
        var recoveryReviewRequired: Bool?
    }
    struct Chunk: Codable { var version = 1; let id: UUID; let index: Int; let bytes: String }
    private let cache: PrivateBridgeCache
    private let vaultId: String
    public init(cache: PrivateBridgeCache, vaultId: String) { self.cache = cache; self.vaultId = vaultId }
    public static func recordId(_ id: UUID) -> String { "companion:document-figure-asset:v1:" + id.uuidString.lowercased() }
    public static func chunkId(_ id: UUID, _ index: Int) -> String { "companion:document-figure-asset-chunk:v1:\(id.uuidString.lowercased()):\(index)" }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func validate(_ receipt: Receipt, parent: JSONValue, requireCurrentFigure: Bool = true) throws {
        guard receipt.version == 1, receipt.byteCount > 0, validHash(receipt.sha256), validHash(receipt.owner),
              ["image/png", "image/jpeg", "image/webp"].contains(receipt.mimeType),
              UUID(uuidString: receipt.ownerRevision) != nil, UUID(uuidString: receipt.figureKey) == receipt.figureId,
              let object = parent.objectValue, let originalID = object["id"]?.stringValue,
              originalID == receipt.targetId, UUID(uuidString: originalID) == receipt.generationId,
              object["context"]?.objectValue?["vaultId"] == .string(receipt.vaultId),
              let entity = object["entityKey"]?.stringValue,
              receipt.parentRecordId == (try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)) else { throw DesktopBridgeError.permissionDenied }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let identity = ["document-figure", receipt.vaultId, "deep-research:\(originalID):\(receipt.ownerRevision):\(receipt.figureKey)"]
        guard hash(try encoder.encode(identity)) == receipt.owner else { throw DesktopBridgeError.permissionDenied }
        if requireCurrentFigure {
            guard let manifest = object["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"]?.objectValue,
                  manifest["vaultId"] == .string(receipt.vaultId),
                  manifest["target"]?.objectValue?["kind"] == .string("deep-research"), manifest["target"]?.objectValue?["id"] == .string(originalID),
                  let figure = manifest["figures"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(receipt.figureKey) })?.objectValue,
                  figure["owner"] == .string(receipt.owner), figure["ownerRevision"] == .string(receipt.ownerRevision),
                  ["running", "failed", "ready"].contains(figure["state"]?.stringValue ?? "") else { throw DesktopBridgeError.permissionDenied }
        }
    }
    static func validate(_ manifest: Manifest) throws {
        let receipt = manifest.receipt
        guard manifest.version == 1, receipt.version == 1, receipt.byteCount > 0,
              receipt.byteCount <= Int64(Int.max) - Int64(chunkBytes), validHash(receipt.sha256), validHash(receipt.owner),
              ["image/png", "image/jpeg", "image/webp"].contains(receipt.mimeType),
              ["importing", "ready"].contains(manifest.state), manifest.chunkHashes.allSatisfy(validHash),
              manifest.chunkHashes.count <= Int((receipt.byteCount + Int64(chunkBytes) - 1) / Int64(chunkBytes)),
              manifest.state != "ready" || manifest.chunkHashes.count == Int((receipt.byteCount + Int64(chunkBytes) - 1) / Int64(chunkBytes)) else { throw DesktopBridgeError.malformedResponse }
    }
    private func parent(_ recordId: String) async throws -> JSONValue {
        guard let data = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: recordId) else { throw DesktopBridgeError.permissionDenied }
        return try JSONDecoder.nodus.decode(JSONValue.self, from: data)
    }
    private func manifest(_ id: UUID) async throws -> Manifest? {
        guard let data = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: Self.recordId(id)) else { return nil }
        let value = try JSONDecoder.nodus.decode(Manifest.self, from: data)
        try Self.validate(value)
        guard value.receipt.id == id, value.receipt.vaultId == vaultId else { throw DesktopBridgeError.permissionDenied }
        return value
    }
    /// The exact receipt-only image request must already be durable on its real parent.
    private func validatesCompletion(_ recordId: String, receipt: Receipt, parent: JSONValue, bytes: Data) async throws {
        guard let object = parent.objectValue, let originalID = object["id"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        var inputs: [JSONValue] = []
        if let request = object["inflight"]?.objectValue?["request"] { inputs.append(request) }
        for call in (object["calls"]?.objectValue ?? [:]).values {
            if let text = call.objectValue?["input"]?.stringValue, let data = text.data(using: .utf8), let value = try? JSONDecoder.nodus.decode(JSONValue.self, from: data) { inputs.append(value) }
        }
        guard try inputs.contains(where: { input in
            guard let fields = input.objectValue, fields["format"] == .string("image"), fields["responseMode"] == .string("receipt"),
                  fields["figureOwner"] == .string(receipt.owner), fields["generationId"] == .string(originalID) else { return false }
            return recordId == "autonomous:\(originalID):completion:" + Self.hash(try JSONEncoder.nodus.encode(input))
        }), let indexBytes = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: "autonomous:completion-index:v1"),
              try JSONDecoder.nodus.decode([String].self, from: indexBytes).contains(recordId),
              let data = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: recordId) else { throw DesktopBridgeError.permissionDenied }
        let stored = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
        if let pointer = stored.objectValue?["documentFigureAsset"] {
            guard try Receipt(value: pointer) == receipt else { throw DesktopBridgeError.permissionDenied }
        } else {
            guard let raw = stored.stringValue?.data(using: .utf8), let image = try JSONDecoder.nodus.decode(JSONValue.self, from: raw).objectValue,
                  image["mime"] == .string(receipt.mimeType), let encoded = image["bytes"]?.stringValue,
                  let imageBytes = Data(base64Encoded: encoded), imageBytes == bytes else { throw DesktopBridgeError.permissionDenied }
        }
    }
    /// Metadata-only lookup closes a lost acknowledgement between storing an asset
    /// and recording its receipt on the journal. No image bytes are loaded here.
    public func receipts(parentRecordId: String, generationId: UUID, figureId: UUID? = nil, owner: String? = nil) async throws -> [Receipt] {
        let source = try await parent(parentRecordId)
        guard let bytes = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: Self.indexKey) else { return [] }
        let ids = try JSONDecoder.nodus.decode([String].self, from: bytes)
        guard Set(ids).count == ids.count else { throw DesktopBridgeError.malformedResponse }
        var result: [Receipt] = []
        for text in ids {
            guard let id = UUID(uuidString: text), text == id.uuidString.lowercased(), let value = try await manifest(id) else { throw DesktopBridgeError.malformedResponse }
            let receipt = value.receipt
            guard receipt.parentRecordId == parentRecordId, receipt.generationId == generationId,
                  figureId == nil || figureId == receipt.figureId, owner == nil || owner == receipt.owner,
                  value.state == "ready" else { continue }
            try Self.validate(receipt, parent: source, requireCurrentFigure: false)
            result.append(receipt)
        }
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func store(data: Data, mimeType: String, parentRecordId: String, generationId: UUID, figureId: UUID,
        owner: String, assetId: UUID = UUID(), sourceCompletionRecordId: String? = nil) async throws -> Receipt {
        let source = try await parent(parentRecordId)
        guard let originalID = source.objectValue?["id"]?.stringValue,
              let figure = source.objectValue?["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"]?.objectValue?["figures"]?.arrayValue?.first(where: { UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == figureId })?.objectValue,
              let figureKey = figure["id"]?.stringValue, let ownerRevision = figure["ownerRevision"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        let receipt = Receipt(id: assetId, vaultId: vaultId, parentRecordId: parentRecordId, generationId: generationId, figureId: figureId,
            owner: owner, ownerRevision: ownerRevision, targetId: originalID, figureKey: figureKey, mimeType: mimeType, byteCount: Int64(data.count), sha256: Self.hash(data))
        try Self.validate(receipt, parent: source)
        let ticket = try await cache.beginDocumentFigureAssetImport(vaultId: vaultId, owner: owner, byteCount: Int64(data.count))
        defer { cache.endDocumentFigureAssetImport(ticket) }
        var item = try await manifest(assetId) ?? Manifest(receipt: receipt)
        guard item.receipt == receipt, item.recoveryReviewRequired != true else { throw DesktopBridgeError.permissionDenied }
        if let record = sourceCompletionRecordId { try await validatesCompletion(record, receipt: receipt, parent: source, bytes: data) }
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(item), vaultId: vaultId, recordId: Self.recordId(assetId), indexId: Self.indexKey, entity: assetId.uuidString.lowercased())
        for index in 0..<Int((receipt.byteCount + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes)) {
            try Task.checkCancellation()
            let start = index * Self.chunkBytes, chunk = data.subdata(in: start..<min(start + Self.chunkBytes, data.count)), hash = Self.hash(chunk)
            if item.chunkHashes.indices.contains(index) { guard item.chunkHashes[index] == hash else { throw DesktopBridgeError.permissionDenied }; continue }
            item.chunkHashes.append(hash)
            try await cache.storeAuthoredBatch(vaultId: vaultId, records: [
                .init(domain: .researchGeneration, recordId: Self.chunkId(assetId, index), data: JSONEncoder.nodus.encode(Chunk(id: assetId, index: index, bytes: chunk.base64EncodedString()))),
                .init(domain: .researchGeneration, recordId: Self.recordId(assetId), data: JSONEncoder.nodus.encode(item))])
        }
        item.state = "ready"
        // Revalidate after suspension: an edited/deleted report must never acquire new assets.
        try Self.validate(receipt, parent: await parent(parentRecordId))
        if let record = sourceCompletionRecordId {
            try await cache.storeAuthoredBatch(vaultId: vaultId, records: [
                .init(domain: .researchGeneration, recordId: Self.recordId(assetId), data: JSONEncoder.nodus.encode(item)),
                .init(domain: .researchGeneration, recordId: record, data: JSONEncoder.nodus.encode(JSONValue.object(["documentFigureAsset": receipt.jsonValue()])))])
        } else { try await cache.store(JSONEncoder.nodus.encode(item), vaultId: vaultId, domain: .researchGeneration, recordId: Self.recordId(assetId)) }
        return receipt
    }
    /// A bounded range read only exposes bytes owned by this exact receipt and vault.
    public func read(_ receipt: Receipt, offset: Int64, count: Int) async throws -> Data {
        guard receipt.vaultId == vaultId, let item = try await manifest(receipt.id), item.receipt == receipt, item.state == "ready",
              offset >= 0, count >= 0, count <= Self.chunkBytes, offset <= receipt.byteCount, Int64(count) <= receipt.byteCount - offset else { throw DesktopBridgeError.permissionDenied }
        var result = Data(), position = offset
        while result.count < count {
            let index = Int(position / Int64(Self.chunkBytes))
            guard let encoded = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: Self.chunkId(receipt.id, index)) else { throw DesktopBridgeError.malformedResponse }
            let chunk = try JSONDecoder.nodus.decode(Chunk.self, from: encoded)
            guard chunk.version == 1, chunk.id == receipt.id, chunk.index == index, let bytes = Data(base64Encoded: chunk.bytes),
                  bytes.count == min(Self.chunkBytes, Int(receipt.byteCount) - index * Self.chunkBytes), Self.hash(bytes) == item.chunkHashes[index] else { throw DesktopBridgeError.malformedResponse }
            let start = Int(position % Int64(Self.chunkBytes)), length = min(count - result.count, bytes.count - start)
            result.append(bytes.subdata(in: start..<(start + length))); position += Int64(length)
        }
        return result
    }
    /// Materializes one requested asset, never the report's entire asset collection.
    public func data(_ receipt: Receipt) async throws -> Data {
        guard receipt.vaultId == vaultId, receipt.byteCount > 0, let item = try await manifest(receipt.id),
              item.receipt == receipt, item.state == "ready" else { throw DesktopBridgeError.permissionDenied }
        var result = Data(), digest = SHA256(), offset: Int64 = 0
        while offset < receipt.byteCount {
            let bytes = try await read(receipt, offset: offset, count: Int(min(Int64(Self.chunkBytes), receipt.byteCount - offset)))
            result.append(bytes); digest.update(data: bytes); offset += Int64(bytes.count)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else { throw DesktopBridgeError.malformedResponse }
        return result
    }
}
