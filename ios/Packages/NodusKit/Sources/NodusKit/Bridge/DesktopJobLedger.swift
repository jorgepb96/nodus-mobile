import Foundation

/// Persist the user's intent before sending it. Lost acknowledgements are recovered
/// with the same idempotency key; reopening never silently creates a second job.
public actor DesktopJobLedger {
    public struct Request: Codable, Sendable, Identifiable {
        public let id: String
        public let method: String
        public let args: [JSONValue]
        public let createdAt: Date
        public var jobId: String?
        public var state: String
        public var issue: String?
    }
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var requests: [String: Request]
    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        requests = try data.map { try JSONDecoder.nodus.decode([String: Request].self, from: $0) } ?? [:]
    }
    public func all() -> [Request] { requests.values.sorted { $0.createdAt > $1.createdAt } }
    public func prepare(id: String, method: String, args: [JSONValue]) async throws -> Request {
        if let stored = requests[id] {
            guard stored.method == method, stored.args == args else { throw DesktopBridgeError.malformedResponse }
            try await persist()
            return stored
        }
        let request = Request(id: id, method: method, args: args, createdAt: Date(), jobId: nil, state: "pending", issue: nil)
        requests[id] = request
        try await persist()
        return request
    }
    public func update(id: String, job: DesktopBridgeJob) async throws {
        guard var request = requests[id] else { throw DesktopBridgeError.malformedResponse }
        if request.jobId == job.id, request.state == job.state.rawValue, request.issue == job.error { return }
        request.jobId = job.id; request.state = job.state.rawValue; request.issue = job.error; requests[id] = request
        try await persist()
    }
    public func disconnected(id: String, issue: String) async throws {
        guard var request = requests[id] else { return }
        request.issue = issue; requests[id] = request; try await persist()
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
