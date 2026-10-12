import Foundation
import CryptoKit

/// Complete BlockNote saves stay on this device until the owning Mac confirms
/// a canonical commit. A frozen in-flight request survives lost acknowledgements.
public actor CompanionDocumentOutbox {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case workspaceNote, studyDocument
        var storageKey: String { self == .workspaceNote ? CompanionDocumentOutbox.storageKey : "companion-study-documents-v1" }
        var editorMethod: String { self == .workspaceNote ? "getWorkspaceNoteEditorData" : "getStudyDocEditorData" }
    }
    /// Mirrors shared/mobileWorkspace.ts; the shared editor keeps its own
    /// smaller native-document and individual attachment limits.
    public static let maximumRequestBytes = 32 * 1024 * 1024
    public enum State: String, Codable, Sendable { case pending, conflict, blocked }
    public struct Request: Codable, Sendable, Equatable {
        public let id: String
        public let noteId: String
        public let input: JSONValue
        public var creation: JSONValue? = nil
        public var command: JSONValue? = nil
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
    private struct StudyCommand: Codable {
        var id: String
        let sourceId: String
        let action: String
        let targetId: String?
        var expectedRevision: Int
        var sourceFingerprint: String?
        let input: JSONValue
        let sourceEditor: JSONValue
        var sourceNote: JSONValue
        var sourcePlacements: JSONValue
        let targetEditor: JSONValue?
        let capturedGeneration: Int
        var dependencyRequestId: String?
        var needsCreation: Bool
        var sending: Request?
        var state: State
        var remote: JSONValue?
        var issue: String?
        var cancelled: Bool? = nil
        let createdAt: Date
    }
    private struct AnnotationCommand: Codable {
        var id: String
        let documentId: String
        var command: JSONValue
        var dependencyId: String?
        var projected: JSONValue?
        var sourceRevision: Int
        var sourceGeneration: Int?
        var sourceEditor: JSONValue?
        var sourceKey: String?
        var sending: Request?
        var state: State
        var remote: JSONValue?
        var issue: String?
        let createdAt: Date
    }
    private struct Authored: Codable {
        var editorData: JSONValue
        var note: JSONValue?
    }
    private struct StoredState: Codable {
        var version: Int
        var vaultId: String
        var records: [String: Record]
        var authored: [String: Authored]
        var folders: [String: JSONValue]?
        var kind: Kind? = nil
        var studyCommands: [String: StudyCommand]? = nil
        var annotationCommands: [String: AnnotationCommand]? = nil
        var annotationSources: [String: JSONValue]? = nil
    }
    private let cache: PrivateBridgeCache
    private let vaultId: String
    private let kind: Kind
    private var records: [String: Record]
    private var authored: [String: Authored] = [:]
    private var knownFolders: [String: JSONValue] = [:]
    private var knownNotes: [String: JSONValue] = [:]
    private var baselines: [String: JSONValue] = [:]
    private var acknowledgedLocalRevisions: [String: Int] = [:]
    private var studyCommands: [String: StudyCommand] = [:]
    private var annotationCommands: [String: AnnotationCommand] = [:]
    private var annotationSources: [String: JSONValue] = [:]
    private var synchronizing = false
    private var diskTask: Task<Void, any Error>?
    private var diskTaskId: UUID?
    static let storageKey = "companion-documents-v1"

    init(cache: PrivateBridgeCache, vaultId: String, data: Data?, kind: Kind = .workspaceNote) throws {
        self.cache = cache; self.vaultId = vaultId; self.kind = kind
        if let data, let state = try? JSONDecoder.nodus.decode(StoredState.self, from: data), state.version == 2 {
            guard state.vaultId == vaultId, (state.kind ?? .workspaceNote) == kind else { throw DesktopBridgeError.malformedResponse }
            records = state.records; authored = state.authored; annotationCommands = state.annotationCommands ?? [:]; annotationSources = state.annotationSources ?? [:]; studyCommands = state.studyCommands ?? [:]; knownFolders = state.folders ?? [:]
            for (key, command) in annotationCommands {
                let editor = command.sourceKey.flatMap { state.annotationSources?[$0] } ?? command.sourceEditor
                guard key == command.id, UUID(uuidString: key) != nil,
                      !command.documentId.isEmpty, command.documentId.utf8.count <= 128, command.sourceRevision >= 0,
                      command.sourceGeneration.map({ $0 > 0 }) ?? true,
                      editor?.objectValue?["annotations"]?.arrayValue != nil,
                      editor?.objectValue?["revision"].flatMap(CompanionStudyAnnotation.exactInteger) != nil,
                      let fields = command.command.objectValue, let action = fields["action"]?.stringValue,
                      let target = fields["annotationId"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                _ = try CompanionStudyAnnotation.command(action: action, id: target, expected: fields["expectedAnnotation"] == .null ? nil : fields["expectedAnnotation"], patch: fields["patch"])
                if let dependency = command.dependencyId { guard dependency != key, annotationCommands[dependency]?.documentId == command.documentId else { throw DesktopBridgeError.malformedResponse } }
                if let sending = command.sending { guard sending.id == key, sending.noteId == command.documentId, sending.command == command.command else { throw DesktopBridgeError.malformedResponse } }
            }
            for (key, command) in studyCommands {
                guard kind == .studyDocument, key == command.id, UUID(uuidString: key) != nil,
                      !command.sourceId.isEmpty, command.sourceId.utf8.count <= 128,
                      ["duplicate", "trash"].contains(command.action), command.expectedRevision >= 0, command.capturedGeneration >= 0,
                      command.input.objectValue?["title"]?.stringValue != nil, command.input.objectValue?["contentMarkdown"]?.stringValue != nil,
                      command.sourceNote.objectValue?["id"] == .string(command.sourceId), command.sourcePlacements.arrayValue != nil,
                      command.action == "duplicate" ? command.targetId.flatMap(UUID.init(uuidString:)) != nil && command.targetId != command.sourceId && command.targetEditor?.objectValue?["documentTitle"]?.stringValue != nil : command.targetId == nil,
                      command.needsCreation || command.sourceFingerprint?.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw DesktopBridgeError.malformedResponse }
                if let sending = command.sending {
                    guard sending.id == command.id, sending.noteId == command.sourceId,
                          sending.command?.objectValue?["action"] == .string(command.action),
                          sending.command?.objectValue?["sourceFingerprint"] == command.sourceFingerprint.map(JSONValue.string) else { throw DesktopBridgeError.malformedResponse }
                }
            }
            for (id, source) in authored {
                guard source.editorData.objectValue?["revision"]?.intValue.map({ $0 >= 0 }) == true,
                      source.editorData.objectValue?["documentTitle"]?.stringValue != nil,
                      source.editorData.objectValue?["contentMarkdown"]?.stringValue != nil,
                      source.note == nil || source.note?.objectValue?["id"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
            }
            for (id, folder) in knownFolders {
                guard !id.isEmpty, folder.objectValue?["id"] == .string(id), Self.validParent(folder.objectValue?["parentId"]) else { throw DesktopBridgeError.malformedResponse }
            }
        } else {
            guard kind == .workspaceNote || data == nil else { throw DesktopBridgeError.malformedResponse }
            records = try data.map { try JSONDecoder.nodus.decode([String: Record].self, from: $0) } ?? [:]
        }
    }
    public static func operationKey(_ method: String, _ args: [JSONValue]) throws -> String {
        "operation:\(method):" + SHA256.hash(data: try JSONEncoder.nodus.encode(args)).map { String(format: "%02x", $0) }.joined()
    }
    public func seed(noteId: String, editorData: JSONValue) async throws {
        guard let revision = editorData.objectValue?["revision"]?.intValue, revision >= 0,
              editorData.objectValue?["documentTitle"]?.stringValue != nil,
              editorData.objectValue?["contentMarkdown"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
        if let previous = baselines[noteId]?.objectValue?["revision"]?.intValue {
            if revision < previous { return }
            if revision != previous { acknowledgedLocalRevisions[noteId] = nil }
        }
        baselines[noteId] = editorData
        if var owned = authored[noteId], editorData != owned.editorData,
           revision >= (owned.editorData.objectValue?["revision"]?.intValue ?? 0) {
            owned.editorData = editorData
            if kind == .studyDocument, let note = editorData.objectValue?["mobileCommandSource"]?.objectValue?["document"], note.objectValue?["id"] == .string(noteId) {
                owned.note = enrichedStudyNote(note, editor: editorData)
            }
            authored[noteId] = owned; try await persist()
        }
    }
    public func confirmedEditorData(noteId: String) -> JSONValue? { authored[noteId]?.editorData }
    public func hasBaseline(noteId: String) -> Bool { records[noteId] != nil || baselines[noteId] != nil || annotationCommands.values.contains { $0.documentId == noteId } || studyCommands.values.contains { $0.sourceId == noteId || $0.targetId == noteId } }
    private static func validParent(_ parent: JSONValue?) -> Bool {
        parent == nil || parent == .null || parent?.stringValue.map({ !$0.isEmpty }) == true
    }
    public func rememberTree(_ tree: JSONValue, authoritative: Bool = true) async throws {
        guard let folders = tree.objectValue?["folders"]?.arrayValue, let notes = tree.objectValue?["notes"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        var folderIds = Set<String>(), noteIds = Set<String>()
        for folder in folders {
            guard let id = folder.objectValue?["id"]?.stringValue, !id.isEmpty, folderIds.insert(id).inserted,
                  Self.validParent(folder.objectValue?["parentId"]) else { throw DesktopBridgeError.malformedResponse }
        }
        for note in notes {
            guard let id = note.objectValue?["id"]?.stringValue, !id.isEmpty, noteIds.insert(id).inserted,
                  Self.validParent(note.objectValue?["folderId"]) else { throw DesktopBridgeError.malformedResponse }
        }
        var changed = false
        for folder in folders {
            let id = folder.objectValue!["id"]!.stringValue!
            if (authoritative || knownFolders[id] == nil), knownFolders[id] != folder { knownFolders[id] = folder; changed = true }
        }
        for note in notes {
            let id = note.objectValue!["id"]!.stringValue!
            if authoritative || knownNotes[id] == nil { knownNotes[id] = note }
            if authoritative, var source = authored[id], source.note != note {
                source.note = note; authored[id] = source; changed = true
            }
        }
        if changed, !authored.isEmpty { try await persist() }
    }
    private func authoredFolders() -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for note in authored.values.compactMap(\.note) + records.values.compactMap(\.createdNote) {
            var next = note.objectValue?["folderId"]?.stringValue, seen = Set<String>()
            while let id = next, seen.insert(id).inserted, seen.count <= 256, let folder = knownFolders[id] {
                result[id] = folder; next = folder.objectValue?["parentId"]?.stringValue
            }
        }
        return result
    }
    public func confirmedTree(includeTrashed: Bool = false) -> JSONValue? {
        guard kind == .workspaceNote else { return nil }
        let notes = authored.keys.sorted().compactMap { authored[$0]?.note }.filter { includeTrashed || Self.isVisibleNote($0) }
        guard !notes.isEmpty else { return nil }
        let folders = authoredFolders()
        return overlayTree(.object(["notes": .array(notes), "folders": .array(folders.keys.sorted().compactMap { folders[$0] }), "mobileSourceScope": .string("authoredDocuments")]), includeConfirmedEdits: true, includeTrashed: includeTrashed)
    }
    public func editorData(noteId: String) -> JSONValue? {
        let base = documentEditorData(noteId: noteId)
        let pending = annotationCommands.values.filter { $0.documentId == noteId }.sorted { $0.createdAt < $1.createdAt }
        guard !pending.isEmpty else { return base }
        guard var editor = (base ?? authored[noteId]?.editorData ?? baselines[noteId] ?? pending.first.flatMap { annotationSource($0) })?.objectValue else { return nil }
        var rows = editor["annotations"]?.arrayValue ?? []
        for item in pending {
            let id = item.command.objectValue?["annotationId"]
            rows.removeAll { $0.objectValue?["id"] == id }
            if let projected = item.projected { rows.append(projected) }
        }
        editor["annotations"] = .array(rows)
        if pending.allSatisfy({ $0.state == .pending }), let state = editor["mobileSyncState"]?.stringValue, state != "pending" { return .object(editor) }
        let issue = pending.first { $0.state != .pending } ?? pending.first!
        editor["mobileSyncState"] = .string(issue.state.rawValue)
        editor["mobileSyncIssue"] = issue.issue.map(JSONValue.string) ?? .null
        if let remote = issue.remote { editor["mobileConflictRemote"] = remote }
        return .object(editor)
    }
    private func documentEditorData(noteId: String) -> JSONValue? {
        guard let record = records[noteId] else {
            guard let command = studyCommands.values.first(where: { $0.targetId == noteId || ($0.sourceId == noteId && $0.cancelled != true) }) else { return nil }
            var editor = (command.targetId == noteId ? command.targetEditor : command.sourceEditor)?.objectValue ?? [:]
            editor["mobileSyncState"] = .string(command.state.rawValue)
            editor["mobileSyncIssue"] = command.issue.map(JSONValue.string) ?? .null
            if let remote = command.remote { editor["mobileConflictRemote"] = remote }
            return .object(editor)
        }
        var editor = record.baseline.objectValue ?? [:]
        for (key, value) in record.draft.objectValue ?? [:] where !["expectedRevision", "reason"].contains(key) {
            editor[key == "title" ? "documentTitle" : key] = value
        }
        editor["revision"] = .int(-Int64(record.generation))
        let command = studyCommands.values.first { ($0.sourceId == noteId || $0.targetId == noteId) && $0.cancelled != true }
        editor["mobileSyncState"] = .string(command?.state.rawValue ?? record.state.rawValue)
        editor["mobileSyncIssue"] = (command?.issue ?? record.issue).map(JSONValue.string) ?? .null
        if let remote = command?.remote ?? record.remote { editor["mobileConflictRemote"] = remote }
        return .object(editor)
    }
    private static func isVisibleNote(_ note: JSONValue) -> Bool { note.objectValue?["trashedAt"] == nil || note.objectValue?["trashedAt"] == .null }
    public func overlayTree(_ tree: JSONValue, includeConfirmedEdits: Bool = false, includeTrashed: Bool = false) -> JSONValue {
        guard var object = tree.objectValue, let notes = object["notes"]?.arrayValue else { return tree }
        let present = Set(notes.compactMap { $0.objectValue?["id"]?.stringValue })
        var additions: [String: JSONValue] = includeConfirmedEdits ? authored.compactMapValues(\.note) : [:]
        for id in records.keys { if let note = records[id]?.createdNote { additions[id] = note } }
        let created = additions.keys.sorted().filter { !present.contains($0) }.compactMap { additions[$0] }.filter { includeTrashed || Self.isVisibleNote($0) }
        object["notes"] = .array((notes + created).map { note in
            guard let id = note.objectValue?["id"]?.stringValue,
                  let editor = (editorData(noteId: id) ?? (includeConfirmedEdits || !present.contains(id) ? confirmedEditorData(noteId: id) : nil))?.objectValue else { return note }
            var value = (includeConfirmedEdits ? authored[id]?.note : nil)?.objectValue ?? note.objectValue!
            value["title"] = editor["documentTitle"]; value["content"] = editor["contentMarkdown"]
            value["editorRevision"] = editor["revision"]; value["mobileSyncState"] = editor["mobileSyncState"] ?? .string("available")
            return .object(value)
        })
        if includeConfirmedEdits, let folders = object["folders"]?.arrayValue {
            let retained = authoredFolders(), presentFolders = Set(folders.compactMap { $0.objectValue?["id"]?.stringValue })
            object["folders"] = .array(folders.map { retained[$0.objectValue?["id"]?.stringValue ?? ""] ?? $0 } + retained.keys.sorted().filter { !presentFolders.contains($0) }.compactMap { retained[$0] })
        }
        return .object(object)
    }
    /// A new authored document has a stable identity before any Mac request.
    /// The same frozen creation and its latest structured edit commit together.
    public func create(input: JSONValue) async throws -> JSONValue {
        guard kind == .workspaceNote else { throw DesktopBridgeError.permissionDenied }
        return try await createDocument(input: input, ideaId: nil)
    }
    private static func isSafeInteger(_ value: JSONValue?) -> Bool {
        switch value {
        case .int(let number): return number >= -9_007_199_254_740_991 && number <= 9_007_199_254_740_991
        case .double(let number): return number.isFinite && number.rounded() == number && abs(number) <= 9_007_199_254_740_991
        default: return false
        }
    }
    /// Allocate the document before contacting the Mac. Its placement and
    /// structured save travel together under the same replayable request.
    public func createStudyDocument(input: JSONValue) async throws -> JSONValue {
        guard kind == .studyDocument, let fields = input.objectValue,
              fields.keys.allSatisfy({ ["title", "kind", "placement", "description", "color", "icon", "emoji", "imageData", "year"].contains($0) }),
              let title = fields["title"]?.stringValue, title.utf16.count <= 4096,
              let documentKind = fields["kind"]?.stringValue,
              ["apunte", "manual", "libro", "articulo", "presentacion", "grabacion", "transcripcion", "banco", "test", "examen"].contains(documentKind)
        else { throw DesktopBridgeError.malformedResponse }
        if let placement = fields["placement"], placement != .null {
            guard let parents = placement.objectValue,
                  parents.keys.allSatisfy({ ["courseId", "subjectId", "topicId", "folderId", "position"].contains($0) }),
                  ["courseId", "subjectId", "topicId", "folderId"].contains(where: { parents[$0]?.stringValue != nil }),
                  ["courseId", "subjectId", "topicId", "folderId"].allSatisfy({ Self.validParent(parents[$0]) && (parents[$0]?.stringValue?.utf8.count ?? 0) <= 128 }),
                  parents["position"] == nil || Self.isSafeInteger(parents["position"]) else { throw DesktopBridgeError.malformedResponse }
        }
        for key in ["description", "color", "icon", "emoji", "imageData"] {
            if let value = fields[key], value != .null {
                let limit = key == "imageData" ? 16 * 1024 * 1024 : key == "description" ? 65_536 : 128
                guard let text = value.stringValue, text.utf16.count <= limit else { throw DesktopBridgeError.malformedResponse }
            }
        }
        guard fields["year"] == nil || fields["year"] == .null || Self.isSafeInteger(fields["year"]) else { throw DesktopBridgeError.malformedResponse }
        let id = UUID().uuidString, titleValue = JSONValue.string(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Documento sin título" : title)
        let timestamp = JSONValue.string(ISO8601DateFormatter().string(from: Date()))
        var creation = fields; creation["title"] = nil
        var note = fields
        note.merge(["id": .string(id), "title": titleValue, "contentMarkdown": .string(""), "createdAt": timestamp, "updatedAt": timestamp,
                    "deletedAt": .null, "archivedAt": .null, "position": .int(0)], uniquingKeysWith: { _, new in new })
        note["mobileStudyPlacement"] = fields["placement"] ?? .null
        let baseline: JSONValue = .object(["revision": .int(0), "documentTitle": titleValue, "contentMarkdown": .string(""),
            "nativeDocument": .array([]), "schemaVersion": .int(2), "academicMetadata": .null,
            "versions": .array([]), "annotations": .array([]), "outgoingLinks": .array([]), "backlinks": .array([]),
            "style": .object(["fontFamily": .string("serif"), "fontSize": .int(18), "lineHeight": .double(1.75), "pageWidth": .int(820), "marginX": .int(56),
                              "paragraphSpacing": .double(0.8), "firstLineIndent": .int(0), "alignment": .string("justify"), "theme": .string("paper")]),
            "spellcheckLanguage": .string("es-ES"), "customDictionary": .array([])])
        let draft: JSONValue = .object(["expectedRevision": .int(0), "title": titleValue, "contentMarkdown": .string(""), "nativeDocument": .array([]), "schemaVersion": .int(2)])
        guard try JSONEncoder.nodus.encode(input).count <= Self.maximumRequestBytes - 65_536 else { throw DesktopBridgeError.malformedResponse }
        records[id] = Record(baseline: baseline, draft: draft, generation: 1, sending: nil, state: .pending, creation: .object(creation), createdNote: .object(note))
        do { try await persist() } catch { records[id] = nil; throw error }
        return noteResult(noteId: id)
    }

    public func overlayStudyTables(_ source: [String: [Row]], includeConfirmedEdits: Bool = false, authoritative: Bool = false) -> [String: [Row]] {
        guard kind == .studyDocument else { return source }
        var tables = source, local = authoritative ? [:] : authored.compactMapValues(\.note)
        for (id, record) in records {
            if let note = record.createdNote, !authoritative || record.creation != nil { local[id] = note }
        }
        for command in studyCommands.values {
            if let target = command.targetId { local[target] = studyCommandNote(command) }
            else if command.cancelled != true { local[command.sourceId] = studyCommandNote(command) }
        }
        var documents = tables["study_docs"] ?? [], placements = tables["study_placements"] ?? []
        for id in Set(local.keys).union(records.keys).sorted() {
            let index = documents.firstIndex { $0.string("id") == id }
            let editor = editorData(noteId: id) ?? (!authoritative && (includeConfirmedEdits || index == nil) ? confirmedEditorData(noteId: id) : nil)
            guard let editor = editor?.objectValue else { continue }
            var fields = index.map { documents[$0].columns } ?? ["id": .string(id)]
            if let note = local[id]?.objectValue {
                for (key, column) in [("kind", "kind"), ("shortId", "short_id"), ("description", "description"), ("color", "color"), ("icon", "icon"), ("emoji", "emoji"), ("imageData", "image_data"), ("year", "year"), ("favorite", "favorite"), ("position", "position"), ("createdAt", "created_at"), ("updatedAt", "updated_at"), ("deletedAt", "deleted_at"), ("archivedAt", "archived_at")] { if let value = note[key] { fields[column] = value } }
                if let copied = note["mobileStudyPlacements"]?.arrayValue, !placements.contains(where: { $0.string("document_id") == id }) {
                    placements += copied.enumerated().compactMap { index, value in
                        guard var placement = value.objectValue else { return nil }
                        if placement["document_id"] != .string(id) {
                            placement["id"] = .string("mobile-\(id)-\(index)"); placement["document_id"] = .string(id)
                            placement["deleted_at"] = .null; placement["archived_at"] = .null
                        }
                        return Row(placement)
                    }
                } else if let placement = note["mobileStudyPlacement"]?.objectValue, !placements.contains(where: { $0.string("document_id") == id }) {
                    var location: [String: JSONValue] = ["id": .string("mobile-\(id)"), "document_id": .string(id)]
                    for (key, column) in [("courseId", "course_id"), ("subjectId", "subject_id"), ("topicId", "topic_id"), ("folderId", "folder_id")] { location[column] = placement[key] ?? .null }
                    placements.append(Row(location))
                }
            }
            fields["title"] = editor["documentTitle"]; fields["content_markdown"] = editor["contentMarkdown"]
            fields["editor_revision"] = editor["revision"]; fields["mobile_sync_state"] = editor["mobileSyncState"] ?? .string("available")
            if let index { documents[index] = Row(fields) } else if local[id] != nil { documents.append(Row(fields)) }
        }
        tables["study_docs"] = documents; tables["study_placements"] = placements
        return tables
    }
    /// Persist the command and its exact local draft before reporting success.
    /// An old selected download without organization metadata cannot silently
    /// invent a kind, placement or source revision.
    public func enqueueStudyCommand(noteId: String, action: String) async throws -> JSONValue {
        guard !annotationCommands.values.contains(where: { $0.documentId == noteId }) else { throw APIError(status: 409, code: "study_annotation_pending", message: "Confirma los comentarios pendientes antes de duplicar o enviar este documento a la papelera.") }

        guard kind == .studyDocument, ["duplicate", "trash"].contains(action) else { throw DesktopBridgeError.permissionDenied }
        if let existing = studyCommands.values.first(where: { $0.sourceId == noteId && $0.cancelled != true }) {
            guard existing.action == action else { throw APIError(status: 409, code: "study_command_pending", message: "Hay otra solicitud pendiente para este documento.") }
            try await persist()
            return action == "duplicate" ? studyCommandNote(existing) : .null
        }
        guard let editor = editorData(noteId: noteId) ?? baselines[noteId] ?? authored[noteId]?.editorData,
              let fields = editor.objectValue,
              let baseline = records[noteId]?.baseline ?? baselines[noteId] ?? authored[noteId]?.editorData,
              let revision = baseline.objectValue?["revision"]?.intValue, revision >= 0,
              let title = fields["documentTitle"]?.stringValue, fields["contentMarkdown"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
        let source = baseline.objectValue?["mobileCommandSource"]?.objectValue
        let needsCreation = records[noteId]?.creation != nil
        let note: JSONValue
        let placements: JSONValue
        let fingerprint: String?
        if needsCreation, let created = records[noteId]?.createdNote {
            note = created; fingerprint = nil
            if let placement = created.objectValue?["mobileStudyPlacement"]?.objectValue {
                var fields: [String: JSONValue] = ["id": .string("mobile-\(noteId)"), "document_id": .string(noteId), "deleted_at": .null]
                for (key, column) in [("courseId", "course_id"), ("subjectId", "subject_id"), ("topicId", "topic_id"), ("folderId", "folder_id"), ("position", "position")] { fields[column] = placement[key] ?? .null }
                placements = .array([.object(fields)])
            } else { placements = .array([]) }
        } else {
            guard source?["version"] == .int(1), let sourceNote = source?["document"], sourceNote.objectValue?["id"] == .string(noteId),
                  let hash = source?["fingerprint"]?.stringValue, hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  let sourcePlacements = source?["placements"], sourcePlacements.arrayValue != nil else {
                throw APIError(status: 409, code: "study_command_source_missing", message: "Esta copia no incluye los datos completos para duplicar o enviar el documento a la papelera. Actualiza la descarga con Nodus conectado.")
            }
            note = sourceNote; placements = sourcePlacements; fingerprint = hash
        }
        var input: [String: JSONValue] = ["title": .string(title), "contentMarkdown": fields["contentMarkdown"]!, "expectedRevision": .int(Int64(revision))]
        for key in ["nativeDocument", "schemaVersion", "academicMetadata", "style", "spellcheckLanguage", "customDictionary"] { if let value = fields[key] { input[key] = value } }
        let target = action == "duplicate" ? UUID().uuidString.lowercased() : nil
        var targetEditor = Self.cloneStudyEditor(fields)
        targetEditor["documentTitle"] = .string(title + " (copia)"); targetEditor["revision"] = .int(0)
        for key in ["versions", "annotations", "outgoingLinks", "backlinks"] { targetEditor[key] = .array([]) }
        targetEditor["mobileCommandSource"] = nil; targetEditor["mobileConflictRemote"] = nil
        var dependency = records[noteId]?.sending?.id
        var newlyFrozenCreation: Request?
        if needsCreation, let record = records[noteId], record.sending == nil {
            var wire = record.draft.objectValue!; wire["expectedRevision"] = .int(Int64(revision))
            newlyFrozenCreation = Request(id: UUID().uuidString, noteId: noteId, input: .object(wire), creation: record.creation, generation: record.generation)
            dependency = newlyFrozenCreation?.id
        }
        var capturedEditor = fields; capturedEditor["mobileCommandSource"] = nil
        let id = UUID().uuidString.lowercased()
        let command = StudyCommand(id: id, sourceId: noteId, action: action, targetId: target, expectedRevision: Int(revision),
            sourceFingerprint: fingerprint, input: .object(input), sourceEditor: .object(capturedEditor), sourceNote: note, sourcePlacements: placements,
            targetEditor: target.map { _ in .object(targetEditor) }, capturedGeneration: records[noteId]?.generation ?? 0,
            dependencyRequestId: dependency, needsCreation: needsCreation, state: .pending, createdAt: Date())
        guard try JSONEncoder.nodus.encode(JSONValue.object(input)).count <= Self.maximumRequestBytes - 65_536 else { throw DesktopBridgeError.malformedResponse }
        if let newlyFrozenCreation, var record = records[noteId] { record.sending = newlyFrozenCreation; records[noteId] = record }
        studyCommands[id] = command
        do { try await persist() } catch {
            studyCommands[id] = nil
            if newlyFrozenCreation != nil, var record = records[noteId], record.sending?.id == dependency { record.sending = nil; records[noteId] = record }
            throw error
        }
        return action == "duplicate" ? studyCommandNote(command) : .null
    }
    /// Block identities are global links. A local copy receives its own ids,
    /// including academic evidence references and structured footnote blocks.
    private static func cloneStudyEditor(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var ids: [String: String] = [:]
        func clone(_ value: JSONValue) -> JSONValue {
            guard let blocks = value.arrayValue else { return value }
            return .array(blocks.map { block in
                guard var fields = block.objectValue else { return block }
                if let old = fields["id"]?.stringValue { let id = UUID().uuidString.lowercased(); ids[old] = id; fields["id"] = .string(id) }
                if let children = fields["children"] { fields["children"] = clone(children) }
                return .object(fields)
            })
        }
        var result = fields
        if let native = result["nativeDocument"] { result["nativeDocument"] = clone(native) }
        if var metadata = result["academicMetadata"]?.objectValue {
            if var notes = metadata["notes"]?.objectValue {
                for key in notes.keys {
                    guard var note = notes[key]?.objectValue, let document = note["document"] else { continue }
                    note["document"] = clone(document); notes[key] = .object(note)
                }
                metadata["notes"] = .object(notes)
            }
            if let evidence = metadata["evidence"]?.arrayValue {
                metadata["evidence"] = .array(evidence.map { value in
                    guard var item = value.objectValue, let old = item["blockId"]?.stringValue, let id = ids[old] else { return value }
                    item["blockId"] = .string(id); return .object(item)
                })
            }
            result["academicMetadata"] = .object(metadata)
        }
        return result
    }
    private func studyCommandNote(_ command: StudyCommand) -> JSONValue {
        var note = command.sourceNote.objectValue ?? [:]
        let editor = (command.targetId == nil ? command.sourceEditor : command.targetEditor)?.objectValue ?? [:]
        let id = command.targetId ?? command.sourceId
        note["id"] = .string(id); note["title"] = editor["documentTitle"]; note["contentMarkdown"] = editor["contentMarkdown"]
        note["editorRevision"] = editor["revision"]; note["mobileSyncState"] = .string(command.state.rawValue)
        note["mobileSyncIssue"] = command.issue.map(JSONValue.string) ?? .null
        if command.targetId != nil {
            note["shortId"] = nil; note["deletedAt"] = .null; note["archivedAt"] = .null; note["favorite"] = .bool(false)
            note["createdAt"] = .string(command.createdAt.ISO8601Format()); note["updatedAt"] = note["createdAt"]
            note["mobileStudyPlacements"] = command.sourcePlacements
        } else if command.cancelled != true { note["deletedAt"] = .string(command.createdAt.ISO8601Format()) }
        return .object(note)
    }
    private func synchronizeStudyCommands(send: @Sendable (Request) async throws -> JSONValue) async throws {
        for key in studyCommands.values.sorted(by: { $0.createdAt < $1.createdAt }).map(\.id) {
            guard var command = studyCommands[key], command.state == .pending, command.cancelled != true else { continue }
            // A source identity must exist canonically, and an already sent save
            // must be acknowledged before this command can freeze its revision.
            guard command.dependencyRequestId == nil, !command.needsCreation else { continue }
            if command.sending == nil {
                guard let fingerprint = command.sourceFingerprint else { throw DesktopBridgeError.malformedResponse }
                var input = command.input.objectValue!; input["expectedRevision"] = .int(Int64(command.expectedRevision))
                var action: [String: JSONValue] = ["action": .string(command.action), "sourceFingerprint": .string(fingerprint)]
                if let target = command.targetId { action["targetId"] = .string(target) }
                command.sending = Request(id: command.id, noteId: command.sourceId, input: .object(input), command: .object(action), generation: command.capturedGeneration)
                studyCommands[key] = command; try await persist()
            }
            let request = command.sending!
            let response: JSONValue
            do { response = try await send(request) }
            catch {
                guard var latest = studyCommands[key] else { throw error }
                if let api = error as? APIError, ["revision_conflict", "source_conflict"].contains(api.code), let remote = api.details["remote"] {
                    latest.state = .conflict; latest.remote = remote
                } else if !Self.isTransportLoss(error) { latest.state = .blocked }
                latest.issue = error.localizedDescription; studyCommands[key] = latest; try await persist(); throw error
            }
            guard response.objectValue?["id"] == .string(request.id), let committed = response.objectValue?["editorData"],
                  let revision = committed.objectValue?["revision"]?.intValue, revision >= 0,
                  let sourceNote = response.objectValue?["note"], sourceNote.objectValue?["id"] == .string(command.sourceId),
                  let result = response.objectValue?["commandResult"]?.objectValue,
                  Self.completeStudyCommandEditor(committed, noteId: command.sourceId) else { throw DesktopBridgeError.malformedResponse }
            if let target = command.targetId {
                guard result["document"]?.objectValue?["id"] == .string(target), let editor = result["editorData"],
                      Self.completeStudyCommandEditor(editor, noteId: target) else { throw DesktopBridgeError.malformedResponse }
            } else {
                guard result["document"]?.objectValue?["id"] == .string(command.sourceId), sourceNote.objectValue?["deletedAt"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
            }
            authored[command.sourceId] = Authored(editorData: committed, note: enrichedStudyNote(sourceNote, editor: committed))
            baselines[command.sourceId] = committed
            if var sourceDraft = records[command.sourceId] {
                let draft = sourceDraft.draft.objectValue ?? [:]
                var currentDraft: [String: JSONValue] = [:], capturedDraft = command.input.objectValue ?? [:]
                for key in Set(draft.keys).union(capturedDraft.keys) where !["expectedRevision", "reason"].contains(key) {
                    currentDraft[key] = draft[key] ?? sourceDraft.baseline.objectValue?[key == "title" ? "documentTitle" : key]
                }
                capturedDraft["expectedRevision"] = nil; capturedDraft["reason"] = nil
                if sourceDraft.generation <= command.capturedGeneration || currentDraft == capturedDraft { records[command.sourceId] = nil }
                else {
                    sourceDraft.baseline = committed; sourceDraft.sending = nil; sourceDraft.state = .pending; sourceDraft.remote = nil; sourceDraft.issue = nil
                    records[command.sourceId] = sourceDraft
                }
            }
            acknowledgedLocalRevisions[command.sourceId] = -command.capturedGeneration
            if let target = command.targetId {
                guard let note = result["document"], note.objectValue?["id"] == .string(target),
                      let editor = result["editorData"], editor.objectValue?["revision"]?.intValue.map({ $0 >= 0 }) == true else { throw DesktopBridgeError.malformedResponse }
                let enriched = enrichedStudyNote(note, editor: editor)
                authored[target] = Authored(editorData: editor, note: enriched); baselines[target] = editor
                if var targetDraft = records[target] { targetDraft.baseline = editor; targetDraft.createdNote = enriched; records[target] = targetDraft }
                try await cache.store(JSONEncoder.nodus.encode(editor), vaultId: vaultId, domain: .corpus, recordId: Self.operationKey(kind.editorMethod, [.string(target)]))
            }
            try await cache.store(JSONEncoder.nodus.encode(committed), vaultId: vaultId, domain: .corpus, recordId: Self.operationKey(kind.editorMethod, [.string(command.sourceId)]))
            // Retire only after the canonical source and target are durable.
            try await persist(); studyCommands[key] = nil
            do { try await persist() } catch { studyCommands[key] = command; throw error }
        }
    }
    private static func completeStudyCommandEditor(_ editor: JSONValue, noteId: String) -> Bool {
        guard let fields = editor.objectValue, fields["documentTitle"]?.stringValue != nil, fields["contentMarkdown"]?.stringValue != nil,
              fields["revision"]?.intValue.map({ $0 >= 0 }) == true,
              let source = fields["mobileCommandSource"]?.objectValue, source["version"] == .int(1),
              source["document"]?.objectValue?["id"] == .string(noteId), source["placements"]?.arrayValue != nil,
              let hash = source["fingerprint"]?.stringValue, hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return false }
        return true
    }
    private func enrichedStudyNote(_ note: JSONValue, editor: JSONValue) -> JSONValue {
        guard var fields = note.objectValue else { return note }
        if let placements = editor.objectValue?["mobileCommandSource"]?.objectValue?["placements"] { fields["mobileStudyPlacements"] = placements }
        return .object(fields)
    }

    public func createManualIdea(input: JSONValue) async throws -> JSONValue {
        guard var fields = input.objectValue, fields.keys.allSatisfy({ ["title", "folderId"].contains($0) }) else { throw DesktopBridgeError.malformedResponse }
        if fields["title"] == nil { fields["title"] = .string("Idea sin título") }
        fields["content"] = .string(""); fields["kind"] = .string("idea")
        let ideaId = "manual-\(UUID().uuidString)"
        let note = try await createDocument(input: .object(fields), ideaId: ideaId)
        return .object(["note": note, "globalId": .string(ideaId)])
    }
    /// A newly authored, not-yet-confirmed idea has a complete local dossier.
    /// Existing corpus dossiers continue through their authenticated query cache.
    public func pendingIdeaDetail(globalId: String, includeConfirmed: Bool = false) -> JSONValue? {
        let pendingId = records.keys.first(where: {
            let source = records[$0]?.createdNote?.objectValue?["source"]?.objectValue
            return records[$0]?.creation?.objectValue?["globalId"] == .string(globalId)
                && source?["note"] == .string("manual-idea") && source?["ref"] == .string(globalId)
        })
        let confirmedId = includeConfirmed ? authored.keys.first(where: {
            let note = authored[$0]?.note?.objectValue, source = note?["source"]?.objectValue
            return note?["kind"] == .string("idea") && Self.isVisibleNote(authored[$0]!.note!)
                && source?["note"] == .string("manual-idea") && source?["ref"] == .string(globalId)
        }) : nil
        guard let id = pendingId ?? confirmedId,
              let note = (records[id]?.createdNote ?? authored[id]?.note)?.objectValue,
              let editor = (editorData(noteId: id) ?? confirmedEditorData(noteId: id))?.objectValue else { return nil }
        var idea: [String: JSONValue] = ["global_id": .string(globalId), "type": .string("claim"),
            "label": editor["documentTitle"]!, "statement": editor["contentMarkdown"]!, "embedding": .null,
            "created_at": note["createdAt"] ?? .null,
            "mobileSyncState": editor["mobileSyncState"] ?? .null,
            "mobileSyncIssue": editor["mobileSyncIssue"] ?? .null]
        if pendingId == nil { idea["mobileSourceScope"] = .string("authoredText") }
        return .object(["idea": .object(idea), "themes": .array([]), "occurrences": .array([]),
            "evidence": .array([]), "gaps": .array([]), "externalRefs": .array([])])
    }
    /// A projection of genuine local authorship, with no fabricated evidence or
    /// derived relations. Durable drafts remain separate from expiring downloads.
    public func pendingIdeaCopy(includeConfirmed: Bool = false) -> JSONValue? {
        var ids = Set(records.values.compactMap { record -> String? in
            guard let source = record.createdNote?.objectValue?["source"]?.objectValue,
                  source["note"] == .string("manual-idea"),
                  record.creation?.objectValue?["globalId"] == source["ref"] else { return nil }
            return source["ref"]?.stringValue
        })
        if includeConfirmed {
            for source in authored.values {
                let note = source.note?.objectValue, provenance = note?["source"]?.objectValue
                if note?["kind"] == .string("idea"), provenance?["note"] == .string("manual-idea"),
                   let id = provenance?["ref"]?.stringValue, Self.isVisibleNote(source.note!) { ids.insert(id) }
            }
        }
        var entries: [JSONValue] = [], nodes: [JSONValue] = []
        for id in ids.sorted() {
            guard let detail = pendingIdeaDetail(globalId: id, includeConfirmed: includeConfirmed), let idea = detail.objectValue?["idea"]?.objectValue else { continue }
            var native = detail.objectValue!; native["relations"] = .array([]); native["revision"] = .null
            entries.append(.object(["summary": .object(["id": .string(id), "label": idea["label"]!, "statement": idea["statement"]!, "type": .string("claim"),
                "workCount": .int(0), "connectionCount": .int(0), "maxConfidence": .double(0), "themes": .array([]), "mobileSourceScope": idea["mobileSourceScope"] ?? .null]),
                "detail": detail, "nativeDetail": .object(native), "connections": .array([])]))
            nodes.append(.object(["id": .string(id), "label": idea["label"]!, "statement": idea["statement"]!, "type": .string("claim"),
                "workCount": .int(0), "workIds": .array([]), "maxConfidence": .double(0), "createdAt": idea["created_at"] ?? .null,
                "themes": .array([]), "authors": .array([]), "years": .array([]), "read": .bool(false), "mobileSourceScope": idea["mobileSourceScope"] ?? .null]))
        }
        guard !entries.isEmpty else { return nil }
        return .object(["version": .int(1), "entries": .array(entries), "graph": .object(["nodes": .array(nodes), "edges": .array([])]),
            "themes": .array([]), "edgeDetails": .array([])])
    }
    private func createDocument(input: JSONValue, ideaId: String?) async throws -> JSONValue {
        guard kind == .workspaceNote else { throw DesktopBridgeError.permissionDenied }
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
        guard try JSONEncoder.nodus.encode(input).count <= Self.maximumRequestBytes - 65_536 else {
            throw APIError(status: 413, code: "workspace_edit_too_large", message: "La nota y sus archivos superan el tamaño permitido para sincronizar. Reduce los archivos adjuntos; el borrador anterior se conserva.")
        }
        if studyCommands.values.contains(where: { $0.sourceId == noteId && $0.action == "trash" && $0.cancelled != true }) {
            throw APIError(status: 409, code: "study_document_pending_trash", message: "El documento está pendiente de enviarse a la papelera. Resuelve esa solicitud antes de seguir editando.")
        }
        guard let fields = input.objectValue, fields["title"]?.stringValue != nil,
              fields["contentMarkdown"]?.stringValue != nil,
              let expected = fields["expectedRevision"]?.intValue,
              let baseline = records[noteId]?.baseline ?? baselines[noteId] ?? studyCommands.values.first(where: { $0.targetId == noteId })?.targetEditor ?? studyCommands.values.first(where: { $0.sourceId == noteId })?.sourceEditor,
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
        if studyCommands.values.contains(where: { $0.targetId == noteId && $0.cancelled == true }) {
            record.state = .blocked; record.issue = "La copia local se conserva, pero su duplicación fue descartada."
        }
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
        if kind == .studyDocument { note["contentMarkdown"] = editor["contentMarkdown"]; note["favorite"] = .bool(false) }
        return .object(note)
    }
    /// Keeps a stable create identity and receipt before the editor reports success.
    public func enqueueStudyAnnotation(documentId: String, method: String, annotationId: String? = nil, patch: JSONValue? = nil) async throws -> JSONValue {
        guard let baseline = records[documentId]?.baseline ?? baselines[documentId] ?? authored[documentId]?.editorData ?? annotationCommands.values.first(where: { $0.documentId == documentId }).flatMap({ annotationSource($0) }),
              let revision = baseline.objectValue?["revision"].flatMap(CompanionStudyAnnotation.exactInteger),
              baseline.objectValue?["annotations"]?.arrayValue != nil else { throw APIError(status: 409, code: "study_annotation_source_missing", message: "Descarga el documento completo antes de editar sus comentarios sin conexión.") }
        guard !studyCommands.values.contains(where: { $0.sourceId == documentId || $0.targetId == documentId }) else { throw APIError(status: 409, code: "study_command_pending", message: "Espera a confirmar la operación pendiente de este documento.") }
        let actions = kind == .studyDocument
            ? ["createStudyAnnotation": "annotationCreate", "updateStudyAnnotation": "annotationUpdate", "deleteStudyAnnotation": "annotationDelete"]
            : ["createWorkspaceAnnotation": "annotationCreate", "updateWorkspaceAnnotation": "annotationUpdate", "deleteWorkspaceAnnotation": "annotationDelete"]
        guard let action = actions[method] else { throw DesktopBridgeError.malformedResponse }
        let target = annotationId ?? UUID().uuidString.lowercased()
        let predecessor = annotationCommands.values.filter { $0.command.objectValue?["annotationId"] == .string(target) }.sorted { $0.createdAt < $1.createdAt }.last
        let expected = predecessor?.projected ?? baseline.objectValue?["annotations"]?.arrayValue?.first { $0.objectValue?["id"] == .string(target) }
        let command = try CompanionStudyAnnotation.command(action: action, id: target, expected: expected, patch: patch)
        let createdAt = Date(), id = UUID().uuidString.lowercased()
        let projected = CompanionStudyAnnotation.projected(command: command, documentId: documentId, timestamp: createdAt.ISO8601Format())
        var sourceFields = baseline.objectValue!
        if let record = records[documentId] {
            for (key, value) in record.draft.objectValue ?? [:] where !["expectedRevision", "reason"].contains(key) { sourceFields[key == "title" ? "documentTitle" : key] = value }
            sourceFields["mobileSourceGeneration"] = .int(Int64(record.generation))
        }
        let sourceSnapshot = JSONValue.object(sourceFields)
        guard try JSONEncoder.nodus.encode(command).count <= Self.maximumRequestBytes,
              try JSONEncoder.nodus.encode(sourceSnapshot).count <= 50 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        let sourceKey: String
        if let existing = annotationSources.first(where: { $0.value == sourceSnapshot }) { sourceKey = existing.key }
        else {
            sourceKey = SHA256.hash(data: try JSONEncoder.nodus.encode(sourceSnapshot)).map { String(format: "%02x", $0) }.joined()
            annotationSources[sourceKey] = sourceSnapshot
        }
        let item = AnnotationCommand(id: id, documentId: documentId, command: command, dependencyId: predecessor?.id, projected: projected,
            sourceRevision: Int(revision), sourceGeneration: records[documentId]?.generation, sourceEditor: nil, sourceKey: sourceKey, state: .pending, createdAt: createdAt)
        annotationCommands[id] = item
        do { try await persist() } catch { annotationCommands[id] = nil; throw error }
        return projected ?? .null
    }
    public func enqueueWorkspaceAnnotation(noteId: String, method: String, annotationId: String? = nil, patch: JSONValue? = nil) async throws -> JSONValue {
        guard kind == .workspaceNote else { throw DesktopBridgeError.permissionDenied }
        return try await enqueueStudyAnnotation(documentId: noteId, method: method, annotationId: annotationId, patch: patch)
    }
    public func workspaceAnnotationDocumentId(annotationId: String) -> String? {
        guard kind == .workspaceNote else { return nil }
        return studyAnnotationDocumentId(annotationId: annotationId)
    }
    /// A downloaded canonical version becomes an ordinary durable native save;
    /// no live restore RPC or Mac version identity is invented.
    public func restoreWorkspaceVersion(noteId: String, versionId: String) async throws -> JSONValue {
        guard kind == .workspaceNote,
              let current = editorData(noteId: noteId) ?? baselines[noteId] ?? authored[noteId]?.editorData,
              let version = current.objectValue?["versions"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(versionId) })?.objectValue,
              let title = version["title"]?.stringValue, let content = version["contentMarkdown"]?.stringValue,
              let revision = current.objectValue?["revision"] else { throw APIError(status: 409, code: "workspace_version_not_downloaded", message: "Esta versión no está incluida en la copia del dispositivo.") }
        var input: [String: JSONValue] = ["title": .string(title), "contentMarkdown": .string(content), "expectedRevision": revision, "reason": .string("restore")]
        for key in ["nativeDocument", "schemaVersion", "academicMetadata", "style"] {
            if let value = version[key], key != "nativeDocument" || value != .null { input[key] = value }
        }
        return try await save(noteId: noteId, input: .object(input))
    }
    private func annotationSource(_ item: AnnotationCommand) -> JSONValue? { item.sourceKey.flatMap { annotationSources[$0] } ?? item.sourceEditor }
    public func studyAnnotationDocumentId(annotationId: String) -> String? {
        let ids = Set(baselines.keys).union(authored.keys).union(records.keys).union(annotationCommands.values.map(\.documentId))
        return ids.first { id in (editorData(noteId: id) ?? baselines[id] ?? authored[id]?.editorData)?.objectValue?["annotations"]?.arrayValue?.contains { $0.objectValue?["id"] == .string(annotationId) } == true }
    }
    private func synchronizeAnnotations(send: @Sendable (Request) async throws -> JSONValue) async throws {
        for key in annotationCommands.values.sorted(by: { $0.createdAt < $1.createdAt }).map(\.id) {
            guard var item = annotationCommands[key], item.state == .pending else { continue }
            if item.sourceGeneration != nil || item.dependencyId != nil { continue }
            if item.sending == nil {
                // Annotation packets never save content; only the revision is a
                // source precondition. Full native/body/assets stay in the shared local snapshot.
                var input: [String: JSONValue] = ["title": annotationSource(item)?.objectValue?["documentTitle"] ?? .string(""), "contentMarkdown": .string(""), "expectedRevision": .int(Int64(item.sourceRevision))]
                input["reason"] = .string("annotation")
                item.sending = Request(id: item.id, noteId: item.documentId, input: .object(input), command: item.command, generation: 0)
                guard try JSONEncoder.nodus.encode(item.sending).count <= Self.maximumRequestBytes else { throw APIError(status: 413, code: "study_edit_too_large", message: "Este documento supera el límite de sincronización móvil.") }
                annotationCommands[key] = item; try await persist()
            }
            let request = item.sending!
            let response: JSONValue
            do { response = try await send(request) }
            catch {
                guard var latest = annotationCommands[key] else { throw error }
                if let api = error as? APIError, ["revision_conflict", "annotation_conflict"].contains(api.code), let remote = api.details["remote"] { latest.state = .conflict; latest.remote = remote }
                else if !Self.isTransportLoss(error) { latest.state = .blocked }
                latest.issue = error.localizedDescription; annotationCommands[key] = latest; try await persist(); throw error
            }
            guard response.objectValue?["id"] == .string(request.id), let editor = response.objectValue?["editorData"],
                  editor.objectValue?["revision"] == .int(Int64(item.sourceRevision)), let rows = editor.objectValue?["annotations"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            let target = item.command.objectValue?["annotationId"]
            guard item.command.objectValue?["action"] == .string("annotationDelete") ? !rows.contains(where: { $0.objectValue?["id"] == target }) : rows.contains(where: { $0.objectValue?["id"] == target }) else { throw DesktopBridgeError.malformedResponse }
            try await cache.store(JSONEncoder.nodus.encode(editor), vaultId: vaultId, domain: .corpus, recordId: Self.operationKey(kind.editorMethod, [.string(item.documentId)]))
            baselines[item.documentId] = editor
            authored[item.documentId] = Authored(editorData: editor, note: response.objectValue?["note"] ?? authored[item.documentId]?.note)
            if var record = records[item.documentId] { record.baseline = editor; records[item.documentId] = record }
            for dependentKey in annotationCommands.keys {
                guard var dependent = annotationCommands[dependentKey], dependent.dependencyId == item.id,
                      dependent.sending == nil, var fields = dependent.command.objectValue else { continue }
                fields["expectedAnnotation"] = rows.first { $0.objectValue?["id"] == target } ?? .null
                dependent.command = .object(fields); dependent.dependencyId = nil
                annotationCommands[dependentKey] = dependent
            }
            annotationCommands[key] = nil
            do { try await persist() } catch { annotationCommands[key] = item; throw error }
        }
    }
    public func pendingCount() -> Int { records.values.filter { $0.state == .pending }.count + studyCommands.values.filter { $0.state == .pending && $0.cancelled != true }.count + annotationCommands.values.filter { $0.state == .pending }.count }
    public func synchronize(send: @Sendable (Request) async throws -> JSONValue) async throws {
        guard !synchronizing else { return }
        synchronizing = true; defer { synchronizing = false }
        try await synchronizeEdits(send: send)
        try await synchronizeStudyCommands(send: send)
        try await synchronizeEdits(send: send)
        try await synchronizeAnnotations(send: send)
    }
    private func synchronizeEdits(send: @Sendable (Request) async throws -> JSONValue) async throws {
        for noteId in records.keys.sorted() {
            while var record = records[noteId], record.state == .pending {
                if record.sending == nil, studyCommands.values.contains(where: { $0.targetId == noteId || ($0.sourceId == noteId && $0.cancelled != true) }), record.creation == nil { break }
                if record.sending == nil {
                    var wire = record.draft.objectValue!
                    wire["expectedRevision"] = record.baseline.objectValue!["revision"]
                    record.sending = Request(id: UUID().uuidString, noteId: noteId, input: .object(wire), creation: record.creation, generation: record.generation)
                    records[noteId] = record; try await persist()
                }
                let request = record.sending!
                var response: JSONValue
                do { response = try await send(request) }
                catch {
                    guard var latest = records[noteId] else { throw error }
                    if let api = error as? APIError, api.code == "revision_conflict", let remote = api.details["remote"] {
                        latest.state = .conflict; latest.remote = remote; latest.generation += 1
                    } else if !Self.isTransportLoss(error) {
                        latest.state = .blocked; latest.generation += 1
                    }
                    latest.issue = error.localizedDescription; records[noteId] = latest
                    if latest.state != .pending {
                        for key in annotationCommands.keys {
                            guard var command = annotationCommands[key], command.documentId == noteId, command.sourceGeneration != nil else { continue }
                            command.state = latest.state; command.remote = latest.remote; command.issue = latest.issue; annotationCommands[key] = command
                        }
                        for key in studyCommands.keys {
                            guard var command = studyCommands[key], command.dependencyRequestId == request.id else { continue }
                            command.state = latest.state; command.remote = latest.remote; command.issue = latest.issue; studyCommands[key] = command
                        }
                    }
                    try await persist(); throw error
                }
                if kind == .studyDocument, var envelope = response.objectValue, var note = envelope["note"]?.objectValue {
                    note["mobileStudyPlacement"] = request.creation?.objectValue?["placement"] ?? records[noteId]?.createdNote?.objectValue?["mobileStudyPlacement"] ?? authored[noteId]?.note?.objectValue?["mobileStudyPlacement"]
                    envelope["note"] = enrichedStudyNote(.object(note), editor: envelope["editorData"] ?? .null); response = .object(envelope)
                }
                guard response.objectValue?["id"]?.stringValue == request.id,
                      let committed = response.objectValue?["editorData"],
                      let revision = committed.objectValue?["revision"]?.intValue, revision >= 0,
                      records[noteId] != nil else { throw DesktopBridgeError.malformedResponse }
                guard committed.objectValue?["documentTitle"]?.stringValue != nil, committed.objectValue?["contentMarkdown"]?.stringValue != nil,
                      response.objectValue?["note"] == nil || response.objectValue?["note"]?.objectValue?["id"] == .string(noteId) else { throw DesktopBridgeError.malformedResponse }
                if request.creation != nil || records[noteId]?.createdNote != nil {
                    guard let note = response.objectValue?["note"], note.objectValue?["id"]?.stringValue == noteId else { throw DesktopBridgeError.malformedResponse }
                    if let globalId = request.creation?.objectValue?["globalId"] {
                        guard note.objectValue?["kind"] == .string("idea"),
                              note.objectValue?["source"]?.objectValue?["ref"] == globalId,
                              note.objectValue?["source"]?.objectValue?["note"] == .string("manual-idea") else { throw DesktopBridgeError.malformedResponse }
                    }
                    authored[noteId] = Authored(editorData: committed, note: note); try await persist()
                    // A confirmed new document must remain discoverable after the
                    // queue retires, including when its selected catalogue predates it.
                    for args: [JSONValue] in kind == .workspaceNote ? [[], [.bool(true)]] : [] {
                        let key = try Self.operationKey("getNotesTree", args)
                        if let data = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key),
                           var tree = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue,
                           var notes = tree["notes"]?.arrayValue {
                            notes.removeAll { $0.objectValue?["id"]?.stringValue == noteId }; notes.append(note)
                            tree["notes"] = .array(notes)
                            try await cache.store(JSONEncoder.nodus.encode(JSONValue.object(tree)), vaultId: vaultId, domain: .corpus, recordId: key)
                        }
                    }
                } else {
                    authored[noteId] = Authored(editorData: committed, note: response.objectValue?["note"] ?? authored[noteId]?.note ?? knownNotes[noteId])
                    try await persist()
                }
                // Make a confirmed document consultable before retiring its
                // durable queue. Failure here leaves the same replayable receipt.
                try await cache.store(JSONEncoder.nodus.encode(committed), vaultId: vaultId, domain: .corpus,
                                      recordId: Self.operationKey(kind.editorMethod, [.string(noteId)]))
                // Disk writes await another actor. An autosave can arrive during
                // that wait, so read its latest generation after storing the ack.
                guard var latest = records[noteId], latest.sending?.id == request.id else { throw DesktopBridgeError.malformedResponse }
                for key in studyCommands.keys {
                    guard var command = studyCommands[key], command.dependencyRequestId == request.id else { continue }
                    command.expectedRevision = Int(revision)
                    if command.needsCreation {
                        guard let source = committed.objectValue?["mobileCommandSource"]?.objectValue,
                              let fingerprint = source["fingerprint"]?.stringValue,
                              let note = source["document"] else { throw DesktopBridgeError.malformedResponse }
                        command.sourceFingerprint = fingerprint; command.sourceNote = note; command.sourcePlacements = source["placements"] ?? .array([])
                        command.needsCreation = false
                    }
                    command.dependencyRequestId = nil; studyCommands[key] = command
                }
                for key in annotationCommands.keys {
                    guard var command = annotationCommands[key], command.documentId == noteId, command.sending == nil,
                          command.sourceGeneration == request.generation else { continue }
                    command.sourceRevision = Int(revision); command.sourceGeneration = nil; annotationCommands[key] = command
                }
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
        if let item = annotationCommands.values.first(where: { $0.documentId == noteId && $0.state == .conflict }), let remote = item.remote {
            if keepMobile {
                guard remote.objectValue?["revision"] == .int(Int64(item.sourceRevision)), item.command.objectValue?["action"] != .string("annotationCreate"),
                      var fields = item.command.objectValue else { throw APIError(status: 409, code: "study_annotation_anchor_conflict", message: "Abre la versión del Mac y vuelve a seleccionar el fragmento antes de aplicar este comentario. El cambio local se conserva.") }
                let target = fields["annotationId"]
                guard let annotation = remote.objectValue?["annotations"]?.arrayValue?.first(where: { $0.objectValue?["id"] == target }) else { throw APIError(status: 409, code: "study_annotation_unavailable", message: "Este comentario ya no está disponible en la versión del Mac. El cambio local se conserva.") }
                fields["expectedAnnotation"] = annotation
                var replacement = item; replacement.id = UUID().uuidString.lowercased(); replacement.command = .object(fields)
                replacement.projected = CompanionStudyAnnotation.projected(command: replacement.command, documentId: noteId, timestamp: Date().ISO8601Format())
                replacement.sending = nil; replacement.state = .pending; replacement.issue = nil; replacement.remote = nil
                let previous = annotationCommands
                annotationCommands[item.id] = nil; annotationCommands[replacement.id] = replacement
                for key in annotationCommands.keys where annotationCommands[key]?.dependencyId == item.id { annotationCommands[key]?.dependencyId = replacement.id }
                do { try await persist() } catch { annotationCommands = previous; throw error }
                return editorData(noteId: noteId) ?? remote
            }
            try await cache.store(JSONEncoder.nodus.encode(remote), vaultId: vaultId, domain: .corpus, recordId: Self.operationKey(kind.editorMethod, [.string(noteId)]))
            baselines[noteId] = remote
            if var owned = authored[noteId] { owned.editorData = remote; authored[noteId] = owned }
            let previous = annotationCommands, previousRecord = records[noteId]
            if records[noteId]?.state == .conflict { records[noteId] = nil }
            annotationCommands = annotationCommands.filter { $0.value.documentId != noteId }
            do { try await persist() } catch { annotationCommands = previous; records[noteId] = previousRecord; throw error }
            try await seed(noteId: noteId, editorData: remote)
            return editorData(noteId: noteId) ?? remote
        }

        if let key = studyCommands.keys.first(where: { studyCommands[$0]?.sourceId == noteId || studyCommands[$0]?.targetId == noteId }),
           var command = studyCommands[key], command.state == .conflict, let remote = command.remote,
           let revision = remote.objectValue?["revision"]?.intValue, revision >= 0,
           let source = remote.objectValue?["mobileCommandSource"]?.objectValue,
           let fingerprint = source["fingerprint"]?.stringValue, let note = source["document"] {
            baselines[command.sourceId] = remote
            authored[command.sourceId] = Authored(editorData: remote, note: enrichedStudyNote(note, editor: remote))
            if keepMobile {
                studyCommands[key] = nil; command.id = UUID().uuidString.lowercased()
                command.expectedRevision = revision; command.sourceFingerprint = fingerprint
                command.sourceNote = note; command.sourcePlacements = source["placements"] ?? .array([])
                command.sending = nil; command.remote = nil; command.issue = nil; command.state = .pending
                command.dependencyRequestId = nil; command.needsCreation = false
                studyCommands[command.id] = command
            } else {
                command.cancelled = true; command.state = .blocked; command.sending = nil
                command.issue = "La solicitud se descartó. El contenido de la copia local se conserva."
                studyCommands[key] = command; records[command.sourceId] = nil
                if let target = command.targetId, var draft = records[target] { draft.state = .blocked; draft.issue = command.issue; records[target] = draft }
            }
            try await persist()
            return editorData(noteId: noteId) ?? remote
        }
        guard var record = records[noteId], record.state == .conflict, let remote = record.remote,
              let revision = remote.objectValue?["revision"]?.intValue, revision >= 0,
              remote.objectValue?["documentTitle"]?.stringValue != nil,
              remote.objectValue?["contentMarkdown"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
        authored[noteId] = Authored(editorData: remote, note: authored[noteId]?.note ?? record.createdNote ?? knownNotes[noteId])
        try await cache.store(JSONEncoder.nodus.encode(remote), vaultId: vaultId, domain: .corpus,
                              recordId: Self.operationKey(kind.editorMethod, [.string(noteId)]))
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
        var storedCommands = annotationCommands, sources: [String: JSONValue] = [:]
        for key in storedCommands.keys {
            guard var item = storedCommands[key], let editor = annotationSource(item) else { throw DesktopBridgeError.malformedResponse }
            let sourceKey: String
            if let existing = item.sourceKey ?? sources.first(where: { $0.value == editor })?.key { sourceKey = existing }
            else { sourceKey = SHA256.hash(data: try JSONEncoder.nodus.encode(editor)).map { String(format: "%02x", $0) }.joined() }
            sources[sourceKey] = editor; item.sourceKey = sourceKey; item.sourceEditor = nil; storedCommands[key] = item
        }
        let bytes = try JSONEncoder.nodus.encode(StoredState(version: 2, vaultId: vaultId, records: records, authored: authored, folders: authoredFolders(), kind: kind, studyCommands: studyCommands, annotationCommands: storedCommands, annotationSources: sources))
        let previous = diskTask, id = UUID(), cache = self.cache, vault = vaultId, storage = kind.storageKey
        let task = Task {
            if let previous { _ = try? await previous.value }
            _ = try await cache.store(bytes, vaultId: vault, domain: .writing, recordId: storage)
        }
        diskTask = task; diskTaskId = id
        do { try await task.value }
        catch { if diskTaskId == id { diskTask = nil; diskTaskId = nil }; throw error }
        if diskTaskId == id { diskTask = nil; diskTaskId = nil }
        // Keep only snapshots still referenced by the current queue; an enqueue
        // may have arrived while the encrypted write awaited another actor.
        let referenced = Set(annotationCommands.values.compactMap(\.sourceKey))
        annotationSources = annotationSources.filter { referenced.contains($0.key) }
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
    public func outbox(pairingId: String, vaultId: String, kind: CompanionDocumentOutbox.Kind = .workspaceNote) async throws -> CompanionDocumentOutbox {
        let key = "\(pairingId)|\(vaultId)" + (kind == .workspaceNote ? "" : "|\(kind.rawValue)")
        if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId: pairingId)
            return try await CompanionDocumentOutbox(cache: cache, vaultId: vaultId,
                data: cache.data(vaultId: vaultId, domain: .writing, recordId: kind.storageKey), kind: kind)
        }
        stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
    public func forget(pairingId: String) {
        for key in stores.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { stores[key] = nil }
    }
}
