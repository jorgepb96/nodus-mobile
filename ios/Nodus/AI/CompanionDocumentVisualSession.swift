import CryptoKit
import Foundation
import NodusKit

/// Independent authoring for a real saved report's figures. These records never
/// enter the prose gallery or the generic report publication constructor.
@MainActor enum CompanionDocumentVisualSession {
    static func checkpoint(_ action: String, reportID: String, value: JSONValue? = nil, session: SpaceSession) async throws -> JSONValue {
        guard UUID(uuidString: reportID) != nil else { throw DesktopBridgeError.malformedResponse }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let entity = "deep-research:\(reportID)", record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        let previousData = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: record)
        let previous = try previousData.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) }
        if action == "load" { return previous ?? .null }
        guard ["save", "replaceSource"].contains(action), let value, let object = value.objectValue,
              object["retainedAssetReceipts"] == nil, object["version"] == .int(1), object["kind"] == .string("documentVisuals"),
              object["entityKey"] == .string(entity), let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
              object["target"]?.objectValue?["kind"] == .string("deep-research"), object["target"]?.objectValue?["id"] == .string(reportID),
              let source = object["source"]?.objectValue, source["vaultId"] == .string(scope.recordVaultId), source["target"] == object["target"],
              source["draft"]?.objectValue?["brief"]?.objectValue?["kind"] == .string("deep_research"),
              let canonical = source["captureCanonical"]?.stringValue,
              let captureData = canonical.data(using: .utf8), try JSONDecoder.nodus.decode(JSONValue.self, from: captureData) == source["capture"],
              source["captureHash"] == .string(SHA256.hash(data: captureData).map { String(format: "%02x", $0) }.joined()) else { throw DesktopBridgeError.malformedResponse }
        if let previous {
            if action == "replaceSource" {
                guard session.aiExecutionMode == .autonomous, previous.objectValue?["id"] != .string(id) else { throw DesktopBridgeError.permissionDenied }
            } else if previous.objectValue?["id"] != .string(id) || previous.objectValue?["source"] != object["source"] {
                throw APIError(status: 409, code: "document_visual_source_conflict", message: "Esta sesión conserva otra versión del informe. Revisa el cambio antes de sustituir su fuente.")
            }
            guard previous.objectValue?["recoveryReviewRequired"] != .bool(true) else { throw DesktopBridgeError.permissionDenied }
        } else if session.aiExecutionMode != .autonomous { throw DesktopBridgeError.permissionDenied }
        try cache.beginAuthoringActivity()
        defer { cache.endAuthoringActivity() }
        try await cache.requireGenerationExecutionAllowed(vaultId: scope.recordVaultId, generationId: id)
        let data = try JSONEncoder.nodus.encode(value)
        guard data.count <= 50 * 1_048_576 else { throw APIError(status: 413, code: "document_visual_source_too_large", message: "La fuente y el trabajo visual superan el límite de 50 MiB. El trabajo anterior permanece conservado.") }
        if action == "replaceSource", let previous, var preserved = previous.objectValue,
           let oldID = preserved["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            let assets = CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId)
            let owned = try await assets.receipts(parentRecordId: record, generationId: oldID)
            let referenced = try await assets.referencedReceipts(parentRecordId: record, generationId: oldID)
            preserved["retainedAssetReceipts"] = .array(try (owned + referenced).map { try $0.jsonValue() })
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
            try await ledger.archiveDocumentVisualCheckpoint(recordId: record, checkpoint: .object(preserved))
        }
        var summary = object.filter { ["kind", "id", "entityKey", "target", "state", "error", "createdAt", "updatedAt", "recoveryReviewRequired"].contains($0.key) }
        summary["source"] = .object(["title": source["draft"]?.objectValue?["title"] ?? .null, "origin": source["origin"] ?? .null, "contentHash": source["contentHash"] ?? .null])
        try await cache.storeIndexedGeneration(data, vaultId: scope.recordVaultId, recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity, summary: .init(recordId: "autonomous:documentVisuals:summary:\(entity)", data: try JSONEncoder.nodus.encode(JSONValue.object(summary))))
        return value
    }
    static func summaries(session: SpaceSession) async throws -> [JSONValue] {
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        guard let data = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:documentVisuals:index:v1") else { return [] }
        let entities = try JSONDecoder.nodus.decode([String].self, from: data)
        var result: [JSONValue] = []
        for entity in entities {
            guard let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:documentVisuals:summary:\(entity)") else { throw APIError(status: 409, code: "document_visual_summary_missing", message: "Hay una sesión visual conservada cuyo resumen no está disponible. Su fuente y sus imágenes no se han eliminado.") }
            result.append(try JSONDecoder.nodus.decode(JSONValue.self, from: bytes))
        }
        return result
    }
    static func archives(reportID: String, session: SpaceSession, id: String? = nil) async throws -> JSONValue {
        let scope = try session.surfaceStorageScope(), ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
        let records = await ledger.all().filter { $0.method == "localDocumentVisuals" && $0.checkpoint?.objectValue?["target"]?.objectValue?["id"] == .string(reportID) && $0.checkpoint?.objectValue?["source"]?.objectValue?["vaultId"] == .string(scope.recordVaultId) }
        if let id { guard let found = records.first(where: { $0.id == id })?.checkpoint else { throw DesktopBridgeError.permissionDenied }; return found }
        return .array(records.map { record in .object(["id": .string(record.id), "state": .string(record.state), "createdAt": record.checkpoint?.objectValue?["createdAt"] ?? .null, "title": record.checkpoint?.objectValue?["source"]?.objectValue?["draft"]?.objectValue?["title"] ?? .null, "error": record.checkpoint?.objectValue?["error"] ?? .null]) })
    }
    static func context(reportID: String, generationID: String? = nil, session: SpaceSession) async throws -> JSONValue? {
        var value = try await checkpoint("load", reportID: reportID, session: session)
        let archived = generationID != nil && value.objectValue?["id"] != generationID.map(JSONValue.string)
        if archived, let generationID { value = try await archives(reportID: reportID, session: session, id: generationID) }
        guard let fields = value.objectValue, let manifest = fields["manifest"], !manifest.isNull,
              let identity = fields["id"]?.stringValue, let generation = UUID(uuidString: identity),
              let entity = fields["entityKey"]?.stringValue else { return nil }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId), record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: entity)
        let receipts: [CompanionDocumentFigureAssets.Receipt]
        if archived {
            receipts = try (fields["retainedAssetReceipts"]?.arrayValue ?? []).map { try CompanionDocumentFigureAssets.Receipt(value: $0) }
            guard receipts.allSatisfy({ $0.vaultId == scope.recordVaultId && $0.targetId == reportID }) else { throw DesktopBridgeError.permissionDenied }
        } else {
            let own = try await store.receipts(parentRecordId: record, generationId: generation)
            receipts = own + (try await store.referencedReceipts(parentRecordId: record, generationId: generation))
        }
        return .object(["manifest": manifest, "receipts": .array(try receipts.map { try $0.jsonValue() }), "entityKey": .string(entity), "generationId": .string(identity), "parentKind": .string("documentVisuals")])
    }
    static func resolve(reportID: String, session: SpaceSession) async throws -> JSONValue {
        let alias = reportID.hasPrefix("mobile-dr-") ? reportID : "mobile-dr-" + reportID
        let own: JSONValue?
        do { own = try await CompanionDeepResearchResult.checkpoint(session: session, id: alias) }
        catch let error as APIError where error.code == "mobile_report_missing" { own = nil }
        guard let object = own?.objectValue, let identity = object["id"]?.stringValue,
              let draft = object["report"]?.objectValue?["draft"], let entity = object["entityKey"]?.stringValue else {
            guard UUID(uuidString: reportID) != nil else { throw DesktopBridgeError.malformedResponse }
            return .object(["reportId": .string(reportID)])
        }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let parent = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
        guard let generation = UUID(uuidString: identity) else { throw DesktopBridgeError.malformedResponse }
        let manifest = object["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"] ?? .null
        let allReceipts = try await CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId).receipts(parentRecordId: parent, generationId: generation)
        let receipts = allReceipts.filter { receipt in CompanionResearchFigures.allows("nodus-image://chat/\(receipt.owner)/\(receipt.id.uuidString.lowercased())", context: .object(["manifest": manifest])) || CompanionResearchFigures.allows("nodus-capability://chat/\(receipt.owner)/\(receipt.id.uuidString.lowercased())", context: .object(["manifest": manifest])) }
        let assets = receipts.map { receipt in JSONValue.object(["id": .string(receipt.id.uuidString.lowercased()), "figureId": .string(receipt.figureKey), "owner": .string(receipt.owner), "mimeType": .string(receipt.mimeType), "byteCount": .int(receipt.byteCount), "sha256": .string(receipt.sha256)]) }
        // The original manifest has the canonical body hash; a report without
        // figures gets its hash from the browser's same pure report-field helper.
        var source: [String: JSONValue] = ["version": .int(1), "vaultId": .string(scope.recordVaultId), "target": .object(["kind": .string("deep-research"), "id": .string(identity)]), "draft": draft, "expectedRevision": manifest.objectValue?["revision"] ?? .null, "origin": .string("authored-mobile"), "originalReceipts": .array(try receipts.map { try $0.jsonValue() }), "publicationDependency": .object(["recordId": .string(parent), "generationId": .string(identity)])]
        if let hash = manifest.objectValue?["contentHash"] { source["contentHash"] = hash }
        return .object(["reportId": .string(identity), "source": .object(source), "captureManifest": manifest, "captureAssets": .array(assets)])
    }
    static func publicationReady(reportID: String, session: SpaceSession) async throws -> Bool {
        guard let value = try await CompanionDeepResearchResult.checkpoint(session: session, id: "mobile-dr-" + reportID) else { return false }
        return value.objectValue?["state"] == .string("available") && value.objectValue?["result"]?.objectValue?["id"] == .string(reportID)
    }
    static func requirePublishingSupport(session: SpaceSession) async throws {
        let (_, pairing, token) = try privateBridgeConnection(session, domain: .writing)
        guard pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let capabilities = try await DesktopBridgeClient(pairing: pairing, token: token).liveCapabilities()
        guard capabilities.operations.contains("saveMobileDeepResearchVisuals"), capabilities.operations.contains("getMobileDeepResearchVisualSource") else {
            throw APIError(status: 426, code: "document_visual_editor_upgrade_required", message: "Actualiza Nodus en el Mac para sincronizar esta edición visual. La fuente, las figuras y las respuestas siguen guardadas en este dispositivo y no se volverán a generar.")
        }
    }
    static func source(reportID: String, session: SpaceSession) async throws -> JSONValue {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
        guard pairing.domains.contains(.corpus), UUID(uuidString: reportID) != nil else { throw DesktopBridgeError.permissionDenied }
        try await requirePublishingSupport(session: session)
        return try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDeepResearchVisualSource", args: [.object(["reportId": .string(reportID)])])
    }
    /// Capture one existing image at a time. Receipt lookup makes an interrupted
    /// transfer restartable without changing the original report's asset IDs.
    static func captureAssets(reportID: String, session: SpaceSession, downloadedOnly: Bool = false) async throws -> JSONValue {
        let parent = try await checkpoint("load", reportID: reportID, session: session)
        guard let object = parent.objectValue, let source = object["source"]?.objectValue,
              let hash = source["captureHash"]?.stringValue, let generationText = object["id"]?.stringValue,
              let generation = UUID(uuidString: generationText),
              let assets = source["capture"]?.objectValue?["assets"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        try cache.beginAuthoringActivity()
        defer { cache.endAuthoringActivity() }
        let record = try CompanionGenerationPublication.recordId(kind: "documentVisuals", entity: "deep-research:\(reportID)")
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId)
        for asset in assets {
            try Task.checkCancellation()
            guard let fields = asset.objectValue, let original = fields["id"]?.stringValue, let id = UUID(uuidString: original),
                  let figureText = fields["figureId"]?.stringValue, let figure = UUID(uuidString: figureText),
                  let owner = fields["owner"]?.stringValue, let mime = fields["mimeType"]?.stringValue,
                  case .some(.int(let count)) = fields["byteCount"], (1...8 * 1_048_576).contains(count) else { throw DesktopBridgeError.malformedResponse }
            if try await store.receipts(parentRecordId: record, generationId: generation, figureId: figure, owner: owner).contains(where: { $0.id == id && $0.sha256 == fields["sha256"]?.stringValue }) { continue }
            if source["origin"] == .string("authored-mobile") {
                guard try await store.referencedReceipts(parentRecordId: record, generationId: generation).contains(where: { $0.id == id && $0.owner == owner && $0.sha256 == fields["sha256"]?.stringValue }) else { throw DesktopBridgeError.permissionDenied }
                continue
            }
            var bytes = Data(), offset: Int64 = 0
            if downloadedOnly && offset < count { throw APIError(status: 404, code: "document_visual_asset_not_downloaded", message: "La imagen de esta figura aún no está descargada. El trabajo conservado permanece disponible.") }
            while offset < count {
                try Task.checkCancellation()
                let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
                guard vault == scope.recordVaultId, pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
                let requested = min(Int64(CompanionDocumentFigureAssets.chunkBytes), count - offset)
                let result = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "readMobileDeepResearchVisualAsset", args: [.object(["reportId": .string(reportID), "captureHash": .string(hash), "assetId": .string(original), "owner": .string(owner), "offset": .int(offset), "count": .int(requested)])])
                guard result.objectValue?["offset"] == .int(offset), result.objectValue?["byteCount"] == .int(count),
                      let encoded = result.objectValue?["base64"]?.stringValue, let chunk = Data(base64Encoded: encoded), chunk.count == requested else { throw DesktopBridgeError.malformedResponse }
                bytes.append(chunk); offset += Int64(chunk.count)
            }
            guard fields["sha256"] == .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()) else { throw DesktopBridgeError.malformedResponse }
            let originalFigure = source["capture"]?.objectValue?["manifest"]?.objectValue?["figures"]?.arrayValue?.first { $0.objectValue?["id"] == .string(figureText) }
            if originalFigure?.objectValue?["ownerRevision"]?.stringValue == nil {
                _ = try await store.importCapturedLegacyAsset(data: bytes, mimeType: mime, parentRecordId: record, generationId: generation, figureId: figure, owner: owner, sourceAssetId: original, assetId: id)
            } else {
                _ = try await store.store(data: bytes, mimeType: mime, parentRecordId: record, generationId: generation, figureId: figure, owner: owner, assetId: id)
            }
        }
        let ownReceipts = try await store.receipts(parentRecordId: record, generationId: generation)
        let receipts = ownReceipts + (try await store.referencedReceipts(parentRecordId: record, generationId: generation))
        return .array(try receipts.map { try $0.jsonValue() })
    }

}
