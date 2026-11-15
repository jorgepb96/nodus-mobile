import NodusKit
import NodusUI
import SwiftUI

/// A selected topic's real evidence lets the phone compose a new immersion
/// without downloading the corpus or invoking a Mac provider/indexer.
struct CompanionImmersionDownloadsView: View {
    let session: SpaceSession
    @State private var topic = ""
    @State private var language = "es"
    @State private var days = 7
    @State private var loading = false
    @State private var issue: String?
    @State private var saved: String?
    @State private var downloadTask: Task<Void, Never>?

    private struct Language: Identifiable {
        let id: String
        let name: String
    }
    // The shared PromptLanguage catalogue; labels are endonyms.
    private let languages: [Language] = [
        .init(id: "es", name: "Español"), .init(id: "en", name: "English"), .init(id: "fr", name: "Français"),
        .init(id: "de", name: "Deutsch"), .init(id: "pt", name: "Português (Portugal)"), .init(id: "pt-BR", name: "Português (Brasil)"),
        .init(id: "it", name: "Italiano"), .init(id: "tr", name: "Türkçe"), .init(id: "zh-Hans", name: "简体中文"),
        .init(id: "zh-Hant", name: "繁體中文"), .init(id: "vi", name: "Tiếng Việt"), .init(id: "ja", name: "日本語"),
        .init(id: "ru", name: "Русский"), .init(id: "uk", name: "Українська"), .init(id: "ko", name: "한국어")
    ]

    var body: some View {
        List {
            Section {
                TextField("Tema de la inmersión", text: $topic, axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("companion-immersion-download-topic")
                Picker("Idioma", selection: $language) {
                    ForEach(languages) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("companion-immersion-download-language")
                Picker("Conservar la descarga", selection: $days) {
                    Text("7 días").tag(7); Text("30 días").tag(30)
                }
            } footer: {
                Text("Descarga el material de un tema mientras estás conectado a Nodus. Después podrás crear nuevas inmersiones sobre ese tema en modo autónomo, con los proveedores del móvil. Podrás elegir duración, cuestionarios y modelo al generar. Otro tema o idioma necesita su propia descarga.")
            }.disabled(loading)
            if loading {
                Section {
                    ProgressView("Preparando ideas y evidencias del Mac…")
                    Button("Cancelar", role: .cancel) { downloadTask?.cancel() }
                }
            }
            if let issue { Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-immersion-download-error") }
            if let saved { Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("companion-immersion-download-ready") }
        }
        .navigationTitle("Material para inmersiones").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Descargar") { downloadTask = Task { await download() } }
                    .disabled(loading || topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("companion-immersion-download-start")
            }
        }
        .onDisappear { downloadTask?.cancel() }
    }

    private func download() async {
        loading = true; issue = nil; saved = nil
        defer { loading = false }
        let selectedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines), selectedLanguage = language, selectedDays = days
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            let args: [JSONValue] = [.object(["topic": .string(selectedTopic), "language": .string(selectedLanguage)])]
            let value = try await client.operation(vaultId: vault, method: "getImmersionOfflineSource", args: args)
            guard value.objectValue?["version"] == .int(1), value.objectValue?["topic"] == .string(selectedTopic),
                  value.objectValue?["language"] == .string(selectedLanguage),
                  let material = value.objectValue?["material"]?.objectValue,
                  let ideas = material["ideas"]?.arrayValue, let passages = material["passages"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            guard !ideas.isEmpty else { throw APIError(status: 422, code: "immersion_topic_without_material", message: "No hay ideas guardadas para este tema. Elige otro tema con contenido en Nodus.") }
            let settings = try await client.operation(vaultId: vault, method: "getSettings", args: [])
            guard settings.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
            let current = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard current == revision else { throw DesktopBridgeError.malformedResponse }
            let records = [
                PrivateBridgeCache.ReadPackRecord(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getImmersionOfflineSource", args), data: try JSONEncoder.nodus.encode(value)),
                PrivateBridgeCache.ReadPackRecord(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getSettings", []), data: try JSONEncoder.nodus.encode(settings))
            ]
            try Task.checkCancellation()
            let cache = try PrivateBridgeCache(pairingId: pairing.id)
            let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: ["immersion-material:\(selectedLanguage):\(selectedTopic)"])
            try await cache.saveReadPack(id: id, vaultId: vault, title: "Inmersión · \(selectedTopic)",
                expiresAt: Date().addingTimeInterval(Double(selectedDays) * 86_400), records: records)
            saved = "Material descargado · \(ideas.count) ideas · \(passages.count) pasajes"
        } catch is CancellationError { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch let error as URLError where error.code == .cancelled { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
}
