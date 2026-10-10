import Foundation
import CryptoKit

/// Complete BlockNote saves stay on this device until the owning Mac confirms
/// a canonical commit. A frozen in-flight request survives lost acknowledgements.
public actor CompanionDocumentOutbox {
    public enum State: String, Codable, Sendable { case pending, conflict, blocked }
    public struct Request: Codable, Sendable, Equatable {
        public let id: String
        public let noteId: String
        public let input: JSONValue
        public var creation: JSONValue? = nil
        let generation: Int
    }
    private struct Record: Codable {
        var baseline: JSONValue
        var draft: JSONValue
        var generation: Int
        var sending: Request?
        var state: State
        var remote: JSONValue?
        var issue: String?
        var creation: JSONValue?
        var createdNote: JSONValue?
    }
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private var records: [String: Record]
    private var baselines: [String: JSONValue] = [:]
    private var acknowledgedLocalRevisions: [String: Int] = [:]
    private var synchronizing = false
    static let storageKey = "companion-documents-v1"

    init(cache: PrivateBridgeCache, vaultId: String, data: Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        records = try data.map { try JSONDecoder.nodus.decode([String: Record].self, from: $0) } ?? [:]
    }
    public static func operationKey(_ method: String, _ args: [JSONValue]) throws -> String {
        "operation:\(method):" + SHA256.hash(data: try JSONEncoder.nodus.encode(args)).map { String(format: "%02x", $0) }.joined()
    }
    public func seed(noteId: String, editorData: JSONValue) throws {
        guard let revision = editorData.objectValue?["revision"]?.intValue, revision >= 0,
              editorData.objectValue?["documentTitle"]?.stringValue != nil,
              editorData.objectValue?["contentMarkdown"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
        if let previous = baselines[noteId]?.objectValue?["revision"]?.intValue {
            if revision < previous { return }
            if revision != previous { acknowledgedLocalRevisions[noteId] = nil }
        }
        baselines[noteId] = editorData
    }
    public func editorData(noteId: String) -> JSONValue? {
        guard let record = records[noteId] else { return nil }
        var editor = record.baseline.objectValue ?? [:]
        for (key, value) in record.draft.objectValue ?? [:] where !["expectedRevision", "reason"].contains(key) {
            editor[key == "title" ? "documentTitle" : key] = value
        }
        editor["revision"] = .int(-Int64(record.generation))
        editor["mobileSyncState"] = .string(record.state.rawValue)
        editor["mobileSyncIssue"] = record.issue.map(JSONValue.string) ?? .null
        if let remote = record.remote { editor["mobileConflictRemote"] = remote }
        return .object(editor)
    }
    public func overlayTree(_ tree: JSONValue) -> JSONValue {
        guard var object = tree.objectValue, let notes = object["notes"]?.arrayValue else { return tree }
        let present = Set(notes.compactMap { $0.objectValue?["id"]?.stringValue })
        let created = records.keys.sorted().filter { !present.contains($0) }.compactMap { records[$0]?.createdNote }
        object["notes"] = .array((notes + created).map { note in
            guard var value = note.objectValue, let id = value["id"]?.stringValue,
                  let editor = editorData(noteId: id)?.objectValue else { return note }
            value["title"] = editor["documentTitle"]; value["content"] = editor["contentMarkdown"]
            value["editorRevision"] = editor["revision"]; value["mobileSyncState"] = editor["mobileSyncState"]
            return .object(value)
        })
        return .object(object)
    }
    /// A new authored document has a stable identity before any Mac request.
    /// The same frozen creation and its latest structured edit commit together.
    public func create(input: JSONValue) async throws -> JSONValue {
        try await createDocument(input: input, ideaId: nil)
    }
    public func createManualIdea(input: JSONValue) async throws -> JSONValue {
        guard var fields = input.objectValue, fields.keys.allSatisfy({ ["title", "folderId"].contains($0) }) else { throw DesktopBridgeError.malformedResponse }
        if fields["title"] == nil { fields["title"] = .string("Idea sin título") }
        fields["content"] = .string(""); fields["kind"] = .string("idea")
        let ideaId = "manual-\(UUID().uuidString)"
        let note = try await createDocument(input: .object(fields), ideaId: ideaId)
        return .object(["note": note, "globalId": .string(ideaId)])
    }
    /// Only a newly authored, not-yet-confirmed idea has a local empty dossier.
    /// Existing corpus dossiers continue through their authenticated query cache.
    public func pendingIdeaDetail(globalId: String) -> JSONValue? {
        guard let id = records.keys.first(where: { records[$0]?.creation?.objectValue?["globalId"] == .string(globalId) }),
              let note = records[id]?.createdNote?.objectValue, let editor = editorData(noteId: id)?.objectValue else { return nil }
        return .object(["idea": .object(["global_id": .string(globalId), "type": .string("claim"),
            "label": editor["documentTitle"]!, "statement": editor["contentMarkdown"]!, "embedding": .null,
            "created_at": note["createdAt"] ?? .null]), "themes": .array([]), "occurrences": .array([]),
            "evidence": .array([]), "gaps": .array([]), "externalRefs": .array([])])
    }
    private func createDocument(input: JSONValue, ideaId: String?) async throws -> JSONValue {
        let kind = ideaId == nil ? "markdown" : "idea"
        guard let fields = input.objectValue,
              fields.keys.allSatisfy({ ["title", "content", "kind", "folderId", "tags", "source"].contains($0) }),
              fields["source"] == nil || fields["source"] == .null,
              fields["content"] == .string(""),
              case let .string(title)? = fields["title"], title.count <= 4096,
              fields["kind"] == nil || fields["kind"] == .string(kind),
              fields["tags"] == nil || fields["tags"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        if let folder = fields["folderId"], folder != .null {
            guard case let .string(id) = folder, !id.isEmpty, id.count <= 128 else { throw DesktopBridgeError.malformedResponse }
        }
        let tags = fields["tags"]?.arrayValue ?? []
        guard tags.count <= 100, tags.allSatisfy({ if case let .string(tag) = $0 { return tag.count <= 80 }; return false }) else { throw DesktopBridgeError.malformedResponse }
        let noteId = UUID().uuidString
        let titleValue = JSONValue.string(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (ideaId == nil ? "Nota sin título" : "Idea sin título") : title)
        let created = JSONValue.string(ISO8601DateFormatter().string(from: Date()))
        var creationFields: [String: JSONValue] = ["kind": .string(kind), "folderId": fields["folderId"] ?? .null, "tags": .array(tags)]
        if let ideaId { creationFields["globalId"] = .string(ideaId) }
        let creation: JSONValue = .object(creationFields)
        let source: JSONValue = ideaId.map { .object(["origin": .string("idea"), "ref": .string($0), "note": .string("manual-idea")]) } ?? .null
        let note: JSONValue = .object(["id": .string(noteId), "title": titleValue, "content": .string(""), "kind": .string(kind),
            "folderId": fields["folderId"] ?? .null, "tags": .array(tags), "source": source, "trashedAt": .null,
            "orderIdx": .int(0), "createdAt": created, "updatedAt": created])
        let baseline: JSONValue = .object(["revision": .int(0), "documentTitle": titleValue, "contentMarkdown": .string(""),
            "nativeDocument": .array([]), "schemaVersion": .int(2), "academicMetadata": .null,
            "versions": .array([]), "annotations": .array([]), "outgoingLinks": .array([]), "backlinks": .array([]),
            "style": .object(["fontFamily": .string("serif"), "fontSize": .int(18), "lineHeight": .double(1.75),
                "pageWidth": .int(820), "marginX": .int(56), "paragraphSpacing": .double(0.8), "firstLineIndent": .int(0),
                "alignment": .string("justify"), "theme": .string("paper")]),
            "spellcheckLanguage": .string("es-ES"), "customDictionary": .array([])])
        let draft: JSONValue = .object(["expectedRevision": .int(0), "title": titleValue, "contentMarkdown": .string(""),
            "nativeDocument": .array([]), "schemaVersion": .int(2)])
        records[noteId] = Record(baseline: baseline, draft: draft, generation: 1, sending: nil, state: .pending, creation: creation, createdNote: note)
        do { try await persist() } catch { records[noteId] = nil; throw error }
        return noteResult(noteId: noteId)
    }
    public func save(noteId: String, input: JSONValue) async throws -> JSONValue {
        guard let fields = input.objectValue, fields["title"]?.stringValue != nil,
              fields["contentMarkdown"]?.stringValue != nil,
              let expected = fields["expectedRevision"]?.intValue,
              let baseline = records[noteId]?.baseline ?? baselines[noteId],
              let baseRevision = baseline.objectValue?["revision"]?.intValue else { throw DesktopBridgeError.malformedResponse }
        let existing = records[noteId]
        guard existing.map({ expected == -$0.generation }) ?? (expected == baseRevision || expected == acknowledgedLocalRevisions[noteId]) else {
            throw APIError(status: 409, code: "local_revision_conflict", message: "The document changed in another mobile view. The draft was preserved.")
        }
        var record = existing ?? Record(baseline: baseline, draft: input, generation: abs(acknowledgedLocalRevisions[noteId] ?? 0), sending: nil, state: .pending)
        record.draft = input; record.generation += 1
        if var note = record.createdNote?.objectValue {
            note["updatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            record.createdNote = .object(note)
        }
        // A rejected input never committed. A transport failure might have
        // committed, so keep that immutable request while coalescing later edits.
        if record.state == .blocked { record.sending = nil; record.state = .pending; record.issue = nil }
        records[noteId] = record
        let result = noteResult(noteId: noteId)
        try await persist()
        return result
    }
    private func noteResult(noteId: String) -> JSONValue {
        let editor = editorData(noteId: noteId)!.objectValue!
        var note = records[noteId]?.createdNote?.objectValue ?? [:]
        note.merge(["id": .string(noteId), "title": editor["documentTitle"]!, "content": editor["contentMarkdown"]!,
                    "editorRevision": editor["revision"]!, "mobileSyncState": editor["mobileSyncState"]!], uniquingKeysWith: { _, new in new })
        return .object(note)
    }
    public func pendingCount() -> Int { records.values.filter { $0.state == .pending }.count }
    public func synchronize(send: @Sendable (Request) async throws -> JSONValue) async throws {
        guard !synchronizing else { return }
        synchronizing = true; defer { synchronizing = false }
        for noteId in records.keys.sorted() {
            while var record = records[noteId], record.state == .pending {
                if record.sending == nil {
                    var wire = record.draft.objectValue!
                    wire["expectedRevision"] = record.baseline.objectValue!["revision"]
                    record.sending = Request(id: UUID().uuidString, noteId: noteId, input: .object(wire), creation: record.creation, generation: record.generation)
                    records[noteId] = record; try await persist()
                }
                let request = record.sending!
                let response: JSONValue
                do { response = try await send(request) }
                catch {
                    guard var latest = records[noteId] else { throw error }
                    if let api = error as? APIError, api.code == "revision_conflict", let remote = api.details["remote"] {
                        latest.state = .conflict; latest.remote = remote; latest.generation += 1
                    } else if !Self.isTransportLoss(error) {
                        latest.state = .blocked; latest.generation += 1
                    }
                    latest.issue = error.localizedDescription; records[noteId] = latest; try await persist()
                    throw error
                }
                guard response.objectValue?["id"]?.stringValue == request.id,
                      let committed = response.objectValue?["editorData"],
                      let revision = committed.objectValue?["revision"]?.intValue, revision >= 0,
                      records[noteId] != nil else { throw DesktopBridgeError.malformedResponse }
                if request.creation != nil || records[noteId]?.createdNote != nil {
                    guard let note = response.objectValue?["note"], note.objectValue?["id"]?.stringValue == noteId else { throw DesktopBridgeError.malformedResponse }
                    if let globalId = request.creation?.objectValue?["globalId"] {
                        guard note.objectValue?["kind"] == .string("idea"),
                              note.objectValue?["source"]?.objectValue?["ref"] == globalId,
                              note.objectValue?["source"]?.objectValue?["note"] == .string("manual-idea") else { throw DesktopBridgeError.malformedResponse }
                    }
                    // A confirmed new document must remain discoverable after the
                    // queue retires, including when its selected catalogue predates it.
                    for args: [JSONValue] in [[], [.bool(true)]] {
                        let key = try Self.operationKey("getNotesTree", args)
                        if let data = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key),
                           var tree = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue,
                           var notes = tree["notes"]?.arrayValue {
                            notes.removeAll { $0.objectValue?["id"]?.stringValue == noteId }; notes.append(note)
                            tree["notes"] = .array(notes)
                            try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(tree)), vaultId: vaultId, domain: .corpus, recordId: key)
                        }
                    }
                }
                // Make a confirmed document consultable before retiring its
                // durable queue. Failure here leaves the same replayable receipt.
                try await cache.store(JSONEncoder.nodus.encode(committed), vaultId: vaultId, domain: .corpus,
                                      recordId: Self.operationKey("getWorkspaceNoteEditorData", [.string(noteId)]))
                // Disk writes await another actor. An autosave can arrive during
                // that wait, so read its latest generation after storing the ack.
                guard var latest = records[noteId], latest.sending?.id == request.id else { throw DesktopBridgeError.malformedResponse }
                baselines[noteId] = committed
                acknowledgedLocalRevisions[noteId] = -request.generation
                if latest.generation == request.generation { records[noteId] = nil }
                else {
                    latest.baseline = committed; latest.sending = nil; latest.issue = nil; latest.creation = nil
                    if let note = response.objectValue?["note"], latest.createdNote != nil { latest.createdNote = note }
                    records[noteId] = latest
                }
                try await persist()
            }
        }
    }
    /// Conflict resolution is an explicit choice and receives a fresh request
    /// identity. Neither side silently overwrites the other's changes.
    public func resolve(noteId: String, keepMobile: Bool) async throws -> JSONValue {
        guard var record = records[noteId], record.state == .conflict, let remote = record.remote,
              let revision = remote.objectValue?["revision"]?.intValue, revision >= 0 else { throw DesktopBridgeError.malformedResponse }
        try await cache.store(JSONEncoder.nodus.encode(remote), vaultId: vaultId, domain: .corpus,
                              recordId: Self.operationKey("getWorkspaceNoteEditorData", [.string(noteId)]))
        baselines[noteId] = remote
        acknowledgedLocalRevisions[noteId] = nil
        if keepMobile {
            record.baseline = remote; record.sending = nil; record.state = .pending; record.remote = nil; record.issue = nil; record.generation += 1
            records[noteId] = record
        } else { records[noteId] = nil }
        let result = editorData(noteId: noteId) ?? remote
        try await persist()
        return result
    }
    private func persist() async throws {
        try await cache.store(JSONEncoder.nodus.encode(records), vaultId: vaultId, domain: .writing, recordId: Self.storageKey)
    }
    private static func isTransportLoss(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let api = error as? APIError, api.status >= 500 || api.isRateLimited { return true }
        guard let value = error as? URLError else { return false }
        return [.cancelled, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(value.code)
    }
}

public actor CompanionDocumentOutboxes {
    public static let shared = CompanionDocumentOutboxes()
    private var stores: [String: Task<CompanionDocumentOutbox, any Error>] = [:]
    public func outbox(pairingId: String, vaultId: String) async throws -> CompanionDocumentOutbox {
        let key = "\(pairingId)|\(vaultId)"
        if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            return try await CompanionDocumentOutbox(cache: cache, vaultId: vaultId,
                data: cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        }
        stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
    public func forget(pairingId: String) {
        for key in stores.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { stores[key] = nil }
    }
}
