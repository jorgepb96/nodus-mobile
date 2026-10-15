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
        guard action == "save", let value, let object = value.objectValue,
              object["version"] == .int(1), object["kind"] == .string("documentVisuals"),
              object["entityKey"] == .string(entity), let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
              object["target"]?.objectValue?["kind"] == .string("deep-research"), object["target"]?.objectValue?["id"] == .string(reportID),
              let source = object["source"]?.objectValue, source["vaultId"] == .string(scope.recordVaultId), source["target"] == object["target"],
              source["draft"]?.objectValue?["brief"]?.objectValue?["kind"] == .string("deep_research"),
              let canonical = source["captureCanonical"]?.stringValue,
              let captureData = canonical.data(using: .utf8), try JSONDecoder.nodus.decode(JSONValue.self, from: captureData) == source["capture"],
              source["captureHash"] == .string(SHA256.hash(data: captureData).map { String(format: "%02x", $0) }.joined()) else { throw DesktopBridgeError.malformedResponse }
        if let previous {
            guard previous.objectValue?["id"] == .string(id), previous.objectValue?["source"] == object["source"] else {
                throw APIError(status: 409, code: "document_visual_source_conflict", message: "Esta sesión conserva otra versión del informe. Revisa el cambio antes de sustituir su fuente.")
            }
            guard previous.objectValue?["recoveryReviewRequired"] != .bool(true) else { throw DesktopBridgeError.permissionDenied }
        } else if session.aiExecutionMode != .autonomous { throw DesktopBridgeError.permissionDenied }
        try cache.beginAuthoringActivity()
        defer { cache.endAuthoringActivity() }
        try await cache.requireGenerationExecutionAllowed(vaultId: scope.recordVaultId, generationId: id)
        let data = try JSONEncoder.nodus.encode(value)
        guard data.count <= 50 * 1_048_576 else { throw APIError(status: 413, code: "document_visual_source_too_large", message: "La fuente y el trabajo visual superan el límite de 50 MiB. El trabajo anterior permanece conservado.") }
        try await cache.storeIndexedGeneration(data, vaultId: scope.recordVaultId, recordId: record, indexId: "autonomous:documentVisuals:index:v1", entity: entity)
        return value
    }
    static func source(reportID: String, session: SpaceSession) async throws -> JSONValue {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
        guard pairing.domains.contains(.corpus), UUID(uuidString: reportID) != nil else { throw DesktopBridgeError.permissionDenied }
        return try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDeepResearchVisualSource", args: [.object(["reportId": .string(reportID)])])
    }
}
