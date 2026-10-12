import Testing
@testable import NodusKit

@Suite("Genealogy dossier context")
struct GenealogyDossierContextTests {
    private func personCopy() -> JSONValue {
        let person: JSONValue = .object(["person_id": .string("selected"), "display_name": .string("Selected person")])
        let neighbour: JSONValue = .object(["person_id": .string("neighbour"), "display_name": .string("Named sibling")])
        return .object(["version": .int(1), "path": .string("persons"), "entries": .array([
            .object(["summary": person, "detail": .object(["person": person,
                "relatedPersons": .array([neighbour]), "relationships": .array([.object(["rel_id": .string("relation"), "from_person": .string("neighbour"), "to_person": .string("selected"), "type": .string("sibling"), "notes": .string("Exact recorded context")])]),
                "places": .array([.object(["place_id": .string("place"), "name": .string("Named place")])]),
                "placeLinks": .array([.object(["id": .string("location"), "person_id": .string("selected"), "place_id": .string("place"), "date": .string("c. 1850"), "label": .string("Recorded residence")])]),
                "evidence": .array([.object(["id": .string("work-evidence"), "source_kind": .string("work"), "nodus_id": .string("work"), "quote": .string("Exact quotation")]), .object(["id": .string("private-source"), "source_kind": .string("archive"), "nodus_id": .string("archive")])])])])])])
    }
    @Test func selectedContextBindsRealNeighboursWithoutPromotingThemToDownloads() throws {
        let copy = try CompanionCollectionCopy(path: "persons", copies: [personCopy()])
        let dossier = try copy.dossier(id: "selected")
        #expect(dossier.fromDevice)
        let context = GenealogyDossierContext.sections(dossier)
        let kinship = try #require(context.first { $0.id == "relationships" }?.entries.first)
        #expect(kinship.title == "Named sibling")
        #expect(kinship.target?.string("person_id") == "neighbour")
        #expect(kinship.associationPath == "relationships")
        #expect(kinship.association.text("notes") == "Exact recorded context")
        let place = try #require(context.first { $0.id == "placeLinks" }?.entries.first)
        #expect(place.title == "Named place")
        #expect(place.association.text("date") == "c. 1850")
        #expect(copy.page().total == 1)
        #expect(throws: CompanionCollectionCopy.CopyError.self) { try copy.dossier(id: "neighbour") }
        let sources = GenealogyDossierContext.bibliographySources(dossier)
        #expect(sources.count == 1)
        #expect(sources[0].target?.string("nodus_id") == "work")
        #expect(sources[0].collectionPath == "works")
        #expect(sources[0].association.text("quote") == "Exact quotation")
        // All operations above are pure selected-copy reads: no client/session or socket exists.
    }
    @Test func participantRolesAndPlaceAssociationsRemainBoundToActualPeople() throws {
        let row: JSONValue = .object(["event_id": .string("event"), "label": .string("Recorded event")])
        let dossier = try CollectionDossier(collection: Collections["events"]!, id: "event", payload: .object([
            "event": row, "participants": .array([.object(["person_id": .string("witness"), "display_name": .string("Actual witness")])]),
            "participantRows": .array([.object(["event_id": .string("event"), "person_id": .string("witness"), "role": .string("witness")]), .object(["event_id": .string("event"), "person_id": .string("unavailable"), "role": .string("principal")])])]))
        let entries = try #require(GenealogyDossierContext.sections(dossier).first?.entries)
        #expect(entries.count == 2)
        #expect(entries[0].title == "Actual witness")
        #expect(entries[0].association.text("role") == "witness")
        #expect(entries[1].target == nil)
        #expect(entries[1].association.text("role") == "principal") // Missing context is preserved, never invented.
    }
    @Test func allContextRowsBeyondFirstScreenAreRetained() throws {
        let row: JSONValue = .object(["place_id": .string("place"), "name": .string("Place")])
        let people = (0..<401).map { JSONValue.object(["person_id": .string("person-\($0)"), "display_name": .string("Person \($0)")]) }
        let links = (0..<401).map { JSONValue.object(["id": .string("link-\($0)"), "person_id": .string("person-\($0)"), "place_id": .string("place"), "date": .string("Date \($0)")]) }
        let dossier = try CollectionDossier(collection: Collections["places"]!, id: "place", payload: .object(["place": row, "persons": .array(people), "personLinks": .array(links)]))
        let context = try #require(GenealogyDossierContext.sections(dossier).first)
        #expect(context.entries.count == 401)
        #expect(context.entries.last?.title == "Person 400")
        #expect(context.entries.last?.association.text("date") == "Date 400")
    }
}
