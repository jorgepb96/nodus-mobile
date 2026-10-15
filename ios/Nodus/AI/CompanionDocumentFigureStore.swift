import CryptoKit
import Foundation
import NodusKit

/// Figure bytes remain authored encrypted chunks. Bridge calls expose one asset or
/// one chunk, while report checkpoints and publication requests carry receipts.
@MainActor enum CompanionDocumentFigureStore {
    private static func context(_ session: SpaceSession, _ input: JSONValue) throws -> (PrivateBridgeCache, String, String, UUID) {
        guard let object = input.objectValue, let entity = object["entityKey"]?.stringValue,
              let original = object["generationId"]?.stringValue, let generation = UUID(uuidString: original) else { throw DesktopBridgeError.malformedResponse }
        let parentKind = object["parentKind"]?.stringValue ?? "deepResearch"
        guard ["deepResearch", "documentVisuals"].contains(parentKind) else { throw DesktopBridgeError.malformedResponse }
        let scope = try session.surfaceStorageScope()
        return (try PrivateBridgeCache(pairingId: scope.cacheId), scope.recordVaultId,
                try CompanionGenerationPublication.recordId(kind: parentKind, entity: entity), generation)
    }
    static func store(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        let (cache, vault, parent, generation) = try context(session, input)
        guard let object = input.objectValue, let owner = object["owner"]?.stringValue,
              let figure = UUID(uuidString: object["figureId"]?.stringValue ?? ""),
              let encoded = object["base64"]?.stringValue, encoded.utf8.count <= 12_000_000,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 8 * 1_048_576,
              let mime = object["mimeType"]?.stringValue,
              let kind = object["kind"]?.stringValue, ["image", "file"].contains(kind) else { throw DesktopBridgeError.malformedResponse }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let identity = SHA256.hash(data: Data("\(owner):\(mime):\(hash)".utf8)).map { String(format: "%02x", $0) }.joined()
        let hex = String(identity.prefix(32)), cuts = [8, 12, 16, 20]
        let formatted = hex.enumerated().map { (cuts.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
        guard let id = UUID(uuidString: formatted) else { throw DesktopBridgeError.malformedResponse }
        let receipt = try await CompanionDocumentFigureAssets(cache: cache, vaultId: vault).store(data: bytes, mimeType: mime, parentRecordId: parent, generationId: generation, figureId: figure, owner: owner, assetId: id, sourceCompletionRecordId: object["sourceCompletionRecordId"]?.stringValue)
        let source = "nodus-\(kind == "image" ? "image" : "capability")://chat/\(owner)/\(receipt.id.uuidString.lowercased())"
        return .object(["receipt": try receipt.jsonValue(), "source": .string(source), "attachmentId": .string(receipt.id.uuidString.lowercased()), "sha256": .string(receipt.sha256), "byteCount": .int(receipt.byteCount)])
    }
    static func receipts(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        let (cache, vault, parent, generation) = try context(session, input)
        let figure = input.objectValue?["figureId"]?.stringValue.flatMap(UUID.init(uuidString:))
        let values = try await CompanionDocumentFigureAssets(cache: cache, vaultId: vault).receipts(parentRecordId: parent, generationId: generation, figureId: figure, owner: input.objectValue?["owner"]?.stringValue)
        return .array(try values.map { try $0.jsonValue() })
    }
    static func read(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        let (cache, vault, parent, generation) = try context(session, input)
        guard let value = input.objectValue?["receipt"] else { throw DesktopBridgeError.malformedResponse }
        let receipt = try CompanionDocumentFigureAssets.Receipt(value: value)
        guard receipt.parentRecordId == parent, receipt.generationId == generation, receipt.vaultId == vault else { throw DesktopBridgeError.permissionDenied }
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: vault)
        if let offset = input.objectValue?["offset"]?.intValue, let count = input.objectValue?["count"]?.intValue,
           let bounded = Int(exactly: count), (1...CompanionDocumentFigureAssets.chunkBytes).contains(bounded) {
            return .string(try await store.read(receipt, offset: offset, count: bounded).base64EncodedString())
        }
        guard receipt.byteCount <= 8 * 1_048_576 else { throw DesktopBridgeError.malformedResponse }
        return .object(["base64": .string(try await store.data(receipt).base64EncodedString()), "mimeType": .string(receipt.mimeType)])
    }
    static func publish(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        let (cache, vault, parent, generation) = try context(session, input)
        guard let raw = input.objectValue?["assets"]?.arrayValue, raw.count <= 1000 else { throw DesktopBridgeError.malformedResponse }
        let store = CompanionDocumentFigureAssets(cache: cache, vaultId: vault)
        let receipts = try await store.receipts(parentRecordId: parent, generationId: generation)
        var results: [JSONValue] = []
        for asset in raw {
            guard let object = asset.objectValue, let id = UUID(uuidString: object["id"]?.stringValue ?? ""),
                  let receipt = receipts.first(where: { $0.id == id }), receipt.byteCount <= 8 * 1_048_576 else { throw DesktopBridgeError.permissionDenied }
            guard object["owner"] == .string(receipt.owner), object["ownerRevision"] == .string(receipt.ownerRevision),
                  object["generationId"] == .string(receipt.targetId), object["figureId"] == .string(receipt.figureKey),
                  object["mimeType"] == .string(receipt.mimeType), object["byteCount"]?.intValue == receipt.byteCount,
                  object["sha256"] == .string(receipt.sha256) else { throw DesktopBridgeError.permissionDenied }
            try await cache.requireGenerationExecutionAllowed(vaultId: vault, generationId: generation.uuidString.lowercased())
            var manifest = object
            manifest["version"] = .int(1); manifest["vaultId"] = .string(vault)
            manifest["metadata"] = object["metadata"] ?? .object([:])
            let request: JSONValue = .object(["manifest": .object(manifest)])
            func send(_ action: String, _ body: JSONValue) async throws -> JSONValue {
                try await cache.requireGenerationExecutionAllowed(vaultId: vault, generationId: generation.uuidString.lowercased())
                let (currentVault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
                guard currentVault == vault, pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
                return try await DesktopBridgeClient(pairing: pairing, token: token).researchFigureUpload(vaultId: vault, uploadId: id, action: action, body: body)
            }
            let begun = try await send("begin", request)
            if begun.objectValue?["state"] != .string("available") {
                let received = Set((begun.objectValue?["received"]?.arrayValue ?? []).compactMap { $0.objectValue?["index"]?.intValue })
                var offset: Int64 = 0, index: Int64 = 0
                while offset < receipt.byteCount {
                    let count = Int(min(Int64(CompanionDocumentFigureAssets.chunkBytes), receipt.byteCount - offset))
                    let bytes = try await store.read(receipt, offset: offset, count: count)
                    if !received.contains(index) {
                        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        _ = try await send("chunk", .object(["index": .int(index), "bytes": .string(bytes.base64EncodedString()), "sha256": .string(digest)]))
                    }
                    offset += Int64(count); index += 1
                }
                let result = try await send("commit", .object([:]))
                guard result.objectValue?["state"] == .string("available") else { throw DesktopBridgeError.malformedResponse }
                results.append(result)
            } else { results.append(begun) }
        }
        return .array(results)
    }

}
