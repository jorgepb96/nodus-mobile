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
    private let embeddings: EmbeddingService
    private var completions: [UUID: (generation: String, task: Task<JSONValue, Error>)] = [:]
    private var cancelled: Set<String> = []
    private var acceptedDeepResearchCompletions: Set<UUID> = []
    private var authoringActivities: [String: PrivateBridgeCache] = [:]
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
        embeddings = EmbeddingService(keyProvider: settings.keyProvider)
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
    func beginAuthoring(_ generation: String, session: SpaceSession) throws {
        guard UUID(uuidString: generation) != nil, session.aiExecutionMode == .autonomous,
              authoringActivities[generation] == nil else { throw DesktopBridgeError.permissionDenied }
        if session.connection.desktopPairingId != nil { _ = try privateBridgeConnection(session, domain: .writing) }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        try cache.beginAuthoringActivity()
        authoringActivities[generation] = cache
    }
    func endAuthoring(_ generation: String) {
        authoringActivities.removeValue(forKey: generation)?.endAuthoringActivity()
    }
    func finishAbandonedAuthoringActivities() {
        for cache in authoringActivities.values { cache.endAuthoringActivity() }
        authoringActivities.removeAll()
    }
    private func deepResearchSummary(_ value: JSONValue) -> JSONValue {
        guard let object = value.objectValue else { return .null }
        let keys = ["id", "entityKey", "state", "createdAt", "context", "request", "progress", "error", "result", "publicationPending", "hiddenFromQueue", "recoveryReviewRequired"]
        var summary = object.filter { keys.contains($0.key) }
        if let request = object["request"]?.objectValue {
            summary["request"] = .object(request.filter { ["objective", "model", "approach", "deepResearchVersion", "sectionLimit", "sectionLength"].contains($0.key) })
        }
        // A receipt needs only its identity here; full bodies remain in the checkpoint.
        if let result = object["result"]?.objectValue { summary["result"] = .object(result.filter { ["id"].contains($0.key) }) }
        if let draft = object["report"]?.objectValue?["draft"]?.objectValue {
            summary["report"] = .object(["draft": .object(["title": draft["title"] ?? .null, "generatedAt": draft["generatedAt"] ?? .null])])
        }
        return .object(summary)
    }
    func deepResearchCheckpoints(session: SpaceSession, summaries: Bool = false, includeArchived: Bool = false) async throws -> JSONValue {
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:deepResearch:index:v1")
        let entities = try bytes.map { try JSONDecoder.nodus.decode([String].self, from: $0) } ?? []
        let ledger = session.connection.desktopPairingId != nil ? try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId) : nil
        var values: [JSONValue] = []
        for entity in entities {
            let key = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
            let summaryKey = "autonomous:deepResearch:summary:\(entity)"
            var record = key
            if summaries, try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: summaryKey) != nil { record = summaryKey }
            if let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: record) {
                let stored = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
                let reconciled = await ledger?.generationCheckpoint(recordId: key, generationId: stored.objectValue?["id"]?.stringValue)
                values.append(summaries ? deepResearchSummary(reconciled ?? stored) : reconciled ?? stored)
            }
        }
        if includeArchived, let ledger {
            for request in await ledger.all() where ["localDeepResearchGeneration", "saveMobileDeepResearchReport"].contains(request.method) {
                guard let value = request.checkpoint, !values.contains(where: { $0.objectValue?["id"] == .string(request.id) }) else { continue }
                values.append(value)
            }
        }
        return .array(values)
    }
    func embeddingConfiguration() throws -> JSONValue {
        guard let configuration = settings.embeddingConfiguration else { return .null }
        return try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(configuration))
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
        let key = try CompanionGenerationPublication.recordId(kind: "dictionary", entity: entryId)
        if action == "load" {
            return try await loadCheckpoint(cache: cache, key: key, scope: scope, session: session)
        }
        guard action == "save", args.count == 3, let object = args[2].objectValue,
            let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
            object["request"]?.objectValue?["entryId"]?.stringValue == entryId else { throw DesktopBridgeError.permissionDenied }
        let bytes = try JSONEncoder.nodus.encode(args[2])
        guard bytes.count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        try await queuePublication(kind: "dictionary", entity: entryId, checkpoint: args[2], scope: scope, session: session)
        try await cache.store(bytes, vaultId: vault, domain: .researchGeneration, recordId: key)
        return try await loadCheckpoint(cache: cache, key: key, scope: scope, session: session)
    }
    func databaseCheckpoints(session: SpaceSession,includeSource: Bool = false) async throws -> JSONValue {
        if session.connection.desktopPairingId != nil { _ = try privateBridgeConnection(session,domain:.corpus) }
        let scope = try session.surfaceStorageScope(),cache = try PrivateBridgeCache(pairingId:scope.cacheId)
        let bytes = try await cache.data(vaultId:scope.recordVaultId,domain:.researchGeneration,recordId:"autonomous:database:index:v1")
        let entities = try bytes.map { try JSONDecoder.nodus.decode([String].self,from:$0) } ?? []
        var readMarkers: [String:JSONValue] = [:]
        if !includeSource,let pairingId = session.connection.desktopPairingId,
           DesktopBridgePairingStore().pairings().first(where:{$0.id == pairingId})?.domains.contains(.writing) == true {
            let outbox = try await CompanionDatabaseReadingOutboxes.shared.outbox(pairingId:scope.cacheId,vaultId:scope.recordVaultId)
            readMarkers = Dictionary(uniqueKeysWithValues:await outbox.all().map { ($0.key,$0.value.draft.readAt.map(JSONValue.string) ?? .null) })
        }
        var records: [JSONValue] = []
        for entity in entities {
            let value = try await loadCheckpoint(cache:cache,key:CompanionGenerationPublication.recordId(kind:"database",entity:entity),scope:scope,session:session)
            if value != .null {
                if includeSource { records.append(value) }
                else if var fields = value.objectValue {
                    fields["context"] = nil;fields["reader"] = nil;fields["reading"] = nil
                    func summary(_ report: JSONValue?) -> JSONValue? {
                        guard let data = report?.objectValue else { return nil }
                        var result = data.filter { ["id","runId","title","summary","createdAt","updatedAt","reportType","readAt","metadata","quality"].contains($0.key) }
                        if let id = data["id"]?.stringValue,let readAt = readMarkers[id] { result["readAt"] = readAt }
                        return .object(result)
                    }
                    fields["result"] = summary(fields["result"])
                    if var detail = fields["detail"]?.objectValue {
                        detail["steps"] = .array([]);detail["claims"] = .array([]);detail["report"] = summary(detail["report"]);fields["detail"] = .object(detail)
                    }
                    records.append(.object(fields))
                }
            }
        }
        return .array(records)
    }
    func databaseLocalReader(_ id: String,session: SpaceSession) async throws -> JSONValue? {
        guard session.connection.desktopPairingId != nil else { return nil }
        _ = try privateBridgeConnection(session,domain:.corpus)
        guard let values = try await databaseCheckpoints(session:session,includeSource:true).arrayValue else { throw DesktopBridgeError.malformedResponse }
        for value in values {
            guard let reader = value.objectValue?["reader"]?.objectValue,reader["report"]?.objectValue?["id"] == .string(id),
                  let reading = value.objectValue?["reading"],
                  ["saved","available","failed"].contains(value.objectValue?["state"]?.stringValue ?? "") else { continue }
            var source = reader
            if source["exportDetail"] == nil,var detail = value.objectValue?["detail"]?.objectValue { detail["report"] = nil;source["exportDetail"] = .object(detail) }
            var result: [String:JSONValue] = ["source":.object(source),"reading":reading,"published":.bool(value.objectValue?["state"] == .string("available"))]
            if let packs = value.objectValue?["context"]?.objectValue?["packs"] { result["sourcePacks"] = packs }
            return .object(result)
        }
        return nil
    }
    func databaseOfflineSource(_ args: [JSONValue],session: SpaceSession) async throws -> JSONValue {
        guard args.count == 1,
              let ids = args[0].objectValue?["databaseIds"]?.arrayValue?.compactMap(\.stringValue),!ids.isEmpty,ids.count <= 30 else { throw DesktopBridgeError.permissionDenied }
        let (vault,pairing,_) = try privateBridgeConnection(session,domain:.corpus),cache = try PrivateBridgeCache(pairingId:pairing.id)
        var copies: [Data] = []
        for id in ids { copies += try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:"companion:database-source:v1:\(id)") }
        var packs: [JSONValue] = [],remaining = Set(ids),seen = Set<String>(),bytes = 0
        for data in copies {
            let value = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
            guard let pack = value.objectValue,pack["version"] == .int(1),pack["vaultId"] == .string(vault),
                  let identity = pack["id"]?.stringValue,let databases = pack["databases"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            let owned = Set(databases.compactMap { $0.objectValue?["snapshot"]?.objectValue?["databaseId"]?.stringValue })
            if !remaining.isDisjoint(with:owned),seen.insert(identity).inserted {
                bytes += data.count;guard bytes <= 16_000_000 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                packs.append(value);remaining.subtract(owned)
            }
            if remaining.isEmpty { break }
        }
        guard remaining.isEmpty else { throw APIError(status:409,code:"database_source_not_downloaded",message:"Descarga las bases seleccionadas desde Para llevar antes de investigarlas sin el Mac.") }
        return .object(["version":.int(1),"packs":.array(packs)])
    }
    func databaseOfflineCatalogue(session: SpaceSession) async throws -> JSONValue {
        let (vault,pairing,_) = try privateBridgeConnection(session,domain:.corpus),cache = try PrivateBridgeCache(pairingId:pairing.id)
        let copies = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:CompanionCollectionCopy.recordId(path:"databases"))
        guard !copies.isEmpty else { throw APIError(status:409,code:"database_source_not_downloaded",message:"No has elegido bases de datos para llevar. Descárgalas mientras el Mac esté conectado.") }
        let collection = try CompanionCollectionCopy(path:"databases",copies:copies.map { try JSONDecoder.nodus.decode(JSONValue.self,from:$0) })
        var sources: [JSONValue] = []
        for row in collection.selectedRows {
            guard let id = row.columns["id"]?.stringValue,let data = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:"companion:database-source:v1:\(id)").first else { throw DesktopBridgeError.malformedResponse }
            let pack = try JSONDecoder.nodus.decode(JSONValue.self,from:data)
            guard pack.objectValue?["vaultId"] == .string(vault),let source = pack.objectValue?["databases"]?.arrayValue?.first(where:{ $0.objectValue?["snapshot"]?.objectValue?["databaseId"] == .string(id) })?.objectValue else { throw DesktopBridgeError.malformedResponse }
            sources.append(.object(source.filter { ["database","columns","views","profiles"].contains($0.key) }))
        }
        return .array(sources)
    }
    func generationCheckpoint(_ args: [JSONValue], session: SpaceSession) async throws -> JSONValue {
        guard args.count >= 3, let action = args[0].stringValue,
            let kind = args[1].stringValue, ["immersion", "translation", "writing", "argument", "database", "academic", "deepResearch"].contains(kind),
            let entity = args[2].stringValue, entity.utf8.count <= 256, !entity.isEmpty else { throw DesktopBridgeError.permissionDenied }
        let scope = try session.surfaceStorageScope()
        let vault = scope.recordVaultId
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let key = try CompanionGenerationPublication.recordId(kind: kind, entity: entity)
        if action == "load" {
            return try await loadCheckpoint(cache: cache, key: key, scope: scope, session: session)
        }
        guard action == "save", args.count == 4, let object = args[3].objectValue,
            object["entityKey"]?.stringValue == entity, let id = object["id"]?.stringValue, UUID(uuidString: id) != nil else { throw DesktopBridgeError.permissionDenied }
        // A mode change cannot discard a response to a generation already
        // authorised on the device. It still cannot start a new device request.
        if session.aiExecutionMode != .autonomous {
            guard let bytes = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key),
                  let previous = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue,
                  previous["id"] == .string(id), previous["request"] == object["request"] else { throw DesktopBridgeError.permissionDenied }
        }
        let bytes = try JSONEncoder.nodus.encode(args[3])
        guard bytes.count <= (kind == "deepResearch" ? 50 * 1024 * 1024 : 20_000_000) else { throw DesktopBridgeError.malformedResponse }
        if ["academic", "deepResearch"].contains(kind), session.connection.desktopPairingId != nil,
           let old = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key) {
            let previous = try JSONDecoder.nodus.decode(JSONValue.self, from: old)
            if previous.objectValue?["id"] != .string(id) {
                let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: vault)
                if kind == "deepResearch" { try await ledger.archiveDeepResearchCheckpoint(recordId: key, checkpoint: previous) }
                else { try await ledger.archiveAcademicCheckpoint(recordId: key, checkpoint: previous) }
            }
        }
        try await queuePublication(kind: kind, entity: entity, checkpoint: args[3], scope: scope, session: session)
        if kind == "academic" { try await cache.storeIndexedGeneration(bytes,vaultId:vault,recordId:key,indexId:"autonomous:academic:index:v1",entity:entity) }
        else if kind == "deepResearch" {
            let summary = PrivateBridgeCache.IndexedGenerationSummary(recordId: "autonomous:deepResearch:summary:\(entity)", data: try JSONEncoder.nodus.encode(deepResearchSummary(args[3])))
            try await cache.storeIndexedGeneration(bytes,vaultId:vault,recordId:key,indexId:"autonomous:deepResearch:index:v1",entity:entity,summary:summary)
        }
        else if kind == "database" { try await cache.storeIndexedGeneration(bytes,vaultId:vault,recordId:key,indexId:"autonomous:database:index:v1",entity:entity) }
        else { try await cache.store(bytes, vaultId: vault, domain: .researchGeneration, recordId: key) }
        return try await loadCheckpoint(cache: cache, key: key, scope: scope, session: session)
    }
    private func queuePublication(kind: String, entity: String, checkpoint: JSONValue,
                                  scope: MobileSurfaceStorageScope, session: SpaceSession) async throws {
        guard session.connection.desktopPairingId != nil,
              let publication = try CompanionGenerationPublication(kind: kind, entity: entity, checkpoint: checkpoint) else { return }
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings().first(where: { $0.id == scope.cacheId }), !pairing.isExpired,
              pairing.vaultIds.contains(scope.recordVaultId), pairing.domains.contains(.writing)
        else { throw DesktopBridgeError.permissionDenied }
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
        try await ledger.preparePublication(publication)
        session.didSaveCompanionResult()
    }
    private func loadCheckpoint(cache: PrivateBridgeCache, key: String, scope: MobileSurfaceStorageScope,
                                session: SpaceSession) async throws -> JSONValue {
        let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: key)
        let local = try bytes.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) }
        guard session.connection.desktopPairingId != nil else { return local ?? .null }
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
        guard let reconciled = await ledger.generationCheckpoint(recordId: key, generationId: local?.objectValue?["id"]?.stringValue),
              var value = reconciled.objectValue else { return local ?? .null }
        if value["state"] == .string("available"), local?.objectValue?["state"] != .string("available") {
            value["recoveredPublication"] = .bool(true)
        }
        if local?.objectValue?["id"] == value["id"],local?.objectValue?["hiddenFromQueue"] == .bool(true) { value["hiddenFromQueue"] = .bool(true) }
        if value["state"] == .string("available"),key.hasPrefix("autonomous:database:") {
            value["context"] = nil
            try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(value)),vaultId:scope.recordVaultId,domain:.researchGeneration,recordId:key)
        }
        return .object(value)
    }
    func dictionaryPublications(session: SpaceSession) async throws -> JSONValue {
        guard session.connection.desktopPairingId != nil else { return .array([]) }
        let scope = try session.surfaceStorageScope()
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
        var seen: Set<String> = []
        var progress: [JSONValue] = []
        for job in await ledger.all() where job.method == "saveDictionaryGeneratedVersion" {
            guard let request = job.checkpoint?.objectValue?["request"]?.objectValue,
                  let entry = request["entryId"]?.stringValue, seen.insert(entry).inserted else { continue }
            let phase = job.state == "available" ? (job.checkpoint?.objectValue?["definition"]?.objectValue?["outcome"] == .string("degraded") ? "degraded" : "done")
                : ["failed", "interrupted", "cancelled"].contains(job.state) ? "failed" : "saving"
            progress.append(.object(["entryId": .string(entry), "mode": request["mode"] ?? .null, "phase": .string(phase),
                "message": .string(job.issue ?? (job.state == "available" ? "Definición sincronizada con Nodus" : "Guardado en este dispositivo · pendiente de sincronizar")),
                "error": job.issue.map(JSONValue.string) ?? .null]))
        }
        return .array(progress)
    }
    func argumentMaps(session: SpaceSession) async throws -> JSONValue {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        var maps: [String: JSONValue] = [:]
        if let bytes = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: "autonomous:academic:index:v1") {
            for entity in try JSONDecoder.nodus.decode([String].self, from: bytes) {
                let key = try CompanionGenerationPublication.recordId(kind: "academic", entity: entity)
                let checkpoint = try await loadCheckpoint(cache: cache, key: key, scope: session.surfaceStorageScope(), session: session)
                if let value = checkpoint.objectValue, value["request"]?.objectValue?["source"]?.objectValue?["kind"] == .string("argument"),
                   let id = value["id"]?.stringValue,
                   let map = value["result"]?.objectValue?["root"] != nil ? value["result"] : value["preview"], map.objectValue?["root"]?.objectValue != nil { maps[id] = map }
            }
        }
        for request in await ledger.all() where ["saveMobileAcademicResult", "localAcademicGeneration"].contains(request.method) {
            guard request.checkpoint?.objectValue?["request"]?.objectValue?["source"]?.objectValue?["kind"] == .string("argument"),
                  let map = request.result?.objectValue?["root"] != nil ? request.result : request.checkpoint?.objectValue?["preview"], map.objectValue?["root"]?.objectValue != nil else { continue }
            maps[request.id] = map
        }
        for request in await ledger.all() where request.method == "buildArgumentMap" && request.state == "available" {
            if let map = request.result, map.objectValue?["root"]?.objectValue != nil { maps[request.jobId ?? request.id] = map }
        }
        return .array(maps.sorted { $0.key < $1.key }.map { .object(["id": .string($0.key), "map": $0.value]) })
    }
    func complete(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        guard let generation = input.objectValue?["generationId"]?.stringValue, UUID(uuidString: generation) != nil,
            !cancelled.contains(generation) else { throw CancellationError() }
        let key = UUID()
        let task = Task { try await self.performCompletion(input, session: session, completionId: key) }
        completions[key] = (generation, task)
        defer { completions[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
            Task { @MainActor in
                self.cancelled.insert(generation)
                if !self.acceptedDeepResearchCompletions.contains(key) { task.cancel() }
            }
        })
    }
    func savedCompletion(_ input: JSONValue, session: SpaceSession) async throws -> JSONValue {
        guard let generation = input.objectValue?["generationId"]?.stringValue, UUID(uuidString: generation) != nil,
              try JSONEncoder.nodus.encode(input).count <= 1_200_000 else { throw DesktopBridgeError.malformedResponse }
        let scope = try session.surfaceStorageScope(), cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let hash = SHA256.hash(data: try JSONEncoder.nodus.encode(input)).map { String(format: "%02x", $0) }.joined()
        guard let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:\(generation):completion:\(hash)") else { return .null }
        return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
    }
    func cancel(_ generation: String) throws {
        guard UUID(uuidString: generation) != nil else { throw DesktopBridgeError.malformedResponse }
        cancelled.insert(generation)
        for (id, completion) in completions where completion.generation == generation {
            if !acceptedDeepResearchCompletions.contains(id) { completion.task.cancel() }
        }
    }
    private func performCompletion(_ input: JSONValue, session: SpaceSession, completionId: UUID) async throws -> JSONValue {
        guard session.aiExecutionMode == .autonomous, let request = input.objectValue,
            let generation = request["generationId"]?.stringValue, UUID(uuidString: generation) != nil,
            let modelJSON = request["model"], let system = request["system"]?.stringValue,
            let user = request["user"]?.stringValue, system.utf8.count + user.utf8.count <= 1_000_000,
            let maxTokens = request["maxTokens"]?.intValue, (1...16_000).contains(maxTokens)
        else { throw DesktopBridgeError.permissionDenied }
        let scope = try session.surfaceStorageScope()
        let vault = scope.recordVaultId
        let model = try JSONDecoder.nodus.decode(ModelRef.self, from: JSONEncoder.nodus.encode(modelJSON))
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        // Hold through the paid-response write, so unlink cannot retire the
        // encryption key between the provider returning and durable recovery.
        let hasOuterActivity = authoringActivities[generation] != nil
        if !hasOuterActivity { try cache.beginAuthoringActivity() }
        defer { if !hasOuterActivity { cache.endAuthoringActivity() } }
        let hash = SHA256.hash(data: try JSONEncoder.nodus.encode(input)).map { String(format: "%02x", $0) }.joined()
        let record = "autonomous:\(generation):completion:\(hash)"
        if let saved = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: record) {
            return try JSONDecoder.nodus.decode(JSONValue.self, from: saved)
        }
        try await cache.requireGenerationExecutionAllowed(vaultId: vault, generationId: generation)
        guard settings.hasKey(for: model.provider) else { throw ProviderError.missingKey(model.provider) }
        let temperature: Double?
        switch request["temperature"] { case .double(let value): temperature = value; case .int(let value): temperature = Double(value); case .null: temperature = nil; default: temperature = 0 }
        let options = request["researchParameters"]?.objectValue ?? [:]
        guard options.keys.allSatisfy({ ["thinking", "reasoning", "reasoning_effort", "output_config", "extra_body"].contains($0) }) else { throw DesktopBridgeError.permissionDenied }
        let parameters = try JSONDecoder.nodus.decode([String: JSONBody].self, from: JSONEncoder.nodus.encode(options))
        let allowance = request["thinkingAllowance"]?.intValue ?? 0
        guard (0...131_072).contains(allowance) else { throw DesktopBridgeError.permissionDenied }
        let format = request["format"]?.stringValue ?? "json"
        guard ["json", "text", "embedding"].contains(format) else { throw DesktopBridgeError.malformedResponse }
        try Task.checkCancellation()
        guard !cancelled.contains(generation) else { throw CancellationError() }
        if request["completionKey"]?.stringValue != nil { acceptedDeepResearchCompletions.insert(completionId) }
        defer { acceptedDeepResearchCompletions.remove(completionId) }
        let result: String
        if format == "embedding" {
            guard system.isEmpty, model.provider.supportsEmbeddings,
                  case .some(.int(let rawDimensions)) = request["embeddingDimensions"],
                  let dimensions = Int(exactly: rawDimensions), (1...65_536).contains(dimensions) else { throw DesktopBridgeError.permissionDenied }
            // A resumed job keeps its explicitly captured model, even if the next
            // job's preference changed. Keys are still required on this device.
            let configuration = EmbeddingIdentity(provider: model.provider.rawValue, model: model.model, dim: dimensions)
            let vector = try await embeddings.embed(user, as: configuration)
            result = String(decoding: try JSONEncoder.nodus.encode(vector), as: UTF8.self)
        } else {
            result = try await provider.complete(ChatRequest(model: model, messages: [.init(role: .system, content: system), .init(role: .user, content: user)], temperature: temperature, maxTokens: maxTokens + allowance, jsonMode: format == "json", researchParameters: parameters))
        }
        let value = JSONValue.string(result)
        try await cache.storeIndexedGeneration(JSONEncoder.nodus.encode(value), vaultId: vault, recordId: record,
            indexId: "autonomous:completion-index:v1", entity: record)
        try Task.checkCancellation()
        guard !cancelled.contains(generation) else { throw CancellationError() }
        return value
    }
}
