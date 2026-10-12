import Foundation
import Testing
@testable import NodusKit

@Suite("Structured companion document saves")
struct CompanionDocumentOutboxTests {
    private struct Fixture {
        let pairing = UUID().uuidString
        let directory: URL
        let keychain: KeychainStore
        let cache: PrivateBridgeCache
        init(readLimitBytes: Int = 0) throws {
            directory = .temporaryDirectory.appendingPathComponent("nodus-companion-\(pairing)")
            keychain = KeychainStore(service: "nodus.tests.companion.\(pairing)")
            cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain, readLimitBytes: readLimitBytes)
        }
        func open(kind: CompanionDocumentOutbox.Kind = .workspaceNote) async throws -> CompanionDocumentOutbox {
            try await CompanionDocumentOutbox(cache: cache, vaultId: "vault-a", data: cache.data(vaultId: "vault-a", domain: .writing, recordId: kind.storageKey), kind: kind)
        }
        func cleanup() {
            try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory)
        }
    }
    private static func editor(_ revision: Int = 7, text: String = "Original") -> JSONValue {
        .object(["revision": .int(Int64(revision)), "documentTitle": .string("Private document"), "contentMarkdown": .string(text),
                 "nativeDocument": .array([.object(["id": .string("table-1"), "type": .string("table"), "content": .object(["rows": .array([.string(text)])])])]),
                 "style": .object(["fontFamily": .string("serif")]), "annotations": .array([]), "versions": .array([])])
    }
    private static func input(_ revision: Int, text: String) -> JSONValue {
        .object(["expectedRevision": .int(Int64(revision)), "title": .string("Private document"), "contentMarkdown": .string(text),
                 "nativeDocument": editor(text: text).objectValue!["nativeDocument"]!, "schemaVersion": .int(2),
                 "academicMetadata": .object(["bibliography": .array([.string("Citation 2024")])]),
                 "style": .object(["fontFamily": .string("serif")]), "spellcheckLanguage": .string("es-ES")])
    }
    private static func receipt(_ request: CompanionDocumentOutbox.Request, revision: Int) -> JSONValue {
        .object(["id": .string(request.id), "editorData": editor(revision, text: request.input.objectValue!["contentMarkdown"]!.stringValue!)])
    }
    private actor Requests {
        var values: [CompanionDocumentOutbox.Request] = []
        func append(_ value: CompanionDocumentOutbox.Request) { values.append(value) }
        func all() -> [CompanionDocumentOutbox.Request] { values }
    }
    private static func studyEditor(_ id: String = "study-a", revision: Int = 7, text: String = "Original", fingerprint: String = String(repeating: "a", count: 64)) -> JSONValue {
        var value = editor(revision, text: text).objectValue!
        value["academicMetadata"] = .object(["bibliography": .array([.string("Citation 2024")])])
        value["schemaVersion"] = .int(2); value["spellcheckLanguage"] = .string("es-ES"); value["customDictionary"] = .array([.string("lemma")])
        value["mobileCommandSource"] = .object(["version": .int(1), "fingerprint": .string(fingerprint),
            "document": .object(["id": .string(id), "title": value["documentTitle"]!, "kind": .string("articulo"), "description": .string("Academic source"), "color": .string("indigo"), "deletedAt": .null, "archivedAt": .null]),
            "placements": .array([.object(["id": .string("place-a"), "document_id": .string(id), "course_id": .string("course-a"), "subject_id": .string("subject-a"), "position": .int(3)]),
                                  .object(["id": .string("place-b"), "document_id": .string(id), "course_id": .string("course-b"), "position": .int(8)])])])
        return .object(value)
    }
    private static func studyReceipt(_ request: CompanionDocumentOutbox.Request, revision: Int) -> JSONValue {
        var editor = studyEditor(request.noteId, revision: revision, text: request.input.objectValue!["contentMarkdown"]!.stringValue!).objectValue!
        for (key, value) in request.input.objectValue! where !["expectedRevision", "reason"].contains(key) { editor[key == "title" ? "documentTitle" : key] = value }
        var source = editor["mobileCommandSource"]!.objectValue!, note = source["document"]!.objectValue!
        note["title"] = editor["documentTitle"]; note["contentMarkdown"] = editor["contentMarkdown"]
        if request.command?.objectValue?["action"] == .string("trash") { note["deletedAt"] = .string("2026-10-12T15:00:00Z") }
        source["document"] = .object(note); editor["mobileCommandSource"] = .object(source)
        var response: [String: JSONValue] = ["id": .string(request.id), "note": .object(note), "editorData": .object(editor)]
        if let command = request.command?.objectValue {
            if let target = command["targetId"]?.stringValue {
                var copy = editor, copyNote = note
                copy["revision"] = .int(0); copy["documentTitle"] = .string(editor["documentTitle"]!.stringValue! + " (copia)")
                copyNote["id"] = .string(target); copyNote["title"] = copy["documentTitle"]
                var copySource = source; copySource["document"] = .object(copyNote)
                copySource["placements"] = .array((source["placements"]?.arrayValue ?? []).enumerated().map { index, value in
                    var placement = value.objectValue!; placement["document_id"] = .string(target); placement["id"] = .string("canonical-\(target)-\(index)")
                    return .object(placement)
                })
                copy["mobileCommandSource"] = .object(copySource)
                response["commandResult"] = .object(["document": .object(copyNote), "editorData": .object(copy)])
            } else { response["commandResult"] = .object(["document": .object(note)]) }
        }
        return .object(response)
    }

    @Test("one hundred same-source comments share one durable full source snapshot")
    func annotationSnapshotDeduplication() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let prose = String(repeating: "Exact source body. ", count: 30_000)
        var baseline = Self.studyEditor(text: prose).objectValue!
        baseline["nativeDocument"] = .array([.object(["id": .string("original-block"), "type": .string("paragraph"), "content": .string(prose), "originalAsset": .string("data:image/png;base64,EXACT-ASSET")])])
        let source = JSONValue.object(baseline)
        try await queue.seed(noteId: "study-a", editorData: source)
        for index in 0..<100 {
            _ = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: .object(["from": .int(0), "to": .int(5), "selectedText": .string("Exact"), "comment": .string("Comment \(index)")]))
        }
        let data = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.Kind.studyDocument.storageKey))
        let stored = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
        #expect(stored.objectValue?["annotationSources"]?.objectValue?.count == 1)
        #expect(stored.objectValue?["annotationCommands"]?.objectValue?.count == 100)
        #expect(stored.objectValue?["annotationCommands"]?.objectValue?.values.allSatisfy { $0.objectValue?["sourceEditor"] == nil } == true)
        #expect(data.count < (try JSONEncoder.nodus.encode(source).count) + 150_000)
        let reopened = try await fixture.open(kind: .studyDocument)
        let restored = try #require(await reopened.editorData(noteId: "study-a"))
        #expect(restored.objectValue?["annotations"]?.arrayValue?.count == 100)
        #expect(restored.objectValue?["contentMarkdown"] == .string(prose))
        #expect(restored.objectValue?["nativeDocument"] == source.objectValue?["nativeDocument"])
        #expect(restored.objectValue?["academicMetadata"] == source.objectValue?["academicMetadata"])
    }
    @Test("fractional, unsafe and malformed anchors are rejected before persistence")
    func annotationExactOffsets() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        let valid: [String: JSONValue] = ["from": .int(0), "to": .int(8), "selectedText": .string("Original"), "comment": .string("Exact")]
        for offset in [JSONValue.double(1.5), .double(.infinity), .int(Int64.max), .int(-1)] {
            var patch = valid; patch["from"] = offset
            await #expect(throws: DesktopBridgeError.self) { try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: .object(patch)) }
            patch = valid; patch["anchor"] = .object(["blockId": .string("table-1"), "from": offset, "to": .int(8)])
            await #expect(throws: DesktopBridgeError.self) { try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: .object(patch)) }
        }
        #expect(await queue.pendingCount() == 0)
    }
    @Test("offline annotations preserve multiple comments and exact native/academic source across replay")
    func annotationReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let baseline = Self.studyEditor()
        try await queue.seed(noteId: "study-a", editorData: baseline)
        let patch = JSONValue.object(["from": .int(0), "to": .int(8), "selectedText": .string("Original"), "comment": .string("First"), "locked": .bool(true), "anchor": .object(["blockId": .string("table-1"), "from": .int(0), "to": .int(8)])])
        let first = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: patch)
        let id = try #require(first.objectValue?["id"]?.stringValue)
        _ = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "updateStudyAnnotation", annotationId: id, patch: .object(["comment": .string("Edited locked comment"), "pinned": .bool(true), "resolved": .bool(true)]))
        _ = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: patch)
        await #expect(throws: APIError.self) { try await queue.enqueueStudyCommand(noteId: "study-a", action: "trash") }
        let local = try #require(await queue.editorData(noteId: "study-a"))
        #expect(local.objectValue?["annotations"]?.arrayValue?.count == 2)
        #expect(local.objectValue?["nativeDocument"] == baseline.objectValue?["nativeDocument"])
        #expect(local.objectValue?["academicMetadata"] == baseline.objectValue?["academicMetadata"])
        let sent = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await sent.append(request); throw URLError(.networkConnectionLost) } }
        let frozen = try #require(await sent.all().first)
        let reopened = try await fixture.open(kind: .studyDocument)
        #expect(await reopened.hasBaseline(noteId: "study-a"))
        #expect(await reopened.studyAnnotationDocumentId(annotationId: id) == "study-a")
        _ = try await reopened.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: patch)
        let server = AnnotationServer(baseline: baseline)
        try await reopened.synchronize { request in await sent.append(request); return await server.apply(request) }
        let requests = await sent.all()
        #expect(requests[1] == frozen)
        #expect(requests.count == 5)
        #expect(requests[2].command?.objectValue?["expectedAnnotation"]?.objectValue?["updatedAt"] == .string("canonical-time"))
        #expect(await reopened.pendingCount() == 0)
        let confirmed = try #require(await reopened.confirmedEditorData(noteId: "study-a"))
        #expect(confirmed.objectValue?["annotations"]?.arrayValue?.count == 3)
        #expect(confirmed.objectValue?["revision"] == .int(7))
        #expect(confirmed.objectValue?["nativeDocument"] == baseline.objectValue?["nativeDocument"])
        _ = try await reopened.enqueueStudyAnnotation(documentId: "study-a", method: "deleteStudyAnnotation", annotationId: id)
        try await reopened.synchronize { await server.apply($0) }
        #expect(await reopened.confirmedEditorData(noteId: "study-a")?.objectValue?["annotations"]?.arrayValue?.count == 2)
    }
    private actor AnnotationServer {
        var baseline: JSONValue
        init(baseline: JSONValue) { self.baseline = baseline }
        func apply(_ request: CompanionDocumentOutbox.Request) -> JSONValue {
            var editor = baseline.objectValue!
            let command = request.command!, id = command.objectValue!["annotationId"]!
            var rows = editor["annotations"]!.arrayValue!; rows.removeAll { $0.objectValue?["id"] == id }
            if let row = CompanionStudyAnnotation.projected(command: command, documentId: request.noteId, timestamp: "canonical-time") { rows.append(row) }
            editor["annotations"] = .array(rows); baseline = .object(editor)
            return .object(["id": .string(request.id), "editorData": baseline])
        }
    }
    @Test("explicitly keeping a comment after target conflict issues a fresh receipt without rebasing source anchors")
    func annotationTargetResolution() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let target = UUID().uuidString.lowercased()
        let original = JSONValue.object(["id": .string(target), "documentId": .string("study-a"), "comment": .string("Original comment"), "locked": .bool(true), "pinned": .bool(false), "from": .int(0), "to": .int(8), "selectedText": .string("Original")])
        var baseline = Self.studyEditor().objectValue!; baseline["annotations"] = .array([original])
        try await queue.seed(noteId: "study-a", editorData: .object(baseline))
        _ = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "updateStudyAnnotation", annotationId: target, patch: .object(["comment": .string("Local comment")]))
        var mac = original.objectValue!; mac["comment"] = .string("Mac comment"); mac["pinned"] = .bool(true)
        var remote = baseline; remote["annotations"] = .array([.object(mac)])
        let remoteValue = JSONValue.object(remote), sent = Requests()
        await #expect(throws: APIError.self) { try await queue.synchronize { request in await sent.append(request); throw APIError(status: 409, code: "annotation_conflict", message: "Mac changed comment", details: ["remote": remoteValue]) } }
        _ = try await queue.resolve(noteId: "study-a", keepMobile: true)
        let server = AnnotationServer(baseline: remoteValue)
        try await queue.synchronize { request in await sent.append(request); return await server.apply(request) }
        let packets = await sent.all()
        #expect(packets.count == 2); #expect(packets[0].id != packets[1].id)
        #expect(packets[1].command?.objectValue?["expectedAnnotation"] == .object(mac))
        let annotation = await queue.confirmedEditorData(noteId: "study-a")?.objectValue?["annotations"]?.arrayValue?.first
        #expect(annotation?.objectValue?["comment"] == .string("Local comment"))
        #expect(annotation?.objectValue?["pinned"] == .bool(true)); #expect(annotation?.objectValue?["locked"] == .bool(true))
    }
    @Test("annotation anchors advance only with the exact source-save generation and Mac changes remain explicit conflicts")
    func annotationSourceDependency() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "Captured source"))
        _ = try await queue.enqueueStudyAnnotation(documentId: "study-a", method: "createStudyAnnotation", patch: .object(["from": .int(0), "to": .int(8), "selectedText": .string("Captured"), "comment": .string("Check")]))
        let sent = Requests()
        await #expect(throws: APIError.self) {
            try await queue.synchronize { request in
                await sent.append(request)
                if request.command == nil { return Self.studyReceipt(request, revision: 8) }
                #expect(request.input.objectValue?["expectedRevision"] == .int(8))
                throw APIError(status: 409, code: "revision_conflict", message: "Mac changed source", details: ["remote": Self.studyEditor(revision: 9, text: "Mac source")])
            }
        }
        #expect(await sent.all().count == 2)
        #expect(await queue.editorData(noteId: "study-a")?.objectValue?["mobileSyncState"] == .string("conflict"))
        await #expect(throws: APIError.self) { try await queue.resolve(noteId: "study-a", keepMobile: true) }
        let chosen = try await queue.resolve(noteId: "study-a", keepMobile: false)
        #expect(chosen.objectValue?["contentMarkdown"] == .string("Mac source"))
        #expect(await queue.pendingCount() == 0)
    }
    @Test("offline duplication keeps structured metadata and placements and replays one identity after a lost acknowledgement")
    func studyDuplicateReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        let duplicate = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let target = try #require(duplicate.objectValue?["id"]?.stringValue)
        #expect(duplicate.objectValue?["kind"] == .string("articulo"))
        #expect(duplicate.objectValue?["description"] == .string("Academic source"))
        #expect(duplicate.objectValue?["mobileStudyPlacements"]?.arrayValue?.count == 2)
        let attempts = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await attempts.append(request); throw URLError(.networkConnectionLost) } }
        let reopened = try await fixture.open(kind: .studyDocument)
        let local = try #require(await reopened.editorData(noteId: target))
        #expect(local.objectValue?["academicMetadata"] == Self.studyEditor().objectValue?["academicMetadata"])
        #expect(local.objectValue?["nativeDocument"]?.arrayValue?.first?.objectValue?["id"] != Self.studyEditor().objectValue?["nativeDocument"]?.arrayValue?.first?.objectValue?["id"])
        #expect(local.objectValue?["nativeDocument"]?.arrayValue?.first?.objectValue?["content"] == Self.studyEditor().objectValue?["nativeDocument"]?.arrayValue?.first?.objectValue?["content"])
        #expect(local.objectValue?["customDictionary"] == .array([.string("lemma")]))
        let tables = await reopened.overlayStudyTables([:])
        #expect(tables["study_docs"]?.first { $0.string("id") == target }?.string("title") == "Private document (copia)")
        #expect(tables["study_placements"]?.count == 2)
        try await reopened.synchronize { request in await attempts.append(request); return Self.studyReceipt(request, revision: 8) }
        let sent = await attempts.all()
        #expect(sent.count == 2); #expect(sent[0] == sent[1]); #expect(sent[0].command?.objectValue?["targetId"] == .string(target))
        let final = try await fixture.open(kind: .studyDocument)
        #expect(await final.pendingCount() == 0)
        #expect(await final.confirmedEditorData(noteId: target)?.objectValue?["documentTitle"] == .string("Private document (copia)"))
        let finalPlacements = await final.overlayStudyTables([:], includeConfirmedEdits: true)["study_placements"] ?? []
        #expect(finalPlacements.count == 4)
        #expect(finalPlacements.filter { $0.string("document_id") == target }.allSatisfy { $0.string("id")?.hasPrefix("canonical-") == true })
    }
    @Test("an offline native copy remaps academic evidence and footnote blocks without changing their text")
    func studyDuplicateAcademicIds() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        var source = Self.studyEditor().objectValue!
        source["academicMetadata"] = .object(["formatVersion": .int(1), "style": .string("apa"), "locale": .string("es-ES"), "placement": .string("footnote"),
            "notes": .object(["note-a": .object(["placement": .string("footnote"), "document": .array([.object(["id": .string("footnote-source"), "type": .string("paragraph"), "content": .string("Private note")])])])]),
            "evidence": .array([.object(["id": .string("evidence-a"), "blockId": .string("table-1"), "text": .string("Protected evidence"), "status": .string("checked")])])])
        try await queue.seed(noteId: "study-a", editorData: .object(source))
        let copy = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let target = try #require(copy.objectValue?["id"]?.stringValue)
        let editor = try #require(await queue.editorData(noteId: target)?.objectValue)
        let clonedId = editor["nativeDocument"]?.arrayValue?.first?.objectValue?["id"]
        #expect(clonedId != .string("table-1"))
        #expect(editor["academicMetadata"]?.objectValue?["evidence"]?.arrayValue?.first?.objectValue?["blockId"] == clonedId)
        let footnote = editor["academicMetadata"]?.objectValue?["notes"]?.objectValue?["note-a"]?.objectValue?["document"]?.arrayValue?.first?.objectValue
        #expect(footnote?["id"] != .string("footnote-source")); #expect(footnote?["content"] == .string("Private note"))
    }

    @Test("authoritative snapshots cannot resurrect acknowledged copies or overwrite later Mac trash and metadata")
    func studyAuthoritativeProjection() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        let duplicate = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let target = try #require(duplicate.objectValue?["id"]?.stringValue)
        #expect(await queue.overlayStudyTables([:], authoritative: true)["study_docs"]?.contains { $0.string("id") == target } == true)
        try await queue.synchronize { request in Self.studyReceipt(request, revision: 8) }
        #expect(await queue.overlayStudyTables([:], authoritative: true)["study_docs"]?.isEmpty == true)
        let remote: [String: [Row]] = ["study_docs": [Row(["id": .string(target), "title": .string("Mac title"), "content_markdown": .string("Mac content"), "editor_revision": .int(11), "description": .string("Changed on Mac"), "deleted_at": .string("2026-10-12T16:00:00Z")])]]
        let projected = await queue.overlayStudyTables(remote, includeConfirmedEdits: true, authoritative: true)
        #expect(projected["study_docs"]?.first?.string("title") == "Mac title")
        #expect(projected["study_docs"]?.first?.string("description") == "Changed on Mac")
        #expect(projected["study_docs"]?.first?.string("deleted_at") != nil)
        #expect(await queue.overlayStudyTables([:], includeConfirmedEdits: true)["study_docs"]?.contains { $0.string("id") == target } == true)
    }

    @Test("duplication commits the captured pending draft atomically and orders later source and copy edits behind it")
    func studyDuplicatePendingEdits() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "At duplication"))
        let duplicate = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let target = try #require(duplicate.objectValue?["id"]?.stringValue)
        _ = try await queue.save(noteId: "study-a", input: Self.input(-1, text: "Later source edit"))
        _ = try await queue.save(noteId: target, input: Self.input(0, text: "Later copy edit"))
        let sent = Requests()
        try await queue.synchronize { request in
            await sent.append(request)
            return Self.studyReceipt(request, revision: request.command == nil ? (request.noteId == target ? 1 : 9) : 8)
        }
        let requests = await sent.all()
        #expect(requests.count == 3)
        #expect(requests[0].command?.objectValue?["action"] == .string("duplicate"))
        #expect(requests[0].input.objectValue?["contentMarkdown"] == .string("At duplication"))
        #expect(requests.first { $0.command == nil && $0.noteId == "study-a" }?.input.objectValue?["expectedRevision"] == .int(8))
        #expect(requests.first { $0.command == nil && $0.noteId == target }?.input.objectValue?["expectedRevision"] == .int(0))
        #expect(await queue.confirmedEditorData(noteId: "study-a")?.objectValue?["contentMarkdown"] == .string("Later source edit"))
        #expect(await queue.confirmedEditorData(noteId: target)?.objectValue?["contentMarkdown"] == .string("Later copy edit"))
    }
    @Test("trash is a durable tombstone and an explicit remote choice restores visibility after a source conflict")
    func studyTrashConflict() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "Before trash"))
        _ = try await queue.enqueueStudyCommand(noteId: "study-a", action: "trash")
        let source: [String: [Row]] = ["study_docs": [Row(["id": .string("study-a"), "title": .string("Original"), "deleted_at": .null])]]
        #expect(await queue.overlayStudyTables(source)["study_docs"]?.first?.string("deleted_at") != nil)
        let reopened = try await fixture.open(kind: .studyDocument)
        #expect(await reopened.overlayStudyTables(source)["study_docs"]?.first?.string("deleted_at") != nil)
        await #expect(throws: APIError.self) { try await reopened.synchronize { _ in throw APIError(status: 409, code: "source_conflict", message: "Placement changed", details: ["remote": Self.studyEditor(revision: 9, fingerprint: String(repeating: "b", count: 64))]) } }
        #expect(await reopened.editorData(noteId: "study-a")?.objectValue?["mobileSyncState"] == .string("conflict"))
        _ = try await reopened.resolve(noteId: "study-a", keepMobile: false)
        #expect(await reopened.overlayStudyTables(source, includeConfirmedEdits: true)["study_docs"]?.first?.string("deleted_at") == nil)
        #expect(await reopened.pendingCount() == 0)
    }
    @Test("new source duplication waits for its stable creation receipt and never invents a source identity")
    func studyDuplicateNewSource() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let document = try await queue.createStudyDocument(input: .object(["title": .string("New source"), "kind": .string("apunte")]))
        let source = try #require(document.objectValue?["id"]?.stringValue)
        _ = try await queue.save(noteId: source, input: Self.input(-1, text: "Captured before copy"))
        _ = try await queue.enqueueStudyCommand(noteId: source, action: "duplicate")
        let attempts = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await attempts.append(request); throw URLError(.timedOut) } }
        let reopened = try await fixture.open(kind: .studyDocument)
        try await reopened.synchronize { request in await attempts.append(request); return Self.studyReceipt(request, revision: request.creation == nil ? 2 : 1) }
        let requests = await attempts.all()
        #expect(requests.count == 3); #expect(requests[0] == requests[1])
        #expect(requests[0].creation != nil); #expect(requests[0].command == nil)
        #expect(requests[2].creation == nil); #expect(requests[2].command?.objectValue?["action"] == .string("duplicate"))
        #expect(requests[2].noteId == source); #expect(requests[2].input.objectValue?["expectedRevision"] == .int(1))
        #expect(requests[2].input.objectValue?["contentMarkdown"] == .string("Captured before copy"))
    }
    @Test("a command waits for an already frozen source save then uses its acknowledged revision exactly once")
    func studyDuplicateFrozenSource() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "Already sent"))
        let attempts = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await attempts.append(request); throw URLError(.networkConnectionLost) } }
        _ = try await queue.save(noteId: "study-a", input: Self.input(-1, text: "At duplication"))
        _ = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let reopened = try await fixture.open(kind: .studyDocument)
        try await reopened.synchronize { request in await attempts.append(request); return Self.studyReceipt(request, revision: request.command == nil ? 8 : 9) }
        let sent = await attempts.all()
        #expect(sent.count == 3); #expect(sent[0] == sent[1])
        #expect(sent[2].input.objectValue?["expectedRevision"] == .int(8))
        #expect(sent[2].input.objectValue?["contentMarkdown"] == .string("At duplication"))
        #expect(sent[2].command != nil); #expect(await reopened.pendingCount() == 0)
    }
    @Test("explicit command conflict resolution keeps the same target and issues a fresh receipt against the selected remote revision")
    func studyDuplicateConflictKeep() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "Captured copy"))
        let copy = try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate")
        let target = try #require(copy.objectValue?["id"]?.stringValue)
        let attempts = Requests()
        await #expect(throws: APIError.self) { try await queue.synchronize { request in
            await attempts.append(request)
            throw APIError(status: 409, code: "source_conflict", message: "Moved on Mac", details: ["remote": Self.studyEditor(revision: 9, text: "Mac text", fingerprint: String(repeating: "b", count: 64))])
        } }
        _ = try await queue.resolve(noteId: target, keepMobile: true)
        try await queue.synchronize { request in await attempts.append(request); return Self.studyReceipt(request, revision: 10) }
        let sent = await attempts.all()
        #expect(sent.count == 2); #expect(sent[0].id != sent[1].id)
        #expect(sent[0].command?.objectValue?["targetId"] == sent[1].command?.objectValue?["targetId"])
        #expect(sent[1].input.objectValue?["expectedRevision"] == .int(9))
        #expect(sent[1].command?.objectValue?["sourceFingerprint"] == .string(String(repeating: "b", count: 64)))
        #expect(sent[1].input.objectValue?["contentMarkdown"] == .string("Captured copy"))
        #expect(await queue.pendingCount() == 0)
    }

    @Test("a rejected new-source dependency retains a blocked local copy and cannot invent a Mac duplicate")
    func studyDuplicateBlockedCreation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let source = try await queue.createStudyDocument(input: .object(["title": .string("New source"), "kind": .string("apunte")]))
        let sourceId = try #require(source.objectValue?["id"]?.stringValue)
        let copy = try await queue.enqueueStudyCommand(noteId: sourceId, action: "duplicate")
        let target = try #require(copy.objectValue?["id"]?.stringValue)
        let sent = Requests()
        await #expect(throws: APIError.self) { try await queue.synchronize { request in
            await sent.append(request); throw APIError(status: 400, code: "placement_unavailable", message: "Destination no longer exists")
        } }
        let reopened = try await fixture.open(kind: .studyDocument)
        #expect(await reopened.editorData(noteId: target)?.objectValue?["mobileSyncState"] == .string("blocked"))
        try await reopened.synchronize { request in await sent.append(request); return Self.studyReceipt(request, revision: 1) }
        #expect(await sent.all().count == 1)
        #expect(await reopened.pendingCount() == 0)
        #expect(await reopened.overlayStudyTables([:])["study_docs"]?.contains { $0.string("id") == target } == true)
    }
    @Test("a later canonical restore and metadata edit replaces an acknowledged local trash when seeding its reader")
    func studyLaterRemoteMetadata() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.studyEditor())
        _ = try await queue.enqueueStudyCommand(noteId: "study-a", action: "trash")
        try await queue.synchronize { request in Self.studyReceipt(request, revision: 8) }
        #expect(await queue.overlayStudyTables([:], includeConfirmedEdits: true)["study_docs"]?.first?.string("deleted_at") != nil)
        var restored = Self.studyEditor(revision: 9, text: "Restored on Mac").objectValue!
        var source = restored["mobileCommandSource"]!.objectValue!, note = source["document"]!.objectValue!
        note["description"] = .string("New canonical metadata"); note["deletedAt"] = .null
        source["document"] = .object(note); restored["mobileCommandSource"] = .object(source)
        try await queue.seed(noteId: "study-a", editorData: .object(restored))
        let reopened = try await fixture.open(kind: .studyDocument)
        let row = await reopened.overlayStudyTables([:], includeConfirmedEdits: true)["study_docs"]?.first
        #expect(row?.string("deleted_at") == nil)
        #expect(row?.string("description") == "New canonical metadata")
        #expect(row?.string("content_markdown") == "Restored on Mac")
    }

    @Test("old downloads without complete command metadata fail explicitly and retain their ordinary editor draft")
    func studyOldDownloadCommandMissing() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        try await queue.seed(noteId: "study-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "study-a", input: Self.input(7, text: "Retained"))
        await #expect(throws: APIError.self) { try await queue.enqueueStudyCommand(noteId: "study-a", action: "duplicate") }
        #expect(await queue.editorData(noteId: "study-a")?.objectValue?["contentMarkdown"] == .string("Retained"))
        #expect(await queue.pendingCount() == 1)
    }

    private static let creationInput: JSONValue = .object(["title": .string("New offline document"), "content": .string(""),
        "kind": .string("markdown"), "folderId": .string("folder-a"), "tags": .array([.string("offline")])])
    @Test("new study documents retain identity, placement and edits across restart, retry and acknowledgement")
    func studyCreationReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let document = try await queue.createStudyDocument(input: .object(["title": .string("Nuevo apunte"), "kind": .string("apunte"), "placement": .object(["courseId": .string("course-a")])]))
        let id = try #require(document.objectValue?["id"]?.stringValue)
        #expect(UUID(uuidString: id) != nil)
        let initial = await queue.overlayStudyTables([:])
        #expect(initial["study_docs"]?.first?.string("title") == "Nuevo apunte")
        #expect(initial["study_placements"]?.first?.string("course_id") == "course-a")
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "Mi nuevo apunte"))
        let requests = Requests()
        do { try await queue.synchronize { request in await requests.append(request); throw URLError(.networkConnectionLost) }; Issue.record("Expected transport loss") }
        catch is URLError {}
        let reopened = try await fixture.open(kind: .studyDocument)
        try await reopened.synchronize { request in
            await requests.append(request)
            var result = Self.receipt(request, revision: 1).objectValue!
            result["note"] = .object(["id": .string(request.noteId), "title": .string("Private document"), "kind": .string("apunte")])
            return .object(result)
        }
        let sent = await requests.all()
        #expect(sent.count == 2 && sent[0] == sent[1])
        #expect(sent[0].creation?.objectValue?["placement"]?.objectValue?["courseId"] == .string("course-a"))
        #expect(sent[0].input.objectValue?["expectedRevision"] == .int(0))
        #expect(sent[0].input.objectValue?["contentMarkdown"] == .string("Mi nuevo apunte"))
        #expect(await reopened.pendingCount() == 0)
        let confirmed = try await fixture.open(kind: .studyDocument)
        let restored = await confirmed.overlayStudyTables([:])
        #expect(restored["study_docs"]?.count == 1)
        #expect(restored["study_placements"]?.first?.string("course_id") == "course-a")
        let mac: [String: [Row]] = ["study_docs": [Row(["id": .string(id), "title": .string("Más reciente en el Mac"), "content_markdown": .string("Mac revision 2"), "editor_revision": .int(2)])]]
        #expect(await confirmed.overlayStudyTables(mac)["study_docs"]?.first?.string("title") == "Más reciente en el Mac")
        #expect(await confirmed.overlayStudyTables(mac, includeConfirmedEdits: true)["study_docs"]?.first?.string("content_markdown") == "Mi nuevo apunte")
        #expect(await confirmed.confirmedTree() == nil, "Study creation must not contaminate the Scriptor notes tree")
    }

    @Test("study creation rejects malformed metadata and cannot be placed in a workspace-note queue")
    func studyCreationValidation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(kind: .studyDocument)
        let valid: [String: JSONValue] = ["title": .string("Apunte"), "kind": .string("apunte")]
        for (key, value) in [("kind", JSONValue.string("markdown")), ("year", .double(1.5)), ("placement", .object([:])), ("placement", .object(["courseId": .string("")])), ("source", .string("private"))] {
            var input = valid; input[key] = value
            await #expect(throws: DesktopBridgeError.self) { try await queue.createStudyDocument(input: .object(input)) }
        }
        #expect(await queue.pendingCount() == 0)
        let notes = try await fixture.open()
        await #expect(throws: DesktopBridgeError.self) { try await notes.createStudyDocument(input: .object(valid)) }
    }

    @Test("study drafts have a separate durable identity and preserve the same request after a lost acknowledgement")
    func studyDraftIsolationAndReplay() async throws {
        let fixture = try Fixture(readLimitBytes: 2 * 1024 * 1024); defer { fixture.cleanup() }
        let notes = try await fixture.open(), study = try await fixture.open(kind: .studyDocument)
        for queue in [notes, study] { try await queue.seed(noteId: "same-id", editorData: Self.editor()) }
        _ = try await notes.save(noteId: "same-id", input: Self.input(7, text: "Workspace draft"))
        let result = try await study.save(noteId: "same-id", input: Self.input(7, text: "Study draft"))
        #expect(result.objectValue?["contentMarkdown"] == .string("Study draft"))
        let requests = Requests()
        do { try await study.synchronize { request in await requests.append(request); throw URLError(.networkConnectionLost) }; Issue.record("Expected a transport loss") }
        catch is URLError {}
        let reopened = try await fixture.open(kind: .studyDocument)
        #expect(await reopened.editorData(noteId: "same-id")?.objectValue?["nativeDocument"] == Self.input(7, text: "Study draft").objectValue?["nativeDocument"])
        try await reopened.synchronize { request in await requests.append(request); return Self.receipt(request, revision: 8) }
        let sent = await requests.all()
        #expect(sent.count == 2 && sent[0] == sent[1])
        #expect(await reopened.pendingCount() == 0)
        let preservedNotes = try await fixture.open()
        #expect(await preservedNotes.editorData(noteId: "same-id")?.objectValue?["contentMarkdown"] == .string("Workspace draft"))
        let confirmed = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .corpus, recordId: CompanionDocumentOutbox.operationKey("getStudyDocEditorData", [.string("same-id")])))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: confirmed).objectValue?["contentMarkdown"] == .string("Study draft"))
        let noteBytes = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.Kind.workspaceNote.storageKey))
        #expect(throws: DesktopBridgeError.self) { try CompanionDocumentOutbox(cache: fixture.cache, vaultId: "vault-a", data: noteBytes, kind: .studyDocument) }
    }

    @Test("study conflict choices preserve their draft and never resolve a same-id workspace note")
    func studyConflictIsolation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let notes = try await fixture.open(), study = try await fixture.open(kind: .studyDocument)
        for queue in [notes, study] { try await queue.seed(noteId: "same-id", editorData: Self.editor()) }
        _ = try await notes.save(noteId: "same-id", input: Self.input(7, text: "Workspace draft"))
        _ = try await study.save(noteId: "same-id", input: Self.input(7, text: "Study draft"))
        let remote = Self.editor(9, text: "Mac study draft")
        do { try await study.synchronize { _ in throw APIError(status: 409, code: "revision_conflict", details: ["remote": remote]) }; Issue.record("Expected a conflict") }
        catch is APIError {}
        let reopened = try await fixture.open(kind: .studyDocument)
        #expect(await reopened.editorData(noteId: "same-id")?.objectValue?["mobileConflictRemote"] == remote)
        #expect(try await reopened.resolve(noteId: "same-id", keepMobile: false) == remote)
        #expect(await reopened.editorData(noteId: "same-id") == nil)
        #expect(await notes.editorData(noteId: "same-id")?.objectValue?["contentMarkdown"] == .string("Workspace draft"))
        await #expect(throws: DesktopBridgeError.self) { try await reopened.create(input: Self.creationInput) }
        await #expect(throws: DesktopBridgeError.self) { try await reopened.createManualIdea(input: .object(["title": .string("Wrong domain")])) }
    }
    @Test("embedded images above the former transport limit survive restart and structured acknowledgement")
    func embeddedImageRoundtrip() async throws {
        let fixture = try Fixture(readLimitBytes: 1); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#6158e8\"/><!--" + String(repeating:"x",count:1_989_000) + "--></svg>"
        let url = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let markdown = "![Nodus](\(url))"
        var input = Self.input(7,text:markdown).objectValue!
        input["nativeDocument"] = .array([.object(["id":.string("image-37"),"type":.string("image"),"props":.object(["url":.string(url),"name":.string("Nodus.svg")])])])
        try await queue.seed(noteId:"note",editorData:Self.editor())
        _ = try await queue.save(noteId:"note",input:.object(input))
        let reopened = try await fixture.open()
        #expect(await reopened.editorData(noteId:"note")?.objectValue?["nativeDocument"] == input["nativeDocument"])
        try await reopened.synchronize { request in
            let wire = JSONValue.object(["id":.string(request.id),"noteId":.string(request.noteId),"input":request.input])
            let bytes = try JSONEncoder.nodus.encode(wire).count
            #expect(bytes > 4 * 1024 * 1024 && bytes < CompanionDocumentOutbox.maximumRequestBytes)
            var confirmed = Self.editor(8,text:markdown).objectValue!
            confirmed["nativeDocument"] = request.input.objectValue?["nativeDocument"]
            return .object(["id":.string(request.id),"editorData":.object(confirmed)])
        }
        #expect(await reopened.pendingCount() == 0)
        let confirmed = await reopened.confirmedEditorData(noteId:"note")
        #expect(confirmed?.objectValue?["contentMarkdown"] == .string(markdown))
        #expect(confirmed?.objectValue?["nativeDocument"] == input["nativeDocument"])
    }

    @Test("confirmed authored documents retain structured content and only their real folder ancestors without a reusable cache")
    func confirmedAuthorship() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let folders: [JSONValue] = [
            .object(["id": .string("folder-a"), "parentId": .string("root"), "title": .string("Writing")]),
            .object(["id": .string("root"), "parentId": .null, "title": .string("Root")]),
            .object(["id": .string("unrelated"), "parentId": .null, "title": .string("Unrelated private folder")])]
        try await queue.rememberTree(.object(["folders": .array(folders), "notes": .array([])]))
        let note = try await queue.create(input: Self.creationInput), id = try #require(note.objectValue?["id"]?.stringValue)
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "Table and citation"))
        try await queue.synchronize { request in
            var response = Self.receipt(request, revision: 8).objectValue!, canonical = note.objectValue!
            canonical["title"] = .string("Private document"); canonical["content"] = .string("Table and citation")
            response["note"] = .object(canonical); return .object(response)
        }
        try await fixture.cache.removeReusableCopies()
        let reopened = try await fixture.open()
        #expect(await reopened.editorData(noteId: id) == nil)
        #expect(await reopened.pendingCount() == 0)
        #expect(await reopened.confirmedEditorData(noteId: id) == Self.editor(8, text: "Table and citation"))
        let tree = try #require(await reopened.confirmedTree())
        #expect(tree.objectValue?["notes"]?.arrayValue?.map { $0.objectValue?["id"]?.stringValue } == [id])
        #expect(Set(tree.objectValue?["folders"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []) == ["root", "folder-a"])
        #expect(tree.objectValue?["mobileSourceScope"] == .string("authoredDocuments"))
        let bytes = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(throws: DesktopBridgeError.self) { try CompanionDocumentOutbox(cache: fixture.cache, vaultId: "vault-b", data: bytes) }
        #expect(await reopened.confirmedEditorData(noteId: "unrelated") == nil)
    }

    @Test("a stale offline tree cannot replace authored metadata or structured edits and a live tree cannot resurrect missing notes")
    func confirmedTreeEpoch() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; let queue = try await fixture.open()
        let original = try await queue.create(input: Self.creationInput), id = try #require(original.objectValue?["id"]?.stringValue)
        try await queue.synchronize { request in
            var response = Self.receipt(request, revision: 8).objectValue!
            response["note"] = original; return .object(response)
        }
        var canonical = original.objectValue!; canonical["folderId"] = .string("new-folder")
        let folder: JSONValue = .object(["id": .string("new-folder"), "parentId": .null, "title": .string("Current folder")])
        try await queue.rememberTree(.object(["notes": .array([.object(canonical)]), "folders": .array([folder])]))
        try await queue.seed(noteId: id, editorData: Self.editor(9, text: "Latest confirmed text"))
        let stale: JSONValue = .object(["notes": .array([original]), "folders": .array([])])
        try await queue.rememberTree(stale, authoritative: false)
        try await queue.seed(noteId: id, editorData: Self.editor(8, text: "Stale cache"))
        let overlay = await queue.overlayTree(stale, includeConfirmedEdits: true)
        #expect(overlay.objectValue?["notes"]?.arrayValue?.first?.objectValue?["folderId"] == .string("new-folder"))
        #expect(overlay.objectValue?["notes"]?.arrayValue?.first?.objectValue?["content"] == .string("Latest confirmed text"))
        #expect(overlay.objectValue?["folders"] == .array([folder]))
        let live = await queue.overlayTree(.object(["notes": .array([]), "folders": .array([])]))
        #expect(live.objectValue?["notes"] == .array([]))
        canonical["trashedAt"] = .string("2026-10-11T09:00:00Z")
        try await queue.rememberTree(.object(["notes": .array([.object(canonical)]), "folders": .array([folder])]))
        #expect(await queue.confirmedTree() == nil)
        #expect(await queue.confirmedTree(includeTrashed: true)?.objectValue?["notes"]?.arrayValue?.count == 1)
    }

    @Test("legacy durable queues migrate without losing in-flight identity or content")
    func legacyStorage() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; let queue = try await fixture.open()
        try await queue.seed(noteId: "legacy", editorData: Self.editor())
        _ = try await queue.save(noteId: "legacy", input: Self.input(7, text: "Legacy table"))
        let stored = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        let records = try #require(try JSONDecoder.nodus.decode(JSONValue.self, from: stored).objectValue?["records"])
        _ = try await fixture.cache.store(JSONEncoder.nodus.encode(records), vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey)
        let reopened = try await fixture.open()
        #expect(await reopened.editorData(noteId: "legacy")?.objectValue?["contentMarkdown"] == .string("Legacy table"))
        try await reopened.synchronize { Self.receipt($0, revision: 8) }
        #expect(try await fixture.open().confirmedEditorData(noteId: "legacy") == Self.editor(8, text: "Legacy table"))
    }

    @Test("authored ideas retain both identities, source ownership and local dossier after offline restart")
    func offlineIdeaCreation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        for invalid: JSONValue in [.object(["globalId": .string("g-0001")]), .object(["source": .null]), .object(["title": .int(37)]), .object(["folderId": .int(37)])] {
            await #expect(throws: DesktopBridgeError.self) { try await queue.createManualIdea(input: invalid) }
        }
        #expect(await queue.pendingCount() == 0)
        let created = try await queue.createManualIdea(input: .object(["title": .string("Authored idea"), "folderId": .string("folder-a")]))
        let note = try #require(created.objectValue?["note"]), globalId = try #require(created.objectValue?["globalId"]?.stringValue)
        let id = try #require(note.objectValue?["id"]?.stringValue)
        #expect(UUID(uuidString: id) != nil); #expect(globalId.hasPrefix("manual-")); #expect(UUID(uuidString: String(globalId.dropFirst(7))) != nil)
        #expect(note.objectValue?["kind"] == .string("idea")); #expect(note.objectValue?["source"]?.objectValue?["ref"] == .string(globalId))
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "User-authored development with a table and citation"))
        try await fixture.cache.removeReusableCopies()
        let reopened = try await fixture.open(), dossier = try #require(await reopened.pendingIdeaDetail(globalId: globalId))
        #expect(dossier.objectValue?["idea"]?.objectValue?["statement"] == .string("User-authored development with a table and citation"))
        #expect(dossier.objectValue?["evidence"] == .array([])); #expect(await reopened.pendingIdeaDetail(globalId: "g-0001") == nil)
        let pending = try #require(await reopened.pendingIdeaCopy())
        let projection = try CompanionIdeaCopy(copies: [pending])
        let catalogue = try #require(try projection.nativeResponse(path: "ideas", query: [URLQueryItem(name: "surface", value: "workspace")], percentEncoded: false))
        let page = try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: catalogue.data)
        #expect(page.items.map(\.id) == [globalId]); #expect(page.items.first?.workCount == 0)
        #expect(page.items.first?.statement == "User-authored development with a table and citation")
        let native = try #require(try projection.nativeResponse(path: "ideas/\(globalId)", query: [], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(IdeaDetail.self, from: native.data).idea.string("mobileSyncState") == "pending")
        #expect(try projection.operation("stellarPage", args: [.object(["kind": .string("corpus")])])?.objectValue?["nodes"]?.arrayValue?.count == 1)
        #expect(try projection.operation("stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string(globalId)])])?.objectValue?["total"]?.intValue == 0)
        let tree = await reopened.overlayTree(.object(["folders": .array([]), "notes": .array([])]))
        #expect(tree.objectValue?["notes"]?.arrayValue?.first?.objectValue?["source"] == note.objectValue?["source"])
        let anotherVault = try await CompanionDocumentOutbox(cache: fixture.cache, vaultId: "vault-b", data: fixture.cache.data(vaultId: "vault-b", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(await anotherVault.pendingIdeaDetail(globalId: globalId) == nil)
        #expect(await anotherVault.pendingIdeaCopy() == nil)
    }
    @Test("lost authored-idea creation acknowledgements reuse both identities and refuse changed canonical ownership")
    func ideaCreationAcknowledgement() async throws {
        let fixture = try Fixture(readLimitBytes: 1_000_000); defer { fixture.cleanup() }
        let queue = try await fixture.open(), requests = Requests()
        let created = try await queue.createManualIdea(input: .object(["folderId": .null]))
        let note = try #require(created.objectValue?["note"]), id = try #require(note.objectValue?["id"]?.stringValue)
        let globalId = try #require(created.objectValue?["globalId"])
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "Complete authored content"))
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await requests.append(request); throw URLError(.networkConnectionLost) } }
        let reopened = try await fixture.open()
        await #expect(throws: DesktopBridgeError.self) {
            try await reopened.synchronize { request in
                await requests.append(request)
                var response = Self.receipt(request, revision: 8).objectValue!, wrong = note.objectValue!
                wrong["source"] = .object(["note": .string("manual-idea"), "ref": .string("g-0001")]); response["note"] = .object(wrong)
                return .object(response)
            }
        }
        #expect(await reopened.pendingCount() == 1); #expect(await reopened.editorData(noteId: id) != nil)
        #expect(await reopened.confirmedEditorData(noteId: id) == nil)
        #expect(await reopened.confirmedTree() == nil)
        try await reopened.synchronize { request in
            await requests.append(request)
            var response = Self.receipt(request, revision: 8).objectValue!; response["note"] = note
            return .object(response)
        }
        let sent = await requests.all()
        #expect(sent.count == 3); #expect(sent[0] == sent[1]); #expect(sent[1] == sent[2])
        #expect(sent[0].creation?.objectValue?["globalId"] == globalId); #expect(sent[0].noteId == id)
        #expect(await reopened.pendingCount() == 0); #expect(await reopened.pendingIdeaDetail(globalId: globalId.stringValue!) == nil)
        try await fixture.cache.removeReusableCopies()
        let confirmed = try await fixture.open()
        let text = try #require(await confirmed.pendingIdeaDetail(globalId: globalId.stringValue!, includeConfirmed: true))
        #expect(text.objectValue?["idea"]?.objectValue?["statement"] == .string("Complete authored content"))
        #expect(text.objectValue?["idea"]?.objectValue?["mobileSourceScope"] == .string("authoredText"))
        let owned = try #require(try await CompanionIdeaCopy.authored(cache: fixture.cache, vaultId: "vault-a"))
        let projection = try CompanionIdeaCopy(copies: [owned])
        #expect(!projection.containsFullIdea(globalId.stringValue!))
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try projection.operation("getIdeaEdges", args: [globalId]) }
        let response = try #require(try projection.nativeResponse(path: "ideas", query: [URLQueryItem(name: "surface", value: "workspace")], percentEncoded: false))
        let catalogue = try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: response.data)
        #expect(catalogue.items.map(\.id) == [globalId.stringValue!])
        #expect(catalogue.items.first?.mobileSourceScope == "authoredText")
        #expect(try await CompanionIdeaCopy.authored(cache: fixture.cache, vaultId: "vault-a", includeConfirmed: false) == nil)
        #expect(try await CompanionIdeaCopy.authored(cache: fixture.cache, vaultId: "vault-b") == nil)
        #expect(await confirmed.confirmedEditorData(noteId: id)?.objectValue?["contentMarkdown"] == .string("Complete authored content"))
    }
    @Test("new offline documents preserve stable identity, metadata and structured content through restart")
    func offlineCreation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let note = try await queue.create(input: Self.creationInput)
        let id = try #require(note.objectValue?["id"]?.stringValue)
        #expect(UUID(uuidString: id) != nil); #expect(note.objectValue?["kind"] == .string("markdown"))
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "New table, formula $x^2$ and citation"))
        try await fixture.cache.removeReusableCopies()
        let reopened = try await fixture.open()
        let tree = await reopened.overlayTree(.object(["folders": .array([]), "notes": .array([])]))
        let notes = try #require(tree.objectValue?["notes"]?.arrayValue)
        #expect(notes.count == 1); #expect(notes[0].objectValue?["id"] == .string(id))
        #expect(notes[0].objectValue?["folderId"] == .string("folder-a")); #expect(notes[0].objectValue?["tags"] == .array([.string("offline")]))
        let editor = try #require(await reopened.editorData(noteId: id))
        #expect(editor.objectValue?["nativeDocument"] == Self.input(-1, text: "New table, formula $x^2$ and citation").objectValue?["nativeDocument"])
        let anotherVault = try await CompanionDocumentOutbox(cache: fixture.cache, vaultId: "vault-b", data: fixture.cache.data(vaultId: "vault-b", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(await anotherVault.editorData(noteId: id) == nil)
    }
    @Test("lost creation acknowledgements replay once before sending a newer edit and retain the canonical catalogue")
    func creationAcknowledgement() async throws {
        let fixture = try Fixture(readLimitBytes: 1_000_000); defer { fixture.cleanup() }
        let queue = try await fixture.open(), requests = Requests()
        let note = try await queue.create(input: Self.creationInput), id = try #require(note.objectValue?["id"]?.stringValue)
        for args: [JSONValue] in [[], [.bool(true)]] {
            try await fixture.cache.store(JSONEncoder.nodus.encode(JSONValue.object(["folders": .array([]), "notes": .array([])])), vaultId: "vault-a", domain: .corpus, recordId: CompanionDocumentOutbox.operationKey("getNotesTree", args))
        }
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await requests.append(request); throw URLError(.networkConnectionLost) } }
        _ = try await queue.save(noteId: id, input: Self.input(-1, text: "Typed after connection loss"))
        let reopened = try await fixture.open()
        try await reopened.synchronize { request in
            await requests.append(request)
            var response = Self.receipt(request, revision: request.creation == nil ? 9 : 8).objectValue!
            var canonicalNote = note.objectValue!
            canonicalNote["content"] = request.input.objectValue?["contentMarkdown"]
            response["note"] = .object(canonicalNote); return .object(response)
        }
        let sent = await requests.all()
        #expect(sent.count == 3); #expect(sent[0] == sent[1]); #expect(sent[0].creation != nil)
        #expect(sent[2].creation == nil); #expect(sent[2].input.objectValue?["expectedRevision"] == .int(8))
        #expect(sent[2].input.objectValue?["contentMarkdown"] == .string("Typed after connection loss"))
        #expect(await reopened.pendingCount() == 0)
        for args: [JSONValue] in [[], [.bool(true)]] {
            let data = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .corpus, recordId: CompanionDocumentOutbox.operationKey("getNotesTree", args)))
            let tree = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
            #expect(tree.objectValue?["notes"]?.arrayValue?.count == 1)
            #expect(tree.objectValue?["notes"]?.arrayValue?.first?.objectValue?["id"] == .string(id))
            #expect(tree.objectValue?["notes"]?.arrayValue?.first?.objectValue?["content"] == .string("Typed after connection loss"))
        }
    }
    @Test("invalid creation metadata and incomplete canonical acknowledgements cannot discard a new draft")
    func rejectedCreation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }; let queue = try await fixture.open()
        for field in ["title", "folderId", "tags"] {
            var input = Self.creationInput.objectValue!; input[field] = field == "tags" ? .array([.int(37)]) : .int(37)
            await #expect(throws: DesktopBridgeError.self) { try await queue.create(input: .object(input)) }
        }
        #expect(await queue.pendingCount() == 0)
        let note = try await queue.create(input: Self.creationInput), id = try #require(note.objectValue?["id"]?.stringValue)
        await #expect(throws: DesktopBridgeError.self) { try await queue.synchronize { Self.receipt($0, revision: 8) } }
        #expect(await queue.pendingCount() == 1)
        let reopened = try await fixture.open()
        #expect(await reopened.editorData(noteId: id) != nil)
    }
    private actor InFlight {
        var first: CompanionDocumentOutbox.Request?
        var ready: [CheckedContinuation<Void, Never>] = []
        var acknowledgement: CheckedContinuation<JSONValue, Never>?
        func send(_ request: CompanionDocumentOutbox.Request) async -> JSONValue {
            if first != nil { return CompanionDocumentOutboxTests.receipt(request, revision: 9) }
            first = request
            for waiter in ready { waiter.resume() }; ready = []
            return await withCheckedContinuation { acknowledgement = $0 }
        }
        func waitUntilStarted() async {
            if first != nil { return }
            await withCheckedContinuation { ready.append($0) }
        }
        func release() { acknowledgement?.resume(returning: CompanionDocumentOutboxTests.receipt(first!, revision: 8)); acknowledgement = nil }
    }
    @Test("typing during an in-flight save cannot retire or overwrite the newer draft")
    func editDuringSend() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "First"))
        let gate = InFlight(), requests = Requests()
        let delivery = Task { try await queue.synchronize { request in await requests.append(request); return await gate.send(request) } }
        await gate.waitUntilStarted()
        _ = try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Typed during delivery"))
        await gate.release(); try await delivery.value
        let sent = await requests.all(); #expect(sent.count == 2)
        #expect(sent[0].input.objectValue?["contentMarkdown"] == .string("First"))
        #expect(sent[1].input.objectValue?["contentMarkdown"] == .string("Typed during delivery"))
        #expect(sent[1].input.objectValue?["expectedRevision"] == .int(8))
        #expect(await queue.pendingCount() == 0)
    }
    @Test("a just-confirmed local revision can be edited before the view's next refresh")
    func editAfterAcknowledgement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "First"))
        try await queue.synchronize { Self.receipt($0, revision: 8) }
        let next = try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Immediate next edit"))
        #expect(next.objectValue?["editorRevision"] == .int(-2))
        try await queue.synchronize { request in
            #expect(request.input.objectValue?["expectedRevision"] == .int(8)); return Self.receipt(request, revision: 9)
        }
        try await queue.seed(noteId: "note-a", editorData: Self.editor(10, text: "New Mac edit"))
        await #expect(throws: APIError.self) { try await queue.save(noteId: "note-a", input: Self.input(-2, text: "Stale view")) }
        #expect(await queue.pendingCount() == 0)
    }
    @Test("suspension and temporary server failures retain the same replayable request")
    func transientFailures() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Must survive suspension"))
        let requests = Requests()
        let failures: [any Error & Sendable] = [CancellationError(), URLError(.cancelled), APIError(status: 500), APIError(status: 429)]
        for failure in failures {
            do { try await queue.synchronize { request in await requests.append(request); throw failure }; Issue.record("The simulated transport must fail") }
            catch { #expect(await queue.pendingCount() == 1) }
        }
        try await queue.synchronize { request in await requests.append(request); return Self.receipt(request, revision: 8) }
        let attempts = await requests.all(); #expect(attempts.count == 5); #expect(Set(attempts.map(\.id)).count == 1)
        #expect(await queue.pendingCount() == 0)
    }
    @Test("an offline structured save survives reopen, quota cleanup and vault isolation")
    func offline() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        try await queue.seed(noteId: "note-a", editorData: Self.editor())
        let input = Self.input(7, text: "Offline private table and formula $x^2$ [source](nodus://evidence/source)")
        let saved = try await queue.save(noteId: "note-a", input: input)
        #expect(saved.objectValue?["editorRevision"] == .int(-1))
        await #expect(throws: URLError.self) { try await queue.synchronize { _ in throw URLError(.cannotConnectToHost) } }
        try await fixture.cache.removeReusableCopies()
        let reopened = try await fixture.open()
        let data = try #require(await reopened.editorData(noteId: "note-a")).objectValue!
        #expect(data["nativeDocument"] == input.objectValue?["nativeDocument"])
        #expect(data["academicMetadata"] == input.objectValue?["academicMetadata"])
        #expect(data["mobileSyncState"] == .string("pending"))
        #expect(try await fixture.cache.data(vaultId: "vault-b", domain: .writing, recordId: CompanionDocumentOutbox.storageKey) == nil)
        for file in try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("bridge-\(fixture.pairing)"), includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("Offline private table".utf8)) == nil)
        }
    }
    @Test("unsent autosaves coalesce while preserving the Mac revision")
    func coalesce() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "First"))
        _ = try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Latest"))
        let requests = Requests()
        try await queue.synchronize { request in await requests.append(request); return Self.receipt(request, revision: 8) }
        let sent = await requests.all()
        #expect(sent.count == 1); #expect(sent[0].input.objectValue?["expectedRevision"] == .int(7))
        #expect(sent[0].input.objectValue?["contentMarkdown"] == .string("Latest"))
        #expect(await queue.editorData(noteId: "note-a") == nil); #expect(await queue.pendingCount() == 0)
    }
    @Test("a lost acknowledgement replays the frozen request before sending newer edits")
    func lostAcknowledgement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "First"))
        let before = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await before.append(request); throw URLError(.networkConnectionLost) } }
        _ = try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Newer draft"))
        let reopened = try await fixture.open(), after = Requests()
        try await reopened.synchronize { request in
            await after.append(request)
            return Self.receipt(request, revision: request.input.objectValue?["expectedRevision"] == .int(7) ? 8 : 9)
        }
        let first = await before.all(), sent = await after.all()
        #expect(sent.count == 2); #expect(sent[0] == first[0]); #expect(sent[1].id != sent[0].id)
        #expect(sent[1].input.objectValue?["expectedRevision"] == .int(8))
        #expect(sent[1].input.objectValue?["contentMarkdown"] == .string("Newer draft"))
        #expect(await reopened.pendingCount() == 0)
    }
    @Test("a conflict preserves both structured documents until an explicit mobile choice")
    func conflict() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Mobile edit"))
        let rejected = Requests(), remote = Self.editor(9, text: "Mac edit")
        await #expect(throws: APIError.self) { try await queue.synchronize { request in
            await rejected.append(request); throw APIError(status: 409, code: "revision_conflict", details: ["remote": remote])
        } }
        let reopened = try await fixture.open()
        let conflicted = try #require(await reopened.editorData(noteId: "note-a")).objectValue!
        #expect(conflicted["contentMarkdown"] == .string("Mobile edit"))
        #expect(conflicted["mobileConflictRemote"] == remote)
        #expect(await reopened.pendingCount() == 0)
        let noRetry = Requests()
        try await reopened.synchronize { request in await noRetry.append(request); return Self.receipt(request, revision: 10) }
        #expect(await noRetry.all().isEmpty)
        _ = try await reopened.resolve(noteId: "note-a", keepMobile: true)
        let approved = Requests()
        try await reopened.synchronize { request in await approved.append(request); return Self.receipt(request, revision: 10) }
        let sent = await approved.all(), prior = await rejected.all()
        #expect(sent.count == 1); #expect(sent[0].id != prior[0].id)
        #expect(sent[0].input.objectValue?["expectedRevision"] == .int(9))
        #expect(sent[0].input.objectValue?["contentMarkdown"] == .string("Mobile edit"))
    }
    @Test("choosing the Mac version retires the local queue without a write")
    func keepMac() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(); try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Mobile edit"))
        let remote = Self.editor(9, text: "Mac edit")
        await #expect(throws: APIError.self) { try await queue.synchronize { _ in throw APIError(status: 409, code: "revision_conflict", details: ["remote": remote]) } }
        #expect(try await queue.resolve(noteId: "note-a", keepMobile: false) == remote)
        #expect(await queue.editorData(noteId: "note-a") == nil)
        let reopened = try await fixture.open()
        #expect(await reopened.pendingCount() == 0)
        #expect(await reopened.confirmedEditorData(noteId: "note-a") == remote)
    }
}
