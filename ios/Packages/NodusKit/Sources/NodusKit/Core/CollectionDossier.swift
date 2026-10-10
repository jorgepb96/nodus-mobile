import Foundation

/// A complete public dossier. Unknown sections remain in the reader instead of
/// being discarded when the Desktop schema adds a version or relation table.
public struct CollectionDossier: Sendable {
    public let collection: CollectionDescriptor
    public let primary: Row
    public let sections: [String: JSONValue]
    public let fromDevice: Bool
    public let payload: JSONValue
    private let primaryKey: String

    public init(collection: CollectionDescriptor, id: String, payload: JSONValue, fromDevice: Bool = false) throws {
        guard let object = payload.objectValue,
              let primary = CompanionCollectionCopy.primaryRow(collection, detail: object),
              primary[collection.idField]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
        self.collection = collection
        self.primary = Row(primary)
        self.fromDevice = fromDevice
        let primaryKey = object[collection.detailKey]?.objectValue != nil ? collection.detailKey : "document"
        self.primaryKey = primaryKey
        self.payload = payload
        self.sections = object.filter { $0.key != primaryKey && $0.key != "revision" && $0.value != .null }
    }

    public func decode<Model: Decodable & Sendable>(_ type: Model.Type) throws -> Model {
        try JSONDecoder.nodus.decode(type, from: JSONEncoder.nodus.encode(payload))
    }

    /// Native domain components render their known fields. Keep every other
    /// section beside them, using the same response and the same revision.
    public func supplement(excluding rendered: Set<String>) throws -> Self? {
        var remaining = sections.filter { !rendered.contains($0.key) }
        guard !remaining.isEmpty, let id = primary.string(collection.idField) else { return nil }
        remaining[primaryKey] = .object(primary.columns)
        return try Self(collection: collection, id: id, payload: .object(remaining), fromDevice: fromDevice)
    }

    /// Only explicit domain context can turn a row into a navigable dossier.
    /// Annotation ids, version ids and aggregate identity keys are never guessed.
    public func linkedCollection(for section: String) -> CollectionDescriptor? {
        let common: [String: String] = ["ideas": "ideas", "works": "works", "authors": "authors", "relatedPersons": "persons",
            "places": "places", "events": "events", "subjects": "study-subjects", "plans": "study-plans",
            "transcripts": "testimony-transcripts", "codes": "testimony-codes"]
        let specific: [String: String]
        switch collection.path {
        case "places": specific = ["parent": "places", "children": "places", "persons": "persons"]
        case "events": specific = ["participants": "persons", "place": "places"]
        case "relationships": specific = ["from": "persons", "to": "persons"]
        case "persons": specific = ["scenes": "world-scenes", "secrets": "world-secrets"]
        case "world-groups": specific = ["children": "world-groups", "members": "persons", "seat": "places"]
        case "world-scenes": specific = ["place": "places"]
        case "world-articles": specific = ["rules": "world-rules"]
        case "world-rules": specific = ["children": "world-rules", "article": "world-articles"]
        case "archive-items": specific = ["excerpts": "archive-excerpts", "units": "archive-units", "repository": "archive-repositories", "analysis": "source-analyses"]
        case "archive-repositories": specific = ["units": "archive-units", "items": "archive-items"]
        case "archive-units": specific = ["repository": "archive-repositories", "items": "archive-items"]
        case "archive-excerpts", "source-analyses": specific = ["item": "archive-items"]
        default: specific = [:]
        }
        return (specific[section] ?? common[section]).flatMap { Collections[$0] }
    }
}
