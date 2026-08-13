import Foundation

public struct PublishedLibraryCollection: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let icon: String?
    public let color: String?
    public let parentId: String?
    public let position: Int
    public let directItemCount: Int
    public let updatedAt: Date
}

public struct PublishedLibraryAnnotation: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let draftId: String
    public let scope: String
    public let kind: String
    public let color: String?
    public let startOffset: Int
    public let endOffset: Int
    public let selectedText: String
    public let prefix: String
    public let suffix: String
    public let comment: String?
    public let createdAt: Date
    public let updatedAt: Date

    /// The shared reader consumes snapshot-shaped rows. Keep that conversion here so the UI
    /// cannot accidentally invent a second annotation contract.
    public var row: Row {
        let timestamp = ISO8601DateFormatter.nodusFractional
        return Row([
            "id": .string(id), "draft_id": .string(draftId), "scope": .string(scope),
            "kind": .string(kind), "color": color.map(JSONValue.string) ?? .null,
            "start_offset": .int(Int64(startOffset)), "end_offset": .int(Int64(endOffset)),
            "selected_text": .string(selectedText), "prefix": .string(prefix), "suffix": .string(suffix),
            "comment_text": comment.map(JSONValue.string) ?? .null,
            "created_at": .string(timestamp.string(from: createdAt)),
            "updated_at": .string(timestamp.string(from: updatedAt)),
        ])
    }
}

public struct PublishedLibraryDocument: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let itemType: String
    public let creators: [String]
    public let abstract: String?
    public let date: String?
    public let year: Int?
    public let language: String?
    public let publisher: String?
    public let publicationTitle: String?
    public let doi: String?
    public let url: String?
    public let tags: [String]
    public let collectionIds: [String]
    public let updatedAt: Date
    public let cleanAvailable: Bool
    public let wordCount: Int
    public let figureCount: Int
    public let packageHash: String?
    public let packageBytes: Int?
    public let originalAvailable: Bool
    public let originalFileName: String?
    public let originalMimeType: String?
    public let annotations: [PublishedLibraryAnnotation]

    public var libraryDraftId: String { "nodus-library:\(id)" }
    public var libraryAnnotationRoutingPrefix: String {
        let encoded = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "library-annotation:\(encoded):"
    }
    public var annotationRows: [Row] {
        annotations.map { annotation in
            var columns = annotation.row.columns
            columns["id"] = .string(libraryAnnotationRoutingPrefix + annotation.id)
            columns["draft_id"] = .string(libraryDraftId)
            columns["scope"] = .string("library")
            return Row(columns)
        }
    }
}

public struct PublishedLibraryDocumentPage: Sendable, Hashable, Codable {
    public let items: [PublishedLibraryDocument]
    public let total: Int
    public let limit: Int
    public let offset: Int
    public let hasMore: Bool
    public let generatedAt: Date
}

private struct PublishedLibraryCollectionsEnvelope: Decodable {
    let collections: [PublishedLibraryCollection]
    let generatedAt: Date
}

private struct PublishedLibraryDocumentEnvelope: Decodable {
    let document: PublishedLibraryDocument
    let generatedAt: Date
}

public extension NodusClient {
    func publishedLibraryCollections(in spaceId: String) async throws -> [PublishedLibraryCollection] {
        let response = try await perform(.init(path: address.spacePath(spaceId, "/library/collections"), cacheable: true))
        return try decode(PublishedLibraryCollectionsEnvelope.self, from: response).collections
    }

    func publishedLibraryDocuments(
        in spaceId: String,
        query: String? = nil,
        collectionId: String? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> PublishedLibraryDocumentPage {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, min(200, limit)))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]
        if let query, !query.isEmpty { queryItems.append(.init(name: "q", value: query)) }
        if let collectionId, !collectionId.isEmpty { queryItems.append(.init(name: "collectionId", value: collectionId)) }
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/library/documents"), query: queryItems, cacheable: true
        ))
        return try decode(PublishedLibraryDocumentPage.self, from: response)
    }

    func publishedLibraryDocument(_ id: String, in spaceId: String) async throws -> PublishedLibraryDocument {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/library/documents/\(escape(id))"), cacheable: true
        ))
        return try decode(PublishedLibraryDocumentEnvelope.self, from: response).document
    }

    func publishedLibraryPackage(_ id: String, in spaceId: String) async throws -> Data {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/library/documents/\(escape(id))/download.zip"),
            extraHeaders: ["Accept": "application/zip"]
        ))
        return response.data
    }
}
