import Foundation

/// Mirrors the desktop's four search categories while retaining private reader targets.
public enum ProsopographySearchProjection {
    public struct Hit: Identifiable, Sendable {
        public let id: String
        public let kind: PrivateCorpusReference.Kind
        public let targetId: String
        public let category: String
        public let title: String
        public let detail: String
    }

    public static func search(_ query: String, in tables: [String: [Row]]) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            needle.isEmpty || values.contains { $0.localizedStandardContains(needle) }
        }
        let restrictedPeople = Set((tables["prosop_person_profiles"] ?? []).filter { $0.text("privacy_status") == "restricted" }.compactMap { $0.string("person_id") })
        let restrictedVariables = Set((tables["prosop_variable_revisions"] ?? []).filter { $0.text("sensitivity") == "restricted" }.compactMap { $0.string("revision_id") })
        let mentions = (tables["prosop_name_attestations"] ?? []).filter { !restrictedPeople.contains($0.string("person_id") ?? "") }
        var hits: [Hit] = []
        func append(_ kind: PrivateCorpusReference.Kind, _ id: String?, _ category: String, _ title: String, _ detail: String = "", key: String? = nil) {
            guard let id, !id.isEmpty else { return }
            hits.append(.init(id: key ?? "\(kind.rawValue):\(id)", kind: kind, targetId: id, category: category, title: title, detail: detail))
        }
        for person in SensitiveRecordsParity.prosopPersons(in: tables) where !restrictedPeople.contains(person.id) {
            if matches(person.displayName) || mentions.contains(where: { $0.string("person_id") == person.id && matches($0.text("literal_name") ?? "") }) {
                append(.person, person.id, "Person", person.displayName)
            }
        }
        for row in mentions where matches(row.text("literal_name") ?? "", row.text("context") ?? "") {
            append(.mention, row.string("attestation_id"), "Literal mention", row.text("literal_name") ?? "Mention", row.text("context") ?? "")
        }
        for row in tables["prosop_sources"] ?? [] where matches(row.text("title") ?? "", row.text("citation") ?? "", row.text("reference_code") ?? "") {
            append(.source, row.string("source_id"), "Source", row.text("title") ?? "Source", row.text("citation") ?? "")
        }
        let factoids = Set((tables["prosop_factoids"] ?? []).compactMap { $0.string("factoid_id") })
        for row in tables["prosop_statements"] ?? [] {
            guard !restrictedVariables.contains(row.string("variable_revision_id") ?? ""),
                  let factoid = row.string("factoid_id"), factoids.contains(factoid),
                  let statement = row.string("statement_id"),
                  matches(row.text("literal_value") ?? "", row.text("value_text") ?? "") else { continue }
            append(.factoid, factoid, "Statement", row.text("literal_value") ?? row.text("value_text") ?? "Statement", row.text("statement_type") ?? "", key: "statement:\(statement)")
        }
        return hits
    }
}
