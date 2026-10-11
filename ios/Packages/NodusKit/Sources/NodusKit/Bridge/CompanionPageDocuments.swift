import Foundation
import CryptoKit

/// Complete universal page edits remain authored records, separate from
/// expiring downloads. An immutable sending request survives a lost reply.
public actor CompanionPageDocuments {
    public static let maximumRequestBytes = 32 * 1024 * 1024
    public struct Request: Codable, Sendable {
        public let id: String
        public let input: JSONValue
        let generation: Int
    }
    private struct Record: Codable {
        var baseline: JSONValue
        var input: JSONValue
        var generation: Int
        var sending: Request?
        var state: String
        var remote: JSONValue?
        var issue: String?
    }
    static let storageKey = "companion-page-documents-v1"
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var records: [String: Record]
    private var baselines: [String: JSONValue] = [:]
    private var acknowledged: [String: Int] = [:]
    private var synchronizing = false
    public private(set) var revision = 0

    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        records = try data.map { try JSONDecoder.nodus.decode([String: Record].self, from: $0) } ?? [:]
    }
    public static func document(_ source: JSONValue, vaultId: String, pageId: String) throws -> JSONValue {
        guard source.objectValue?["version"] == .int(1), source.objectValue?["vaultId"] == .string(vaultId),
              let document = source.objectValue?["document"] else { throw DesktopBridgeError.malformedResponse }
        try validate(document, id: pageId, local: false); return document
    }
    private static func validate(_ document: JSONValue, id: String, local: Bool) throws {
        guard let value = document.objectValue, value["page"]?.objectValue?["id"] == .string(id),
              let revision = value["revision"]?.intValue, (local ? revision != 0 : revision > 0),
              value["markdown"]?.stringValue != nil, let blocks = value["blocks"]?.arrayValue,
              blocks.allSatisfy({ $0.objectValue?["id"]?.stringValue?.isEmpty == false && $0.objectValue?["content"]?.objectValue != nil }) else { throw DesktopBridgeError.malformedResponse }
        let ids = blocks.compactMap { $0.objectValue?["id"]?.stringValue }
        guard ids.count == Set(ids).count else { throw DesktopBridgeError.malformedResponse }
    }
    public func seed(pageId: String, document: JSONValue) throws {
        try Self.validate(document, id: pageId, local: false)
        if let before = baselines[pageId]?.objectValue?["revision"]?.intValue,
           let next = document.objectValue?["revision"]?.intValue {
            if next < before { return }
            if next != before { acknowledged[pageId] = nil }
        }
        baselines[pageId] = document
    }
    public func hasDraft(pageId:String)->Bool { records[pageId] != nil }
    /// Called only for the new standalone page just authored through the typed
    /// mutation outbox. Revision one is its empty creation baseline; it never
    /// substitutes an existing Mac page. A later Mac edit still causes a conflict.
    public func createLocal(page: Row) async throws -> JSONValue {
        guard let id = page.string("id"), !id.isEmpty, id.utf8.count <= 1024,
              page.string("origin") == "standalone", page.string("state") == "active", page.int("revision") == 1,
              page.string("row_id") == nil, page.string("note_id") == nil,
              page.bool("locked") != true, let title = page.string("title"), title.utf8.count <= 4096,
              page.string("created_at") != nil, page.string("updated_at") != nil else { throw DesktopBridgeError.malformedResponse }
        if let document = document(pageId: id) { return document }
        guard baselines[id] == nil else { throw DesktopBridgeError.malformedResponse }
        var metadata: [String: JSONValue] = ["id": .string(id), "origin": .string("standalone"), "title": .string(title),
            "state": .string("active"), "revision": .int(1), "locked": .bool(false), "fullWidth": .bool(page.bool("full_width") == true)]
        for (raw, portable) in ["row_id":"rowId", "note_id":"noteId", "parent_page_id":"parentPageId", "icon":"icon", "cover_blob_hash":"coverBlobHash", "created_by":"createdBy", "updated_by":"updatedBy", "created_at":"createdAt", "updated_at":"updatedAt"] {
            metadata[portable] = page.columns[raw] ?? .null
        }
        baselines[id] = .object(["page": .object(metadata), "revision": .int(1), "markdown": .string(""), "blocks": .array([]),
            "nativeDocument": .null, "schemaVersion": .int(1), "updateSequence": .int(0), "snapshotSequence": .int(0),
            "markdownHash": .string(SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())])
        let input: JSONValue = .object(["pageId": .string(id), "expectedRevision": .int(1), "title": .string(title), "markdown": .string(""), "blocks": .array([]), "reason": .string("Página creada en el móvil")])
        return try await save(pageId: id, input: input).objectValue!["document"]!
    }
    public func document(pageId: String) -> JSONValue? {
        guard let record = records[pageId] else { return nil }
        var document = record.baseline.objectValue!
        let fields = record.input.objectValue!
        for key in ["nativeDocument", "academicMetadata", "schemaVersion", "markdown"] where fields[key] != nil { document[key] = fields[key] }
        if let blocks = fields["blocks"]?.arrayValue {
            document["blocks"] = .array(blocks.enumerated().map { position, value in
                var block = value.objectValue ?? [:]
                block["pageId"] = .string(pageId); block["order"] = block["order"] ?? .int(Int64(position))
                return .object(block)
            })
        }
        if let title = fields["title"] { var page = document["page"]!.objectValue!; page["title"] = title; document["page"] = .object(page) }
        document["revision"] = .int(-Int64(record.generation))
        document["mobileSyncState"] = .string(record.state)
        document["mobileSyncIssue"] = record.issue.map(JSONValue.string) ?? .null
        if let remote = record.remote { document["mobileConflictRemote"] = remote }
        return .object(document)
    }
    public func save(pageId: String, input: JSONValue) async throws -> JSONValue {
        guard try JSONEncoder.nodus.encode(input).count <= Self.maximumRequestBytes - 65_536,
              let fields = input.objectValue,
              fields.keys.allSatisfy({ ["pageId", "expectedRevision", "title", "blocks", "nativeDocument", "schemaVersion", "academicMetadata", "reason", "markdown"].contains($0) }),
              fields["pageId"] == .string(pageId), !pageId.isEmpty, pageId.utf8.count <= 1024,
              let expected = fields["expectedRevision"]?.intValue, let blocks = fields["blocks"]?.arrayValue,
              blocks.count <= 100_000, blocks.allSatisfy({ $0.objectValue?["id"]?.stringValue?.isEmpty == false && $0.objectValue?["type"]?.stringValue != nil && $0.objectValue?["content"]?.objectValue != nil }),
              let baseline = records[pageId]?.baseline ?? baselines[pageId],
              let base = baseline.objectValue?["revision"]?.intValue else { throw DesktopBridgeError.malformedResponse }
        guard records[pageId].map({ expected == -$0.generation }) ?? (expected == base || expected == acknowledged[pageId]) else {
            throw APIError(status: 409, code: "local_page_revision_conflict", message: "La página cambió en otra vista del móvil. El borrador anterior se conserva.")
        }
        var record = records[pageId] ?? Record(baseline: baseline, input: input, generation: abs(acknowledged[pageId] ?? 0), state: "pending")
        record.input = input; record.generation += 1
        if record.state == "blocked" { record.state = "pending"; record.sending = nil; record.issue = nil }
        records[pageId] = record; try await persist()
        return .object(["ok": .bool(true), "document": document(pageId: pageId)!])
    }
    public func synchronize(send: @Sendable (Request) async throws -> JSONValue) async throws {
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for pageId in records.keys.sorted() {
            while var record = records[pageId], record.state == "pending" {
                if record.sending == nil {
                    var fields = record.input.objectValue!
                    fields["expectedRevision"] = record.baseline.objectValue!["revision"]
                    fields["expectedPageRevision"] = record.baseline.objectValue!["page"]!.objectValue!["revision"]
                    fields["markdown"] = nil // Desktop owns the canonical projection.
                    record.sending = Request(id: UUID().uuidString, input: .object(fields), generation: record.generation)
                    records[pageId] = record; try await persist()
                }
                let request = record.sending!, response: JSONValue
                do { response = try await send(request) }
                catch {
                    guard var latest = records[pageId] else { throw error }
                    if let api = error as? APIError, api.code == "page_revision_conflict", let remote = api.details["remote"] {
                        try Self.validate(remote, id: pageId, local: false)
                        latest.state = "conflict"; latest.remote = remote; latest.generation += 1
                    } else if !Self.transportLoss(error) { latest.state = "blocked"; latest.generation += 1 }
                    latest.issue = error.localizedDescription; records[pageId] = latest; try await persist(); throw error
                }
                guard response.objectValue?["id"] == .string(request.id), let committed = response.objectValue?["document"] else { throw DesktopBridgeError.malformedResponse }
                try Self.validate(committed, id: pageId, local: false)
                let source = JSONValue.object(["version": .int(1), "vaultId": .string(vaultId), "document": committed,"assets":response.objectValue?["assets"] ?? .array([]),"dependencies":response.objectValue?["dependencies"] ?? .array([])])
                try await cache.store(JSONEncoder.nodus.encode(source), vaultId: vaultId, domain: .corpus,
                    recordId: CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string(pageId)]))
                guard var latest = records[pageId], latest.sending?.id == request.id else { throw DesktopBridgeError.malformedResponse }
                baselines[pageId] = committed; acknowledged[pageId] = -request.generation
                if latest.generation == request.generation { records[pageId] = nil }
                else { latest.baseline = committed; latest.sending = nil; latest.issue = nil; records[pageId] = latest }
                try await persist()
            }
        }
    }
    public func resolve(pageId: String, keepMobile: Bool) async throws -> JSONValue {
        guard var record = records[pageId], record.state == "conflict", let remote = record.remote else { throw DesktopBridgeError.malformedResponse }
        try Self.validate(remote, id: pageId, local: false)
        let source = JSONValue.object(["version": .int(1), "vaultId": .string(vaultId), "document": remote])
        try await cache.store(JSONEncoder.nodus.encode(source), vaultId: vaultId, domain: .corpus,
            recordId: CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string(pageId)]))
        baselines[pageId] = remote; acknowledged[pageId] = nil
        if keepMobile { record.baseline = remote; record.sending = nil; record.state = "pending"; record.remote = nil; record.issue = nil; record.generation += 1; records[pageId] = record }
        else { records[pageId] = nil }
        try await persist(); return document(pageId: pageId) ?? remote
    }
    private func persist() async throws {
        try await cache.store(JSONEncoder.nodus.encode(records), vaultId: vaultId, domain: .writing, recordId: Self.storageKey)
        revision += 1
    }
    private static func transportLoss(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let api = error as? APIError, api.status >= 500 || api.isRateLimited { return true }
        guard let url = error as? URLError else { return false }
        return [.cancelled, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(url.code)
    }
}

public actor CompanionPageDocumentStores {
    public static let shared = CompanionPageDocumentStores()
    private var stores: [String: Task<CompanionPageDocuments, any Error>] = [:]
    public func store(pairingId: String, vaultId: String) async throws -> CompanionPageDocuments {
        let key = "\(pairingId)|\(vaultId)"; if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            return try await CompanionPageDocuments(cache: cache, vaultId: vaultId,
                data: cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionPageDocuments.storageKey))
        }; stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
    public func forget(pairingId: String) { for key in stores.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { stores[key] = nil } }
}
