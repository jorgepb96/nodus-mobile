import Foundation
import NodusKit

/// Shared by explicit native synthesis controls. The durable typed action owns
/// execution; closing or retrying its UI never invents another pending intent.
@MainActor
enum CompanionLiveGenerationAction {
    private static var stores: [String: GenerationActionIntentStore] = [:]
    private static var active: [String: Task<SpaceAction, Error>] = [:]

    static func run(session: SpaceSession, kind: SpaceActionKind, payload initialPayload: [String: JSONValue],
                    onStatus: @escaping (String) -> Void) async throws -> SpaceAction {
        guard session.aiExecutionMode == .live else { throw DesktopBridgeError.permissionDenied }
        var payload = initialPayload
        var ledger: DesktopJobLedger?
        if session.connection.desktopPairingId != nil {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .researchGeneration)
            let modelKey = kind == .argumentMapGenerate ? "argumentMapModel" : "synthesisModel"
            let settings = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getSettings", args: [])
            guard let model = settings.objectValue?[modelKey], model.objectValue != nil else {
                throw APIError(status: 409, code: "mac_generation_model_missing", message: "Selecciona el modelo de esta generación en Nodus para Mac.")
            }
            if kind == .argumentMapGenerate, var request = payload["request"]?.objectValue {
                request["model"] = model; payload["request"] = .object(request)
            } else { payload["model"] = model }
            ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
        }
        let revision = session.publishedRevision
        let scope = try GenerationActionIntentStore.scope(kind: kind, payload: payload, revision: revision, mode: "live")
        let activeKey = session.connection.storageId + ":" + scope
        if let task = active[activeKey] { return try await task.value }
        let requestPayload = payload, generationLedger = ledger
        let store: GenerationActionIntentStore
        if let existing = stores[session.connection.storageId] { store = existing }
        else {
            store = try GenerationActionIntentStore(directory: ConnectionClient.spacesDirectory
                .appendingPathComponent(session.connection.storageId, isDirectory: true))
            stores[session.connection.storageId] = store
        }
        let task = Task { @MainActor in
            let records = await generationLedger?.all() ?? []
            let pending = records.first { record in
                guard record.method == "runMobileSpaceAction", ["pending", "accepted", "running", "saved"].contains(record.state),
                      record.cancellationRequested != true, let args = record.args.first?.objectValue else { return false }
                return args["kind"] == .string(kind.rawValue) && args["payload"] == .object(requestPayload)
                    && (args["inputRevision"] ?? .null) == (revision.map(JSONValue.string) ?? .null)
                    && args["executionMode"] == .string("live")
            }
            let key = try await store.prepare(scope: scope, preferredKey: pending?.args.first?.objectValue?["idempotencyKey"]?.stringValue)
            let knownId = session.connection.desktopPairingId == nil ? key : DesktopBridgeClient.companionActionIdentity(idempotencyKey: key)
            do {
                var action = try await session.client.createSpaceAction(id: UUID(uuidString: key) == nil ? UUID().uuidString : key,
                    idempotencyKey: key, kind: kind, payload: requestPayload, inputRevision: revision,
                    executionMode: "live", in: session.connection.spaceId).action
                onStatus(action.receiptMessage)
                // A request durably queued while the Mac is disconnected is already
                // visible in Jobs. Return its receipt rather than poll a sleeping Mac.
                while !action.status.isTerminal && action.sequence > 0 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(700))
                    action = try await session.client.spaceAction(id: action.id, in: session.connection.spaceId)
                    onStatus(action.receiptMessage)
                }
                try await store.acknowledge(scope: scope, key: key, terminal: action.status.isTerminal)
                if [.failed, .refused, .cancelled].contains(action.status) {
                    throw APIError(status: 409, code: action.errorCode ?? action.status.rawValue, message: action.receiptMessage)
                }
                return action
            } catch {
                if error.isCancellation {
                    let cancelled = try? await session.client.cancelSpaceAction(id: knownId, in: session.connection.spaceId)
                    if let cancelled {
                        try await store.acknowledge(scope: scope, key: key, terminal: cancelled.status.isTerminal)
                        onStatus(cancelled.receiptMessage)
                    }
                }
                throw error
            }
        }
        active[activeKey] = task
        defer { active[activeKey] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
