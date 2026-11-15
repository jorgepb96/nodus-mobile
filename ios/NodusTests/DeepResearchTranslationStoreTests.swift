import Foundation
import NodusAI
import NodusKit
import Testing
@testable import Nodus

@Suite("Deep Research translations")
@MainActor
struct DeepResearchTranslationStoreTests {
    @Test("all eighteen Desktop translation languages are offered exactly once")
    func languageContract() {
        #expect(TranslationLanguage.supported.count == 18)
        #expect(Set(TranslationLanguage.supported.map(\.id)) == [
            "en", "es", "fr", "de", "it", "pt", "pt-BR", "ca", "gl", "eu", "nl", "pl", "ru", "ar", "zh", "ja", "ko", "hi",
        ])
    }

    @Test("a regenerated language replaces its old translation and survives relaunch")
    func durableReplacement() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("translations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ModelRef(provider: .openai, model: "test")
        let store = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        store.save(reportId: "report", language: "es", markdown: "Primera", model: model)
        store.save(reportId: "report", language: "es", markdown: "Segunda", model: model)

        let reopened = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        #expect(reopened.translations.count == 1)
        #expect(reopened.translation(language: "es")?.markdown == "Segunda")
    }

    @Test("the latest server publication replaces stale local translations in an open reader")
    func authoritativeServerReplacement() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("translations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        store.save(
            reportId: "report",
            language: "es",
            markdown: "Versión local obsoleta",
            model: ModelRef(provider: .openai, model: "test")
        )

        store.markSynchronized(language: "es")

        store.replaceFromServer(rows: [
            Row([
                "id": .string("desktop-translation"),
                "entity_kind": .string("deep_research"),
                "entity_id": .string("report"),
                "language": .string("fr"),
                "markdown": .string("Version publiée"),
                "created_at": .string("2026-08-22T18:00:00Z"),
                "updated_at": .string("2026-08-22T18:01:00Z"),
            ]),
        ])

        #expect(store.translations.map(\.language) == ["fr"])
        #expect(store.translation(language: "es") == nil)
        #expect(store.translation(language: "fr")?.id == "desktop-translation")

        let reopened = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        #expect(reopened.translation(language: "fr")?.markdown == "Version publiée")
    }
    @Test("stale or empty Mac reads never erase a translation waiting to synchronize")
    func pendingTranslationSurvivesRefreshAndRelaunch() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("translations-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        let generated = store.save(reportId: "report", language: "en", markdown: "New offline translation", model: ModelRef(provider: .deepseek, model: "test"))
        store.replaceFromServer(rows: [])
        #expect(store.translation(language: "en")?.markdown == generated.markdown)
        let reopened = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        var stale = generated.row; stale["markdown"] = .string("Old translation")
        reopened.replaceFromServer(rows: [Row(stale)])
        #expect(reopened.translation(language: "en")?.markdown == generated.markdown)
        reopened.replaceFromServer(rows: [Row(generated.row)]) // Exact delivery acknowledgement.
        reopened.replaceFromServer(rows: [Row(stale)])
        #expect(reopened.translation(language: "en")?.markdown == "Old translation")
    }

    @Test("a canonical Mac translation is retained offline and does not block later server updates")
    func canonicalMacTranslation() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("translations-mac-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        store.save(reportId: "report", language: "es", markdown: "Old pending mobile result", model: ModelRef(provider: .deepseek, model: "phone"))
        let canonical = ContentTranslation(id: "mac-translation", reportId: "report", language: "es", markdown: "Saved on Mac",
            model: ModelRef(provider: .openai, model: "mac"), createdAt: Date())
        store.acceptServer(canonical)
        let reopened = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        #expect(reopened.translation(language: "es")?.id == canonical.id)
        #expect(reopened.translation(language: "es")?.markdown == canonical.markdown)
        var updated = canonical.row; updated["markdown"] = .string("Edited on Mac")
        reopened.replaceFromServer(rows: [Row(updated)])
        #expect(reopened.translation(language: "es")?.markdown == "Edited on Mac")
        reopened.acceptServer(ContentTranslation(id: "foreign", reportId: "other-report", language: "es", markdown: "Wrong report", model: nil, createdAt: Date()))
        #expect(reopened.translation(language: "es")?.id == canonical.id)
    }

    @Test("a pending offline deletion cannot be resurrected by stale publication rows")
    func pendingDeletion() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("translations-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        let generated = store.save(reportId: "report", language: "en", markdown: "Deleted locally", model: ModelRef(provider: .deepseek, model: "test"))
        store.replaceFromServer(rows: [Row(generated.row)])
        store.delete(language: "en")
        let reopened = DeepResearchTranslationStore(spaceId: "space", reportId: "report", root: root)
        reopened.replaceFromServer(rows: [Row(generated.row)])
        #expect(reopened.translation(language: "en") == nil)
        reopened.replaceFromServer(rows: []) // Mac has now applied the deletion.
        reopened.replaceFromServer(rows: [Row(generated.row)])
        #expect(reopened.translation(language: "en")?.markdown == generated.markdown)
    }

}
