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
    private struct DatabaseActionPrerequisite: Codable {
        let requestId: String
        let rowId: String
        let originalBlocks: [JSONValue]
    }
    private struct Record: Codable {
        var baseline: JSONValue
        var input: JSONValue
        var generation: Int
        var sending: Request?
        var state: String
        var remote: JSONValue?
        var issue: String?
        var databaseAction: DatabaseActionPrerequisite? = nil
    }
    private struct StoredState: Codable {
        var version: Int
        var records: [String: Record]
        var authored: [String: JSONValue]
    }
    static let storageKey = "companion-page-documents-v1"
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var records: [String: Record]
    private var authored: [String: JSONValue] = [:]
    private var baselines: [String: JSONValue] = [:]
    private var acknowledged: [String: Int] = [:]
    private var synchronizing = false
    private var diskTask: Task<Void, any Error>?
    private var diskTaskId: UUID?
    public private(set) var revision = 0

    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        if let data, let state = try? JSONDecoder.nodus.decode(StoredState.self, from: data), state.version == 2 {
            records = state.records; authored = state.authored
            for (id, source) in authored { _ = try Self.document(source, vaultId: vaultId, pageId: id) }
        } else { records = try data.map { try JSONDecoder.nodus.decode([String: Record].self, from: $0) } ?? [:] }
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
    /// Only documents actually authored on this device enter durable storage.
    /// Other consulted Mac pages remain disposable/selected read copies.
    public func authoredSource(pageId: String) -> JSONValue? { authored[pageId] }
    public func authoredPageRows() -> [Row] {
        var documents = authored.compactMapValues { $0.objectValue?["document"] }
        for id in records.keys { documents[id] = document(pageId: id) }
        return documents.keys.sorted().compactMap { id in
            guard let document = documents[id]?.objectValue, let page = document["page"]?.objectValue else { return nil }
            var row: [String: JSONValue] = [:]
            for (portable, raw) in ["id":"id", "title":"title", "origin":"origin", "state":"state", "rowId":"row_id", "noteId":"note_id", "parentPageId":"parent_page_id", "icon":"icon", "coverBlobHash":"cover_blob_hash", "locked":"locked", "fullWidth":"full_width", "revision":"revision", "createdBy":"created_by", "updatedBy":"updated_by", "createdAt":"created_at", "updatedAt":"updated_at"] { row[raw] = page[portable] ?? .null }
            row["mobileSyncState"] = document["mobileSyncState"] ?? .string("available")
            return Row(row)
        }
    }
    public func refreshAuthoredSource(pageId: String, source: JSONValue) async throws {
        guard let previous = authored[pageId] else { return }
        let document = try Self.document(source, vaultId: vaultId, pageId: pageId)
        let old = try Self.document(previous, vaultId: vaultId, pageId: pageId)
        guard let revision = document.objectValue?["revision"]?.intValue, let prior = old.objectValue?["revision"]?.intValue,
              revision > prior || revision == prior && (document.objectValue?["page"]?.objectValue?["revision"]?.intValue ?? 0) >= (old.objectValue?["page"]?.objectValue?["revision"]?.intValue ?? 0) else { return }
        guard source != previous else { return }; authored[pageId] = source; try await persist()
    }
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
        guard baselines[id] == nil, authored[id] == nil else { throw DesktopBridgeError.malformedResponse }
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
    /// Open only a real, confirmed create_page operation. Its original blocks
    /// remain the immutable creation baseline; later editor drafts are separate.
    public func prepareDatabaseActionPage(checkpoint: CompanionDatabaseActionCheckpoint, rowId: String) async throws -> String {
        guard checkpoint.value.objectValue?["vaultId"] == .string(vaultId), checkpoint.value.objectValue?["recoveryReviewRequired"] != .bool(true),
              let receipt = checkpoint.value.objectValue?["buttonResult"]?.objectValue,
              let count = receipt["completedSteps"]?.intValue, let clicked = receipt["clickedAt"]?.stringValue,
              let plan = checkpoint.value.objectValue?["source"]?.objectValue?["plan"],
              let operations = try CompanionDatabaseActionCheckpoint.instantiate(plan, requestId: checkpoint.id, clickedAt: clicked).objectValue?["operations"]?.arrayValue,
              count >= 0, count <= operations.count,
              let creation = operations.prefix(count).first(where: { $0.objectValue?["type"] == .string("create_page") && $0.objectValue?["rowId"] == .string(rowId) }),
              let blocks = creation.objectValue?["blocks"]?.arrayValue else { throw DesktopBridgeError.permissionDenied }
        let pageId = "row:" + rowId
        if records[pageId] != nil || authored[pageId] != nil { return pageId }
        var title = ""
        let columns = checkpoint.value.objectValue?["source"]?.objectValue?["automationContext"]?.objectValue?["columns"]?.arrayValue ?? []
        if let column = columns.first(where: { $0.objectValue?["type"] == .string("title") && $0.objectValue?["databaseId"] == creation.objectValue?["databaseId"] })?.objectValue?["id"]?.stringValue {
            title = try checkpoint.projectedCells()[rowId]?[column]?.stringValue ?? ""
        }
        let metadata: JSONValue = .object(["id":.string(pageId),"rowId":.string(rowId),"origin":.string("database_row"),"title":.string(title),"state":.string("active"),"revision":.int(1),"locked":.bool(false),"fullWidth":.bool(false)])
        let baseline: JSONValue = .object(["page":metadata,"revision":.int(1),"blocks":.array(blocks),"markdown":.string(""),"nativeDocument":.null,"schemaVersion":.int(1)])
        try Self.validate(baseline, id:pageId, local:false)
        let input: JSONValue = .object(["pageId":.string(pageId),"expectedRevision":.int(1),"title":.string(title),"blocks":.array(blocks),"markdown":.string(""),"reason":.string("Página creada por acción local")])
        records[pageId] = Record(baseline:baseline,input:input,generation:1,state:"pending",databaseAction:DatabaseActionPrerequisite(requestId:checkpoint.id,rowId:rowId,originalBlocks:blocks))
        try await persist()
        return pageId
    }
    private func reconcileDatabaseAction(pageId: String) async throws -> Bool {
        guard var record = records[pageId], let dependency = record.databaseAction else { return true }
        guard let bytes = try await cache.data(vaultId:vaultId,domain:.researchGeneration,recordId:"job-ledger-v1") else { return false }
        let ledger = try JSONDecoder.nodus.decode([String:DesktopJobLedger.Request].self,from:bytes)
        guard let latest = records[pageId], latest.databaseAction?.requestId == dependency.requestId else { return false }
        record = latest
        guard let action = ledger[dependency.requestId], action.state == "available", action.method == "saveMobileDatabaseButtonResult",
              let document = action.result?.objectValue?["createdPages"]?.arrayValue?.first(where: { $0.objectValue?["page"]?.objectValue?["id"] == .string(pageId) }) else { return false }
        try Self.validate(document,id:pageId,local:false)
        guard document.objectValue?["page"]?.objectValue?["rowId"] == .string(dependency.rowId),
              let blocks = document.objectValue?["blocks"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        func canonicalBlocks(_ blocks:[JSONValue]) -> [JSONValue] {
            blocks.map { block in
                let fields = block.objectValue ?? [:]
                return .object(["id":fields["id"] ?? .null,"type":fields["type"] ?? .null,"content":fields["content"] ?? .null,"parentBlockId":fields["parentBlockId"] ?? .null])
            }
        }
        guard canonicalBlocks(blocks) == canonicalBlocks(dependency.originalBlocks) else {
            throw APIError(status:409,code:"database_action_page_conflict",message:"El contenido confirmado de la página cambió. El borrador estructurado se conserva sin sobrescribir el Mac.")
        }
        let source: JSONValue = .object(["version":.int(1),"vaultId":.string(vaultId),"document":document])
        authored[pageId] = source; baselines[pageId] = document
        if record.generation == 1 { records[pageId] = nil; acknowledged[pageId] = -1 }
        else { record.baseline = document; record.databaseAction = nil; record.sending = nil; records[pageId] = record }
        try await persist()
        return records[pageId] != nil
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
            guard try await reconcileDatabaseAction(pageId:pageId) else { continue }
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
                // Persist the confirmed authored result before retiring its sending
                // draft. Disposable cache overflow must not strand an applied save.
                authored[pageId] = source; try await persist()
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
        authored[pageId] = source; try await persist()
        try await cache.store(JSONEncoder.nodus.encode(source), vaultId: vaultId, domain: .corpus,
            recordId: CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string(pageId)]))
        baselines[pageId] = remote; acknowledged[pageId] = nil
        if keepMobile { record.baseline = remote; record.sending = nil; record.state = "pending"; record.remote = nil; record.issue = nil; record.generation += 1; records[pageId] = record }
        else { records[pageId] = nil }
        try await persist(); return document(pageId: pageId) ?? remote
    }
    private func persist() async throws {
        let bytes = try JSONEncoder.nodus.encode(StoredState(version: 2, records: records, authored: authored))
        let previous = diskTask, id = UUID(), cache = self.cache, vault = vaultId
        let task = Task {
            if let previous { _ = try? await previous.value }
            _ = try await cache.store(bytes, vaultId: vault, domain: .writing, recordId: Self.storageKey)
        }
        diskTask = task; diskTaskId = id
        do { try await task.value }
        catch { if diskTaskId == id { diskTask = nil; diskTaskId = nil }; throw error }
        if diskTaskId == id { diskTask = nil; diskTaskId = nil }
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
