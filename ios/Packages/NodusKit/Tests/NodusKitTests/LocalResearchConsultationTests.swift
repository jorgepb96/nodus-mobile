import Foundation
import Testing
@testable import NodusKit

@Suite("Downloaded research consultation")
struct LocalResearchConsultationTests {
    private func client(reportCount: Int = 241, immersionCount: Int = 1, damagedColumn: String? = nil, damagedValue: String = "{broken") async throws -> (NodusClient, MirrorStore, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-local-research-\(UUID().uuidString)", isDirectory: true)
        var reports: [JSONValue] = (0..<reportCount).map { index in
            .object(["id": .string("report-\(index)"), "title": .string("Informe \(index)"),
                     "brief_json": .string(#"{"kind":"deep_research","objective":"Consultar el corpus","language":"es"}"#),
                     "draft_json": .string(###"{"draftMarkdown":"## Evidencia\n\nUna cita [fuente](nodus://idea/idea-1).","bibliography":["Autora, 2026"]}"###),
                     "created_at": .string("2026-10-01"), "updated_at": .string("2026-10-08")])
        }
        if let damagedColumn {
            var row: [String: JSONValue] = ["id": .string("damaged-report"), "brief_json": .string(#"{"kind":"deep_research"}"#), "draft_json": .string(#"{"draftMarkdown":"Preserved content"}"#)]
            row[damagedColumn] = .string(damagedValue)
            reports.append(.object(row))
        }
        let tables: [String: JSONValue] = [
            "writing_saved_drafts": .array(reports + [
                .object(["id": .string("ordinary-writing"), "brief_json": .string(#"{"kind":"writing"}"#)])]),
            "writing_draft_reads": .array([.object(["draft_id": .string("report-240"), "updated_at": .string("2026-10-08")])]),
            "writing_draft_annotations": .array([.object(["id": .string("highlight"), "draft_id": .string("report-240"), "quote": .string("Una cita"), "comment": .string("Anotación publicada")])]),
            "content_translations": .array([.object(["id": .string("translation"), "entity_kind": .string("deep_research"), "entity_id": .string("report-240"), "target_language": .string("en"), "content": .string("A citation")])]),
            "immersion_sessions": .array((0..<immersionCount).map { index in .object(["id": .string(index == 0 ? "immersion" : "immersion-\(index)"), "topic": .string("Memoria"), "title": .string("Inmersión guardada"),
                 "language": .string("es"), "minutes": .int(20), "stats_json": .string(#"{"stations":2}"#),
                 "plan_json": .string(#"{"stations":[{"id":"station-1","title":"Fuentes"}]}"#),
                 "progress_json": .string(#"{"station":9,"privateReaderPosition":true}"#), "created_at": .string("2026-10-01"), "updated_at": .string("2026-10-08")]) })
        ]
        let document: JSONValue = .object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "revision": .string("local-research-revision"), "tables": .object(tables)])
        let archive = try JSONEncoder.nodus.encode(document)
        let mirror = try await MirrorStore.open(spaceId: "isolated-space", directory: directory)
        try await mirror.replace(with: SnapshotDownload.read(archive), revision: "local-research-revision")
        let local = LocalCorpus(space: .init(id: "isolated-space", name: "Laboratorio"), mirror: mirror, archive: archive)
        let client = NodusClient(local: local, address: ServerAddress(trusted: "nodus-demo://this-device"), cache: ResponseCache(directory: directory.appendingPathComponent("cache")))
        return (client, mirror, directory)
    }

    @Test("all report pages, full prose, citations, translations and annotations survive without a server")
    func reports() async throws {
        let (client, mirror, directory) = try await client()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await client.deepResearchReports(in: "isolated-space", limit: 200)
        #expect(first.total == 241)
        #expect(first.items.count == 200)
        #expect(first.hasMore)
        let last = try await client.deepResearchReports(in: "isolated-space", limit: 200, offset: 200)
        #expect(last.items.count == 41)
        #expect(!last.hasMore)
        #expect(last.items.last?.string("id") == "report-240")
        #expect(last.items.last?.string("read_at") == "2026-10-08")
        let all = try await client.allDeepResearchReports(in: "isolated-space")
        #expect(all.count == 241)
        let detail = try await client.deepResearchReport("report-240", in: "isolated-space")
        #expect(detail.report["draft"]?.objectValue?["draftMarkdown"]?.stringValue == "## Evidencia\n\nUna cita [fuente](nodus://idea/idea-1).")
        #expect(detail.translations.first?.string("id") == "translation")
        #expect(detail.annotations?.first?.string("comment") == "Anotación publicada")
        #expect(detail.revision == "local-research-revision")
        #expect(detail.image == nil)
        let before = try await mirror.tableCounts()
        await #expect(throws: APIError.self) { try await client.deepResearchReport("ordinary-writing", in: "isolated-space") }
        await #expect(throws: APIError.self) { try await client.deepResearchReport("missing", in: "isolated-space") }
        #expect(try await mirror.tableCounts() == before)
    }

    @Test("immersion consultation preserves the stored plan and never copies another reader's progress")
    func immersions() async throws {
        let (client, _, directory) = try await client()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await client.immersionSessions(in: "isolated-space")
        #expect(page.total == 1)
        #expect(page.items.first?["stats"]?.objectValue?["stations"] == .int(2))
        #expect(page.items.first?["progress_json"] == nil)
        let detail = try await client.immersionSession("immersion", in: "isolated-space")
        #expect(detail["plan"]?.objectValue?["stations"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "Fuentes")
        #expect(detail["progress_json"] == nil)
        #expect(detail["privateReaderPosition"] == nil)
        await #expect(throws: APIError.self) { try await client.immersionSession("missing", in: "isolated-space") }
    }

    @Test("immersion metadata pagination includes sessions beyond the first hundred without copying private progress")
    func completeImmersionCatalogue() async throws {
        let (client, _, directory) = try await client(immersionCount: 241)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try await client.allImmersionSessions(in: "isolated-space")
        #expect(rows.count == 241)
        #expect(Set(rows.compactMap { $0.string("id") }).count == 241)
        #expect(rows.contains { $0.string("id") == "immersion-240" })
        #expect(rows.allSatisfy { $0["progress_json"] == nil && $0["plan_json"] == nil })
    }

    @Test("damaged downloaded reports fail explicitly, including beyond the first page, and preserve the exact stored rows")
    func damagedReports() async throws {
        for column in ["brief_json", "draft_json"] {
            for value in ["{broken", "null", "[]", "42"] {
                let (client, mirror, directory) = try await client(damagedColumn: column, damagedValue: value)
                defer { try? FileManager.default.removeItem(at: directory) }
                let before = try await mirror.allRows(table: "writing_saved_drafts")
                for offset in [0, 200] {
                    do {
                        _ = try await client.deepResearchReports(in: "isolated-space", limit: 200, offset: offset)
                        Issue.record("Damaged records cannot disappear from a successful catalogue")
                    } catch let error as APIError {
                        #expect(error.status == 422); #expect(error.code == "invalid_saved_reports")
                        #expect(!error.isNotFound && !error.isNotPublished)
                    }
                }
                do {
                    _ = try await client.deepResearchReport("damaged-report", in: "isolated-space")
                    Issue.record("A damaged report must not return a null document")
                } catch let error as APIError {
                    #expect(error.status == 422); #expect(error.code == "invalid_saved_reports")
                }
                #expect(try await mirror.allRows(table: "writing_saved_drafts") == before)
            }
        }
        let (emptyClient, _, emptyDirectory) = try await client(reportCount: 0)
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let empty = try await emptyClient.deepResearchReports(in: "isolated-space")
        #expect(empty.total == 0 && empty.items.isEmpty && !empty.hasMore)
        let (brokenClient, _, brokenDirectory) = try await client(reportCount: 0, damagedColumn: "brief_json")
        defer { try? FileManager.default.removeItem(at: brokenDirectory) }
        await #expect(throws: APIError.self) { try await brokenClient.deepResearchReports(in: "isolated-space") }
    }
}
