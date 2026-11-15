import Foundation

/// Mirrors Desktop mapPoints/listEvents using the selected vault's published tables.
/// Display dates remain verbatim; only canonical date_sort keys determine chronology.
public enum GenealogyConsultation {
    public struct MapPoint: Identifiable, Hashable, Sendable {
        public let id: String
        public let personId: String
        public let personName: String
        public let placeId: String
        public let placeName: String
        public let latitude: Double
        public let longitude: Double
        public let date: String?
        public let sortKey: String?
        public let label: String?
        public let region: String
    }
    public struct Participant: Identifiable, Hashable, Sendable {
        public let personId: String
        public let name: String
        public let role: String
        public var id: String { personId + ":" + role }
    }
    public struct Event: Identifiable, Hashable, Sendable {
        public let id: String
        public let row: Row
        public let type: String
        public let date: String?
        public let sortKey: String?
        public let placeName: String?
        public let participants: [Participant]
    }
    /// Only independently selected dossiers become navigable people/events.
    /// Linked places and participant labels remain inside their owning selection.
    public static func selectedTables(persons: CompanionCollectionCopy?, events: CompanionCollectionCopy?) throws -> [String: [Row]] {
        var tables: [String: [Row]] = ["persons": persons?.selectedRows ?? [], "events": events?.selectedRows ?? [], "places": [], "person_places": [], "event_participants": []]
        if let persons {
            for person in persons.selectedRows {
                guard let id = person.string("person_id") else { continue }
                let dossier = try persons.dossier(id: id)
                for (section, table) in [("places", "places"), ("placeLinks", "person_places")] {
                    tables[table, default: []] += dossier.sections[section]?.arrayValue?.compactMap { $0.objectValue.map(Row.init) } ?? []
                }
            }
        }
        if let events {
            for event in events.selectedRows {
                guard let id = event.string("event_id") else { continue }
                let dossier = try events.dossier(id: id)
                if let place = dossier.sections["place"]?.objectValue { tables["places", default: []].append(Row(place)) }
                let labels = Dictionary((dossier.sections["participants"]?.arrayValue ?? []).compactMap { value -> (String, String)? in
                    guard let row = value.objectValue, let id = row["person_id"]?.stringValue, let label = row["display_name"]?.stringValue else { return nil }
                    return (id, label)
                }, uniquingKeysWith: { first, _ in first })
                tables["event_participants", default: []] += (dossier.sections["participantRows"]?.arrayValue ?? []).compactMap { value in
                    guard var row = value.objectValue, row["event_id"] == .string(id) else { return nil }
                    if let label = row["person_id"]?.stringValue.flatMap({ labels[$0] }) { row["display_name"] = .string(label) }
                    return Row(row)
                }
            }
        }
        return tables
    }
    public static func year(_ key: String?) -> Int? {
        guard let key, let match = key.range(of: #"^-?\d{1,4}"#, options: .regularExpression) else { return nil }
        return Int(key[match])
    }
    private static func ordered(_ lhs: String?, _ rhs: String?) -> Bool {
        if let lhs, let rhs { return lhs < rhs }
        return lhs != nil && rhs == nil
    }
    public static func mapPoints(tables: [String: [Row]]) -> [MapPoint] {
        let people = Dictionary((tables["persons"] ?? []).compactMap { row in row.string("person_id").map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let places = Dictionary((tables["places"] ?? []).compactMap { row in row.string("place_id").map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        return (tables["person_places"] ?? []).compactMap { row in
            guard let id = row.string("id"), let personId = row.string("person_id"), let person = people[personId],
                  let placeId = row.string("place_id"), let place = places[placeId],
                  let lat = place.double("latitude"), let lon = place.double("longitude"),
                  lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return MapPoint(id: id, personId: personId, personName: person.text("display_name") ?? personId,
                placeId: placeId, placeName: place.text("name") ?? placeId, latitude: lat, longitude: lon,
                date: row.text("date"), sortKey: row.text("date_sort"), label: row.text("label"),
                region: [place.text("admin1"), place.text("country")].compactMap { $0 }.joined(separator: " · "))
        }.sorted { ordered($0.sortKey, $1.sortKey) }
    }
    public static func filter(_ points: [MapPoint], people: Set<String>, throughYear: Int?) -> [MapPoint] {
        points.filter { point in
            guard people.isEmpty || people.contains(point.personId) else { return false }
            guard let throughYear, let pointYear = year(point.sortKey) else { return true }
            return pointYear <= throughYear
        }
    }
    public static func yearRange(_ points: [MapPoint]) -> ClosedRange<Int>? {
        let years = points.compactMap { year($0.sortKey) }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first...last
    }
    public static func routes(_ points: [MapPoint]) -> [[MapPoint]] {
        Dictionary(grouping: points, by: \.personId).keys.sorted().compactMap { person in
            let orderedPoints = points.filter { $0.personId == person }.sorted { ordered($0.sortKey, $1.sortKey) }
            var route: [MapPoint] = []
            for point in orderedPoints where route.last?.placeId != point.placeId { route.append(point) }
            return route.count > 1 ? route : nil
        }
    }
    public static func events(tables: [String: [Row]], people selectedPeople: Set<String> = [], types: Set<String> = []) -> [Event] {
        let people = Dictionary((tables["persons"] ?? []).compactMap { row in row.string("person_id").map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let places = Dictionary((tables["places"] ?? []).compactMap { row in row.string("place_id").map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let participation = Dictionary(grouping: tables["event_participants"] ?? [], by: { $0.string("event_id") ?? "" })
        return (tables["events"] ?? []).compactMap { row in
            guard let id = row.string("event_id"), let type = row.string("type") else { return nil }
            let participants = (participation[id] ?? []).compactMap { participant -> Participant? in
                guard let personId = participant.string("person_id") else { return nil }
                return Participant(personId: personId, name: people[personId]?.text("display_name") ?? participant.text("display_name") ?? personId, role: participant.text("role") ?? "other")
            }
            guard (types.isEmpty || types.contains(type)), selectedPeople.isEmpty || participants.contains(where: { selectedPeople.contains($0.personId) }) else { return nil }
            return Event(id: id, row: row, type: type, date: row.text("date"), sortKey: row.text("date_sort"),
                placeName: row.string("place_id").flatMap { places[$0]?.text("name") }, participants: participants)
        }.sorted { lhs, rhs in
            if lhs.sortKey != rhs.sortKey { return ordered(lhs.sortKey, rhs.sortKey) }
            return (lhs.row.text("created_at") ?? "") < (rhs.row.text("created_at") ?? "")
        }
    }
}
