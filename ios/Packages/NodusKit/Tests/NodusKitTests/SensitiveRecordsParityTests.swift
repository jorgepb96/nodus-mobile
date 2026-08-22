import Testing
@testable import NodusKit

@Suite("Sensitive research record projections")
struct SensitiveRecordsParityTests {
    private func row(_ values: [String: JSONValue]) -> Row { Row(values) }

    @Test("archive hierarchy and integrity counts are stable")
    func archiveProjection() {
        let units = SensitiveRecordsParity.archiveUnits(in: [
            row(["unit_id": .string("fonds"), "title": .string("Fonds"), "level": .string("fonds"), "position": .int(0)]),
            row(["unit_id": .string("series"), "parent_unit_id": .string("fonds"), "title": .string("Letters"), "level": .string("series"), "position": .int(1)]),
        ])
        #expect(units.map(\.depth) == [0, 1])

        let items = SensitiveRecordsParity.archiveItems(in: [
            "archive_items": [row(["item_id": .string("item"), "title": .string("Letter")])],
            "archive_item_profiles": [row(["item_id": .string("item"), "access_status": .string("open")])],
            "archive_item_files": [
                row(["file_id": .string("a"), "item_id": .string("item"), "verification_status": .string("verified")]),
                row(["file_id": .string("b"), "item_id": .string("item"), "verification_status": .string("pending")]),
            ],
            "archive_text_versions": [row(["text_version_id": .string("t"), "item_id": .string("item")])],
            "archive_excerpts": [row(["excerpt_id": .string("e"), "item_id": .string("item")])],
        ])
        #expect(items.first?.fileCount == 2)
        #expect(items.first?.verifiedFileCount == 1)
        #expect(items.first?.textVersionCount == 1)
        #expect(items.first?.excerptCount == 1)
    }

    @Test("prosopography keeps evidence and network provenance")
    func prosopProjection() {
        let tables: [String: [Row]] = [
            "persons": [row(["person_id": .string("p1"), "given_names": .string("Ada"), "surnames": .string("Lovelace")])],
            "prosop_person_profiles": [row(["person_id": .string("p1"), "identity_status": .string("resolved"), "completeness_cache": .double(0.75)])],
            "prosop_statements": [row(["statement_id": .string("s1"), "factoid_id": .string("f1")])],
            "prosop_statement_entities": [row(["statement_id": .string("s1"), "entity_kind": .string("person"), "entity_id": .string("p1")])],
            "prosop_authority_ids": [row(["authority_id": .string("a1"), "entity_kind": .string("person"), "entity_id": .string("p1")])],
        ]
        let person = SensitiveRecordsParity.prosopPersons(in: tables).first
        #expect(person?.displayName == "Ada Lovelace")
        #expect(person?.factoidCount == 1)
        #expect(person?.authorityCount == 1)

        let edges = SensitiveRecordsParity.networkEdges(in: [
            row(["edge_id": .string("active"), "source_person_id": .string("p1"), "target_person_id": .string("p2"), "origin": .string("explicit")]),
            row(["edge_id": .string("self"), "source_person_id": .string("p1"), "target_person_id": .string("p1")]),
            row(["edge_id": .string("retired"), "source_person_id": .string("p1"), "target_person_id": .string("p3"), "status": .string("retired")]),
        ])
        #expect(edges.map(\.id) == ["active"])
    }

    @Test("testimony access and version lineage remain attached to the interview")
    func testimonyProjection() {
        let tables: [String: [Row]] = [
            "testimony_interviews": [row(["id": .string("i1"), "title": .string("Life history")])],
            "testimony_participant_profiles": [row(["person_id": .string("p1"), "public_name": .string("Narrator A")])],
            "testimony_interview_participants": [row(["interview_id": .string("i1"), "person_id": .string("p1")])],
            "testimony_sessions": [row(["id": .string("session"), "interview_id": .string("i1")])],
            "testimony_media": [row(["id": .string("media"), "session_id": .string("session")])],
            "testimony_transcripts": [row(["id": .string("transcript"), "media_id": .string("media"), "version_no": .int(2)])],
            "testimony_annotations": [row(["id": .string("annotation"), "interview_id": .string("i1")])],
            "testimony_agreements": [row(["id": .string("agreement"), "interview_id": .string("i1"), "is_current": .int(1), "version_no": .int(3), "status": .string("documented"), "access_level": .string("embargoed")])],
        ]
        let interview = SensitiveRecordsParity.testimonyInterviews(in: tables).first
        #expect(interview?.participantNames == ["Narrator A"])
        #expect(interview?.sessionCount == 1)
        #expect(interview?.transcriptCount == 1)
        #expect(interview?.annotationCount == 1)
        #expect(interview?.accessLevel == "embargoed")
        #expect(interview?.agreementStatus == "documented")
    }
}
