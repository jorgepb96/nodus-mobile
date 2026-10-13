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
    @Test("workspace organization survives reopen and unknown acknowledgements with stable FIFO parent identities")
    func workspaceOrganizationReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(), calls = Requests()
        let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([]), "notes": .array([])])
        let parent = try await queue.enqueueWorkspaceOrganization(type: "folderCreate", arguments: .object(["name": .string("Parent")]), tree: tree)
        let parentID = try #require(parent.objectValue?["id"]?.stringValue)
        let child = try await queue.enqueueWorkspaceOrganization(type: "folderCreate", arguments: .object(["name": .string("Child"), "parentId": .string(parentID)]), tree: tree)
        #expect(child.objectValue?["parentId"] == .string(parentID))
        do { try await queue.synchronize { request in await calls.append(request); throw URLError(.networkConnectionLost) }; Issue.record("Expected unknown acknowledgement") } catch {}
        let first = try #require(await calls.all().first)
        #expect(first.noteId == parentID)
        #expect(first.input == .object([:]))
        await #expect(throws: APIError.self) { try await queue.cancelWorkspaceOrganization(id: first.id) }
        let reopened = try await fixture.open()
        let local = await reopened.overlayTree(tree, includeTrashed: true)
        #expect(local.objectValue?["folders"]?.arrayValue?.count == 2)
        try await reopened.synchronize { request in await calls.append(request); return .object(["tree": local]) }
        let requests = await calls.all()
        #expect(requests.count == 3)
        #expect(requests[0] == requests[1])
        #expect(requests[2].command?.objectValue?["operation"]?.objectValue?["parentAncestry"]?.arrayValue?.first?.objectValue?["id"] == .string(parentID))
        #expect(await reopened.pendingCount() == 0)
    }
    @Test("organization waits native saves and conflicted operations remain cancelable without discarding documents")
    func workspaceOrganizationSaveAndConflict() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(), calls = Requests()
        try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Authored native body"))
        let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([]), "notes": .array([.object(["id": .string("note-a"), "title": .string("A"), "folderId": .null, "tags": .array([]), "trashedAt": .null])])])
        _ = try await queue.enqueueWorkspaceOrganization(type: "tags", id: "note-a", arguments: .object(["add": .array([.string("tag")])]), tree: tree)
        do { try await queue.synchronize { request in
            await calls.append(request)
            if request.command == nil { return Self.receipt(request, revision: 8) }
            throw APIError(status: 409, code: "organization_conflict", message: "Changed Mac placement", details: ["remote": tree])
        }; Issue.record("Expected conflict") } catch {}
        let values = await calls.all()
        #expect(values.count == 2)
        #expect(values.first?.input.objectValue?["contentMarkdown"] == .string("Authored native body"))
        let issue = try #require(await queue.workspaceOrganizationIssues().arrayValue?.first?.objectValue)
        #expect(issue["state"] == .string("conflict"))
        try await queue.cancelWorkspaceOrganization(id: try #require(issue["id"]?.stringValue))
        #expect(await queue.confirmedEditorData(noteId: "note-a")?.objectValue?["contentMarkdown"] == .string("Authored native body"))
        #expect(await queue.workspaceOrganizationIssues() == .array([]))
    }
    @Test("stable offline folder is committed before a new note and live full snapshot retires old organization overlays")
    func workspaceFolderCreationDependency() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(), calls = Requests()
        let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([]), "notes": .array([])])
        let folder = try await queue.enqueueWorkspaceOrganization(type: "folderCreate", arguments: .object(["name": .string("Original name")]), tree: tree)
        let id = try #require(folder.objectValue?["id"]?.stringValue)
        try await queue.rememberTree(await queue.overlayTree(tree, includeTrashed: true), authoritative: false)
        let note = try await queue.create(input: .object(["title": .string("New note"), "content": .string(""), "kind": .string("markdown"), "folderId": .string(id)]))
        let noteID = try #require(note.objectValue?["id"]?.stringValue)
        try await queue.synchronize { request in
            await calls.append(request)
            if request.command != nil { return .object(["tree": .object(["folders": .array([folder]), "notes": .array([])])]) }
            var editor = Self.editor(1, text: "").objectValue!; editor["documentTitle"] = .string("New note")
            return .object(["id": .string(request.id), "note": note, "editorData": .object(editor)])
        }
        let packets = await calls.all()
        #expect(packets.count == 2)
        #expect(packets.first?.command?.objectValue?["operation"]?.objectValue?["type"] == .string("folderCreate"))
        #expect(packets.last?.noteId == noteID)
        var renamed = folder.objectValue!; renamed["name"] = .string("Later Mac name")
        let live: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([.object(renamed)]), "notes": .array([note])])
        try await queue.rememberTree(live, authoritative: true)
        #expect(await queue.overlayTree(live, includeConfirmedEdits: true).objectValue?["folders"]?.arrayValue?.first?.objectValue?["name"] == .string("Later Mac name"))
    }
    @Test("large consulted tree stays transient while a folder command retains only its subtree")
    func organizationDownloadedSnapshot() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let notes: [JSONValue] = (0..<10_000).map { index in .object(["id": .string("read-\(index)"), "title": .string("Read title \(index)"), "folderId": index == 0 ? .string("selected") : .null, "tags": .array([]), "trashedAt": .null, "content": .string("PRIVATE BODY")]) }
        let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([.object(["id": .string("selected"), "parentId": .null, "name": .string("Selected")])]), "notes": .array(notes)])
        try await queue.rememberTree(tree, authoritative: false)
        #expect(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey) == nil)
        let fresh = try await fixture.open()
        #expect(await fresh.workspaceOrganizationTree() == nil)
        _ = try await queue.enqueueWorkspaceOrganization(type: "folderTrash", id: "selected", arguments: .object([:]), tree: tree)
        let reopened = try await fixture.open()
        let issue = try #require(await reopened.workspaceOrganizationIssues().arrayValue?.first)
        let subtree = try #require(issue.objectValue?["operation"]?.objectValue?["expectedSubtree"])
        #expect(subtree.objectValue?["notes"]?.arrayValue?.count == 1)
        #expect(subtree.objectValue?["notes"]?.arrayValue?.first?.objectValue?["id"] == .string("read-0"))
        let bytes = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Read title 9999"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE BODY"))
    }
    @Test("legacy consulted-only forest is removed from durable cache on migration")
    func organizationReadOnlyMigration() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let legacy: JSONValue = .object(["version": .int(2), "vaultId": .string("vault-a"), "records": .object([:]), "authored": .object([:]), "workspaceOrganizationSnapshot": .object(["mobileOrganizationComplete": .bool(true), "folders": .array([]), "notes": .array([.object(["id": .string("consulted"), "title": .string("Read only")])])])])
        let bytes = try JSONEncoder.nodus.encode(legacy)
        try await fixture.cache.store(bytes, vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey)
        let queue = try await fixture.open()
        try await queue.migrateConsultedOrganizationSnapshot()
        #expect(await queue.workspaceOrganizationTree() == nil)
        #expect(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey) == nil)
    }
    @Test("consulted forest migration does not erase durable move identity or CAS on conflict")
    func organizationReadMigrationMoveConflict() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([.object(["id": .string("from"), "parentId": .null, "name": .string("From")]), .object(["id": .string("to"), "parentId": .null, "name": .string("To")])]), "notes": .array([.object(["id": .string("note"), "folderId": .string("from"), "tags": .array([]), "trashedAt": .null])])])
        try await queue.rememberTree(tree)
        _ = try await queue.enqueueWorkspaceOrganization(type: "move", id: "note", arguments: .object(["folderId": .string("to")]), tree: tree)
        let before = try #require(await queue.workspaceOrganizationIssues().arrayValue?.first)
        let bytes = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        var legacy = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue!
        legacy["workspaceOrganizationSnapshot"] = tree
        let restored = try CompanionDocumentOutbox(cache: fixture.cache, vaultId: "vault-a", data: JSONEncoder.nodus.encode(JSONValue.object(legacy)))
        try await restored.migrateConsultedOrganizationSnapshot()
        let restoredTree = try #require(await restored.workspaceOrganizationTree())
        #expect(restoredTree.objectValue?["mobileOrganizationComplete"] == .bool(false))
        #expect(restoredTree.objectValue?["notes"]?.arrayValue?.isEmpty == true)
        do {
            try await restored.synchronize { request in
                #expect(request.id == before.objectValue?["id"]?.stringValue)
                #expect(request.command?.objectValue?["operation"]?.objectValue?["expectedFolderId"] == .string("from"))
                throw APIError(status: 409, code: "organization_conflict", message: "Placement changed")
            }
            Issue.record("Expected actual conflict")
        } catch {}
        let reopened = try await fixture.open()
        let after = try #require(await reopened.workspaceOrganizationIssues().arrayValue?.first)
        #expect(after.objectValue?["id"] == before.objectValue?["id"])
        #expect(after.objectValue?["operation"] == before.objectValue?["operation"])
        #expect(after.objectValue?["state"] == .string("conflict"))
        let persisted = try #require(try await fixture.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: persisted).objectValue?["workspaceOrganizationSnapshot"] == nil)
    }
    @Test("closing rejects every new manual mutation before queue or metadata state changes")
    func closingRejectsManualState() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let queue = try await f.open()
        try await queue.seed(noteId: "note-a", editorData: Self.workspaceEditor())
        let tree: JSONValue = .object(["folders": .array([]), "notes": .array([])])
        let before = try await f.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey)
        try f.cache.beginClosingForRevocation()
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.save(noteId: "note-a", input: Self.input(7, text: "Must not enter state")) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.create(input: .object(["title": .string("Must not create"), "content": .string("")])) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.createManualIdea(input: .object(["statement": .string("Must not create idea")])) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.seed(noteId: "new-baseline", editorData: Self.editor()) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.rememberTree(tree) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.enqueueWorkspaceOrganization(type: "folderCreate", arguments: .object(["name": .string("Must not create folder")]), tree: tree) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.enqueueWorkspaceAnnotation(noteId: "note-a", method: "createWorkspaceAnnotation", patch: .object(["from": .int(0), "to": .int(0), "selectedText": .string(""), "comment": .string("Must not enqueue")])) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.enqueueWorkspaceCommand(noteId: "note-a", action: "duplicate") }
        #expect(await queue.pendingCount() == 0)
        #expect(await queue.editorData(noteId: "note-a") == nil)
        #expect(await queue.hasBaseline(noteId: "new-baseline") == false)
        #expect(await queue.workspaceOrganizationIssues() == .array([]))
        #expect(try await f.cache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey) == before)
        try await f.cache.freezeForRevocation(false)
    }
    private actor PausedAcknowledgement {
        var request: CompanionDocumentOutbox.Request?
        private var continuation: CheckedContinuation<JSONValue, Never>?
        func send(_ value: CompanionDocumentOutbox.Request) async -> JSONValue {
            request = value
            return await withCheckedContinuation { continuation = $0 }
        }
        func started() async throws -> CompanionDocumentOutbox.Request {
            while request == nil { try await Task.sleep(for: .milliseconds(5)) }
            return request!
        }
        func complete(_ value: JSONValue) { continuation?.resume(returning: value); continuation = nil }
    }
    @Test("an accepted native write finishes and its acknowledgement remains durable while new mutations close")
    func activeWriteFinishesDuringClosing() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let queue = try await f.open(), server = PausedAcknowledgement()
        try await queue.seed(noteId: "note-a", editorData: Self.editor())
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Accepted full native draft"))
        let task = Task { try await queue.synchronize { await server.send($0) } }
        let request = try await server.started()
        try f.cache.beginClosingForRevocation()
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await f.cache.freezeForRevocation(true) }
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Late mutation must be rejected")) }
        #expect(await queue.editorData(noteId: "note-a")?.objectValue?["contentMarkdown"] == .string("Accepted full native draft"))
        let preparation = Task { try await queue.prepareForRevocation() }
        preparation.cancel() // A canceled UI retirement still waits for the durable ACK.
        await server.complete(Self.receipt(request, revision: 8))
        try await task.value; try await preparation.value
        #expect(await queue.confirmedEditorData(noteId: "note-a")?.objectValue?["contentMarkdown"] == .string("Accepted full native draft"))
        try await f.cache.freezeForRevocation(true)
        let snapshot = try await f.cache.authoringRecoverySnapshot(vaultIds: ["vault-a"])
        #expect(snapshot.records.contains { String(decoding: $0.data, as: UTF8.self).contains("Accepted full native draft") })
        try await f.cache.freezeForRevocation(false)
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await queue.save(noteId: "note-a", input: Self.input(8, text: "Old actor after unfreeze")) }
        let fresh = try await f.open()
        #expect(await fresh.confirmedEditorData(noteId: "note-a")?.objectValue?["contentMarkdown"] == .string("Accepted full native draft"))
    }
    @Test("scoped retirement seals only removed actors and leaves other live queues usable")
    func scopedRegistryRetirement() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let registry = CompanionDocumentOutboxes(directory: f.directory, keychain: f.keychain)
        let removed = try await registry.outbox(pairingId: f.pairing, vaultId: "vault-a")
        let kept = try await registry.outbox(pairingId: f.pairing, vaultId: "kept")
        _ = try await removed.create(input: .object(["title": .string("Removed source"), "content": .string("")]))
        _ = try await kept.create(input: .object(["title": .string("Kept source"), "content": .string("")]))
        try f.cache.beginClosingForRevocation()
        try await registry.prepareForRevocation(pairingId: f.pairing, vaultIds: ["vault-a"])
        try await f.cache.freezeForRevocation(true); try await f.cache.freezeForRevocation(false)
        await registry.forget(pairingId: f.pairing, vaultIds: ["vault-a"])
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await removed.create(input: .object(["title": .string("Forbidden late write"), "content": .string("")])) }
        _ = try await kept.create(input: .object(["title": .string("Kept remains editable"), "content": .string("")]))
        let same = try await registry.outbox(pairingId: f.pairing, vaultId: "kept")
        #expect(same === kept)
        #expect(await kept.pendingCount() == 2)
        await registry.forget(pairingId: f.pairing)
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await kept.create(input: .object(["title": .string("Old retained actor"), "content": .string("")])) }
    }
    @Test("a retired source can return only through a fresh actor with archived work requiring review")
    func returnedVaultFreshReview() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let old = try await f.open()
        let note = try await old.create(input: .object(["title": .string("Authored removed vault"), "content": .string("")]))
        let id = try #require(note.objectValue?["id"]?.stringValue)
        try f.cache.beginClosingForRevocation(); try await old.prepareForRevocation(); try await f.cache.freezeForRevocation(true)
        let snapshot = try await f.cache.authoringRecoverySnapshot(vaultIds: ["vault-a"])
        let recovery = PrivateBridgeAuthoringRecovery(directory: f.directory.appendingPathComponent("recovery"), keychain: f.keychain)
        let pairing = try DesktopBridgePairing(id: f.pairing, origin: "https://fixture.local", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "phone", deviceName: "Phone", vaultIds: ["vault-a"], domains: [.corpus, .writing], pairedAt: Date(), expiresAt: nil)
        let receipt = try await recovery.preserve(snapshot: snapshot, pairing: pairing, macDeviceId: "Mac", forceReview: true)
        try await f.cache.retireArchivedVaultRecords(snapshot.records, receipt: receipt); try await recovery.completeRevocation(receipt)
        try await f.cache.freezeForRevocation(false)
        await #expect(throws: PrivateBridgeAuthoringRecovery.RecoveryError.self) { try await old.save(noteId: id, input: Self.input(-1, text: "Cannot resurrect the retired file")) }
        for record in snapshot.records {
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("bridge-" + f.pairing).appendingPathComponent(record.filename).path))
        }
        let recoveryCache = try PrivateBridgeCache(pairingId: f.pairing, directory: f.directory, keychain: f.keychain)
        #expect(try await recovery.adopt(pairing: pairing, macDeviceId: "Mac", cache: recoveryCache) == snapshot.records.count)
        let returnedCache = try PrivateBridgeCache(pairingId: f.pairing, directory: f.directory, keychain: f.keychain)
        let fresh = try await CompanionDocumentOutbox(cache: returnedCache, vaultId: "vault-a", data: returnedCache.data(vaultId: "vault-a", domain: .writing, recordId: CompanionDocumentOutbox.storageKey))
        #expect(await fresh.editorData(noteId: id)?.objectValue?["mobileSyncState"] == .string("blocked"))
        try await fresh.synchronize { _ in Issue.record("Returning source must never replay before explicit review"); throw DesktopBridgeError.permissionDenied }
        try? f.keychain.remove(receipt.recoveryKeyName)
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

    private static func workspaceEditor(_ id: String = "note-a", revision: Int = 7, kind: String = "idea", text: String = "Original", fingerprint: String = String(repeating: "a", count: 64)) -> JSONValue {
        var editor = Self.studyEditor(id, revision: revision, text: text).objectValue!
        editor["mobileCommandSource"] = .object(["version": .int(1), "fingerprint": .string(fingerprint), "placements": .array([]),
            "document": .object(["id": .string(id), "title": .string("Private document"), "content": .string(text), "kind": .string(kind), "folderId": .string("folder-a"), "tags": .array([.string("Research")]), "orderIdx": .int(4), "source": kind == "idea" ? .object(["note": .string("manual-idea"), "ref": .string("manual-original")]) : .null, "trashedAt": .null])])
        return .object(editor)
    }
    private actor WorkspaceServer {
        var editors: [String: JSONValue], copies: [String: JSONValue], receipts: [String: JSONValue] = [:]
        var copyCount = 0, trashCount = 0
        init(source: JSONValue, copies: [String: JSONValue] = [:]) {
            let id = source.objectValue!["mobileCommandSource"]!.objectValue!["document"]!.objectValue!["id"]!.stringValue!
            editors = [id: source]; self.copies = copies
        }
        func counts() -> (Int,Int) { (copyCount,trashCount) }
        func apply(_ request: CompanionDocumentOutbox.Request) throws -> JSONValue {
            if let receipt = receipts[request.id] { return receipt }
            if editors[request.noteId] == nil, let creation = request.creation?.objectValue {
                var value = CompanionDocumentOutboxTests.workspaceEditor(request.noteId, revision: 0, kind: creation["kind"]?.stringValue ?? "markdown").objectValue!
                var source = value["mobileCommandSource"]!.objectValue!, note = source["document"]!.objectValue!
                note["folderId"] = creation["folderId"] ?? .null; note["tags"] = creation["tags"] ?? .array([]); note["orderIdx"] = .int(0)
                note["source"] = creation["globalId"].map { .object(["note": .string("manual-idea"), "ref": $0]) } ?? .null
                source["document"] = .object(note); value["mobileCommandSource"] = .object(source); editors[request.noteId] = .object(value)
            }
            guard var editor = editors[request.noteId]?.objectValue,
                  editor["revision"] == request.input.objectValue?["expectedRevision"] else { throw APIError(status: 409, code: "revision_conflict", message: "Changed source", details: ["remote": editors[request.noteId] ?? .null]) }
            let action = request.command?.objectValue?["action"]?.stringValue
            if action?.hasPrefix("annotation") == true {
                let target = request.command!.objectValue!["annotationId"]!
                var rows = editor["annotations"]!.arrayValue!; rows.removeAll { $0.objectValue?["id"] == target }
                if let annotation = CompanionStudyAnnotation.projected(command: request.command!, documentId: request.noteId, timestamp: "canonical-comment-time") { rows.append(annotation) }
                editor["annotations"] = .array(rows)
            } else {
                for (key,value) in request.input.objectValue! where !["expectedRevision", "reason"].contains(key) { editor[key == "title" ? "documentTitle" : key] = value }
                editor["revision"] = .int(Int64(editor["revision"]!.intValue! + 1))
            }
            var source = editor["mobileCommandSource"]!.objectValue!, note = source["document"]!.objectValue!
            note["title"] = editor["documentTitle"]; note["content"] = editor["contentMarkdown"]; note["editorRevision"] = editor["revision"]
            var result: JSONValue?
            if action == "duplicate" {
                let target = request.command!.objectValue!["targetId"]!.stringValue!
                var copy = copies[target]!.objectValue!, copyNote = note
                copy["revision"] = .int(1); copyNote["id"] = .string(target); copyNote["kind"] = .string("markdown"); copyNote["source"] = .null
                copyNote["title"] = copy["documentTitle"]; copyNote["content"] = copy["contentMarkdown"]; copyNote["editorRevision"] = .int(1)
                var copySource = source; copySource["document"] = .object(copyNote); copy["mobileCommandSource"] = .object(copySource)
                editors[target] = .object(copy); copyCount += 1; result = .object(["document": .object(copyNote), "editorData": .object(copy)])
            } else if action == "trash" { note["trashedAt"] = .string("2026-10-12T19:00:00Z"); trashCount += 1; result = .object(["document": .object(note)]) }
            source["document"] = .object(note); editor["mobileCommandSource"] = .object(source); editors[request.noteId] = .object(editor)
            var response: [String:JSONValue] = ["id": .string(request.id), "note": .object(note), "editorData": .object(editor)]
            if let result { response["commandResult"] = result }
            let receipt = JSONValue.object(response); receipts[request.id] = receipt; return receipt
        }
    }
    @Test("offline Scriptor duplication and trash preserve pending source comments and replay one stable identity")
    func workspaceLifecycleReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open(), baseline = Self.workspaceEditor()
        try await queue.seed(noteId: "note-a", editorData: baseline)
        let original = baseline.objectValue!["mobileCommandSource"]!.objectValue!["document"]!
        let tree = JSONValue.object(["notes": .array([original]), "folders": .array([.object(["id": .string("folder-a"), "name": .string("Actual folder"), "parentId": .null])])])
        try await queue.rememberTree(tree)
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Captured source"))
        _ = try await queue.enqueueWorkspaceAnnotation(noteId: "note-a", method: "createWorkspaceAnnotation", patch: .object(["from": .int(0), "to": .int(8), "selectedText": .string("Captured"), "comment": .string("Keep source comment"), "locked": .bool(true)]))
        let note = try await queue.enqueueWorkspaceCommand(noteId: "note-a", action: "duplicate")
        let target = try #require(note.objectValue?["id"]?.stringValue), copied = try #require(await queue.editorData(noteId: target))
        #expect(note.objectValue?["kind"] == .string("markdown")); #expect(note.objectValue?["source"] == .null)
        #expect(note.objectValue?["folderId"] == .string("folder-a")); #expect(note.objectValue?["tags"] == .array([.string("Research")]))
        let bootstrap = try #require(await queue.confirmedTree())
        #expect(bootstrap.objectValue?["notes"]?.arrayValue?.contains { $0.objectValue?["id"] == .string(target) } == true)
        #expect(bootstrap.objectValue?["folders"]?.arrayValue?.first?.objectValue?["name"] == .string("Actual folder"))
        #expect(copied.objectValue?["annotations"]?.arrayValue?.isEmpty == true)
        #expect(copied.objectValue?["nativeDocument"]?.arrayValue?.first?.objectValue?["id"] != .string("table-1"))
        let server = WorkspaceServer(source: baseline, copies: [target: copied]), sent = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in
            await sent.append(request); let result = try await server.apply(request)
            if request.command?.objectValue?["action"] == .string("duplicate") { throw URLError(.networkConnectionLost) }
            return result
        } }
        let reopened = try await fixture.open()
        try await reopened.synchronize { request in await sent.append(request); return try await server.apply(request) }
        let packets = await sent.all()
        #expect(packets.count == 4); #expect(packets[0].command == nil)
        #expect(packets[1].command?.objectValue?["action"] == .string("annotationCreate"))
        #expect(packets[2].command?.objectValue?["action"] == .string("duplicate")); #expect(packets[2] == packets[3])
        #expect(await server.counts().0 == 1)
        #expect(await reopened.confirmedEditorData(noteId: "note-a")?.objectValue?["annotations"]?.arrayValue?.count == 1)
        #expect(await reopened.confirmedEditorData(noteId: target)?.objectValue?["contentMarkdown"] == .string("Captured source"))
        _ = try await reopened.enqueueWorkspaceCommand(noteId: "note-a", action: "trash")
        #expect(await reopened.overlayTree(tree, includeConfirmedEdits: true).objectValue?["notes"]?.arrayValue?.contains { $0.objectValue?["id"] == .string("note-a") } == false)
        await #expect(throws: URLError.self) { try await reopened.synchronize { request in await sent.append(request); _ = try await server.apply(request); throw URLError(.networkConnectionLost) } }
        let final = try await fixture.open()
        try await final.synchronize { request in await sent.append(request); return try await server.apply(request) }
        #expect(await server.counts().1 == 1); #expect(await final.pendingCount() == 0)
        #expect(await final.overlayTree(tree, includeConfirmedEdits: true).objectValue?["notes"]?.arrayValue?.contains { $0.objectValue?["id"] == .string("note-a") } == false)
        #expect(await final.confirmedEditorData(noteId: "note-a")?.objectValue?["annotations"]?.arrayValue?.count == 1)
    }
    @Test("new authored source copies wait their exact creation and comment receipts, without inventing Mac source identity")
    func workspaceNewSourceCopy() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let created = try await queue.create(input: .object(["title": .string("New source"), "content": .string("")]))
        let id = try #require(created.objectValue?["id"]?.stringValue)
        _ = try await queue.enqueueWorkspaceAnnotation(noteId: id, method: "createWorkspaceAnnotation", patch: .object(["from": .int(0), "to": .int(0), "selectedText": .string(""), "comment": .string("Creation comment")]))
        let copy = try await queue.enqueueWorkspaceCommand(noteId: id, action: "duplicate")
        let target = try #require(copy.objectValue?["id"]?.stringValue), editor = try #require(await queue.editorData(noteId: target))
        let server = WorkspaceServer(source: Self.workspaceEditor(), copies: [target: editor]), sent = Requests()
        try await queue.synchronize { request in await sent.append(request); return try await server.apply(request) }
        let packets = await sent.all()
        #expect(packets.count == 3); #expect(packets[0].noteId == id); #expect(packets[0].creation != nil)
        #expect(packets[1].command?.objectValue?["action"] == .string("annotationCreate"))
        #expect(packets[2].command?.objectValue?["action"] == .string("duplicate"))
        #expect(packets[2].input.objectValue?["expectedRevision"] == .int(1))
        #expect(await queue.pendingCount() == 0)
    }
    @Test("older downloads cannot invent copy metadata and overtaken comment anchors preserve explicit conflicts")
    func workspaceLifecycleSourceSafety() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        try await queue.seed(noteId: "old", editorData: Self.editor())
        await #expect(throws: APIError.self) { try await queue.enqueueWorkspaceCommand(noteId: "old", action: "duplicate") }
        let baseline = Self.workspaceEditor(); try await queue.seed(noteId: "note-a", editorData: baseline)
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "First source"))
        _ = try await queue.enqueueWorkspaceAnnotation(noteId: "note-a", method: "createWorkspaceAnnotation", patch: .object(["from": .int(0), "to": .int(5), "selectedText": .string("First"), "comment": .string("Retain anchor")]))
        _ = try await queue.save(noteId: "note-a", input: Self.input(-1, text: "Later source"))
        let copied = try await queue.enqueueWorkspaceCommand(noteId: "note-a", action: "duplicate")
        let target = try #require(copied.objectValue?["id"]?.stringValue), copyEditor = try #require(await queue.editorData(noteId: target))
        let server = WorkspaceServer(source: baseline, copies: [target: copyEditor]), sent = Requests()
        try await queue.synchronize { request in await sent.append(request); return try await server.apply(request) }
        #expect(await sent.all().count == 1); #expect(await server.counts().0 == 0)
        let local = try #require(await queue.editorData(noteId: "note-a"))
        #expect(local.objectValue?["mobileSyncState"] == .string("conflict"))
        #expect(local.objectValue?["annotations"]?.arrayValue?.first?.objectValue?["comment"] == .string("Retain anchor"))
        #expect(await queue.editorData(noteId: target)?.objectValue?["contentMarkdown"] == .string("Later source"))
        try await queue.prepareForRevocation()
        let reopened = try await fixture.open()
        #expect(await reopened.editorData(noteId: "note-a")?.objectValue?["mobileSyncState"] == .string("conflict"))
    }
    @Test("Scriptor annotations use the workspace receipt lane and preserve full note content through lost ACK")
    func workspaceAnnotationReplay() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let baseline = Self.editor()
        try await queue.seed(noteId: "note-a", editorData: baseline)
        let patch = JSONValue.object(["from": .int(0), "to": .int(8), "selectedText": .string("Original"), "comment": .string("Scriptor comment"), "locked": .bool(true)])
        await #expect(throws: DesktopBridgeError.self) { try await queue.enqueueStudyAnnotation(documentId: "note-a", method: "createStudyAnnotation", patch: patch) }
        let created = try await queue.enqueueWorkspaceAnnotation(noteId: "note-a", method: "createWorkspaceAnnotation", patch: patch)
        let annotationId = try #require(created.objectValue?["id"]?.stringValue)
        #expect(await queue.workspaceAnnotationDocumentId(annotationId: annotationId) == "note-a")
        let sent = Requests()
        await #expect(throws: URLError.self) { try await queue.synchronize { request in await sent.append(request); throw URLError(.networkConnectionLost) } }
        let reopened = try await fixture.open(), server = AnnotationServer(baseline: baseline)
        try await reopened.synchronize { request in await sent.append(request); return await server.apply(request) }
        let packets = await sent.all()
        #expect(packets.count == 2); #expect(packets[0] == packets[1])
        #expect(packets[0].command?.objectValue?["action"] == .string("annotationCreate"))
        #expect(await reopened.confirmedEditorData(noteId: "note-a")?.objectValue?["nativeDocument"] == baseline.objectValue?["nativeDocument"])
        #expect(await reopened.confirmedEditorData(noteId: "note-a")?.objectValue?["revision"] == .int(7))
        _ = try await reopened.enqueueWorkspaceAnnotation(noteId: "note-a", method: "updateWorkspaceAnnotation", annotationId: annotationId, patch: .object(["comment": .string("Edited locked note comment"), "resolved": .bool(true)]))
        try await reopened.synchronize { await server.apply($0) }
        #expect(await reopened.confirmedEditorData(noteId: "note-a")?.objectValue?["annotations"]?.arrayValue?.first?.objectValue?["locked"] == .bool(true))
        _ = try await reopened.enqueueWorkspaceAnnotation(noteId: "note-a", method: "deleteWorkspaceAnnotation", annotationId: annotationId)
        try await reopened.synchronize { await server.apply($0) }
        #expect(await reopened.confirmedEditorData(noteId: "note-a")?.objectValue?["annotations"]?.arrayValue?.isEmpty == true)
    }
    @Test("a downloaded Scriptor version restores native structure and academic metadata as a durable save")
    func workspaceOfflineVersionRestore() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let queue = try await fixture.open()
        let native = JSONValue.array([.object(["id": .string("old-equation"), "type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Original $x^2$"), "styles": .object(["italic": .bool(true)])])])])])
        let academic = JSONValue.object(["formatVersion": .int(1), "notes": .object(["exact-note": .object(["id": .string("exact-note"), "content": .string("Original citation")])])])
        let version = JSONValue.object(["id": .string("version-a"), "documentId": .string("note-a"), "title": .string("Old title"), "contentMarkdown": .string("Original $x^2$"), "nativeDocument": native, "schemaVersion": .int(2), "academicMetadata": academic, "style": .object(["fontFamily": .string("serif")])])
        var baseline = Self.editor().objectValue!; baseline["versions"] = .array([version])
        try await queue.seed(noteId: "note-a", editorData: .object(baseline))
        _ = try await queue.save(noteId: "note-a", input: Self.input(7, text: "Pending draft"))
        let restored = try await queue.restoreWorkspaceVersion(noteId: "note-a", versionId: "version-a")
        #expect(restored.objectValue?["editorRevision"] == .int(-2))
        let local = try #require(await queue.editorData(noteId: "note-a"))
        #expect(local.objectValue?["nativeDocument"] == native); #expect(local.objectValue?["academicMetadata"] == academic)
        #expect(local.objectValue?["documentTitle"] == .string("Old title"))
        let reopened = try await fixture.open(), sent = Requests()
        try await reopened.synchronize { request in
            await sent.append(request)
            #expect(request.command == nil); #expect(request.input.objectValue?["reason"] == .string("restore"))
            #expect(request.input.objectValue?["expectedRevision"] == .int(7))
            #expect(request.input.objectValue?["nativeDocument"] == native); #expect(request.input.objectValue?["academicMetadata"] == academic)
            var committed = local.objectValue!; committed["revision"] = .int(8)
            return .object(["id": .string(request.id), "editorData": .object(committed)])
        }
        #expect(await sent.all().count == 1)
        await #expect(throws: APIError.self) { try await reopened.restoreWorkspaceVersion(noteId: "note-a", versionId: "not-downloaded") }
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
