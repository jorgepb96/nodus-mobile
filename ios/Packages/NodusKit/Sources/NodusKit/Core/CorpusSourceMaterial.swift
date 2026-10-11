import Foundation

/// Provider-free citable projections for public specialised records. The map
/// mirrors sourceMaterials.mjs; private data has its own grant and contract.
public struct CorpusSourceMaterial: Sendable {
    private struct Projection {
        let route: String
        let fields: [String]
    }
    private static let projections: [String: Projection] = [
        "persons": .init(route: "person", fields: ["display_name", "notes", "biography"]),
        "places": .init(route: "place", fields: ["name", "kind", "notes"]),
        "events": .init(route: "event", fields: ["title", "name", "description", "notes"]),
        "world-groups": .init(route: "world/group", fields: ["name", "summary", "description", "notes"]),
        "world-scenes": .init(route: "world/scene", fields: ["title", "summary", "notes"]),
        "world-articles": .init(route: "world/article", fields: ["title", "summary", "body", "notes"]),
        "world-threads": .init(route: "world/thread", fields: ["title", "pitch", "stakes", "outcome"]),
        "world-rules": .init(route: "world/rule", fields: ["title", "statement", "cost", "limits"]),
        "world-questions": .init(route: "world/question", fields: ["question"]),
        "world-secrets": .init(route: "world/secret", fields: ["title", "content", "notes"]),
        "study-docs": .init(route: "study/doc", fields: ["title", "summary", "content", "content_markdown", "notes"]),
        "study-materials": .init(route: "study/material", fields: ["title", "description", "summary", "text"]),
        "archive-items": .init(route: "archive", fields: ["title", "description", "notes", "source", "date_display"]),
        "archive-excerpts": .init(route: "primary-source-excerpt", fields: ["quoted_text", "locator_display"]),
        "testimony-interviews": .init(route: "testimonios/interview", fields: ["title", "description", "summary", "notes"]),
        "testimony-contrasts": .init(route: "testimonios/contrast", fields: ["title", "memo_markdown", "summary", "description"]),
    ]
    public static var paths: [String] { projections.keys.sorted() }
    public let row: Row
    public var citation: String { row.string("citation")! }
    public var id: String { row.string("recordId")! }
    public var kind: String { row.string("kind")! }
    public var label: String { row.text("label")! }
    public var text: String { row.string("text")! }

    public init(row: Row) throws {
        if row["privateKind"] != nil {
            self.row = try PrivateCorpusSourceMaterial(row: row).row
            return
        }
        guard row.int("version") == 1, let path = row.string("collection"), let projection = Self.projections[path],
              let id = row.string("recordId"), !id.isEmpty, let citation = row.string("citation"),
              let label = row.text("label"), !label.isEmpty, let text = row.text("text"), !text.isEmpty,
              ["record", "metadata"].contains(row.string("contentScope") ?? ""),
              citation == Self.citation(projection: projection, id: id, parent: row.string("parentId")),
              row.string("kind") == citation.components(separatedBy: "://").last?.components(separatedBy: "/").first else { throw DesktopBridgeError.malformedResponse }
        self.row = row
    }
    private static func citation(projection: Projection, id: String, parent: String?) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let identity = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        if projection.route == "primary-source-excerpt" {
            guard let parent, !parent.isEmpty, let encoded = parent.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "nodus://primary-source/\(encoded)/excerpt/\(identity)"
        }
        return "nodus://\(projection.route)/\(identity)"
    }
    public static func selected(copy: CompanionCollectionCopy) throws -> [Row] {
        guard let projection = projections[copy.collection.path] else { throw DesktopBridgeError.permissionDenied }
        return try copy.selectedRows.compactMap { primary in
            guard let id = primary.string(copy.collection.idField) else { throw DesktopBridgeError.malformedResponse }
            var parts = projection.fields.compactMap { primary.string($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if copy.collection.path == "world-scenes" {
                let body = try copy.dossier(id: id).payload.objectValue?["text"]?.objectValue
                if body?["scene_id"]?.stringValue == id,
                   let text = body?["content_markdown"]?.stringValue ?? body?["text"]?.stringValue ?? body?["body"]?.stringValue, !text.isEmpty { parts.append(text) }
            }
            let parent = primary.string("item_id")
            guard !parts.isEmpty, let citation = citation(projection: projection, id: id, parent: parent) else { return nil }
            let metadata = copy.collection.path == "study-materials" && primary.text("text") == nil
            var text = parts.joined(separator: "\n\n")
            if metadata { text = "Solo metadatos del material; no contiene su documento original ni una extracción de este.\n\n" + text }
            let label = primary.text("title") ?? primary.text("name") ?? primary.text("display_name") ?? primary.text("question") ?? primary.text("locator_display") ?? parts[0]
            let row = Row(["version": .int(1), "collection": .string(copy.collection.path), "recordId": .string(id),
                "kind": .string(citation.components(separatedBy: "://").last!.components(separatedBy: "/").first!),
                "citation": .string(citation), "label": .string(String(label.prefix(240))), "text": .string(text),
                "contentScope": .string(metadata ? "metadata" : "record"), "locator": primary.columns["locator_display"] ?? .null,
                "parentId": projection.route == "primary-source-excerpt" ? parent.map(JSONValue.string) ?? .null : .null])
            return try CorpusSourceMaterial(row: row).row
        }
    }
}
