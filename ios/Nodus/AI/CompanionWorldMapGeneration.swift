import Foundation
import NodusAI
import NodusKit
import UIKit

@MainActor enum CompanionWorldMapGeneration {
    private static var stores: [String: Task<CompanionWorldMapGenerationJournal, Error>] = [:]
    private static var active: [String: Task<DesktopJobLedger.Request, Error>] = [:]
    private static var activeMaps: [String: String] = [:]
    static func journal(session: SpaceSession) async throws -> CompanionWorldMapGenerationJournal {
        let (vault,pairing,_) = try privateBridgeConnection(session, domain: .writing)
        let key = pairing.id + ":" + vault
        if let store = stores[key] { return try await store.value }
        let store = Task { try await CompanionWorldMapGenerationJournal(cache: PrivateBridgeCache(pairingId: pairing.id), vault: vault) }
        stores[key] = store
        do { return try await store.value } catch { stores[key] = nil; throw error }
    }
    private static func ownerKey(session: SpaceSession) throws -> String {
        let (vault,pairing,_) = try privateBridgeConnection(session, domain: .writing)
        return pairing.id + ":" + vault
    }
    static func cancelDevice(session: SpaceSession, mapId: String) {
        guard let owner = try? ownerKey(session: session) else { return }
        if let scope = activeMaps[owner + ":" + mapId] {
            active[scope]?.cancel()
            Task {
                guard let journal = try? await journal(session: session) else { return }
                let prefix = owner + ":"
                let checkpointScope = String(scope.dropFirst(prefix.count))
                await journal.cancel(scope: checkpointScope)
                // If the provider just completed, also persist cancellation of
                // the complete publication identity before reconnect can send it.
                if let checkpoint = try? await journal.load(scope: checkpointScope), let input = checkpoint.publication,
                   let (vault,pairing,token) = try? privateBridgeConnection(session, domain: .writing),
                   let ledger = try? await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault) {
                    if await ledger.all().contains(where: { $0.id == checkpoint.id }) { try? await ledger.requestCancellation(id: checkpoint.id) }
                    _ = try? await DesktopBridgeClient(pairing: pairing, token: token).cancelJobRequest(vaultId: vault, method: "saveMobileWorldMapImage", args: [input], idempotencyKey: checkpoint.id)
                }
            }
        }
    }
    static func observeDevice(session: SpaceSession, mapId: String) async throws -> DesktopJobLedger.Request? {
        guard let scope = activeMaps[try ownerKey(session: session) + ":" + mapId], let task = active[scope] else { return nil }
        return try await task.value
    }
    static func isActive(session: SpaceSession, mapId: String) -> Bool {
        guard let owner = try? ownerKey(session: session) else { return false }; return activeMaps[owner + ":" + mapId] != nil
    }

    static func download(session: SpaceSession, mapId: String, days: Int) async throws {
        guard [7,30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
        let (vault,pairing,token) = try privateBridgeConnection(session, domain: .corpus)
        let client = DesktopBridgeClient(pairing: pairing, token: token), cache = try PrivateBridgeCache(pairingId: pairing.id)
        let args: [JSONValue] = [.string(mapId)]
        let value = try await client.operation(vaultId: vault, method: "getMobileWorldMapGenerationSource", args: args)
        let source = try CompanionWorldMapGenerationSource(value, mapId: mapId)
        let key = try CompanionDocumentOutbox.operationKey("getMobileWorldMapGenerationSource", args)
        var records = [PrivateBridgeCache.ReadPackRecord(domain: .corpus, recordId: key, data: try JSONEncoder.nodus.encode(value))]
        if let imageSource = source.imageSource {
            let descriptor = try await client.fileDescriptor(vaultId: vault, kind: .corpusImage, id: imageSource)
            let bytes = try await client.fileData(vaultId: vault, descriptor: descriptor)
            let image = try CompanionCorpusImage(descriptor: descriptor, data: bytes)
            try image.validate(source: imageSource, domains: Array(pairing.domains))
            records.append(.init(domain: .corpus, recordId: CompanionCorpusImage.recordId(source: imageSource), data: try JSONEncoder.nodus.encode(image)))
        }
        guard try await client.operation(vaultId: vault, method: "getMobileWorldMapGenerationSource", args: args) == value else {
            throw APIError(status: 409, code: "map_download_changed", message: "El mapa cambió durante la descarga. Reintenta para conservar una copia consistente.")
        }
        let selection = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: records.map(\.recordId))
        try Task.checkCancellation()
        try await cache.saveReadPack(id: selection, vaultId: vault, title: source.value.objectValue?["name"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Fuentes del mapa: " + String($0.prefix(200)) } ?? "Fuentes del mapa", expiresAt: Date().addingTimeInterval(Double(days)*86400), records: records)
        session.didChangeCompanionDownloads()
    }
    static func source(session: SpaceSession, mapId: String) async throws -> CompanionWorldMapGenerationSource {
        let (vault,pairing,token) = try privateBridgeConnection(session, domain: .corpus)
        let key = try CompanionDocumentOutbox.operationKey("getMobileWorldMapGenerationSource", [.string(mapId)])
        let copies = try await PrivateBridgeCache(pairingId: pairing.id).downloadedData(vaultId: vault, domain: .corpus, recordId: key)
        // A selected downloaded copy is sufficient by itself: autonomous does not
        // consult the Mac to complete its prompt or describe its reference image.
        if let bytes = copies.first { return try CompanionWorldMapGenerationSource(JSONDecoder.nodus.decode(JSONValue.self, from: bytes), mapId: mapId) }
        do {
            let value = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileWorldMapGenerationSource", args: [.string(mapId)], timeout: 4)
            return try CompanionWorldMapGenerationSource(value, mapId: mapId)
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            throw APIError(status: 409, code: "map_sources_not_downloaded", message: "Descarga las fuentes y la imagen del mapa para llevar mientras tu Mac esté conectado.")
        }
    }
    static func preparePublication(session: SpaceSession, checkpoint: CompanionWorldMapGenerationCheckpoint) async throws -> DesktopJobLedger.Request {
        guard checkpoint.value.objectValue?["recoveryReviewRequired"] != .bool(true) else {
            throw APIError(status: 409, code: "recovery_review_required", message: "Revisa este resultado recuperado en Ajustes antes de publicarlo con la nueva vinculación.")
        }
        guard checkpoint.state != .cancelled, let input = checkpoint.publication else { throw DesktopBridgeError.malformedResponse }
        let (vault,pairing,_) = try privateBridgeConnection(session, domain: .writing)
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        guard await ledger.all().first(where: { $0.id == checkpoint.id })?.state != "recoveryReview" else {
            throw APIError(status: 409, code: "recovery_review_required", message: "Revisa este resultado recuperado en Ajustes antes de publicarlo con la nueva vinculación.")
        }
        return try await ledger.prepare(id: checkpoint.id, method: "saveMobileWorldMapImage", args: [input])
    }
    static func generate(session: SpaceSession, request: JSONValue, ai: AISettings) async throws -> DesktopJobLedger.Request {
        try BetaAIFeatures.requireAutonomousGeneration()
        guard session.aiExecutionMode == .autonomous, let mapId = request.objectValue?["mapId"]?.stringValue else { throw DesktopBridgeError.permissionDenied }
        guard let model = ai.model(for: .image) else { throw APIError(status: 409, code: "mobile_image_model_missing", message: "Selecciona un modelo de imagen en los ajustes de este dispositivo.") }
        let (vault,pairing,_) = try privateBridgeConnection(session, domain: .writing)
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let source = try await source(session: session, mapId: mapId)
        let modelValue = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(model))
        let scope = try CompanionWorldMapGenerationCheckpoint.scope(request: request, revision: source.revision, model: modelValue)
        let owner = pairing.id + ":" + vault
        let activeKey = owner + ":" + scope, mapKey = owner + ":" + mapId
        if let task = active[activeKey] { return try await task.value }
        let journal = try await journal(session: session)
        let previous = try await journal.load(scope: scope)
        if let previous, previous.publication != nil, previous.state != .cancelled {
            let existing = await ledger.all().first { $0.id == previous.id }
            // Bytes without an acknowledged publication are recovered first. A
            // deliberate new generation follows only a completed publication.
            if existing?.state != "available" { return try await preparePublication(session: session, checkpoint: previous) }
        }
        let prompt = try source.prompt(request: request), mode = request.objectValue?["mode"]?.stringValue
        if ["expand","restyle"].contains(mode ?? "") {
            guard model.provider == .gemini, !model.model.lowercased().contains("imagen") else { throw APIError(status: 409, code: "mobile_map_reference_required", message: "Para ampliar o cambiar el estilo, selecciona un modelo Gemini de imagen con referencia. Los proveedores móviles de sólo texto siguen disponibles para generar imágenes y variantes.") }
        }
        // Recheck after journal I/O, then register before the task can purchase
        // provider work. Closing an observer never cancels this owned task.
        if let task = active[activeKey] { return try await task.value }
        guard activeMaps[mapKey] == nil else { throw APIError(status: 409, code: "device_map_busy", message: "Este dispositivo ya está generando una imagen de este mapa.") }
        let id = UUID().uuidString.lowercased()
        let accepted = try CompanionWorldMapGenerationCheckpoint(.object(["version":.int(1),"id":.string(id),"request":request,"revision":.string(source.revision),"model":modelValue,"state":.string("accepted"),"createdAt":.string(ISO8601DateFormatter().string(from: Date())),"title":source.value.objectValue?["name"] ?? .string("Mapa")]))
        let service = ImageService(keyProvider: ai.keyProvider)
        let activityCache = try PrivateBridgeCache(pairingId: pairing.id)
        let task = Task { @MainActor in
            try activityCache.beginAuthoringActivity()
            defer { activityCache.endAuthoringActivity() }
            var checkpoint = accepted
            do {
                checkpoint = try await journal.perform(accepted: accepted) { @MainActor in
                    let image: GeneratedImage
                    if ["expand","restyle"].contains(mode ?? "") {
                        guard let imageSource = source.imageSource else { throw APIError(status: 409, code: "map_image_missing", message: "Este mapa necesita una imagen antes de ampliarse o cambiar su estilo.") }
                        let original = try await ReaderImageSource.load(imageSource, session: session, downloadedOnly: true)
                        let reference = mode == "expand" ? try expanded(original, request: request) : GeneratedImage(data: original.data, mimeType: original.mime)
                        try Task.checkCancellation()
                        image = try await service.generate(prompt: prompt, reference: reference, with: model)
                    } else { try Task.checkCancellation(); image = try await service.generate(prompt: prompt, with: model) }
                    return (image.data,image.mimeType)
                }
                try Task.checkCancellation()
                let current = try privateBridgeConnection(session, domain: .writing)
                guard current.0 == vault, current.1.id == pairing.id else { throw APIError(status: 409, code: "map_generation_scope_changed", message: "La conexión cambió durante la generación. La imagen se conserva en la conexión original.") }
                let prepared = try await preparePublication(session: session, checkpoint: checkpoint)
                if Task.isCancelled { try await ledger.requestCancellation(id: prepared.id); throw CancellationError() }
                return prepared
            } catch {
                checkpoint = try await journal.load(scope: accepted.scope) ?? checkpoint
                checkpoint = try checkpoint.changing(state: error.isCancellation ? .cancelled : .failed, error: error.localizedDescription)
                try await journal.put(checkpoint)
                throw error
            }
        }
        active[activeKey] = task; activeMaps[mapKey] = activeKey
        defer { active[activeKey] = nil; if activeMaps[mapKey] == activeKey { activeMaps[mapKey] = nil } }
        return try await task.value
    }
    private static func expanded(_ content: ReaderImageSource.Content, request: JSONValue) throws -> GeneratedImage {
        guard let source = UIImage(data: content.data)?.cgImage, let value = request.objectValue,
              let edge = value["edge"]?.stringValue, let fraction = value["fraction"]?.doubleValue,
              fraction.isFinite, fraction > 0, fraction <= 2 else { throw DesktopBridgeError.malformedResponse }
        let width = Double(source.width), height = Double(source.height)
        let grownWidth = ["east","west"].contains(edge) ? (width*(1+fraction)).rounded() : width
        let grownHeight = ["north","south"].contains(edge) ? (height*(1+fraction)).rounded() : height
        guard grownWidth*grownHeight <= 40_000_000 else { throw APIError(status: 413, code: "map_canvas_too_large", message: "Esta ampliación excede el tamaño de imagen que puede preparar el dispositivo.") }
        let size = CGSize(width: grownWidth, height: grownHeight), format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 242/255, green: 236/255, blue: 225/255, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            let x = edge == "west" ? (fraction/(1+fraction)*grownWidth).rounded() : 0
            let y = edge == "north" ? (fraction/(1+fraction)*grownHeight).rounded() : 0
            UIImage(cgImage: source).draw(in: CGRect(x: x, y: y, width: width, height: height))
        }
        return GeneratedImage(data: image, mimeType: "image/png")
    }
}
