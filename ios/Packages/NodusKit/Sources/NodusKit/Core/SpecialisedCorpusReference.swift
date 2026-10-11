import Foundation

/// Desktop's existing internal links resolve to known read collections. A link
/// never supplies a table, a vault identity, a grant or a filesystem path.
public struct SpecialisedCorpusReference: Sendable, Hashable {
    public enum ReadError: Error, LocalizedError, Sendable {
        case sourceMismatch
        public var errorDescription: String? { "El contenido recibido no pertenece a la fuente citada. Vuelve a abrir o descargar esa fuente desde Nodus." }
    }
    public let collectionPath: String
    public let recordId: String
    public let expectedParentId: String?
    public let expectedParentField: String?
    public let page: Int?
    public let slide: Int?
    public let from: Int?
    public let timestamp: Double?
    public let transcriptId: String?

    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "nodus", parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased() else { return nil }
        // Decode IDs once after splitting the encoded path. An encoded slash
        // belongs to the ID, not a second route component.
        let encoded = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let segments = encoded.compactMap { String($0).removingPercentEncoding }
        guard segments.count == encoded.count, segments.allSatisfy(Self.validId) else { return nil }
        var path: String?, identity: String?, parent: String?, parentField: String?
        switch host {
        case "world" where segments.count == 2:
            path = ["character": "persons", "place": "places", "event": "events", "group": "world-groups",
                "scene": "world-scenes", "article": "world-articles", "map": "world-maps", "thread": "world-threads",
                "rule": "world-rules", "question": "world-questions", "secret": "world-secrets"][segments[0]]
            identity = segments[1]
        case "study" where segments.count == 2:
            path = ["doc": "study-docs", "material": "study-materials"][segments[0]]
            identity = segments[1]
        case "archive" where segments.count == 1:
            path = "archive-items"; identity = segments[0]
        case "primary-source" where segments.count == 1:
            path = "archive-items"; identity = segments[0]
        case "primary-source" where segments.count == 3 && segments[1] == "excerpt":
            path = "archive-excerpts"; identity = segments[2]; parent = segments[0]; parentField = "item_id"
        case "testimonios" where segments.count == 2:
            path = ["interview": "testimony-interviews", "participant": "persons", "contrast": "testimony-contrasts"][segments[0]]
            identity = segments[1]
        default: return nil
        }
        guard let path, let identity, Collections[path] != nil else { return nil }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        func positive(_ name: String) -> Int? { query[name].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } }
        collectionPath = path; recordId = identity; expectedParentId = parent; expectedParentField = parentField
        page = positive("page"); slide = positive("slide"); from = positive("from")
        timestamp = query["t"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        transcriptId = query["transcript"].flatMap { Self.validId($0) ? $0 : nil }
    }
    public func accepts(_ row: Row) -> Bool {
        guard let descriptor = Collections[collectionPath], row.string(descriptor.idField) == recordId else { return false }
        guard let expectedParentId, let expectedParentField else { return true }
        return row.string(expectedParentField) == expectedParentId
    }
    private static func validId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".."
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
