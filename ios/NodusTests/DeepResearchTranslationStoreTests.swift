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
}
