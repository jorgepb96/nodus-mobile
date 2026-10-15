import Foundation
import NodusAI
import NodusKit
import Observation

/// Which provider does what, and which keys this device holds.
///
/// The split mirrors the desktop: keys live outside any vault, so configuring one configures
/// every space (`electron/secrets/secretStore.ts:10-12`), while the model chosen for a task is
/// a preference. What never happens here — and never happens on the desktop — is a key
/// crossing into a view. `configuredProviders` is a set of provider ids; the values stay in
/// the Keychain and are read only when a request is built.
@Observable
@MainActor
final class AISettings {
    /// One model per task, kept apart because they genuinely differ: a fast model for chat, a
    /// careful one for a report that costs real money to run.
    struct Models: Codable, Equatable {
        var chat: ModelRef?
        var deepResearch: ModelRef?
        var image: ModelRef?
        var dictionary: ModelRef?
        var immersion: ModelRef?
        var writing: ModelRef?
        var synthesis: ModelRef?
        var translation: ModelRef?
        var argumentMap: ModelRef?
    }

    private(set) var embeddingConfiguration: EmbeddingIdentity?
    private let embeddingConfigurationKey = "nodus.ai.embedding-configuration.v1"
    func setEmbeddingConfiguration(_ value: EmbeddingIdentity?) throws {
        if let value {
            guard let provider = AIProvider(rawValue: value.provider), provider.supportsEmbeddings,
                  !value.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.model.utf8.count <= 256,
                  (1...65_536).contains(value.dim) else { throw DesktopBridgeError.malformedResponse }
            store.set(try JSONEncoder.nodus.encode(value), forKey: embeddingConfigurationKey)
        } else { store.set(Data(), forKey: embeddingConfigurationKey) }
        embeddingConfiguration = value
    }
    private(set) var models = Models()
    /// Models the user pinned, so a list of several hundred opens on the four they use.
    private(set) var pinnedModels: [ModelRef] = []
    private(set) var configuredProviders: Set<AIProvider> = []
    /// Providers whose key was entered but which the last call rejected.
    private(set) var rejectedProviders: Set<AIProvider> = []

    private let keychain = KeychainStore()
    private let store: SyncedDefaults
    private let defaultsKey = "nodus.ai.models.v1"
    private let pinnedKey = "nodus.ai.pinned.v1"

    /// The choices travel; the keys do not.
    ///
    /// Which model writes a report is a preference, and one worth carrying to the other device —
    /// it is a name, it is chosen once, and re-choosing it on every device is exactly the kind of
    /// tedium a person notices. The key that pays for the call is a secret and stays in this
    /// device's Keychain, which is what `ConnectView` promises in as many words. The split here
    /// is the same one the whole type is built around: `configuredProviders` is a set of ids and
    /// never a value.
    init(store: SyncedDefaults = .shared) {
        self.store = store
        if let data = store.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Models.self, from: data) {
            models = decoded
        }
        if let data = store.data(forKey: pinnedKey),
           let decoded = try? JSONDecoder().decode([ModelRef].self, from: data) {
            pinnedModels = decoded
        }
        embeddingConfiguration = store.data(forKey: embeddingConfigurationKey).flatMap { try? JSONDecoder.nodus.decode(EmbeddingIdentity.self, from: $0) }
        refreshConfigured()
#if DEBUG && targetEnvironment(simulator)
        // Used only by the isolated acceptance simulator. No secret enters XCTest
        // arguments, launch environments, logs, or the Desktop pairing protocol.
        let fixtureURL = URL.documentsDirectory.appendingPathComponent("NodusAcceptance.provider.json")
        if let bytes = try? Data(contentsOf: fixtureURL),
           let fixture = try? JSONDecoder().decode(AcceptanceProvider.self, from: bytes),
           fixture.marker == "nodus-mobile-isolated-acceptance-0.1.0" {
            do {
                try setKey(fixture.key, for: fixture.provider)
                for task in fixture.tasks?.compactMap(Task.init(rawValue:)) ?? [.dictionary] {
                    setModel(ModelRef(provider: fixture.provider, model: fixture.model), for: task)
                }
                try FileManager.default.removeItem(at: fixtureURL)
            } catch { /* Missing configuration remains a failing acceptance condition. */ }
        }
#endif
        store.onExternalChange(of: [defaultsKey, pinnedKey, embeddingConfigurationKey]) { [weak self] in self?.adoptRemote() }
    }

    /// Take what another device chose.
    ///
    /// Assigning the properties directly rather than going through `setModel` or `togglePinned`:
    /// those persist, and persisting a value that came from iCloud would stamp it as this
    /// device's own newer choice and send it straight back — see `SyncedDefaults`.
    private func adoptRemote() {
        embeddingConfiguration = store.data(forKey: embeddingConfigurationKey).flatMap { try? JSONDecoder.nodus.decode(EmbeddingIdentity.self, from: $0) }
        if let data = store.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Models.self, from: data) {
            models = decoded
        }
        if let data = store.data(forKey: pinnedKey),
           let decoded = try? JSONDecoder().decode([ModelRef].self, from: data) {
            pinnedModels = decoded
        }
    }

#if DEBUG && targetEnvironment(simulator)
    private struct AcceptanceProvider: Decodable { let marker: String; let provider: AIProvider; let model: String; let key: String; let tasks: [String]? }
#endif
    var surfacePreferences: [String: JSONValue] {
        let base: [String: JSONValue] = ["researchWebSearch": .string("off"), "modelSettingsMode": .string("advanced"), "researchThinkingEffort": .string("standard"), "researchEffortByModel": .object([:])]
        guard let bytes = store.data(forKey: "nodus.ai.surface-preferences.v1"),
            let saved = try? JSONDecoder.nodus.decode([String: JSONValue].self, from: bytes) else { return base }
        return base.merging(saved, uniquingKeysWith: { _, new in new })
    }
    func setSurfacePreferences(_ patch: [String: JSONValue]) throws {
        let allowed = Set(["modelSettingsMode", "researchThinkingEffort", "researchEffortByModel", "researchWebSearch", "studyImproveToolbarStyleIds"])
        guard patch.keys.allSatisfy(allowed.contains) else { throw DesktopBridgeError.permissionDenied }
        if let web = patch["researchWebSearch"], !["off", "auto", "on"].contains(web.stringValue ?? "") { throw DesktopBridgeError.malformedResponse }
        if let styles = patch["studyImproveToolbarStyleIds"] {
            guard let values = styles.arrayValue, values.count <= 4,
                values.allSatisfy({ $0.stringValue.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? false }),
                Set(values.compactMap(\.stringValue)).count == values.count else { throw DesktopBridgeError.malformedResponse }
        }
        let value = surfacePreferences.merging(patch, uniquingKeysWith: { _, new in new })
        store.set(try JSONEncoder.nodus.encode(value), forKey: "nodus.ai.surface-preferences.v1")
    }

    // MARK: - Keys

    /// Presence only. Deliberately not a getter for the value.
    func hasKey(for provider: AIProvider) -> Bool {
        configuredProviders.contains(provider)
    }

    func setKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeKey(for: provider) }
        try keychain.set(trimmed, for: KeychainStore.providerKeyKey(provider: provider.rawValue))
        rejectedProviders.remove(provider)
        refreshConfigured()
    }

    func removeKey(for provider: AIProvider) throws {
        try keychain.remove(KeychainStore.providerKeyKey(provider: provider.rawValue))
        rejectedProviders.remove(provider)
        refreshConfigured()
    }

    func markRejected(_ provider: AIProvider) {
        rejectedProviders.insert(provider)
    }

    private func refreshConfigured() {
        configuredProviders = Set(AIProvider.allCases.filter {
            keychain.contains(KeychainStore.providerKeyKey(provider: $0.rawValue))
        })
    }

    /// The closure the provider clients read through.
    ///
    /// `nonisolated` and reading the Keychain directly rather than closing over `self`: a
    /// request is built off the main actor, and this must not hop back for every call.
    nonisolated var keyProvider: @Sendable (AIProvider) -> String? {
        let store = KeychainStore()
        return { provider in
            store.value(for: KeychainStore.providerKeyKey(provider: provider.rawValue))
        }
    }

    // MARK: - Models

    func setModel(_ model: ModelRef?, for task: Task) {
        switch task {
        case .chat: models.chat = model
        case .deepResearch: models.deepResearch = model
        case .image: models.image = model
        case .dictionary: models.dictionary = model
        case .immersion: models.immersion = model
        case .writing: models.writing = model
        case .synthesis: models.synthesis = model
        case .translation: models.translation = model
        case .argumentMap: models.argumentMap = model
        }
        persist()
    }

    func model(for task: Task) -> ModelRef? {
        switch task {
        case .chat: return models.chat
        case .deepResearch: return models.deepResearch ?? models.chat
        case .image: return models.image
        case .dictionary: return models.dictionary ?? models.chat
        case .immersion: return models.immersion ?? models.chat
        case .writing: return models.writing ?? models.chat
        case .synthesis: return models.synthesis ?? models.chat
        case .translation: return models.translation ?? models.chat
        case .argumentMap: return models.argumentMap ?? models.chat
        }
    }

    enum Task: String, CaseIterable, Sendable {
        case chat, deepResearch, image, dictionary, immersion, writing, synthesis, translation, argumentMap

        var label: String {
            switch self {
            case .chat: return String(localized: "Chat")
            case .deepResearch: return String(localized: "Deep Research")
            case .image: return String(localized: "Images")
            case .dictionary: return String(localized: "Dictionary")
            case .immersion: return String(localized: "Immersion")
            case .writing: return String(localized: "Writing")
            case .synthesis: return String(localized: "Synthesis")
            case .translation: return String(localized: "Translation")
            case .argumentMap: return String(localized: "Argument map")
            }
        }
    }

    /// Providers that can serve a task at all, given the keys this device holds.
    ///
    /// The task is not decoration: every provider with a key can hold a conversation, but only
    /// three of them can draw. Listing the other five under Images offers a choice that
    /// produces nothing, and the error arrives much later than the choice did.
    func availableProviders(for task: Task) -> [AIProvider] {
        AIProvider.allCases.filter { provider in
            guard configuredProviders.contains(provider) else { return false }
            return task != .image || provider.supportsImageGeneration
        }
    }

    // MARK: - Pinned

    func isPinned(_ model: ModelRef) -> Bool { pinnedModels.contains(model) }

    func togglePinned(_ model: ModelRef) {
        if let index = pinnedModels.firstIndex(of: model) {
            pinnedModels.remove(at: index)
        } else {
            pinnedModels.append(model)
        }
        persistPinned()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(models) else { return }
        store.set(data, forKey: defaultsKey)
    }

    private func persistPinned() {
        guard let data = try? JSONEncoder().encode(pinnedModels) else { return }
        store.set(data, forKey: pinnedKey)
    }
}

/// A short, honest note about what a provider is.
enum ProviderNotes {
    static func description(_ provider: AIProvider) -> String {
        switch provider {
        case .anthropic: return "Claude. Its own protocol, no JSON mode."
        case .openai: return "GPT and embeddings. The usual choice for indexing a vault."
        case .openrouter: return "A gateway to many models, with its own embeddings."
        case .groq: return "Very fast. Its free tier counts prompt and answer against one budget."
        case .cerebras: return "Very fast, short catalogue."
        case .deepseek: return "Inexpensive, with switchable reasoning."
        case .gemini: return "Google. Also serves embeddings and images."
        case .xiaomi: return "MiMo."
        }
    }

    static func keyPlaceholder(_ provider: AIProvider) -> String {
        switch provider {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .openrouter: return "sk-or-…"
        case .gemini: return "AIza…"
        default: return "API key"
        }
    }
}
