import Foundation
import CryptoKit

/// Persist the user's intent before sending it. Lost acknowledgements are recovered
/// with the same idempotency key; reopening never silently creates a second job.
public actor DesktopJobLedger {
    public struct Request: Codable, Sendable, Identifiable {
        public let id: String
        public let method: String
        public var args: [JSONValue]
        public var argsFingerprint: String? = nil
        public let createdAt: Date
        public var jobId: String?
        public var state: String
        public var issue: String?
        public var result: JSONValue?
        public var checkpointRecordId: String?
        public var checkpoint: JSONValue?
        public var cancellationRequested:Bool? = nil
        public var actionSequence: Int? = nil
        public var macCreatedAt: Date? = nil
        public var macUpdatedAt: Date? = nil
    }
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var requests: [String: Request]
    private var durablyPrepared: Set<String>
    private var isSynchronizing = false
    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        requests = try data.map { try JSONDecoder.nodus.decode([String: Request].self, from: $0) } ?? [:]
        durablyPrepared = Set(requests.keys)
    }
    public func all() -> [Request] { requests.values.sorted { $0.createdAt > $1.createdAt } }
    private func fingerprint(_ args: [JSONValue]) throws -> String {
        SHA256.hash(data:try JSONEncoder.nodus.encode(args)).map { String(format:"%02x",$0) }.joined()
    }
    private func sameArguments(_ request: Request,_ args: [JSONValue]) throws -> Bool {
        if let expected = request.argsFingerprint { return try fingerprint(args) == expected }
        return request.args == args
    }
    public func prepare(id: String, method: String, args: [JSONValue]) async throws -> Request {
        if let stored = requests[id] {
            guard stored.method == method, try sameArguments(stored,args) else { throw DesktopBridgeError.malformedResponse }
            try await persist()
            durablyPrepared.insert(id)
            return stored
        }
        let request = Request(id: id, method: method, args: args, createdAt: Date(), jobId: nil, state: "pending", issue: nil)
        requests[id] = request
        try await persist()
        durablyPrepared.insert(id)
        return request
    }
    public func preparePublication(_ publication: CompanionGenerationPublication) async throws {
        var request: Request
        if let stored = requests[publication.id] {
            guard stored.method == publication.method, try sameArguments(stored,publication.args),
                  stored.checkpointRecordId == nil || stored.checkpointRecordId == publication.recordId
            else { throw DesktopBridgeError.malformedResponse }
            request = stored
        } else {
            request = Request(id: publication.id, method: publication.method, args: publication.args,
                createdAt: Date(), jobId: nil, state: "pending", issue: nil)
        }
        if request.checkpoint == nil {
            request.checkpointRecordId = publication.recordId; request.checkpoint = publication.checkpoint
        }
        // Never reset an acknowledged/failed publication when the renderer
        // saves an older local checkpoint after losing its transport.
        request.checkpoint = reconciledCheckpoint(request)
        requests[request.id] = request
        try await persist()
        durablyPrepared.insert(request.id)
    }
    /// Preserve even an unparseable paid response before an explicit retry
    /// replaces the active checkpoint. This record is never a sendable Mac job.
    public func archiveAcademicCheckpoint(recordId: String, checkpoint: JSONValue) async throws {
        guard var value = checkpoint.objectValue, let id = value["id"]?.stringValue,
              UUID(uuidString: id) != nil, value["request"]?.objectValue?["source"]?.objectValue != nil,
              let raw = value["raw"]?.stringValue, !raw.isEmpty,
              try JSONEncoder.nodus.encode(checkpoint).count <= 20_000_000 else { return }
        if requests[id] != nil { return }
        value["kind"] = .string("academic")
        value["state"] = .string("failed")
        value["error"] = value["error"] ?? .string("Respuesta anterior conservada. La nueva generación usa otra solicitud.")
        requests[id] = Request(id: id, method: "localAcademicGeneration", args: [], createdAt: Date(),
            jobId: nil, state: "failed", issue: value["error"]?.stringValue,
            checkpointRecordId: recordId, checkpoint: .object(value))
        try await persist()
    }
    public func generationCheckpoint(recordId: String, generationId: String? = nil) -> JSONValue? {
        guard let request = all().first(where: { $0.checkpointRecordId == recordId && (generationId == nil || $0.id == generationId) }) else { return nil }
        return reconciledCheckpoint(request)
    }
    private func reconciledCheckpoint(_ request: Request) -> JSONValue? {
        guard var value = request.checkpoint?.objectValue else { return nil }
        switch request.state {
        case "available":
            value["state"] = .string("available"); value["error"] = nil
            value["publicationPending"] = nil
            if let result = request.result { value["result"] = result }
            if request.method == "saveMobileDatabaseResearchReport" { value["context"] = nil }
        case "failed", "interrupted", "cancelled":
            value["state"] = .string(request.state == "cancelled" ? "cancelled" : "failed")
            value["error"] = request.issue.map(JSONValue.string)
            value["publicationPending"] = nil
        default:
            value["state"] = .string("saved"); value["publicationPending"] = .bool(true)
        }
        return .object(value)
    }
    public func update(id: String, job: DesktopBridgeJob) async throws {
        guard var request = requests[id], job.vaultId == vaultId, job.method == request.method,
              request.jobId == nil || request.jobId == job.id else { throw DesktopBridgeError.malformedResponse }
        if request.method == "streamMobileCompanionChat",request.argsFingerprint != nil,
           ["available","failed","interrupted","cancelled"].contains(request.state) { return }
        // A poll and an in-flight submission acknowledgement can arrive out of
        // order. An older accepted/running snapshot cannot undo a terminal save.
        if request.state == "available", job.state != .available { return }
        if ["failed", "cancelled"].contains(request.state), [.accepted, .running, .saved].contains(job.state) { return }
        if request.jobId == job.id, request.state == job.state.rawValue, request.issue == job.error,
           request.actionSequence == job.actionSequence, request.macUpdatedAt == job.updatedAt,
           job.state != .available || request.result == job.result { return }
        request.jobId = job.id; request.state = job.state.rawValue; request.issue = job.error
        request.actionSequence = job.actionSequence; request.macCreatedAt = job.createdAt; request.macUpdatedAt = job.updatedAt
        if job.state == .available { request.result = job.result }
        if job.state == .available, request.method == "saveMobileDatabaseResearchReport", request.argsFingerprint == nil {
            // Keep the receipt identity and the user's finished report. The
            // signed raw rows are needed only until the Mac acknowledges them.
            request.argsFingerprint = try fingerprint(request.args);request.args = []
        }
        request.checkpoint = reconciledCheckpoint(request); requests[id] = request
        try await persist()
    }
    public func disconnected(id: String, issue: String) async throws {
        guard var request = requests[id] else { return }
        request.issue = issue; requests[id] = request; try await persist()
    }
    /// A definite pre-acceptance rejection is different from a lost reply.
    /// Keeping it pending would silently retry a forbidden or conflicting write.
    public func rejectUnsubmitted(id: String, issue: String) async throws {
        guard var request = requests[id], request.jobId == nil, request.state == "pending" else { return }
        request.state = "failed"; request.issue = issue; requests[id] = request; try await persist()
    }
    public func requestCancellation(id:String) async throws {
        guard var request=requests[id] else { throw DesktopBridgeError.malformedResponse }
        if ["available", "failed", "interrupted", "cancelled"].contains(request.state) { return }
        request.cancellationRequested=true;requests[id]=request;try await persist()
    }
    /// Only after the Mac confirms no request with this identity exists.
    public func cancelUnsubmitted(id:String) async throws {
        guard var request=requests[id],request.jobId == nil,request.cancellationRequested == true,request.state == "pending" else { throw DesktopBridgeError.malformedResponse }
        request.state="cancelled";request.issue=nil;requests[id]=request;try await persist()
    }
    public func releaseLivePayload(id:String) async throws {
        guard var request=requests[id],request.method == "streamMobileCompanionChat",["available","failed","interrupted","cancelled"].contains(request.state) else { throw DesktopBridgeError.malformedResponse }
        if request.argsFingerprint == nil { request.argsFingerprint=try fingerprint(request.args) }
        request.args=[];request.result=nil;requests[id]=request;try await persist()
    }
    /// A real successful Mac probe may recover previously authorised sends.
    /// Accepted jobs are only observed; failed/interrupted work is never restarted
    /// automatically. A lost acknowledgement reuses the original request identity.
    public func synchronize(
        list: @Sendable () async throws -> [DesktopBridgeJob],
        canSubmit: @Sendable (Request) async -> Bool = { _ in true },
        submit: @Sendable (Request) async throws -> DesktopBridgeJob
    ) async throws {
        guard !isSynchronizing, requests.values.contains(where: { ["pending", "accepted", "running", "saved"].contains($0.state) }) else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let remote = try await list()
        for request in all() {
            try Task.checkCancellation()
            if let jobId = request.jobId {
                if let job = remote.first(where: { $0.id == jobId }) { try await update(id: request.id, job: job) }
                // A known job absent from the server listing must not silently
                // become a new generation; retain its identity for explicit recovery.
                continue
            }
            guard durablyPrepared.contains(request.id), requests[request.id]?.state == "pending" else { continue }
            guard requests[request.id]?.cancellationRequested != true else { continue }
            guard await canSubmit(request) else { continue }
            do {
                let job = try await submit(request)
                try await update(id: request.id, job: job)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if let api = error as? APIError, [400,403,404,409,422].contains(api.status) {
                    try await rejectUnsubmitted(id: request.id, issue: error.localizedDescription)
                } else { try await disconnected(id: request.id, issue: error.localizedDescription) }
                throw error
            }
        }
    }
    private func persist() async throws {
        let data = try JSONEncoder.nodus.encode(requests)
        try await cache.store(data, vaultId: vaultId, domain: .researchGeneration, recordId: "job-ledger-v1")
    }
}

/// One ledger per grant and vault serializes concurrent views on the device.
public actor DesktopJobLedgers {
    public static let shared = DesktopJobLedgers()
    private var ledgers: [String: Task<DesktopJobLedger, any Error>] = [:]
    public func ledger(pairingId: String, vaultId: String) async throws -> DesktopJobLedger {
        let key = "\(pairingId)|\(vaultId)"
        if let task = ledgers[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            let data = try await cache.data(vaultId: vaultId, domain: .researchGeneration, recordId: "job-ledger-v1")
            return try DesktopJobLedger(cache: cache, vaultId: vaultId, data: data)
        }
        ledgers[key] = task
        do { return try await task.value } catch { ledgers[key] = nil; throw error }
    }
    public func forget(pairingId: String) {
        for key in ledgers.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { ledgers[key] = nil }
    }
}
