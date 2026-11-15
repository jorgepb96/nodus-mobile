import Foundation

/// Authored text is durable, scoped to its Mac/vault, and excluded from read-cache eviction.
public actor CompanionManuscriptDraftStore {
    public struct Draft: Codable, Sendable, Equatable {
        public let sceneId: String
        public var baseline: String
        public var text: String
        public var updatedAt: Date
        public init(sceneId: String, baseline: String, text: String, updatedAt: Date = Date()) {
            self.sceneId = sceneId; self.baseline = baseline; self.text = text; self.updatedAt = updatedAt
        }
        private enum CodingKeys: String, CodingKey { case sceneId, baseline, text, updatedAt, updatedAtTimestamp }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sceneId = try values.decode(String.self, forKey: .sceneId)
            baseline = try values.decode(String.self, forKey: .baseline)
            text = try values.decode(String.self, forKey: .text)
            if let timestamp = try values.decodeIfPresent(Double.self, forKey: .updatedAtTimestamp) {
                guard timestamp.isFinite else { throw DesktopBridgeError.malformedResponse }
                updatedAt = Date(timeIntervalSinceReferenceDate: timestamp)
            } else { updatedAt = try values.decode(Date.self, forKey: .updatedAt) }
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sceneId, forKey: .sceneId); try values.encode(baseline, forKey: .baseline); try values.encode(text, forKey: .text)
            try values.encode(updatedAt, forKey: .updatedAt)
            // Preserve local write order within the same wire-format millisecond.
            try values.encode(updatedAt.timeIntervalSinceReferenceDate, forKey: .updatedAtTimestamp)
        }
        public func conflicts(with remote: String) -> Bool { remote != baseline && remote != text }
    }
    static let storageKey = "companion-manuscript-drafts-v1"
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var drafts: [String: Draft]
    private var writing: Task<Void, any Error>?
    private var writeId: UUID?

    public init(cache: PrivateBridgeCache, vaultId: String, data: Data? = nil) throws {
        guard !vaultId.isEmpty else { throw DesktopBridgeError.malformedResponse }
        self.cache = cache; self.vaultId = vaultId
        drafts = try data.map { try JSONDecoder.nodus.decode([String: Draft].self, from: $0) } ?? [:]
        guard drafts.allSatisfy({ $0.key == $0.value.sceneId && !$0.key.isEmpty }) else { throw DesktopBridgeError.malformedResponse }
    }
    public func records() -> [String: Draft] { drafts }
    public func set(_ draft: Draft) async throws {
        guard !draft.sceneId.isEmpty, draft.baseline.utf8.count + draft.text.utf8.count <= CompanionDocumentOutbox.maximumRequestBytes else {
            throw APIError(status: 413, code: "manuscript_draft_too_large", message: "El borrador supera el tamaño admitido por el editor móvil.")
        }
        if let current = drafts[draft.sceneId], current.updatedAt > draft.updatedAt { return }
        drafts[draft.sceneId] = draft
        let data = try JSONEncoder.nodus.encode(drafts), previous = writing, cache = cache, vault = vaultId, id = UUID()
        // Actor reentrancy must not let an older disk write replace newer text.
        let task = Task<Void, any Error> {
            if let previous { _ = try? await previous.value }
            _ = try await cache.store(data, vaultId: vault, domain: .writing, recordId: Self.storageKey)
        }
        writing = task; writeId = id
        do { try await task.value }
        catch { if writeId == id { writing = nil; writeId = nil }; throw error }
        if writeId == id { writing = nil; writeId = nil }
    }
}

public actor CompanionManuscriptDraftStores {
    public static let shared = CompanionManuscriptDraftStores()
    private var stores: [String: Task<CompanionManuscriptDraftStore, any Error>] = [:]
    public func store(pairingId: String, vaultId: String) async throws -> CompanionManuscriptDraftStore {
        let key = "\(pairingId)|\(vaultId)"
        if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            return try await CompanionManuscriptDraftStore(cache: cache, vaultId: vaultId,
                data: cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionManuscriptDraftStore.storageKey))
        }
        stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
}
