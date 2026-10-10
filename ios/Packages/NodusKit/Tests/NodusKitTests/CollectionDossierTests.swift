import Foundation
import Testing
@testable import NodusKit

@Suite("Complete public dossier contracts")
struct CollectionDossierTests {
    @Test("question versions and nested content survive beyond the first page of a reader")
    func completeSections() throws {
        let collection = try #require(Collections["study-questions"])
        let versions = (0..<241).map { JSONValue.object(["id": .string("v\($0)"), "version_no": .int(Int64($0)), "answer": .string("Answer \($0)"), "evidence": .array([.object(["quote": .string("Exact quote \($0)")])])]) }
        let payload = JSONValue.object(["question": .object(["id": .string("q/1#%"), "prompt": .string("Question")]), "versions": .array(versions), "newDesktopSection": .object(["nested": .array(versions)]), "optional": .null, "revision": .string("r1")])
        let dossier = try CollectionDossier(collection: collection, id: "q/1#%", payload: payload)
        #expect(dossier.primary.string("id") == "q/1#%")
        #expect(dossier.sections["versions"]?.arrayValue?.count == 241)
        #expect(dossier.sections["versions"]?.arrayValue?.last?.objectValue?["evidence"]?.arrayValue?.first?.objectValue?["quote"] == .string("Exact quote 240"))
        #expect(dossier.sections["newDesktopSection"] == payload.objectValue?["newDesktopSection"])
        #expect(dossier.sections["optional"] == nil)
        #expect(dossier.sections["revision"] == nil)
        #expect(dossier.linkedCollection(for: "versions") == nil)
        #expect(throws: DesktopBridgeError.self) { try CollectionDossier(collection: collection, id: "another", payload: payload) }
    }

    @Test("archive and world links use explicit dossier context, not annotation or aggregate ids")
    func domainLinks() throws {
        func dossier(_ path: String, _ idField: String) throws -> CollectionDossier {
            let collection = try #require(Collections[path])
            return try CollectionDossier(collection: collection, id: "one", payload: .object([collection.detailKey: .object([idField: .string("one")])]))
        }
        let archive = try dossier("archive-items", "item_id")
        #expect(archive.linkedCollection(for: "units")?.path == "archive-units")
        #expect(archive.linkedCollection(for: "analysis")?.path == "source-analyses")
        #expect(archive.linkedCollection(for: "persons") == nil) // archive_item_persons joins are not person dossiers
        let world = try dossier("world-groups", "group_id")
        #expect(world.linkedCollection(for: "children")?.path == "world-groups")
        #expect(world.linkedCollection(for: "members")?.path == "persons")
        #expect(world.linkedCollection(for: "affiliations") == nil)
        let aggregate = try dossier("prosopography-public-population", "id")
        #expect(aggregate.linkedCollection(for: "population") == nil)
        #expect(aggregate.linkedCollection(for: "identity") == nil)
    }

    @Test("study materials retain the document variant and its tags and links")
    func documentVariant() throws {
        let collection = try #require(Collections["study-materials"])
        let dossier = try CollectionDossier(collection: collection, id: "doc", payload: .object(["document": .object(["id": .string("doc"), "source_kind": .string("document")]), "tags": .array([.object(["tag": .string("chosen")])]), "links": .array([])]))
        #expect(dossier.sections["document"] == nil)
        #expect(dossier.sections["tags"]?.arrayValue?.first?.objectValue?["tag"] == .string("chosen"))
        #expect(dossier.sections["links"] == .array([]))
    }
}
