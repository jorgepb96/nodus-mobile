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
