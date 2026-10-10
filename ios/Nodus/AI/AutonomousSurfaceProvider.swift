import CryptoKit
import Foundation
import NodusAI
import NodusKit

/// The shared renderer receives model names and results. Provider keys stay in iOS Keychain.
@MainActor
final class AutonomousSurfaceProvider {
    private let settings: AISettings
    private let provider: ProviderClient
    private let catalogue: ModelCatalogue
    private var completions: [UUID: (generation: String, task: Task<JSONValue, Error>)] = [:]
    private var cancelled: Set<String> = []
    static let modelTasks: [String: AISettings.Task] = [
        "chatModel": .chat, "deepResearchModel": .deepResearch, "dictionaryModel": .dictionary,
        "immersionModel": .immersion, "writingModel": .writing, "synthesisModel": .synthesis,
        "argumentMapModel": .argumentMap, "improveModel": .writing, "studyModel": .writing,
        "imageModel": .image, "translationModel": .translation, "authorModel": .synthesis,
        "nodiModel": .chat, "tutorModel": .chat, "hypothesisModel": .synthesis,
        "questionGenModel": .synthesis, "gradingModel": .synthesis, "flashcardModel": .synthesis
    ]
    init(settings: AISettings) {
        self.settings = settings
        provider = ProviderClient(keyProvider: settings.keyProvider)
        catalogue = ModelCatalogue(keyProvider: settings.keyProvider)
    }
    func portableSettings(_ value: JSONValue) throws -> JSONValue {
        guard var result = value.objectValue else { throw DesktopBridgeError.malformedResponse }
        for key in result.keys where key.hasSuffix("Model") && key != "embeddingModel" { result[key] = .null }
        for (name, task) in Self.modelTasks {
            result[name] = try settings.model(for: task).map { try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode($0)) } ?? .null
        }
        let providers = result["providerKeys"]?.objectValue ?? [:]
        result["providerKeys"] = .object(providers.mapValues { _ in .bool(false) }.merging(
            Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0.rawValue, JSONValue.bool(settings.hasKey(for: $0))) }), uniquingKeysWith: { _, new in new }))
        result["favorites"] = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(settings.pinnedModels))
        result.merge(settings.surfacePreferences, uniquingKeysWith: { _, new in new })
        result["lockedProviderKeys"] = .array([])
        result["defaultModel"] = .null
        return .object(result)
    }
    func updateSettings(_ patch: JSONValue) throws {
        guard let object = patch.objectValue, object.keys.allSatisfy({ Self.modelTasks[$0] != nil || ["modelSettingsMode", "researchThinkingEffort", "researchEffortByModel", "researchWebSearch", "studyImproveToolbarStyleIds"].contains($0) }) else { throw DesktopBridgeError.permissionDenied }
        try settings.setSurfacePreferences(object.filter { Self.modelTasks[$0.key] == nil })
        for (name, value) in object {
            guard let task = Self.modelTasks[name] else { continue }
            let model = value == .null ? nil : try JSONDecoder.nodus.decode(ModelRef.self, from: JSONEncoder.nodus.encode(value))
            if let model, !settings.hasKey(for: model.provider) { throw ProviderError.missingKey(model.provider) }
            settings.setModel(model, for: task)
        }
    }
    func models(_ providerName: String, includeStatus: Bool) async throws -> JSONValue {
        guard let kind = AIProvider(rawValue: providerName), settings.hasKey(for: kind) else { throw DesktopBridgeError.permissionDenied }
        let models = try await catalogue.models(for: kind).map { JSONValue.object(["id": .string($0)]) }
        return includeStatus ? .object(["status": .string("read"), "models": .array(models), "selectableModels": .array(models)]) : .array(models)
    }
    func dictionaryCheckpoint(_ args: [JSONValue], session: SpaceSession) async throws -> JSONValue {
        guard let action = args.first?.stringValue, action == "load" || session.aiExecutionMode == .autonomous,
            args.count >= 2, let entryId = args[1].stringValue, !entryId.isEmpty, entryId.utf8.count <= 256 else { throw DesktopBridgeError.permissionDenied }
        let scope = try session.surfaceStorageScope()
        let vault = scope.recordVaultId
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let key = "autonomous:dictionary:" + SHA256.hash(data: Data(entryId.utf8)).map { String(format: "%02x", $0) }.joined()
        if action == "load" {
            guard let bytes = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key) else { return .null }
            return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
        }
        guard action == "save", args.count == 3, let object = args[2].objectValue,
            let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
            object["request"]?.objectValue?["entryId"]?.stringValue == entryId else { throw DesktopBridgeError.permissionDenied }
        let bytes = try JSONEncoder.nodus.encode(args[2])
        guard bytes.count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        try await cache.store(bytes, vaultId: vault, domain: .researchGeneration, recordId: key)
        return .null
    }
    func generationCheckpoint(_ args: [JSONValue], session: SpaceSession) async throws -> JSONValue {
        guard session.aiExecutionMode == .autonomous, args.count >= 3,
            let action = args[0].stringValue, let kind = args[1].stringValue, ["immersion", "translation", "writing", "argument"].contains(kind),
            let entity = args[2].stringValue, entity.utf8.count <= 256, !entity.isEmpty else { throw DesktopBridgeError.permissionDenied }
        let scope = try session.surfaceStorageScope()
        let vault = scope.recordVaultId
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let key = "autonomous:\(kind):" + SHA256.hash(data: Data(entity.utf8)).map { String(format: "%02x", $0) }.joined()
        if action == "load" {
            guard let bytes = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key) else { return .null }
            return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
        }
        guard action == "save", args.count == 4, let object = args[3].objectValue,
            object["entityKey"]?.stringValue == entity, let id = object["id"]?.stringValue, UUID(uuidString: id) != nil else { throw DesktopBridgeError.permissionDenied }
        let bytes = try JSONEncoder.nodus.encode(args[3])
        guard bytes.count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        try await cache.store(bytes, vaultId: vault, domain: .researchGeneration, recordId: key)
        return .null
    }
    func complete(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        guard let generation = input.objectValue?["generationId"]?.stringValue, UUID(uuidString: generation) != nil,
            !cancelled.contains(generation) else { throw CancellationError() }
        let key = UUID()
        let task = Task { try await self.performCompletion(input, session: session) }
        completions[key] = (generation, task)
        defer { completions[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func cancel(_ generation: String) throws {
        guard UUID(uuidString: generation) != nil else { throw DesktopBridgeError.malformedResponse }
        cancelled.insert(generation)
        for completion in completions.values where completion.generation == generation { completion.task.cancel() }
    }
    private func performCompletion(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        guard session.aiExecutionMode == .autonomous, let request = input.objectValue,
            let generation = request["generationId"]?.stringValue, UUID(uuidString: generation) != nil,
            let modelJSON = request["model"], let system = request["system"]?.stringValue,
            let user = request["user"]?.stringValue, system.utf8.count + user.utf8.count <= 1_000_000,
            let maxTokens = request["maxTokens"]?.intValue, (1...16_000).contains(maxTokens)
        else { throw DesktopBridgeError.permissionDenied }
        let scope = try session.surfaceStorageScope()
        let vault = scope.recordVaultId
        let model = try JSONDecoder.nodus.decode(ModelRef.self, from: JSONEncoder.nodus.encode(modelJSON))
        guard settings.hasKey(for: model.provider) else { throw ProviderError.missingKey(model.provider) }
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let hash = SHA256.hash(data: try JSONEncoder.nodus.encode(input)).map { String(format: "%02x", $0) }.joined()
        let record = "autonomous:\(generation):completion:\(hash)"
        if let saved = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: record) {
            return try JSONDecoder.nodus.decode(JSONValue.self, from: saved)
        }
        let temperature: Double?
        switch request["temperature"] { case .double(let value): temperature = value; case .int(let value): temperature = Double(value); case .null: temperature = nil; default: temperature = 0 }
        let options = request["researchParameters"]?.objectValue ?? [:]
        guard options.keys.allSatisfy({ ["thinking", "reasoning", "reasoning_effort", "output_config", "extra_body"].contains($0) }) else { throw DesktopBridgeError.permissionDenied }
        let parameters = try JSONDecoder.nodus.decode([String: JSONBody].self, from: JSONEncoder.nodus.encode(options))
        let allowance = request["thinkingAllowance"]?.intValue ?? 0
        guard (0...131_072).contains(allowance) else { throw DesktopBridgeError.permissionDenied }
        let format = request["format"]?.stringValue ?? "json"
        guard ["json", "text"].contains(format) else { throw DesktopBridgeError.malformedResponse }
        let result = try await provider.complete(ChatRequest(model: model, messages: [.init(role: .system, content: system), .init(role: .user, content: user)], temperature: temperature, maxTokens: maxTokens + allowance, jsonMode: format == "json", researchParameters: parameters))
        try Task.checkCancellation()
        let value = JSONValue.string(result)
        try await cache.store(JSONEncoder.nodus.encode(value), vaultId: vault, domain: .researchGeneration, recordId: record)
        return value
    }
}
