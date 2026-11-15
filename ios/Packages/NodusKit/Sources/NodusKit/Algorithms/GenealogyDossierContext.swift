import Foundation

/// Named join context from the owning dossier only. Related summaries are
/// navigation targets, never independently downloaded neighbour dossiers.
public enum GenealogyDossierContext {
    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let association: Row
        public let target: Row?
        public let collectionPath: String
        public let associationPath: String?
        public let title: String?
    }
    public struct Section: Identifiable, Sendable {
        public let id: String
        public let entries: [Entry]
    }

    /// Only explicit bibliography pointers use the public Works reader. Archive
    /// source pointers cannot be relabelled as works or fabricate an archive row.
    public static func archiveSources(_ dossier: CollectionDossier) -> [PrivateCorpusReference] {
        var seen = Set<String>()
        return (dossier.sections["evidence"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue, object["source_kind"] == .string("archive"),
                  let id = object["nodus_id"]?.stringValue else { return nil }
            let excerpt = object["excerpt_id"]?.stringValue
            guard seen.insert("\(id):\(excerpt ?? "")").inserted else { return nil }
            return try? PrivateCorpusReference(kind: .archive, id: id, annotationId: excerpt)
        }
    }

    public static func bibliographySources(_ dossier: CollectionDossier) -> [Entry] {
        (dossier.sections["evidence"]?.arrayValue ?? []).enumerated().compactMap { offset, value in
            guard let object = value.objectValue, object["source_kind"] == .string("work"),
                  let id = object["nodus_id"]?.stringValue, !id.isEmpty else { return nil }
            return Entry(id: object["id"]?.stringValue ?? "evidence:\(offset)", association: Row(object),
                target: Row(["nodus_id": .string(id)]), collectionPath: "works", associationPath: nil, title: nil)
        }
    }

    public static func sections(_ dossier: CollectionDossier) -> [Section] {
        func rows(_ key: String) -> [Row] { (dossier.sections[key]?.arrayValue ?? []).compactMap { $0.objectValue.map(Row.init) } }
        func index(_ key: String, _ idField: String) -> [String: Row] {
            Dictionary(rows(key).compactMap { row in row.string(idField).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        }
        var result: [Section] = []
        func append(_ section: String, _ links: [Row], path: String, associationPath: String? = nil,
                    targets: [String: Row], targetID: (Row) -> String?) {
            guard !links.isEmpty else { return }
            result.append(Section(id: section, entries: links.enumerated().map { offset, link in
                let target = targetID(link).flatMap { targets[$0] }
                return Entry(id: "\(section):\(offset)", association: link, target: target, collectionPath: path,
                    associationPath: associationPath, title: target.flatMap { row in
                        ["display_name", "name", "label", "title"].compactMap { row.text($0) }.first
                    })
            }))
        }
        switch dossier.collection.path {
        case "persons":
            let selected = dossier.primary.string("person_id")
            append("relationships", rows("relationships"), path: "persons", associationPath: "relationships",
                   targets: index("relatedPersons", "person_id")) { row in
                let from = row.string("from_person") ?? row.string("from_person_id")
                let to = row.string("to_person") ?? row.string("to_person_id")
                return from == selected ? to : to == selected ? from : nil
            }
            append("placeLinks", rows("placeLinks"), path: "places", targets: index("places", "place_id")) { $0.string("place_id") }
        case "places":
            append("personLinks", rows("personLinks"), path: "persons", targets: index("persons", "person_id")) { $0.string("person_id") }
        case "events":
            append("participantRows", rows("participantRows"), path: "persons", targets: index("participants", "person_id")) { $0.string("person_id") }
        default: break
        }
        return result
    }
}
