import Foundation
import NodusAI
import Testing
@testable import Nodus

/// What a report on disk survives.
///
/// `reload()` decodes inside a `compactMap`, so a decode failure is not an error anybody sees —
/// it is a report that silently stops being in the list. A run costs one model call per section,
/// which makes "the field I added dropped every report you had already paid for" the most
/// expensive mistake this file can make. Hence the fixture below is a *literal*: encoding the
/// current type and decoding it back would pass no matter what shape was added.
@Suite("Local report store")
@MainActor
struct LocalReportStoreTests {
    private func temporaryRoot() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeLegacyReport(id: String, in root: URL, spaceId: String) throws {
        let directory = root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The shape written by every build before sending existed: five keys, no more.
        let json = """
        {
          "id": "\(id)",
          "createdAt": "2026-05-01T10:00:00Z",
          "mode": "research",
          "modelLabel": "claude-test",
          "report": {
            "objective": "La escasez como política",
            "sections": [
              {
                "title": "Primera",
                "prose": "Prosa con apoyo (nodus://idea/i-1).",
                "citations": ["nodus://idea/i-1"],
                "rejectedCitations": []
              }
            ],
            "references": [
              { "token": "nodus://work/w-1", "kind": "work", "id": "w-1", "label": "Una obra (1975)" }
            ],
            "words": 42,
            "pages": 0.1,
            "citationsChecked": 3,
            "citationsRejected": 0
          }
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(id).json"))
    }

    private func report() -> DeepResearchReport {
        DeepResearchReport(
            objective: "La escasez como política",
            sections: [
                DeepResearchSection(
                    title: "Primera",
                    prose: "Prosa con apoyo (nodus://idea/i-1).",
                    citations: ["nodus://idea/i-1"],
                    rejectedCitations: []
                ),
            ],
            references: [CitationCatalog.Entry(token: "nodus://work/w-1", kind: "work", id: "w-1", label: "Una obra (1975)")],
            words: 42,
            pages: 0.1,
            citationsChecked: 3,
            citationsRejected: 0,
            stoppedReason: nil
        )
    }

    // The whole reason `sentAt`, `outboxId`, `vaultRowId` and `modelRef` are optional.
    @Test("a report written before sending existed still loads")
    func legacyReportSurvives() throws {
        let root = temporaryRoot()
        try writeLegacyReport(id: "old-1", in: root, spaceId: "space-1")

        let store = LocalReportStore(spaceId: "space-1", root: root)

        #expect(store.reports.count == 1)
        let saved = try #require(store.reports.first)
        #expect(saved.id == "old-1")
        #expect(saved.title == "La escasez como política")
        #expect(saved.modelLabel == "claude-test")
        // Absent, not defaulted to something that would claim the report had travelled.
        #expect(saved.sentAt == nil)
        #expect(saved.wasSent == false)
        #expect(saved.modelRef == nil)
    }

    @Test("saving keeps the model as a reference, not only as a label")
    func saveKeepsTheModelReference() throws {
        let root = temporaryRoot()
        let store = LocalReportStore(spaceId: "space-2", root: root)

        let saved = store.save(report(), mode: .research, model: ModelRef(provider: .anthropic, model: "claude-test"))

        #expect(saved.modelLabel == "claude-test")
        #expect(saved.modelRef == ModelRef(provider: .anthropic, model: "claude-test"))
    }

    // Reopened rather than re-read: `ResearchLibraryView` calls `reload()` on every appearance,
    // so a flag that lived only in the array would last until the user navigated away.
    @Test("being sent is written to the file, not just to the array")
    func markSentOutlivesTheStore() throws {
        let root = temporaryRoot()
        let store = LocalReportStore(spaceId: "space-3", root: root)
        let saved = store.save(report(), mode: .research, model: ModelRef(provider: .anthropic, model: "claude-test"))

        let marked = try #require(store.markSent(saved.id, outboxId: "outbox-7", vaultRowId: "row-9"))
        #expect(marked.wasSent)

        let reopened = LocalReportStore(spaceId: "space-3", root: root)
        let after = try #require(reopened.reports.first)
        #expect(after.sentAt != nil)
        #expect(after.outboxId == "outbox-7")
        #expect(after.vaultRowId == "row-9")
        // Still there, still readable — marking is not a rewrite of the report itself.
        #expect(after.report.objective == "La escasez como política")
        #expect(after.modelRef == ModelRef(provider: .anthropic, model: "claude-test"))
    }

    @Test("marking an id the store does not hold changes nothing")
    func markSentIgnoresUnknownIds() {
        let root = temporaryRoot()
        let store = LocalReportStore(spaceId: "space-4", root: root)
        store.save(report(), mode: .research, model: ModelRef(provider: .anthropic, model: "claude-test"))

        #expect(store.markSent("not-a-report", outboxId: "o", vaultRowId: "r") == nil)
        #expect(store.reports.count == 1)
        #expect(store.reports.first?.wasSent == false)
    }
}
