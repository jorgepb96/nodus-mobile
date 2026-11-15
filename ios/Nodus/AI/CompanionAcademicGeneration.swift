import CryptoKit
import Foundation
import NodusAI
import NodusKit

@MainActor
final class CompanionAcademicGeneration {
    private static var active: [String: Task<JSONValue, Error>] = [:]
    private let provider: AutonomousSurfaceProvider
    private let settings: AISettings
    init(settings: AISettings) { self.settings = settings; provider = AutonomousSurfaceProvider(settings: settings) }

    static var language: String {
        let code = Locale.current.language.languageCode?.identifier ?? "es"
        if code == "zh" { return Locale.current.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
        if code == "pt", Locale.current.region?.identifier == "BR" { return "pt-BR" }
        return ["es", "en", "fr", "tr", "de", "pt", "it", "vi", "ja", "ru", "uk", "ko"].contains(code) ? code : "es"
    }

    static func sourceRequest(kind: String, author: String? = nil, theme: String? = nil, scene: String? = nil, language: String, draft: JSONValue? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["kind": .string(kind), "language": .string(language)]
        if let author { value["authorId"] = .string(author) }; if let theme { value["themeId"] = .string(theme) }; if let scene { value["sceneId"] = .string(scene) }
        if let draft { value["draft"] = draft }
        return .object(value)
    }
    private static func entity(_ request: JSONValue) throws -> String {
        SHA256.hash(data: try JSONEncoder.nodus.encode(request)).map { String(format: "%02x", $0) }.joined()
    }
    static func saved(session: SpaceSession, request: JSONValue, onlyUnpublished: Bool = false) async throws -> JSONValue? {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let key = try CompanionGenerationPublication.recordId(kind: "academic", entity: entity(request))
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        let local = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key).map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) }
        let entries = await ledger.all().filter { $0.method == "saveMobileAcademicResult" && $0.checkpointRecordId == key && $0.checkpoint?.objectValue?["preview"]?.objectValue != nil }
        let checkpoint: JSONValue?
        if let local, local.objectValue?["preview"]?.objectValue != nil {
            checkpoint = await ledger.generationCheckpoint(recordId: key, generationId: local.objectValue?["id"]?.stringValue) ?? local
        } else if let entry = entries.first {
            checkpoint = await ledger.generationCheckpoint(recordId: key, generationId: entry.id)
        } else { checkpoint = nil }
        if onlyUnpublished, checkpoint?.objectValue?["state"] == .string("available") { return nil }
        return checkpoint?.objectValue?["preview"]
    }
    static func download(session: SpaceSession, request: JSONValue, days: Int) async throws {
        guard [7, 30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        let client = DesktopBridgeClient(pairing: pairing, token: token)
        let records = try await CompanionArgumentDownload.capture(request: request, maximumBytes: 50 * 1024 * 1024) { method, args in
            try await client.operation(vaultId: vault, method: method, args: args)
        }
        let record = try CompanionDocumentOutbox.operationKey("getMobileAcademicSource", [request])
        let selection = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: [record])
        try Task.checkCancellation()
        try await PrivateBridgeCache(pairingId: pairing.id).saveReadPack(id: selection, vaultId: vault, title: "Fuentes de síntesis y revisión",
            expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: records)
        session.didChangeCompanionDownloads()
    }
    static func source(session: SpaceSession, request: JSONValue) async throws -> JSONValue {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        var baseline = request.objectValue ?? [:]; baseline["draft"] = nil
        let baselineRequest = JSONValue.object(baseline)
        let key = try CompanionDocumentOutbox.operationKey("getMobileAcademicSource", [baselineRequest])
        let chosen = try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: key)
        let localScene = chosen.isEmpty ? try await localSceneSource(session:session,request:request) : nil
        if let localScene, localScene.pending { return localScene.value }
        let value: JSONValue
        do { value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileAcademicSource", args: [request], timeout: chosen.isEmpty ? nil : 4) }
        catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            if let localScene { return localScene.value }
            guard let bytes = chosen.first else { throw APIError(status: 409, code: "academic_sources_not_downloaded", message: "Descarga estas fuentes para llevar mientras tu Mac esté conectado.") }
            let downloaded = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
            value = request.objectValue?["draft"] == nil ? downloaded : try CompanionProseDraft.source(downloaded, request: request)
        }
        _ = try CompanionAcademicSource(value, request: request); return value
    }

    /// A fresh scene can be reviewed using this device's own durable edits, even
    /// before it has ever been visible on the Mac. Existing scenes require a copy.
    private static func localSceneSource(session:SpaceSession,request:JSONValue) async throws -> (value:JSONValue,pending:Bool)? {
        guard session.vaultType == .worldbuilding, request.objectValue?["kind"] == .string("prose"),
              let scene=request.objectValue?["sceneId"]?.stringValue, let draft=request.objectValue?["draft"]?.objectValue,
              let declared=draft["beats"]?.arrayValue else { return nil }
        let queue=try MutationOutbox(spaceId:session.connection.storageId,directory:ConnectionClient.spacesDirectory)
        let changes=try await queue.retainedMutations(table:.worldScenes)
        guard let creation=changes.first(where:{$0.kind == .upsert && $0.key == [scene] && $0.companionCreation == true}) else { return nil }
        let states=try await queue.items()
        let names=["world_scenes","world_scene_text","world_beats","world_threads","world_rules"]
        let tables:[String:[Row]]
        do { tables=try await worldTables(session,names) }
        catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            tables=try await queue.companionContentProjection(Dictionary(uniqueKeysWithValues:names.map{($0,[Row]())}))
        }
        guard let row=tables["world_scenes"]?.first(where:{$0.string("scene_id")==scene}), let title=row.string("title") else { throw DesktopBridgeError.malformedResponse }
        let beats=(tables["world_beats"] ?? []).filter{$0.string("scene_id")==scene}
        let baselineBeats: [JSONValue] = try beats.map { row in
            guard let kind=row.string("thread_kind"),let id=row.string("thread_id"),let mark=row.string("mark") else { throw DesktopBridgeError.malformedResponse }
            let original=declared.first{$0.objectValue?["threadKind"] == .string(kind) && $0.objectValue?["threadId"] == .string(id)}?.objectValue
            let owner=(tables[kind == "rule" ? "world_rules":"world_threads"] ?? []).first{$0.string(kind == "rule" ? "rule_id":"thread_id")==id}
            guard let label=owner?.string("title") ?? original?["threadTitle"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            return .object(["threadKind":.string(kind),"threadId":.string(id),"threadTitle":.string(label),"mark":.string(mark),"text":row["text"] ?? .null])
        }
        let prose=tables["world_scene_text"]?.first(where:{$0.string("scene_id")==scene})?.string("text") ?? ""
        let baseline:JSONValue = .object(["sceneTitle":.string(title),"text":.string(prose),"beats":.array(baselineBeats)])
        return (try CompanionProseDraft.localSceneSource(request:request,creationMutationId:creation.id,baselineDraft:baseline),states.first{$0.id==creation.id}?.state != .delivered)
    }

    func run(session: SpaceSession, request: JSONValue, onStatus: @escaping (String) -> Void) async throws -> JSONValue {
        try NodusLinkPolicy.requireAuthoring()
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .writing)
        let model = try settings.model(for: .synthesis).map { try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode($0)) } ?? .null
        let identity = try Self.entity(.object(["request": request, "model": model]))
        let key = "\(pairing.id):\(vault):\(identity)"
        if let task = Self.active[key] { return try await task.value }
        let task = Task { try await self.execute(session: session, request: request, onStatus: onStatus) }
        Self.active[key] = task; defer { Self.active[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func execute(session: SpaceSession, request: JSONValue, onStatus: (String) -> Void) async throws -> JSONValue {
        guard session.aiExecutionMode == .autonomous, ["author", "matrix", "prose"].contains(request.objectValue?["kind"]?.stringValue ?? ""), let model = settings.model(for: .synthesis) else {
            throw APIError(status: 409, code: "mobile_synthesis_model_missing", message: "Elige un modelo de síntesis y configura su proveedor en los ajustes del móvil.")
        }
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .writing)
        guard pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let cache = try PrivateBridgeCache(pairingId: pairing.id), entity = try Self.entity(request)
        try cache.beginAuthoringActivity()
        defer { cache.endAuthoringActivity() }
        let key = try CompanionGenerationPublication.recordId(kind: "academic", entity: entity)
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let modelJSON = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(model))
        let work: JSONValue = .object(["source": request, "model": modelJSON])
        let previous = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key).map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0).objectValue } ?? nil
        // A complete result awaiting acknowledgement resumes its provider-free
        // publication. A rejected/finished attempt never reuses stale sources.
        var value: [String: JSONValue]
        let receipt = await ledger.all().first { $0.id == previous?["id"]?.stringValue }
        if let previous, CompanionGenerationRecovery.resumeAcademic(checkpoint: .object(previous), work: work, receiptState: receipt?.state) { value = previous }
        else {
            if let previous { try await ledger.archiveAcademicCheckpoint(recordId: key, checkpoint: .object(previous)) }
            value = ["id": .string(UUID().uuidString.lowercased()), "entityKey": .string(entity), "request": work, "state": .string("accepted")]
        }
        guard let id = value["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        func save() async throws { try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(value)), vaultId: vault, domain: .researchGeneration, recordId: key) }
        do {
            try Task.checkCancellation(); try await save()
            if value["context"] == nil {
                onStatus("Preparando las fuentes de Nodus")
                let source = try await Self.source(session: session, request: request)
                let captured = try CompanionAcademicSource(source, request: request)
                value["context"] = .object(["source": source, "revision": .string(captured.revision)]); try await save()
            }
            guard let source = value["context"]?.objectValue?["source"] else { throw DesktopBridgeError.malformedResponse }
            let captured = try CompanionAcademicSource(source, request: request)
            if value["raw"] == nil {
                value["state"] = .string("running"); value["error"] = nil; try await save()
                onStatus("Generando con el modelo del móvil")
                var input = captured.completion; input["generationId"] = .string(id); input["model"] = modelJSON
                value["raw"] = captured.needsModel ? try await provider.complete(.object(input), session: session) : .string("{\"stance\":\"\"}")
                value["generatedAt"] = .string(Date().ISO8601Format()); try await save()
            }
            guard let raw = value["raw"]?.stringValue, let date = value["generatedAt"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let preview = try captured.preview(raw: raw, model: modelJSON, generatedAt: date)
            value["preview"] = preview; value["state"] = .string("saved"); value["error"] = nil; try await save()
            // Complete results are committed before attempting network delivery.
            guard let publication = try CompanionGenerationPublication(kind: "academic", entity: entity, checkpoint: .object(value)) else { throw DesktopBridgeError.malformedResponse }
            try await ledger.preparePublication(publication); session.didSaveCompanionResult()
            onStatus("Guardado en el móvil · pendiente de sincronizar")
            await session.synchronizeCompanionChanges()
            if let receipt = await ledger.all().first(where: { $0.id == id }) {
                if receipt.state == "available" { onStatus("Sincronizado con Nodus") }
                else if ["failed", "interrupted", "cancelled"].contains(receipt.state) { onStatus("Resultado conservado en el móvil · \(receipt.issue ?? "revisa la sincronización")") }
            }
            return preview
        } catch {
            if value["preview"] == nil { value["state"] = .string(error.isCancellation ? "cancelled" : "failed") }
            value["error"] = .string(error.localizedDescription); try await save(); throw error
        }
    }
}
