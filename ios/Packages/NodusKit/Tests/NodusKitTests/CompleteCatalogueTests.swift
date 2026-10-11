import Foundation
import Testing
@testable import NodusKit

@Suite("Complete companion catalogues")
struct CompleteCatalogueTests {
    @Test("Study, agenda and family catalogues preserve records beyond previous UI caps")
    func fullCatalogues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = ["study_questions": 1205, "study_flashcards": 407, "study_goals": 1600, "persons": 2201, "relationships": 4401]
        let ids = ["persons": "person_id", "relationships": "rel_id"]
        var tables: [String: JSONValue] = [:]
        for (table, count) in counts {
            tables[table] = .array((0..<count).map { index in .object([ids[table] ?? "id": .string("\(table)-\(index)"), "title": .string("Fuente \(index)"), "name": .string("Persona \(index)"), "prompt": .string("Pregunta \(index)")]) })
        }
        let document = JSONValue.object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "revision": .string("complete-catalogue"), "tables": .object(tables)])
        let archive = try JSONEncoder.nodus.encode(document)
        let mirror = try await MirrorStore.open(spaceId: "catalogue-lab", directory: directory)
        try await mirror.replace(with: SnapshotDownload.read(archive), revision: "complete-catalogue")
        let client = NodusClient(local: LocalCorpus(space: .init(id: "catalogue-lab", name: "Catálogos completos"), mirror: mirror, archive: archive), address: ServerAddress(trusted: "nodus-demo://this-device"), cache: ResponseCache(directory: directory.appendingPathComponent("cache")))
        for path in ["study-questions", "study-flashcards", "study-goals", "persons", "relationships"] {
            let collection = try #require(Collections[path])
            let rows = try await client.allItems(collection, in: "catalogue-lab")
            #expect(rows.count == counts[collection.table])
            #expect(Set(rows.compactMap { $0.string(collection.idField) }).count == rows.count)
            let found = try await client.allItems(collection, in: "catalogue-lab", query: "Fuente 1204")
            if rows.count > 1204 { #expect(found.count == 1) }
        }
    }
}
