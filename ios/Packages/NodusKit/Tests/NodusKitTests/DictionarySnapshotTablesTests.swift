import Foundation
import Testing
@testable import NodusKit

@Suite("Downloaded Dictionary source selection")
struct DictionarySnapshotTablesTests {
    @Test("historical contradiction citations retain both actual idea statements without unrelated ideas")
    func contradictionSources() throws {
        let table: [String: JSONValue] = [
            "dictionary_versions": .array([.object(["content_markdown": .string("[Tensión](nodus://contradiction/edge-old)")])]),
            "edges": .array([.object(["id": .string("edge-old"), "from_id": .string("source"), "to_id": .string("target")])]),
            "ideas": .array(["source", "target", "unrelated"].map { .object(["global_id": .string($0), "statement": .string("Enunciado de \($0)")]) })
        ]
        let document: JSONValue = .object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object(table)])
        let selected = try SnapshotDownload.read(JSONEncoder.nodus.encode(document)).dictionaryConsultationTables()
        #expect(selected["ideas"]?.arrayValue?.count == 2)
        #expect(selected["ideas"]?.arrayValue?.map { $0.objectValue?["statement"]?.stringValue } == ["Enunciado de source", "Enunciado de target"])
        #expect(selected["edges"] == table["edges"])
    }
    @Test("source dossiers retain uncited ideas and evidence without exposing private domains or passage bodies")
    func fullSourceDossiers() throws {
        let tables: [String: JSONValue] = [
            "works": .array([.object(["nodus_id": .string("work")])]),
            "ideas": .array([.object(["global_id": .string("cited")]), .object(["global_id": .string("uncited")])]),
            "evidence": .array([.object(["id": .string("uncited-evidence"), "global_id": .string("uncited")])]),
            "work_idea_synthesis": .array([]), "author_dossier_synthesis": .array([]),
            "passages": .array([.object(["passage_id": .string("large-body")])]),
            "teaching_students": .array([.object(["id": .string("private")])])
        ]
        let document: JSONValue = .object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object(tables)])
        let selected = try SnapshotDownload.read(JSONEncoder.nodus.encode(document)).sourceConsultationTables()
        #expect(selected["ideas"] == tables["ideas"])
        #expect(selected["evidence"] == tables["evidence"])
        #expect(selected["work_idea_synthesis"] == .array([]))
        #expect(selected["passages"] == nil)
        #expect(selected["teaching_students"] == nil)
        #expect(selected["edge_feedback"] == nil, "absence must reach the shared renderer as a compatibility error")
    }
    @Test("a referenced source beyond page one survives without copying unrelated documents")
    func completeSourceSelection() throws {
        let passages: [JSONValue] = (0..<1200).map { index in
            .object(["passage_id": .string("work#\(index)"), "text": .string(String(repeating: "Documento ajeno ", count: 20))])
        }
        let table: [String: JSONValue] = [
            "passages": .array(passages),
            "ideas": .array([.object(["global_id": .string("idea-used")]), .object(["global_id": .string("idea-other")])]),
            "dictionary_evidence": .array([
                .object(["kind": .string("passage"), "ref_id": .string("work#1199")]),
                .object(["kind": .string("idea"), "ref_id": .string("idea-used")])]),
            "dictionary_entries": .array([]), "works": .array([.object(["nodus_id": .string("work")])]),
            "teaching_students": .array([.object(["id": .string("private")])])
        ]
        let document: JSONValue = .object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object(table)])
        let raw = try JSONEncoder.nodus.encode(document)
        let snapshot = try SnapshotDownload.read(raw)
        let selected = snapshot.dictionaryConsultationTables()
        #expect(selected["passages"]?.arrayValue?.count == 1)
        #expect(selected["passages"]?.arrayValue?.first?.objectValue?["passage_id"]?.stringValue == "work#1199")
        #expect(selected["ideas"]?.arrayValue?.count == 1)
        #expect(selected["works"] == table["works"])
        #expect(selected["teaching_students"] == nil)
        #expect(selected["dictionary_entries"] == .array([]))
        #expect(selected["dictionary_versions"] == nil)
        #expect(try JSONEncoder.nodus.encode(JSONValue.object(selected)).count < raw.count / 100)
        #expect(snapshot.document["tables"] == .object(table))
    }

    @Test("historical versions retain their cited sources after evidence changes")
    func historicalCitations() throws {
        let table: [String: JSONValue] = [
            "dictionary_entries": .array([]), "dictionary_evidence": .array([]),
            "dictionary_versions": .array([.object(["content_markdown": .string("[Anterior](nodus://passage/work%23old). [Idea](nodus://idea/old-idea).")])]),
            "passages": .array([.object(["passage_id": .string("work#old")]), .object(["passage_id": .string("unrelated")])]),
            "ideas": .array([.object(["global_id": .string("old-idea")])])
        ]
        let document: JSONValue = .object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "tables": .object(table)])
        let selected = try SnapshotDownload.read(JSONEncoder.nodus.encode(document)).dictionaryConsultationTables()
        #expect(selected["passages"]?.arrayValue?.count == 1)
        #expect(selected["passages"]?.arrayValue?.first?.objectValue?["passage_id"]?.stringValue == "work#old")
        #expect(selected["ideas"] == table["ideas"])
    }
}
