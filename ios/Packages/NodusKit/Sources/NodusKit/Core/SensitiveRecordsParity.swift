import Foundation

/// Deterministic projections for the three Bridge-only research domains. Transport and storage
/// deliberately stay outside this type: a projection cannot accidentally publish its input.
public enum SensitiveRecordsParity {
    public struct ArchiveUnit: Sendable, Hashable, Identifiable {
        public let id: String
        public let parentId: String?
        public let title: String
        public let referenceCode: String
        public let level: String
        public let depth: Int
    }

    public struct ArchiveItem: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let dateDisplay: String
        public let description: String
        public let provenance: String
        public let documentType: String
        public let accessStatus: String
        public let processingStatus: String
        public let fileCount: Int
        public let verifiedFileCount: Int
        public let textVersionCount: Int
        public let excerptCount: Int
    }

    public struct ProsopPerson: Sendable, Hashable, Identifiable {
        public let id: String
        public let displayName: String
        public let identityStatus: String
        public let reviewStatus: String
        public let privacyStatus: String
        public let completeness: Double?
        public let factoidCount: Int
        public let statementCount: Int
        public let authorityCount: Int
    }

    public struct NetworkEdge: Sendable, Hashable, Identifiable {
        public let id: String
        public let sourceId: String
        public let targetId: String
        public let weight: Double
        public let origin: String
        public let status: String
    }

    public struct TestimonyInterview: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let workflowStatus: String
        public let collection: String
        public let conductedAt: String
        public let accessLevel: String
        public let agreementStatus: String
        public let embargoUntil: String?
        public let participantNames: [String]
        public let sessionCount: Int
        public let mediaCount: Int
        public let transcriptCount: Int
        public let annotationCount: Int
    }

    public static func archiveUnits(in rows: [Row]) -> [ArchiveUnit] {
        let source = rows.compactMap { row -> (String, String?, String, String, String, Int)? in
            guard let id = row.string("unit_id") ?? row.string("id") else { return nil }
            return (
                id, row.string("parent_unit_id") ?? row.string("parent_id"), row.text("title") ?? "Untitled unit",
                row.text("reference_code") ?? "", row.text("level") ?? "item", row.int("position") ?? 0
            )
        }
        let parent = Dictionary(uniqueKeysWithValues: source.map { ($0.0, $0.1) })
        func depth(_ id: String) -> Int {
            var seen = Set([id]); var current = parent[id] ?? nil; var result = 0
            while let value = current, !seen.contains(value), result < 32 {
                seen.insert(value); result += 1; current = parent[value] ?? nil
            }
            return result
        }
        return source.sorted {
            if $0.5 != $1.5 { return $0.5 < $1.5 }
            return $0.2.localizedStandardCompare($1.2) == .orderedAscending
        }.map { ArchiveUnit(id: $0.0, parentId: $0.1, title: $0.2, referenceCode: $0.3, level: $0.4, depth: depth($0.0)) }
    }

    public static func archiveItems(in tables: [String: [Row]]) -> [ArchiveItem] {
        let profiles = Dictionary(uniqueKeysWithValues: (tables["archive_item_profiles"] ?? []).compactMap { row in
            (row.string("item_id") ?? row.string("id")).map { ($0, row) }
        })
        let files = Dictionary(grouping: tables["archive_item_files"] ?? [], by: { $0.string("item_id") ?? "" })
        let texts = Dictionary(grouping: tables["archive_text_versions"] ?? [], by: { $0.string("item_id") ?? "" })
        let excerpts = Dictionary(grouping: tables["archive_excerpts"] ?? [], by: { $0.string("item_id") ?? "" })
        return (tables["archive_items"] ?? []).compactMap { row in
            guard let id = row.string("item_id") ?? row.string("id"), row.text("deleted_at") == nil else { return nil }
            let profile = profiles[id]
            let itemFiles = files[id] ?? []
            return ArchiveItem(
                id: id, title: row.text("title") ?? "Untitled source",
                dateDisplay: row.text("date_display") ?? row.text("date") ?? "",
                description: row.text("description") ?? row.text("notes") ?? "",
                provenance: row.text("source") ?? row.text("provenance") ?? "",
                documentType: row.text("doc_type") ?? row.text("type") ?? "document",
                accessStatus: profile?.text("access_status") ?? "unknown",
                processingStatus: profile?.text("processing_status") ?? "imported",
                fileCount: itemFiles.count,
                verifiedFileCount: itemFiles.filter { $0.text("verification_status") == "verified" }.count,
                textVersionCount: texts[id]?.count ?? 0,
                excerptCount: excerpts[id]?.count ?? 0
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func prosopPersons(in tables: [String: [Row]]) -> [ProsopPerson] {
        let people = Dictionary(uniqueKeysWithValues: (tables["persons"] ?? []).compactMap { row in
            (row.string("person_id") ?? row.string("id")).map { ($0, row) }
        })
        let factoidPeople = personReferences(
            statements: tables["prosop_statements"] ?? [],
            entities: tables["prosop_statement_entities"] ?? []
        )
        let statementsByPerson = Dictionary(grouping: tables["prosop_statement_entities"] ?? [], by: { $0.string("entity_id") ?? "" })
        let authorities = Dictionary(grouping: (tables["prosop_authority_ids"] ?? []).filter { $0.text("entity_kind") == "person" }, by: { $0.string("entity_id") ?? "" })
        let profiles = tables["prosop_person_profiles"] ?? []
        var result: [ProsopPerson] = []
        for profile in profiles {
            guard let id = profile.string("person_id") ?? profile.string("id") else { continue }
            let person = people[id]
            let firstName = person?.text("given_names") ?? person?.text("first_name") ?? ""
            let lastName = person?.text("surnames") ?? person?.text("last_name") ?? ""
            let combinedName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = person?.text("display_name") ?? person?.text("preferred_name") ?? combinedName
            result.append(ProsopPerson(
                id: id, displayName: name.isEmpty ? id : name,
                identityStatus: profile.text("identity_status") ?? "provisional",
                reviewStatus: profile.text("review_status") ?? "unreviewed",
                privacyStatus: profile.text("privacy_status") ?? "ordinary",
                completeness: profile.double("completeness_cache"),
                factoidCount: factoidPeople[id]?.count ?? 0,
                statementCount: statementsByPerson[id]?.count ?? 0,
                authorityCount: authorities[id]?.count ?? 0
            ))
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static func networkEdges(in rows: [Row]) -> [NetworkEdge] {
        rows.compactMap { row in
            guard
                let id = row.string("edge_id") ?? row.string("id"),
                let source = row.string("source_person_id"), let target = row.string("target_person_id"),
                source != target
            else { return nil }
            return NetworkEdge(
                id: id, sourceId: source, targetId: target, weight: max(0, row.double("weight") ?? 1),
                origin: row.text("origin") ?? "explicit", status: row.text("status") ?? "active"
            )
        }.filter { $0.status == "active" }.sorted { $0.id < $1.id }
    }

    public static func testimonyInterviews(in tables: [String: [Row]]) -> [TestimonyInterview] {
        let profiles = Dictionary(uniqueKeysWithValues: (tables["testimony_participant_profiles"] ?? []).compactMap { row in
            row.string("person_id").map { ($0, row) }
        })
        let participations = Dictionary(grouping: tables["testimony_interview_participants"] ?? [], by: { $0.string("interview_id") ?? "" })
        let sessions = Dictionary(grouping: tables["testimony_sessions"] ?? [], by: { $0.string("interview_id") ?? "" })
        let sessionPairs: [(String, String)] = (tables["testimony_sessions"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("id"), let interview = row.string("interview_id") else { return nil }; return (id, interview)
        }
        let sessionInterview: [String: String] = Dictionary(uniqueKeysWithValues: sessionPairs)
        let mediaPairs: [(String, String)] = (tables["testimony_media"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("id"), let session = row.string("session_id"), let interview = sessionInterview[session] else { return nil }; return (id, interview)
        }
        let mediaInterview: [String: String] = Dictionary(uniqueKeysWithValues: mediaPairs)
        let media = Dictionary(grouping: tables["testimony_media"] ?? [], by: { mediaInterview[$0.string("id") ?? ""] ?? "" })
        let transcriptPairs: [(String, String)] = (tables["testimony_transcripts"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("id"), let mediaId = row.string("media_id"), let interview = mediaInterview[mediaId] else { return nil }; return (id, interview)
        }
        let transcriptInterview: [String: String] = Dictionary(uniqueKeysWithValues: transcriptPairs)
        let transcripts = Dictionary(grouping: tables["testimony_transcripts"] ?? [], by: { transcriptInterview[$0.string("id") ?? ""] ?? "" })
        let annotations = Dictionary(grouping: tables["testimony_annotations"] ?? [], by: { $0.string("interview_id") ?? "" })
        let agreements = Dictionary(grouping: (tables["testimony_agreements"] ?? []).filter { $0.int("is_current") == 1 }, by: { $0.string("interview_id") ?? "" })

        return (tables["testimony_interviews"] ?? []).compactMap { row -> TestimonyInterview? in
            guard let id = row.string("id"), row.text("deleted_at") == nil else { return nil }
            let agreement = agreements[id]?.max { ($0.int("version_no") ?? 0) < ($1.int("version_no") ?? 0) }
            let names = (participations[id] ?? []).compactMap { profiles[$0.string("person_id") ?? ""]?.text("public_name") }.filter { !$0.isEmpty }
            return TestimonyInterview(
                id: id, title: row.text("title") ?? "Untitled interview",
                workflowStatus: row.text("workflow_status") ?? "preparation",
                collection: row.text("collection_label") ?? "", conductedAt: row.text("conducted_at") ?? "",
                accessLevel: agreement?.text("access_level") ?? "private",
                agreementStatus: agreement?.text("status") ?? "pending", embargoUntil: agreement?.text("embargo_until"),
                participantNames: names, sessionCount: sessions[id]?.count ?? 0, mediaCount: media[id]?.count ?? 0,
                transcriptCount: transcripts[id]?.count ?? 0, annotationCount: annotations[id]?.count ?? 0
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func personReferences(statements: [Row], entities: [Row]) -> [String: Set<String>] {
        let pairs: [(String, String)] = statements.compactMap { row -> (String, String)? in
            guard let id = row.string("statement_id"), let factoid = row.string("factoid_id") else { return nil }; return (id, factoid)
        }
        let factoidByStatement: [String: String] = Dictionary(uniqueKeysWithValues: pairs)
        var result: [String: Set<String>] = [:]
        for entity in entities where entity.text("entity_kind") == "person" {
            guard let person = entity.string("entity_id"), let statement = entity.string("statement_id"), let factoid = factoidByStatement[statement] else { continue }
            result[person, default: []].insert(factoid)
        }
        return result
    }
}
