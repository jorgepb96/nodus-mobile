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
        public let captureHash: String?
        public let capturedAssetId: String?
        public let derivation: String?
        public func jsonValue() throws -> JSONValue { try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(self)) }
        public init(value: JSONValue) throws { self = try JSONDecoder.nodus.decode(Self.self, from: JSONEncoder.nodus.encode(value)) }
        init(id: UUID, vaultId: String, parentRecordId: String, generationId: UUID, figureId: UUID, owner: String, ownerRevision: String, targetId: String, figureKey: String, mimeType: String, byteCount: Int64, sha256: String, captureHash: String? = nil, capturedAssetId: String? = nil, derivation: String? = nil) {
            self.id = id; self.vaultId = vaultId; self.parentRecordId = parentRecordId; self.generationId = generationId
            self.figureId = figureId; self.owner = owner; self.ownerRevision = ownerRevision; self.targetId = targetId; self.figureKey = figureKey; self.mimeType = mimeType; self.byteCount = byteCount; self.sha256 = sha256; self.captureHash = captureHash; self.capturedAssetId = capturedAssetId; self.derivation = derivation
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
    /// Visual-only sessions own their bytes without pretending to be a prose
    /// generation or changing the report's original publication receipt.
    struct Parent {
        let id: String
        let targetId: String
        let manifest: [String: JSONValue]
        let source: [String: JSONValue]
        init(_ value: JSONValue, vaultId: String, recordId: String) throws {
            guard let fields = value.objectValue, let id = fields["id"]?.stringValue, UUID(uuidString: id) != nil,
                  let entity = fields["entityKey"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
            self.id = id
            if fields["kind"] == .string("documentVisuals") {
                guard fields["version"] == .int(1), let source = fields["source"]?.objectValue,
                      source["vaultId"] == .string(vaultId), source["draft"]?.objectValue != nil,
                      let contentHash = source["contentHash"]?.stringValue, validHash(contentHash),
                      ["desktop-capture", "authored-mobile"].contains(source["origin"]?.stringValue ?? ""),
                      let target = fields["target"]?.objectValue, target["kind"] == .string("deep-research"),
                      let targetId = target["id"]?.stringValue, UUID(uuidString: targetId) != nil,
                      entity == "deep-research:" + targetId,
                      recordId == (try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)),
                      fields["manifest"] == .null || fields["manifest"]?.objectValue != nil else { throw DesktopBridgeError.permissionDenied }
                self.targetId = targetId; self.manifest = fields["manifest"]?.objectValue ?? [:]; self.source = source
            } else {
                guard fields["context"]?.objectValue?["vaultId"] == .string(vaultId),
                      recordId == (try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)),
                      let manifest = fields["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"]?.objectValue else { throw DesktopBridgeError.permissionDenied }
                self.targetId = id; self.manifest = manifest; self.source = [:]
            }
            if !manifest.isEmpty {
                guard manifest["vaultId"] == .string(vaultId), manifest["target"]?.objectValue?["kind"] == .string("deep-research"),
                      manifest["target"]?.objectValue?["id"] == .string(targetId) else { throw DesktopBridgeError.permissionDenied }
            }
        }
    }
    static func validate(_ receipt: Receipt, parent: JSONValue, requireCurrentFigure: Bool = true) throws {
        let source = try Parent(parent, vaultId: receipt.vaultId, recordId: receipt.parentRecordId)
        guard receipt.version == 1, receipt.byteCount > 0, validHash(receipt.sha256), validHash(receipt.owner),
              ["image/png", "image/jpeg", "image/webp"].contains(receipt.mimeType),
              UUID(uuidString: receipt.figureKey) == receipt.figureId,
              receipt.targetId == source.targetId, UUID(uuidString: source.id) == receipt.generationId else { throw DesktopBridgeError.permissionDenied }
        if receipt.captureHash != nil {
            try validateCaptured(receipt, parent: source)
            if requireCurrentFigure {
                guard let figure = source.manifest["figures"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(receipt.figureKey) })?.objectValue,
                      figure["owner"] == .string(receipt.owner), figure["ownerRevision"] == nil else { throw DesktopBridgeError.permissionDenied }
                if receipt.derivation != nil {
                    let captured = try capturedFigure(receipt, parent: source)
                    guard figure["view"] == captured["view"] else { throw DesktopBridgeError.permissionDenied }
                }
            }
            return
        }
        guard receipt.capturedAssetId == nil, receipt.derivation == nil, UUID(uuidString: receipt.ownerRevision) != nil else { throw DesktopBridgeError.permissionDenied }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let identity = ["document-figure", receipt.vaultId, "deep-research:\(source.targetId):\(receipt.ownerRevision):\(receipt.figureKey)"]
        guard hash(try encoder.encode(identity)) == receipt.owner else { throw DesktopBridgeError.permissionDenied }
        if requireCurrentFigure {
            guard let figure = source.manifest["figures"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(receipt.figureKey) })?.objectValue,
                  figure["owner"] == .string(receipt.owner), figure["ownerRevision"] == .string(receipt.ownerRevision),
                  ["running", "failed", "ready"].contains(figure["state"]?.stringValue ?? "") else { throw DesktopBridgeError.permissionDenied }
        }
    }
    /// Legacy assets are admitted only by the exact, authenticated source capture.
    /// Its original serialized bytes avoid Swift/JavaScript numeric or escaping
    /// differences, while decoded equality binds the complete metadata envelope.
    private static func capture(_ parent: Parent, vaultId: String, targetId: String, expectedHash: String? = nil) throws -> [String: JSONValue] {
        guard let expected = parent.source["captureHash"]?.stringValue, validHash(expected), expectedHash == nil || expectedHash == expected,
              let canonical = parent.source["captureCanonical"]?.stringValue, let bytes = canonical.data(using: .utf8),
              hash(bytes) == expected, let capture = parent.source["capture"],
              try JSONDecoder.nodus.decode(JSONValue.self, from: bytes) == capture,
              let fields = capture.objectValue, fields["version"] == .int(1), fields["vaultId"] == .string(vaultId),
              fields["target"]?.objectValue?["kind"] == .string("deep-research"), fields["target"]?.objectValue?["id"] == .string(targetId),
              fields["contentHash"] == parent.source["contentHash"], let manifest = fields["manifest"]?.objectValue,
              manifest["vaultId"] == .string(vaultId), manifest["target"] == fields["target"] else { throw DesktopBridgeError.permissionDenied }
        return fields
    }
    private static func capturedFigure(_ receipt: Receipt, parent: Parent) throws -> [String: JSONValue] {
        guard receipt.ownerRevision.isEmpty, let expected = receipt.captureHash else { throw DesktopBridgeError.permissionDenied }
        let fields = try capture(parent, vaultId: receipt.vaultId, targetId: receipt.targetId, expectedHash: expected)
        guard let figures = fields["manifest"]?.objectValue?["figures"]?.arrayValue,
              let figure = figures.first(where: { $0.objectValue?["id"] == .string(receipt.figureKey) })?.objectValue,
              figures.filter({ $0.objectValue?["id"] == .string(receipt.figureKey) }).count == 1,
              figure["owner"] == .string(receipt.owner), figure["ownerRevision"] == nil else { throw DesktopBridgeError.permissionDenied }
        return figure
    }
    /// A visual-only source may refer to an existing authored receipt, but cannot
    /// rewrite its ownership or turn an arbitrary cached file into a reader alias.
    static func validateReferenced(_ receipt: Receipt, parent value: JSONValue, parentRecordId: String, generationId: UUID) throws {
        let parent = try Parent(value, vaultId: receipt.vaultId, recordId: parentRecordId)
        guard value.objectValue?["kind"] == .string("documentVisuals"), UUID(uuidString: parent.id) == generationId,
              parent.targetId == receipt.targetId,
              let originals = parent.source["originalReceipts"]?.arrayValue else { throw DesktopBridgeError.permissionDenied }
        let parsed = try originals.map { try Receipt(value: $0) }
        guard Set(parsed.map(\.id)).count == parsed.count, parsed.contains(receipt) else { throw DesktopBridgeError.permissionDenied }
        let fields = try capture(parent, vaultId: receipt.vaultId, targetId: receipt.targetId)
        guard let figures = fields["manifest"]?.objectValue?["figures"]?.arrayValue,
              let figure = figures.first(where: { $0.objectValue?["id"] == .string(receipt.figureKey) })?.objectValue,
              figures.filter({ $0.objectValue?["id"] == .string(receipt.figureKey) }).count == 1,
              figure["owner"] == .string(receipt.owner), figure["view"]?.objectValue != nil,
              receipt.ownerRevision.isEmpty ? figure["ownerRevision"] == nil : figure["ownerRevision"] == .string(receipt.ownerRevision),
              let assets = fields["assets"]?.arrayValue,
              let descriptor = assets.first(where: { UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == receipt.id })?.objectValue,
              assets.filter({ UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == receipt.id }).count == 1,
              descriptor["figureId"] == .string(receipt.figureKey), descriptor["owner"] == .string(receipt.owner),
              descriptor["mimeType"] == .string(receipt.mimeType), descriptor["byteCount"] == .int(receipt.byteCount), descriptor["sha256"] == .string(receipt.sha256)
        else { throw DesktopBridgeError.permissionDenied }
        let id = receipt.id.uuidString.lowercased()
        func references(_ nodes: [JSONValue], depth: Int = 0) -> Bool {
            guard depth <= 64 else { return false }
            return nodes.contains { node in
                let object = node.objectValue ?? [:]
                return object["attachmentId"] == .string(id) || references(object["children"]?.arrayValue ?? [], depth: depth + 1)
            }
        }
        guard figure["poster"] == .string("nodus-image://chat/\(receipt.owner)/\(id)") || references(figure["view"]?.objectValue?["nodes"]?.arrayValue ?? []) else { throw DesktopBridgeError.permissionDenied }
    }
    static func validateCaptured(_ receipt: Receipt, parent: Parent) throws {
        let figure = try capturedFigure(receipt, parent: parent)
        if let derivation = receipt.derivation {
            guard derivation == "captured-view-poster-v1", receipt.capturedAssetId == nil,
                  receipt.mimeType == "image/png", receipt.byteCount <= 8 * 1_048_576,
                  let view = figure["view"]?.objectValue, view["schemaVersion"] == .int(1), view["nodes"]?.arrayValue != nil else { throw DesktopBridgeError.permissionDenied }
            return
        }
        guard let assetId = receipt.capturedAssetId, let fields = parent.source["capture"]?.objectValue,
              let assets = fields["assets"]?.arrayValue,
              let descriptor = assets.first(where: { $0.objectValue?["id"] == .string(assetId) })?.objectValue,
              assets.filter({ $0.objectValue?["id"] == .string(assetId) }).count == 1,
              descriptor["figureId"] == .string(receipt.figureKey), descriptor["owner"] == .string(receipt.owner),
              descriptor["mimeType"] == .string(receipt.mimeType), descriptor["byteCount"] == .int(receipt.byteCount),
              descriptor["sha256"] == .string(receipt.sha256) else { throw DesktopBridgeError.permissionDenied }
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
    /// Metadata-only bindings reuse the original encrypted manifest and chunks.
    /// They are available for reading after recovery, never permission to execute.
    public func referencedReceipts(parentRecordId: String, generationId: UUID) async throws -> [Receipt] {
        let source = try await parent(parentRecordId)
        let scope = try Parent(source, vaultId: vaultId, recordId: parentRecordId)
        guard UUID(uuidString: scope.id) == generationId else { throw DesktopBridgeError.permissionDenied }
        guard let originals = scope.source["originalReceipts"] else { return [] }
        guard let list = originals.arrayValue else { throw DesktopBridgeError.permissionDenied }
        let receipts = try list.map { try Receipt(value: $0) }
        for receipt in receipts {
            guard receipt.vaultId == vaultId, let item = try await manifest(receipt.id), item.receipt == receipt, item.state == "ready" else { throw DesktopBridgeError.permissionDenied }
            try Self.validateReferenced(receipt, parent: source, parentRecordId: parentRecordId, generationId: generationId)
        }
        return receipts.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func readReferenced(_ receipt: Receipt, parentRecordId: String, generationId: UUID, offset: Int64, count: Int) async throws -> Data {
        guard try await referencedReceipts(parentRecordId: parentRecordId, generationId: generationId).contains(receipt) else { throw DesktopBridgeError.permissionDenied }
        return try await read(receipt, offset: offset, count: count)
    }
    public func dataReferenced(_ receipt: Receipt, parentRecordId: String, generationId: UUID) async throws -> Data {
        guard try await referencedReceipts(parentRecordId: parentRecordId, generationId: generationId).contains(receipt) else { throw DesktopBridgeError.permissionDenied }
        return try await data(receipt)
    }
    public func store(data: Data, mimeType: String, parentRecordId: String, generationId: UUID, figureId: UUID,
        owner: String, assetId: UUID = UUID(), sourceCompletionRecordId: String? = nil) async throws -> Receipt {
        let source = try await parent(parentRecordId)
        let scope = try Parent(source, vaultId: vaultId, recordId: parentRecordId)
        guard let figure = scope.manifest["figures"]?.arrayValue?.first(where: { UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == figureId })?.objectValue,
              let figureKey = figure["id"]?.stringValue, let ownerRevision = figure["ownerRevision"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        let receipt = Receipt(id: assetId, vaultId: vaultId, parentRecordId: parentRecordId, generationId: generationId, figureId: figureId,
            owner: owner, ownerRevision: ownerRevision, targetId: scope.targetId, figureKey: figureKey, mimeType: mimeType, byteCount: Int64(data.count), sha256: Self.hash(data))
        try Self.validate(receipt, parent: source)
        return try await persist(receipt, source: source, data: data, sourceCompletionRecordId: sourceCompletionRecordId)
    }
    /// Copies one real legacy image captured by the authenticated Mac source. This
    /// cannot mint a new owner, infer a birth revision, or accept arbitrary bytes.
    public func importCapturedLegacyAsset(data: Data, mimeType: String, parentRecordId: String, generationId: UUID,
        figureId: UUID, owner: String, sourceAssetId: String, assetId: UUID = UUID()) async throws -> Receipt {
        let source = try await parent(parentRecordId), scope = try Parent(source, vaultId: vaultId, recordId: parentRecordId)
        guard let captureHash = scope.source["captureHash"]?.stringValue,
              let figureKey = scope.manifest["figures"]?.arrayValue?.first(where: { UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == figureId })?.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        let receipt = Receipt(id: assetId, vaultId: vaultId, parentRecordId: parentRecordId, generationId: generationId, figureId: figureId,
            owner: owner, ownerRevision: "", targetId: scope.targetId, figureKey: figureKey, mimeType: mimeType, byteCount: Int64(data.count), sha256: Self.hash(data), captureHash: captureHash, capturedAssetId: sourceAssetId)
        try Self.validate(receipt, parent: source)
        return try await persist(receipt, source: source, data: data, sourceCompletionRecordId: nil)
    }
    /// Trusted native snapshot callers pass the exact rendered view. A legacy
    /// poster retry derives only from the immutable captured view; this cannot
    /// attach a different view, mint an owner birth, or admit a generic file.
    public func storeDerivedCapturedPoster(data: Data, view: JSONValue, parentRecordId: String, generationId: UUID,
        figureId: UUID, owner: String, assetId: UUID = UUID()) async throws -> Receipt {
        guard data.count <= 8 * 1_048_576, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw DesktopBridgeError.malformedResponse }
        let source = try await parent(parentRecordId), scope = try Parent(source, vaultId: vaultId, recordId: parentRecordId)
        guard let captureHash = scope.source["captureHash"]?.stringValue,
              let figure = scope.manifest["figures"]?.arrayValue?.first(where: { UUID(uuidString: $0.objectValue?["id"]?.stringValue ?? "") == figureId })?.objectValue,
              let figureKey = figure["id"]?.stringValue, figure["view"] == view else { throw DesktopBridgeError.permissionDenied }
        let receipt = Receipt(id: assetId, vaultId: vaultId, parentRecordId: parentRecordId, generationId: generationId, figureId: figureId,
            owner: owner, ownerRevision: "", targetId: scope.targetId, figureKey: figureKey, mimeType: "image/png", byteCount: Int64(data.count), sha256: Self.hash(data), captureHash: captureHash, derivation: "captured-view-poster-v1")
        try Self.validate(receipt, parent: source)
        return try await persist(receipt, source: source, data: data, sourceCompletionRecordId: nil)
    }
    private func persist(_ receipt: Receipt, source: JSONValue, data: Data, sourceCompletionRecordId: String?) async throws -> Receipt {
        guard source.objectValue?["recoveryReviewRequired"] != .bool(true) else { throw DesktopBridgeError.permissionDenied }
        let assetId = receipt.id, parentRecordId = receipt.parentRecordId
        let ticket = try await cache.beginDocumentFigureAssetImport(vaultId: vaultId, owner: receipt.owner, byteCount: Int64(data.count))
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
