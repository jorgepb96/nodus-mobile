import Foundation
import NodusAI
import NodusKit
import Observation

struct ContentTranslation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let reportId: String
    let language: String
    let markdown: String
    let model: ModelRef?
    let createdAt: Date
    let updatedAt: Date?

    init(id: String, reportId: String, language: String, markdown: String, model: ModelRef?, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.reportId = reportId
        self.language = language
        self.markdown = markdown
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(row: Row) {
        guard row.text("entity_kind") == "deep_research",
              let id = row.text("id"), let reportId = row.text("entity_id"),
              let language = row.text("language"), let markdown = row.string("markdown")
        else { return nil }
        var parsedModel: ModelRef?
        if let value = row.embeddedJSON("model_json")?.objectValue,
           let providerName = value["provider"]?.stringValue,
           let provider = AIProvider(rawValue: providerName),
           let modelName = value["model"]?.stringValue {
            parsedModel = ModelRef(provider: provider, model: modelName)
        }
        self.init(id: id, reportId: reportId, language: language, markdown: markdown, model: parsedModel,
                  createdAt: row.date("created_at") ?? .distantPast, updatedAt: row.date("updated_at"))
    }

    var row: [String: JSONValue] {
        let formatter = ISO8601DateFormatter.nodusFractional
        let modelJSON: JSONValue = model.map {
            .string(#"{"provider":"\#($0.provider.rawValue)","model":"\#($0.model)"}"#)
        } ?? .null
        return [
            "id": .string(id), "entity_kind": .string("deep_research"), "entity_id": .string(reportId),
            "language": .string(language),
            "language_label": .string(TranslationLanguage.supported.first(where: { $0.id == language })?.name ?? language),
            "title": .string("Translation · \(language)"), "markdown": .string(markdown),
            "model_json": modelJSON, "status": .string("ready"), "error": .null,
            "created_at": .string(formatter.string(from: createdAt)),
            "updated_at": .string(formatter.string(from: updatedAt ?? createdAt)),
        ]
    }
}

struct TranslationLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let nativeName: String

    static let supported: [TranslationLanguage] = [
        .init(id: "en", name: "English", nativeName: "English"),
        .init(id: "es", name: "Spanish", nativeName: "Español"),
        .init(id: "fr", name: "French", nativeName: "Français"),
        .init(id: "de", name: "German", nativeName: "Deutsch"),
        .init(id: "it", name: "Italian", nativeName: "Italiano"),
        .init(id: "pt", name: "Portuguese", nativeName: "Português"),
        .init(id: "pt-BR", name: "Brazilian Portuguese", nativeName: "Português (Brasil)"),
        .init(id: "ca", name: "Catalan", nativeName: "Català"),
        .init(id: "gl", name: "Galician", nativeName: "Galego"),
        .init(id: "eu", name: "Basque", nativeName: "Euskara"),
        .init(id: "nl", name: "Dutch", nativeName: "Nederlands"),
        .init(id: "pl", name: "Polish", nativeName: "Polski"),
        .init(id: "ru", name: "Russian", nativeName: "Русский"),
        .init(id: "ar", name: "Arabic", nativeName: "العربية"),
        .init(id: "zh", name: "Chinese (Simplified)", nativeName: "简体中文"),
        .init(id: "ja", name: "Japanese", nativeName: "日本語"),
        .init(id: "ko", name: "Korean", nativeName: "한국어"),
        .init(id: "hi", name: "Hindi", nativeName: "हिन्दी"),
    ]
}

/// Offline-first translations overlaid with the latest server publication.
@Observable
@MainActor
final class DeepResearchTranslationStore {
    private(set) var translations: [ContentTranslation] = []
    private let file: URL
    private let reportId: String
    private var pendingLanguages = Set<String>()
    private var deletedLanguages = Set<String>()
    private struct State: Codable {
        var translations: [ContentTranslation]
        var pendingLanguages: Set<String>
        var deletedLanguages: Set<String>
    }

    init(spaceId: String, reportId: String, root: URL = .applicationSupportDirectory) {
        self.reportId = reportId
        let directory = root.appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("report-translations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("\(reportId).json")
        reload()
    }

    func translation(language: String) -> ContentTranslation? { translations.first { $0.language == language } }

    func isPendingDeletion(language: String) -> Bool { deletedLanguages.contains(language) }

    @discardableResult
    func save(reportId: String, language: String, markdown: String, model: ModelRef) -> ContentTranslation {
        let now = Date()
        let existing = translation(language: language)
        let value = ContentTranslation(
            id: existing?.id ?? "translation:deep_research:\(reportId):\(language)",
            reportId: reportId,
            language: language,
            markdown: markdown,
            model: model,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        pendingLanguages.insert(language); deletedLanguages.remove(language)
        translations.removeAll { $0.language == language }
        translations.append(value)
        translations.sort { $0.language < $1.language }
        persist()
        return value
    }

    /// A result generated and saved by the Mac is already acknowledged. Keep it
    /// offline without scheduling a second write through the mobile outbox.
    func acceptServer(_ value: ContentTranslation) {
        guard value.reportId == reportId else { return }
        pendingLanguages.remove(value.language); deletedLanguages.remove(value.language)
        translations.removeAll { $0.language == value.language }
        translations.append(value)
        translations.sort { $0.language < $1.language }
        persist()
    }

    func delete(language: String) {
        pendingLanguages.insert(language); deletedLanguages.insert(language)
        translations.removeAll { $0.language == language }
        persist()
    }

    func replaceFromServer(rows: [Row]) {
        var remote = rows.compactMap(ContentTranslation.init(row:)).filter { $0.reportId == reportId }
        for language in pendingLanguages {
            let latest = remote.first { $0.language == language }
            if deletedLanguages.contains(language) {
                if latest == nil { pendingLanguages.remove(language); deletedLanguages.remove(language) }
                else { remote.removeAll { $0.language == language } }
            } else if let local = translation(language: language) {
                if latest?.markdown == local.markdown {
                    pendingLanguages.remove(language)
                } else {
                    remote.removeAll { $0.language == language }; remote.append(local)
                }
            }
        }
        translations = remote.sorted { $0.language < $1.language }
        persist()
    }

    /// Used only for an explicitly confirmed delivery; a queued mutation alone
    /// is not an acknowledgement from the Mac.
    func markSynchronized(language: String) {
        pendingLanguages.remove(language); deletedLanguages.remove(language); persist()
    }

    private func reload() {
        guard let data = try? Data(contentsOf: file) else { return }
        if let state = try? JSONDecoder.nodusTranslations.decode(State.self, from: data) {
            translations = state.translations; pendingLanguages = state.pendingLanguages; deletedLanguages = state.deletedLanguages
        } else if let saved = try? JSONDecoder.nodusTranslations.decode([ContentTranslation].self, from: data) {
            // Older files contain no delivery state. Preserve their content as
            // pending until a matching Mac row actually confirms it.
            translations = saved; pendingLanguages = Set(saved.map(\.language))
        }
    }

    private func persist() {
        let state = State(translations: translations, pendingLanguages: pendingLanguages, deletedLanguages: deletedLanguages)
        guard let data = try? JSONEncoder.nodusTranslations.encode(state) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONDecoder {
    static var nodusTranslations: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}

private extension JSONEncoder {
    static var nodusTranslations: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
