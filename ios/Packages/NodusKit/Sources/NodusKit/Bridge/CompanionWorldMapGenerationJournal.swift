import CryptoKit
import Foundation

/// Device provider work has its own journal. Only complete saved images can
/// become a Mac publication request; accepted/running intents are never sent.
public struct CompanionWorldMapGenerationCheckpoint: Sendable, Identifiable {
    public enum State: String, Sendable { case accepted, running, saved, failed, cancelled, interrupted }
    public let value: JSONValue
    public let id: String
    public let mapId: String
    public let scope: String
    public let state: State
    public let publication: JSONValue?
    /// Complete received bytes can be reviewed after a failed subsequent step.
    /// Cancelled or unfinished intents never become recovery publication jobs.
    public var publicationInput: JSONValue? { [.saved,.failed,.interrupted].contains(state) ? publication : nil }
    public init(_ value: JSONValue) throws {
        guard let object = value.objectValue, object["version"] == .int(1),
              let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
              let request = object["request"], let mapId = request.objectValue?["mapId"]?.stringValue, !mapId.isEmpty,
              let revision = object["revision"]?.stringValue, revision.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let model = object["model"], model.objectValue?["provider"]?.stringValue != nil, model.objectValue?["model"]?.stringValue != nil,
              let createdAt = object["createdAt"]?.stringValue, ISO8601DateFormatter().date(from: createdAt) != nil,
              let stateString = object["state"]?.stringValue, let state = State(rawValue: stateString),
              try JSONEncoder.nodus.encode(value).count <= 28_128_000 else { throw DesktopBridgeError.malformedResponse }
        self.scope = try Self.scope(request: request, revision: revision, model: model)
        var publication: JSONValue?
        if let bytes = object["bytes"]?.stringValue {
            guard ["image/png","image/jpeg","image/webp"].contains(object["mime"]?.stringValue ?? ""),
                  let data = Data(base64Encoded: bytes), !data.isEmpty, data.count <= 20_000_000,
                  data.base64EncodedString() == bytes else { throw DesktopBridgeError.malformedResponse }
            publication = .object(["request":request,"requestId":.string(id),"revision":.string(revision),"model":model,"mime":object["mime"]!,"bytes":.string(bytes)])
        }
        guard state != .saved || publication != nil else { throw DesktopBridgeError.malformedResponse }
        self.value = value; self.id = id; self.mapId = mapId; self.state = state; self.publication = publication
    }
    public static func scope(request: JSONValue, revision: String, model: JSONValue) throws -> String {
        "companion:world-map-generation:v1:" + SHA256.hash(data: try JSONEncoder.nodus.encode(JSONValue.array([request,.string(revision),model]))).map { String(format: "%02x", $0) }.joined()
    }
    public func changing(state: State, error: String? = nil, bytes: Data? = nil, mime: String? = nil) throws -> Self {
        var object = value.objectValue!
        object["state"] = .string(state.rawValue); object["error"] = error.map(JSONValue.string)
        if let bytes { object["bytes"] = .string(bytes.base64EncodedString()); object["mime"] = mime.map(JSONValue.string) }
        return try Self(.object(object))
    }
}
public actor CompanionWorldMapGenerationJournal {
    private let cache: PrivateBridgeCache
    private let vault: String
    private var index: [String: JSONValue]
    private var active: [String: Task<CompanionWorldMapGenerationCheckpoint, Error>] = [:]
    private static let indexKey = "companion:world-map-generation-index:v1"
    public init(cache: PrivateBridgeCache, vault: String) async throws {
        self.cache = cache; self.vault = vault
        if let data = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: Self.indexKey) {
            guard let index = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue else { throw DesktopBridgeError.malformedResponse }
            self.index = index
        } else { index = [:] }
    }
    /// This journal owns the provider task, rather than a sheet's observation.
    /// Two observers of an exact intent share one paid call; cancelling an
    /// observer does not cancel generation. Only cancel(scope:) does so.
    public func perform(accepted: CompanionWorldMapGenerationCheckpoint,
                        generate: @escaping @Sendable () async throws -> (data: Data, mime: String)) async throws -> CompanionWorldMapGenerationCheckpoint {
        if let task = active[accepted.scope] { return try await task.value }
        guard accepted.state == .accepted, accepted.publication == nil else { throw DesktopBridgeError.malformedResponse }
        let task = Task {
            var checkpoint = accepted
            do {
                try await self.put(checkpoint)
                checkpoint = try checkpoint.changing(state: .running); try await self.put(checkpoint)
                try Task.checkCancellation()
                let result = try await generate()
                checkpoint = try checkpoint.changing(state: .saved, bytes: result.data, mime: result.mime)
                // Even a provider that ignores cancellation has its received
                // bytes preserved before the cancellation receipt is written.
                try await self.put(checkpoint)
                try Task.checkCancellation()
                return checkpoint
            } catch {
                checkpoint = try checkpoint.changing(state: error.isCancellation ? .cancelled : .failed, error: error.localizedDescription)
                try await self.put(checkpoint)
                throw error
            }
        }
        active[accepted.scope] = task
        defer { active[accepted.scope] = nil }
        return try await task.value
    }
    public func observer(scope: String) -> Task<CompanionWorldMapGenerationCheckpoint, Error>? {
        guard let owned = active[scope] else { return nil }
        return Task { try await owned.value }
    }
    public func cancel(scope: String) { active[scope]?.cancel() }
    public func load(scope: String) async throws -> CompanionWorldMapGenerationCheckpoint? {
        guard let data = try await cache.data(vaultId: vault, domain: .researchGeneration, recordId: scope) else { return nil }
        let checkpoint = try CompanionWorldMapGenerationCheckpoint(JSONDecoder.nodus.decode(JSONValue.self, from: data))
        guard checkpoint.scope == scope else { throw DesktopBridgeError.malformedResponse }
        return checkpoint
    }
    public func put(_ checkpoint: CompanionWorldMapGenerationCheckpoint) async throws {
        try await cache.store(JSONEncoder.nodus.encode(checkpoint.value), vaultId: vault, domain: .researchGeneration, recordId: checkpoint.scope)
        var summary = checkpoint.value.objectValue!; summary["bytes"] = nil
        summary["scope"] = .string(checkpoint.scope)
        index[checkpoint.scope] = .object(summary)
        try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(index)), vaultId: vault, domain: .researchGeneration, recordId: Self.indexKey)
    }
    /// Lightweight rows retain every request's state; large image bytes are
    /// read individually only when the user opens a result.
    public func summaries() -> [JSONValue] {
        index.values.sorted { ($0.objectValue?["createdAt"]?.stringValue ?? "") > ($1.objectValue?["createdAt"]?.stringValue ?? "") }
    }
}
