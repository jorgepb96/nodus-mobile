import Foundation

extension DesktopBridgeClient {
    private func actionLedger(vaultId: String, writing: Bool = false) async throws -> DesktopJobLedger {
        try validateCompanionScope(vaultId: vaultId, domains: writing ? [.corpus, .writing] : [.corpus])
        return try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vaultId)
    }
    private func action(_ request: DesktopJobLedger.Request, vaultId: String) throws -> SpaceAction {
        guard request.method == "runMobileSpaceAction", request.args.count == 1,
              let value = request.args[0].objectValue, let key = value["idempotencyKey"]?.stringValue,
              let kind = value["kind"]?.stringValue.flatMap(SpaceActionKind.init(rawValue:)),
              let payload = value["payload"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
        let status: RemoteWorkStatus
        switch request.state {
        case "available": status = .applied
        case "running", "saved": status = .running
        case "failed", "interrupted": status = .failed
        case "cancelled": status = .cancelled
        default: status = .queued
        }
        let updated = request.macUpdatedAt ?? request.createdAt
        return SpaceAction(id: request.jobId ?? request.id, sequence: request.actionSequence ?? 0, spaceId: vaultId,
            idempotencyKey: key, kind: kind, schemaVersion: 1, payload: payload, actorUserId: pairing.id,
            createdByDevice: pairing.id, inputRevision: value["inputRevision"]?.stringValue,
            inputFingerprint: value["inputFingerprint"]?.stringValue, status: status, claimedByDevice: nil,
            result: request.result, errorCode: request.issue, createdAt: request.macCreatedAt ?? request.createdAt,
            updatedAt: updated, claimedAt: nil, finishedAt: status.isTerminal ? updated : nil)
    }
    func createCompanionAction(vaultId: String, body: JSONValue, submitNow:Bool = true) async throws -> SpaceActionCreation {
        let ledger = try await actionLedger(vaultId: vaultId, writing: true)
        _ = try DesktopCompanionActions.validateWrite(path: "actions", query: [], body: body, domains: pairing.domains)
        guard var value = body.objectValue, let key = value["idempotencyKey"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        value["id"] = nil
        let id = DesktopCompanionActions.identity(key)
        let previous = await ledger.all().first { $0.id == id }
        let prepared = try await ledger.prepare(id: id, method: "runMobileSpaceAction", args: [.object(value)])
        if submitNow, ["pending", "accepted", "running", "saved"].contains(prepared.state), prepared.cancellationRequested != true {
            do {
                let job = try await submitJob(vaultId: vaultId, method: prepared.method, args: prepared.args, idempotencyKey: id)
                try await ledger.update(id: id, job: job)
            } catch {
                if let api = error as? APIError, [400, 403, 404, 409, 422].contains(api.status) {
                    try await ledger.rejectUnsubmitted(id: id, issue: error.localizedDescription)
                } else { try await ledger.disconnected(id: id, issue: error.localizedDescription) }
                guard DesktopCompanionActions.isOffline(error) else { throw error }
            }
        }
        let current = try await requiredRequest(ledger, id: id)
        return SpaceActionCreation(action: try action(current, vaultId: vaultId), duplicate: previous != nil)
    }
    private func requiredRequest(_ ledger: DesktopJobLedger, id: String) async throws -> DesktopJobLedger.Request {
        guard let request = await ledger.all().first(where: { $0.id == id }) else { throw DesktopBridgeError.malformedResponse }
        return request
    }
    func companionAction(vaultId: String, id: String) async throws -> SpaceAction {
        let ledger = try await actionLedger(vaultId: vaultId)
        if let request = await ledger.all().first(where: { $0.method == "runMobileSpaceAction" && ($0.id == id || $0.jobId == id) }) {
            if request.jobId != nil || request.state == "pending" {
                do {
                    let job: DesktopBridgeJob?
                    if let jobId = request.jobId { job = try await readJob(vaultId: vaultId, id: jobId) }
                    else {
                        guard let key = request.args.first?.objectValue?["idempotencyKey"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        job = try await jobForSpaceAction(vaultId: vaultId, idempotencyKey: key)
                    }
                    if let job { try await ledger.update(id: request.id, job: job) }
                }
                catch {
                    try await ledger.disconnected(id: request.id, issue: error.localizedDescription)
                    guard DesktopCompanionActions.isOffline(error) else { throw error }
                }
            }
            // Reading a locally queued operation never starts a Mac provider.
            return try action(await requiredRequest(ledger, id: request.id), vaultId: vaultId)
        }
        guard DesktopCompanionActions.isIdentity(id) else { throw DesktopBridgeError.malformedResponse }
        struct Envelope: Decodable { let action: SpaceAction }
        let response = try await corpus(vaultId: vaultId, path: "actions/\(id)")
        return try JSONDecoder.nodus.decode(Envelope.self, from: response.data).action
    }
    func companionActions(vaultId: String, since: Int, limit: Int) async throws -> SpaceActionPage {
        let ledger = try await actionLedger(vaultId: vaultId)
        let local = try await ledger.all().filter { $0.method == "runMobileSpaceAction" && $0.jobId == nil }.map { try action($0, vaultId: vaultId) }
        do {
            let response = try await corpus(vaultId: vaultId, path: "actions", query: [
                URLQueryItem(name: "since", value: String(max(0, since))),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 100)))])
            let page = try JSONDecoder.nodus.decode(SpaceActionPage.self, from: response.data)
            let keys = Set(page.actions.map(\.idempotencyKey))
            return SpaceActionPage(actions: page.actions + (since <= 0 ? local.filter { !keys.contains($0.idempotencyKey) } : []),
                cursor: page.cursor, hasMore: page.hasMore)
        } catch {
            guard since <= 0, !local.isEmpty, DesktopCompanionActions.isOffline(error) else { throw error }
            return SpaceActionPage(actions: local, cursor: 0, hasMore: false)
        }
    }
    func cancelCompanionAction(vaultId: String, id: String) async throws -> SpaceAction {
        let ledger = try await actionLedger(vaultId: vaultId, writing: true)
        if let request = await ledger.all().first(where: { $0.method == "runMobileSpaceAction" && ($0.id == id || $0.jobId == id) }) {
            do { try await cancelDurableJob(vaultId: vaultId, requestId: request.id) }
            catch { guard DesktopCompanionActions.isOffline(error) else { throw error } }
            return try action(await requiredRequest(ledger, id: request.id), vaultId: vaultId)
        }
        guard DesktopCompanionActions.isIdentity(id) else { throw DesktopBridgeError.malformedResponse }
        struct Envelope: Decodable { let action: SpaceAction }
        let response = try await corpus(vaultId: vaultId, path: "actions/\(id)/cancel", method: "POST", body: .object([:]))
        return try JSONDecoder.nodus.decode(Envelope.self, from: response.data).action
    }
}

public extension DesktopBridgeClient {
    func cancelDurableJob(vaultId: String, requestId: String, method: String? = nil, args: [JSONValue]? = nil) async throws {
        try validateCompanionScope(vaultId: vaultId, domains: [.writing])
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vaultId)
        if let method, let args {
            guard Self.jobMethods.contains(method) else { throw DesktopBridgeError.permissionDenied }
            _ = try await ledger.prepare(id: requestId, method: method, args: args)
        }
        try await ledger.requestCancellation(id: requestId)
        try await reconcileDurableCancellations(vaultId: vaultId, requestId: requestId)
    }
    /// Resolve a lost submission acknowledgement before honouring cancellation.
    /// A missing receipt requires a Mac-side cancellation receipt too: a POST
    /// may still be in flight. Offline intent remains durable on the phone.
    func reconcileDurableCancellations(vaultId: String, requestId: String? = nil) async throws {
        try validateCompanionScope(vaultId: vaultId, domains: [.writing])
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vaultId)
        for request in await ledger.all() where request.cancellationRequested == true
            && (requestId == nil || request.id == requestId)
            && ["pending", "accepted", "running", "saved"].contains(request.state) {
            do {
                var job: DesktopBridgeJob?
                if let id = request.jobId { job = try await readJob(vaultId: vaultId, id: id) }
                else if request.method == "runMobileSpaceAction" {
                    guard let key = request.args.first?.objectValue?["idempotencyKey"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                    job = try await jobForSpaceAction(vaultId: vaultId, idempotencyKey: key)
                } else { job = try await jobForRequest(vaultId: vaultId, requestId: request.id) }
                if let found = job {
                    guard found.method == request.method, found.vaultId == vaultId else { throw DesktopBridgeError.malformedResponse }
                    if [.accepted, .running, .saved].contains(found.state) { job = try await cancelJob(vaultId: vaultId, id: found.id) }
                    try await ledger.update(id: request.id, job: job!)
                } else {
                    let cancelled = try await cancelJobRequest(vaultId: vaultId, method: request.method, args: request.args, idempotencyKey: request.id)
                    try await ledger.update(id: request.id, job: cancelled)
                }
            } catch {
                try await ledger.disconnected(id: request.id, issue: error.localizedDescription)
                throw error
            }
        }
    }
}
