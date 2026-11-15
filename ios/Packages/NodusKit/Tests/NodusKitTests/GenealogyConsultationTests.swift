import Foundation
import Testing
@testable import NodusKit

@Suite("Genealogy geographic and chronological consultation")
struct GenealogyConsultationTests {
    private var tables: [String: [Row]] {
        ["persons": [Row(["person_id": .string("a"), "display_name": .string("Ana")]), Row(["person_id": .string("b"), "display_name": .string("Bernardo")])],
         "places": [place("madrid", 40.4, -3.7), place("paris", 48.8, 2.3), place("invalid", 120, 190)],
         "person_places": [stop("1", "a", "madrid", "ABT 1890", "1890-01-01"), stop("2", "a", "madrid", "1895", "1895-01-01"), stop("3", "a", "paris", "BET 1900 AND 1905", "1900-01-01"), stop("4", "a", "madrid", nil, nil), stop("5", "b", "paris", "1910", "1910-01-01"), stop("6", "a", "invalid", "1920", "1920-01-01"), stop("7", "missing", "paris", nil, nil)],
         "events": [event("later", "migration", "BET 1900 AND 1905", "1900-01-01"), event("early", "birth", "ABT 1890", "1890-01-01"), event("undated", "custom:festival", nil, nil)],
         "event_participants": [Row(["event_id": .string("early"), "person_id": .string("a"), "role": .string("principal")]), Row(["event_id": .string("later"), "person_id": .string("b"), "role": .string("witness")])]]
    }
    private func place(_ id: String, _ lat: Double, _ lon: Double) -> Row { Row(["place_id": .string(id), "name": .string(id.capitalized), "latitude": .double(lat), "longitude": .double(lon)]) }
    private func stop(_ id: String, _ person: String, _ place: String, _ date: String?, _ sort: String?) -> Row { Row(["id": .string(id), "person_id": .string(person), "place_id": .string(place), "date": date.map(JSONValue.string) ?? .null, "date_sort": sort.map(JSONValue.string) ?? .null]) }
    private func event(_ id: String, _ type: String, _ date: String?, _ sort: String?) -> Row { Row(["event_id": .string(id), "type": .string(type), "date": date.map(JSONValue.string) ?? .null, "date_sort": sort.map(JSONValue.string) ?? .null, "place_id": .string("madrid")]) }

    @Test("person-place joins reject unlocated and invalid points without inventing coordinates")
    func locatedPoints() {
        let points = GenealogyConsultation.mapPoints(tables: tables)
        #expect(points.map(\.id) == ["1", "2", "3", "5", "4"])
        #expect(points.first?.personName == "Ana")
        #expect(points.first?.placeName == "Madrid")
        #expect(points.first?.date == "ABT 1890")
        #expect(GenealogyConsultation.yearRange(points) == 1890...1910)
    }
    @Test("year sweeps retain undated points and route ordering collapses only consecutive stays")
    func yearAndRoutes() {
        let points = GenealogyConsultation.mapPoints(tables: tables)
        let early = GenealogyConsultation.filter(points, people: ["a"], throughYear: 1895)
        #expect(early.map(\.id) == ["1", "2", "4"])
        let routes = GenealogyConsultation.routes(points)
        #expect(routes.count == 1)
        #expect(routes.first?.map(\.placeId) == ["madrid", "paris", "madrid"])
        #expect(GenealogyConsultation.year("-0044-03-15") == -44)
        #expect(GenealogyConsultation.year("unknown") == nil)
    }
    @Test("timeline filters participant membership and custom types while preserving uncertain dates")
    func timeline() {
        let all = GenealogyConsultation.events(tables: tables)
        #expect(all.map(\.id) == ["early", "later", "undated"])
        #expect(all[0].date == "ABT 1890")
        #expect(all[0].participants.first?.name == "Ana")
        #expect(all[1].date == "BET 1900 AND 1905")
        #expect(GenealogyConsultation.events(tables: tables, people: ["b"], types: ["migration"]).map(\.id) == ["later"])
        #expect(GenealogyConsultation.events(tables: tables, people: ["a"], types: ["migration"]).isEmpty)
        #expect(GenealogyConsultation.events(tables: tables, types: ["custom:festival"]).map(\.id) == ["undated"])
    }
    @Test("selected dossiers never turn linked participant summaries into downloaded people")
    func selectedDownloadScope() throws {
        func copy(_ path: String, _ primary: String, _ row: Row, _ sections: [String: JSONValue]) throws -> CompanionCollectionCopy {
            var detail = sections; detail[primary] = .object(row.columns)
            return try CompanionCollectionCopy(path: path, copies: [.object(["version": .int(1), "path": .string(path), "entries": .array([
                .object(["summary": .object(row.columns), "detail": .object(detail)])
            ])])])
        }
        let person = tables["persons"]![0]
        let selectedPerson = try copy("persons", "person", person, ["places": .array([.object(tables["places"]![0].columns)]), "placeLinks": .array([.object(tables["person_places"]![0].columns)])])
        let selectedEvent = try copy("events", "event", tables["events"]![0], [
            "place": .object(tables["places"]![0].columns),
            "participants": .array([.object(tables["persons"]![1].columns)]),
            "participantRows": .array([.object(tables["event_participants"]![1].columns)])
        ])
        let selected = try GenealogyConsultation.selectedTables(persons: selectedPerson, events: selectedEvent)
        #expect(selected["persons"]?.map { $0.string("person_id") } == ["a"])
        #expect(GenealogyConsultation.mapPoints(tables: selected).map(\.id) == ["1"])
        let events = GenealogyConsultation.events(tables: selected)
        #expect(events.map(\.id) == ["later"])
        #expect(events.first?.participants.first?.personId == "b")
        #expect(events.first?.participants.first?.name == "Bernardo")
        #expect(selected["persons"]?.contains { $0.string("person_id") == "b" } == false)
    }

}
