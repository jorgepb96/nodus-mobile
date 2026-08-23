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
        translations.removeAll { $0.language == language }
        translations.append(value)
        translations.sort { $0.language < $1.language }
        persist()
        return value
    }

    func delete(language: String) {
        translations.removeAll { $0.language == language }
        persist()
    }

    func replaceFromServer(rows: [Row]) {
        translations = rows.compactMap(ContentTranslation.init(row:))
            .filter { $0.reportId == reportId }
            .sorted { $0.language < $1.language }
        persist()
    }

    private func reload() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder.nodusTranslations.decode([ContentTranslation].self, from: data) else { return }
        translations = saved
    }

    private func persist() {
        guard let data = try? JSONEncoder.nodusTranslations.encode(translations) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}

private extension JSONDecoder {
    static var nodusTranslations: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}

private extension JSONEncoder {
    static var nodusTranslations: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
