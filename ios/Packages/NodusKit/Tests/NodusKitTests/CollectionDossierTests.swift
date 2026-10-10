import Foundation
import Testing
@testable import NodusKit

@Suite("Complete public dossier contracts")
struct CollectionDossierTests {
    @Test("typed library readers retain the same response's document profile and exact evidence")
    func librarySupplement() throws {
        let collection = try #require(Collections["works"])
        let profile: JSONValue = .object(["citationPolicy": .string("orientation_only"), "fields": .array([.object(["field": .string("argument"), "value": .string("Orientation only")])])])
        let evidence: JSONValue = .array([.object(["id": .string("quote-1"), "quote": .string("Literal evidence"), "location": .string("p. 37")])])
        let payload = JSONValue.object(["work": .object(["nodus_id": .string("chosen-work"), "title": .string("Chosen work")]), "ideas": .array([]), "summary": .null,
            "passages": .int(1201), "revision": .string("same-response-revision"), "documentProfile": profile, "evidence": evidence])
        let dossier = try CollectionDossier(collection: collection, id: "chosen-work", payload: payload, fromDevice: true)
        let typed = try dossier.decode(WorkDetail.self)
        #expect(typed.passages == 1201)
        #expect(typed.revision == "same-response-revision")
        let supplement = try #require(dossier.supplement(excluding: ["ideas", "summary", "passages"]))
        #expect(supplement.fromDevice)
        #expect(supplement.sections["documentProfile"] == profile)
        #expect(supplement.sections["evidence"] == evidence)
        #expect(supplement.sections["passages"] == nil)
        #expect(try dossier.supplement(excluding: ["ideas", "summary", "passages", "documentProfile", "evidence"]) == nil)
    }

    @Test("character supplements keep scene and secret links while private annotations never become identity links")
    func characterSupplement() throws {
        let collection = try #require(Collections["persons"])
        let payload = JSONValue.object(["person": .object(["person_id": .string("character"), "display_name": .string("Character")]),
            "names": .array([]), "places": .array([]), "relationships": .array([]), "events": .array([]),
            "abilities": .array([.object(["description": .string("Complete ability")])]),
            "scenes": .array([.object(["scene_id": .string("scene"), "title": .string("Appearance")])]),
            "secrets": .array([.object(["secret_id": .string("secret"), "knowledge": .object(["confidence": .double(0.75)])])])])
        let dossier = try CollectionDossier(collection: collection, id: "character", payload: payload)
        #expect(try dossier.decode(PersonDetail.self).person.string("person_id") == "character")
        let extra = try #require(dossier.supplement(excluding: ["names", "places", "relationships", "events", "portrait"]))
        #expect(extra.linkedCollection(for: "scenes")?.path == "world-scenes")
        #expect(extra.linkedCollection(for: "secrets")?.path == "world-secrets")
        #expect(extra.linkedCollection(for: "abilities") == nil)
        #expect(extra.sections["secrets"]?.arrayValue?.first?.objectValue?["knowledge"]?.objectValue?["confidence"] == .double(0.75))
    }

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
