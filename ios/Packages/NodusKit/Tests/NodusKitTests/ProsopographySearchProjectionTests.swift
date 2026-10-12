import Testing
@testable import NodusKit

struct ProsopographySearchProjectionTests {
    @Test func literalMentionsFindTheirPersonAndKeepEvidenceTarget() {
        let tables: [String: [Row]] = [
            "persons": [Row(["person_id": .string("p"), "display_name": .string("Resolved identity")])],
            "prosop_person_profiles": [Row(["person_id": .string("p")])],
            "prosop_name_attestations": [Row(["attestation_id": .string("a"), "person_id": .string("p"), "literal_name": .string("José Pérez")])],
        ]
        let hits = ProsopographySearchProjection.search("jose", in: tables)
        #expect(hits.map(\.kind) == [.person, .mention])
        #expect(hits.map(\.targetId) == ["p", "a"])
    }

    @Test func statementsOpenFactoidsAndDoNotExposeRestrictedValuesOrDanglingTargets() {
        let tables: [String: [Row]] = [
            "prosop_factoids": [Row(["factoid_id": .string("f")])],
            "prosop_variable_revisions": [Row(["revision_id": .string("v"), "sensitivity": .string("restricted")])],
            "prosop_statements": [
                Row(["statement_id": .string("s"), "factoid_id": .string("f"), "literal_value": .string("merchant")]),
                Row(["statement_id": .string("secret"), "factoid_id": .string("f"), "variable_revision_id": .string("v"), "literal_value": .string("merchant")]),
                Row(["statement_id": .string("orphan"), "factoid_id": .string("missing"), "literal_value": .string("merchant")]),
            ],
        ]
        let hits = ProsopographySearchProjection.search("merchant", in: tables)
        #expect(hits.count == 1)
        #expect(hits.first?.id == "statement:s")
        #expect(hits.first?.kind == .factoid)
        #expect(hits.first?.targetId == "f")
    }

    @Test func restrictedIdentityAlsoRemovesLiteralMentions() {
        let tables: [String: [Row]] = [
            "persons": [Row(["person_id": .string("p"), "display_name": .string("Hidden")])],
            "prosop_person_profiles": [Row(["person_id": .string("p"), "privacy_status": .string("restricted")])],
            "prosop_name_attestations": [Row(["attestation_id": .string("a"), "person_id": .string("p"), "literal_name": .string("Hidden")])],
        ]
        #expect(ProsopographySearchProjection.search("", in: tables).isEmpty)
    }
}
