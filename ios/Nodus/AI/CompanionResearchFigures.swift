import Foundation
import NodusKit

/// The rich reader receives only the exact manifest and small receipts. Its
/// Markdown source and UTF-16 annotation offsets remain unchanged.
@MainActor enum CompanionResearchFigures {
    static func context(session: SpaceSession, reportID: String, downloadedOnly: Bool = false, preferAuthored: Bool = false, expectedDraft:JSONValue? = nil) async throws -> JSONValue? {
        if !downloadedOnly, !preferAuthored, !reportID.hasPrefix("mobile-dr-"), session.connection.desktopPairingId != nil, !session.isDemo {
            return try await CompanionLiveDocumentVisualRead.context(session:session,reportID:reportID,expectedDraft:expectedDraft)
        }
        if downloadedOnly, !preferAuthored, session.connection.desktopPairingId != nil, !session.isDemo {
            return try await CompanionDownloadedResearchFigures.context(session:session,reportID:reportID,expectedDraft:expectedDraft)
        }
        let identity = reportID.hasPrefix("mobile-dr-") ? String(reportID.dropFirst(10)) : reportID
        if UUID(uuidString: identity) != nil, let context = try await CompanionDocumentVisualSession.context(reportID: identity, session: session) { return context }
        guard let checkpoint = try await CompanionDeepResearchResult.checkpoint(session: session, id: reportID, publishedReceipt: !reportID.hasPrefix("mobile-dr-")),
              let object = checkpoint.objectValue,
              let manifest = object["report"]?.objectValue?["mobileVisuals"]?.objectValue?["manifest"],
              let entity = object["entityKey"]?.stringValue, let original = object["id"]?.stringValue,
              let generation = UUID(uuidString: original) else { return nil }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let receipts = try await CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId).receipts(parentRecordId: CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity), generationId: generation)
        return .object(["manifest": manifest, "receipts": .array(try receipts.map { try $0.jsonValue() }), "entityKey": .string(entity), "generationId": .string(original)])
    }
    static func allows(_ source: String, context: JSONValue?) -> Bool {
        guard let url = URL(string: source), ["nodus-image", "nodus-capability"].contains(url.scheme), url.host == "chat", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let object = context?.objectValue else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[1]) != nil,
              let figures = object["manifest"]?.objectValue?["figures"]?.arrayValue else { return false }
        func includes(_ nodes: [JSONValue]) -> Bool {
            nodes.contains { node in
                node.objectValue?["attachmentId"]?.stringValue?.lowercased() == parts[1].lowercased()
                || includes(node.objectValue?["children"]?.arrayValue ?? [])
            }
        }
        return figures.contains { value in
            guard let figure = value.objectValue, figure["owner"] == .string(parts[0]) else { return false }
            if url.scheme == "nodus-image" { return figure["poster"] == .string(source) }
            return includes(figure["view"]?.objectValue?["nodes"]?.arrayValue ?? [])
        }
    }
    static func svg(_ svg: String, figureID: String, context: JSONValue?) -> Bool {
        guard svg.utf8.count <= 1_048_576,
              let figure = context?.objectValue?["manifest"]?.objectValue?["figures"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(figureID) }) else { return false }
        func contains(_ nodes: [JSONValue]) -> Bool {
            nodes.contains { $0.objectValue?["kind"] == .string("svg") && $0.objectValue?["svg"] == .string(svg) || contains($0.objectValue?["children"]?.arrayValue ?? []) }
        }
        return contains(figure.objectValue?["view"]?.objectValue?["nodes"]?.arrayValue ?? [])
    }
    static func load(_ source: String, context: JSONValue, session: SpaceSession) async throws -> ReaderImageSource.Content {
        if context.objectValue?["unsupportedOriginals"]?.arrayValue?.contains(.string(source)) == true { throw APIError(status:415,code:"figure_original_not_available",message:"Este tipo de original todavía no está disponible en este lector. La vista previa se conserva.") }
        if context.objectValue?["origin"] == .string("downloaded-mac") { return try await CompanionDownloadedResearchFigures.data(source,context:context,session:session) }
        if context.objectValue?["origin"] == .string("live-mac") { return try await CompanionLiveDocumentVisualRead.data(source,context:context,session:session) }
        guard allows(source, context: context), let url = URL(string: source), let id = url.path.split(separator: "/").last,
              let raw = context.objectValue?["receipts"]?.arrayValue?.first(where: { $0.objectValue?["id"]?.stringValue?.lowercased() == id.lowercased() }) else { throw DesktopBridgeError.permissionDenied }
        let receipt = try CompanionDocumentFigureAssets.Receipt(value: raw)
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        guard receipt.vaultId == scope.recordVaultId, receipt.byteCount <= 8 * 1_048_576, url.path.split(separator: "/").first.map(String.init) == receipt.owner else { throw DesktopBridgeError.permissionDenied }
        let data = try await CompanionDocumentFigureAssets(cache: cache, vaultId: scope.recordVaultId).data(receipt)
        return .init(data: data, mime: receipt.mimeType)
    }
}
