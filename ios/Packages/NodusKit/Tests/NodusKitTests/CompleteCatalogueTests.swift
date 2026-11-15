import Foundation
import Testing
@testable import NodusKit

@Suite("Complete companion catalogues")
struct CompleteCatalogueTests {
    @Test("All nine vault families and Dictionary preserve catalogues beyond previous UI caps")
    func fullCatalogues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = ["study_questions": 1205, "study_flashcards": 407, "study_goals": 1600, "persons": 2201, "relationships": 4401, "works": 405, "world_rules": 407, "archive_items": 409, "testimony_codes": 411, "prosopography_public_variables": 413, "teaching_rubrics": 415, "db_databases": 417, "dictionary_entries": 419, "writing_saved_drafts": 421]
        let ids = ["persons": "person_id", "relationships": "rel_id", "works": "nodus_id", "world_rules": "rule_id", "archive_items": "item_id"]
        var tables: [String: JSONValue] = [:]
        for (table, count) in counts {
            tables[table] = .array((0..<count).map { index in .object([ids[table] ?? "id": .string("\(table)-\(index)"), "title": .string("Fuente \(index)"), "name": .string("Persona \(index)"), "prompt": .string("Pregunta \(index)")]) })
        }
        tables["writing_saved_drafts"] = .array((0..<421).map { index in .object([
            "id": .string("report-\(index)"), "title": .string("Informe \(index)"),
            "brief_json": .object(["kind": .string("deep_research"), "objective": .string("Corpus completo")]),
            "draft_json": .object(["draftMarkdown": .string("Informe original \(index)")]),
        ]) })
        let document = JSONValue.object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "revision": .string("complete-catalogue"), "tables": .object(tables)])
        let archive = try JSONEncoder.nodus.encode(document)
        let mirror = try await MirrorStore.open(spaceId: "catalogue-lab", directory: directory)
        try await mirror.replace(with: SnapshotDownload.read(archive), revision: "complete-catalogue")
        let client = NodusClient(local: LocalCorpus(space: .init(id: "catalogue-lab", name: "Catálogos completos"), mirror: mirror, archive: archive), address: ServerAddress(trusted: "nodus-demo://this-device"), cache: ResponseCache(directory: directory.appendingPathComponent("cache")))
        let reports = try await client.deepResearchCatalogue(in: "catalogue-lab")
        #expect(reports.items.count == 421)
        #expect(reports.items.last?.string("id") == "report-420")
        for path in ["study-questions", "study-flashcards", "study-goals", "persons", "relationships", "works", "world-rules", "archive-items", "testimony-codes", "prosopography-public-variables", "teaching-rubrics", "databases", "dictionary"] {
            let collection = try #require(Collections[path])
            let rows = try await client.allItems(collection, in: "catalogue-lab")
            #expect(rows.count == counts[collection.table])
            #expect(Set(rows.compactMap { $0.string(collection.idField) }).count == rows.count)
            let found = try await client.allItems(collection, in: "catalogue-lab", query: "Fuente 1204")
            if rows.count > 1204 { #expect(found.count == 1) }
        }
    }
}
