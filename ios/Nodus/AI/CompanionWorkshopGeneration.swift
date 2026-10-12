import CryptoKit
import Foundation
import NodusAI
import NodusKit

/// The workshop can choose categories with no ordinary collection screen,
/// including contradictions and tutor routes. Keep exactly that selection.
@MainActor
func saveWorkshopSourceSelection(_ session: SpaceSession, selection: JSONValue, days: Int) async throws {
    guard [7, 30].contains(days) else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
    let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
    guard !pairing.isExpired else { throw DesktopBridgeError.expired }
    let value = try await DesktopBridgeClient(pairing: pairing, token: token)
        .operation(vaultId: vault, method: "getWritingWorkshopMobileSource", args: [selection])
    let source = try CompanionWorkshopSource(copies: [value]).selected(selection)
    let bytes = try JSONEncoder.nodus.encode(source.value)
    let identity = SHA256.hash(data: try JSONEncoder.nodus.encode(selection)).map { String(format: "%02x", $0) }.joined()
    let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: ["\(CompanionWorkshopSource.recordId):\(identity)"])
    let count = CompanionWorkshopSource.groups.keys.reduce(0) { $0 + (selection.objectValue?[$1]?.arrayValue?.count ?? 0) }
    try Task.checkCancellation()
    try await PrivateBridgeCache(pairingId: pairing.id).saveReadPack(id: id, vaultId: vault,
        title: "Fuentes del taller · \(count)", expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: [
            .init(domain: .corpus, recordId: CompanionWorkshopSource.recordId, data: bytes),
        ])
    session.didChangeCompanionDownloads()
}

/// Prepares downloads in bounded batches, retaining only selected sources.
@MainActor
func workshopDownloadRecord(client: DesktopBridgeClient, vault: String, path: String, ids: [String]) async throws -> PrivateBridgeCache.ReadPackRecord? {
    guard CompanionWorkshopSource.collectionKeys[path] != nil else { return nil }
    let selected = Array(Set(ids)).sorted()
    var copies: [JSONValue] = []
    for offset in stride(from: 0, to: selected.count, by: 100) {
        try Task.checkCancellation()
        let selection = try CompanionWorkshopSource.selection(path: path, ids: Array(selected[offset..<min(offset + 100, selected.count)]))
        copies.append(try await client.operation(vaultId: vault, method: "getWritingWorkshopMobileSource", args: [selection]))
    }
    let source = try CompanionWorkshopSource(copies: copies)
    guard let key = CompanionWorkshopSource.collectionKeys[path], source.rows(for: key).count == selected.count else { throw DesktopBridgeError.malformedResponse }
    return .init(domain: .corpus, recordId: CompanionWorkshopSource.recordId, data: try JSONEncoder.nodus.encode(source.value))
}

/// A complete device response and its provider-free publication are persisted
/// before the view reports success. A resumed request reuses paid work.
@MainActor
final class CompanionWorkshopGeneration {
    private static var active: [String: Task<DesktopJobLedger.Request, Error>] = [:]
    private let provider: AutonomousSurfaceProvider
    init(settings: AISettings) { provider = AutonomousSurfaceProvider(settings: settings) }

    func run(session: SpaceSession, request: JSONValue, onStatus: @escaping (String) -> Void) async throws -> DesktopJobLedger.Request {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .writing)
        let identity = SHA256.hash(data: try JSONEncoder.nodus.encode(request)).map { String(format: "%02x", $0) }.joined()
        let key = "\(pairing.id):\(vault):\(identity)"
        if let task = Self.active[key] { return try await task.value }
        let task = Task { try await self.execute(session: session, request: request, onStatus: onStatus) }
        Self.active[key] = task
        defer { Self.active[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func execute(session: SpaceSession, request: JSONValue, onStatus: (String) -> Void) async throws -> DesktopJobLedger.Request {
        guard session.aiExecutionMode == .autonomous,
              let selection = request.objectValue?["selection"], let model = request.objectValue?["model"]
        else { throw DesktopBridgeError.permissionDenied }
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        let entity = SHA256.hash(data: try JSONEncoder.nodus.encode(request)).map { String(format: "%02x", $0) }.joined()
        let key = try CompanionGenerationPublication.recordId(kind: "workshop", entity: entity)
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        let prior = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: key)
        var checkpoint = try prior.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0).objectValue } ?? nil
        if checkpoint == nil {
            checkpoint = await ledger.generationCheckpoint(recordId: key)?.objectValue
        }
        let receipt = await ledger.all().first { $0.id == checkpoint?["id"]?.stringValue }
        if !CompanionGenerationRecovery.resumeAcademic(checkpoint: checkpoint.map(JSONValue.object), work: request, receiptState: receipt?.state) {
            if let checkpoint { try await ledger.archiveWorkshopCheckpoint(recordId: key, checkpoint: .object(checkpoint)) }
            checkpoint = ["id": .string(UUID().uuidString.lowercased()), "entityKey": .string(entity),
                "request": request, "state": .string("accepted")]
        }
        guard var value = checkpoint, value["request"] == request, let identity = value["id"]?.stringValue,
              UUID(uuidString: identity) != nil else { throw DesktopBridgeError.malformedResponse }
        if let existing = await ledger.all().first(where: { $0.id == identity }) { return existing }
        func save() async throws {
            try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(value)), vaultId: vault, domain: .researchGeneration, recordId: key)
        }
        do {
            try await save()
            if value["context"] == nil {
                onStatus("Preparando las fuentes elegidas")
                let source: CompanionWorkshopSource
                do {
                    let remote = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault,
                        method: "getWritingWorkshopMobileSource", args: [selection], timeout: 4)
                    source = try CompanionWorkshopSource(copies: [remote]).selected(selection)
                    value["sourceScope"] = .string("linked_corpus")
                } catch {
                    guard isPrivateBridgeOffline(error) else { throw error }
                    let (currentVault, currentPairing, _) = try privateBridgeConnection(session, domain: .corpus)
                    guard currentVault == vault, currentPairing.id == pairing.id, currentPairing.domains.contains(.writing) else {
                        throw DesktopBridgeError.permissionDenied
                    }
                    guard let downloaded = try await CompanionWorkshopSource.downloaded(cache: cache, vaultId: vault)
                    else { throw CompanionWorkshopSource.SourceError.notDownloaded }
                    source = try downloaded.selected(selection)
                    value["sourceScope"] = .string("device_downloads")
                }
                value["context"] = .object(["source": source.value, "revision": .string(source.configurationRevision)])
                try await save()
            }
            guard let context = value["context"]?.objectValue, let sourceJSON = context["source"],
                  let scope = value["sourceScope"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let source = try CompanionWorkshopSource(copies: [sourceJSON]).selected(selection)
            if value["raw"] == nil {
                try Task.checkCancellation()
                var completion = try source.prompt(request: request).objectValue!
                completion["generationId"] = .string(identity); completion["model"] = model
                value["state"] = .string("running"); value["error"] = nil; try await save()
                onStatus("Generando con el modelo del móvil")
                let result = try await provider.complete(.object(completion), session: session)
                guard let raw = result.stringValue else { throw DesktopBridgeError.malformedResponse }
                value["raw"] = .string(raw); try await save()
            }
            guard let raw = value["raw"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            value["preview"] = try source.preview(raw: raw, request: request, scope: scope, generatedAt: Date().ISO8601Format())
            value["state"] = .string("saved"); value["error"] = nil
            try await save()
            try Task.checkCancellation()
            guard let publication = try CompanionGenerationPublication(kind: "workshop", entity: entity, checkpoint: .object(value))
            else { throw DesktopBridgeError.malformedResponse }
            try await ledger.preparePublication(publication)
            session.didSaveCompanionResult()
            onStatus("Borrador guardado en el móvil · pendiente de sincronizar")
            // The session uses the provider-free lane in either execution mode.
            // A disconnected Mac leaves the already complete result pending.
            await session.synchronizeCompanionChanges()
            guard let result = await ledger.all().first(where: { $0.id == identity }) else { throw DesktopBridgeError.malformedResponse }
            return result
        } catch {
            // Once a complete result exists, cancellation never destroys it.
            if value["preview"] == nil { value["state"] = .string(error is CancellationError ? "cancelled" : "failed") }
            value["error"] = .string(error.localizedDescription)
            try await save()
            throw error
        }
    }
}
