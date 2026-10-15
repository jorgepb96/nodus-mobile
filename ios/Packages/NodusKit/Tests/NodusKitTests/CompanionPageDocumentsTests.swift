import Foundation
import Testing
@testable import NodusKit

@Suite("Complete companion page documents")
struct CompanionPageDocumentsTests {
    private func document(_ revision:Int=3,title:String="Original") -> JSONValue {
        .object(["page":.object(["id":.string("page"),"title":.string(title),"revision":.int(Int64(revision)),"locked":.bool(false)]),"revision":.int(Int64(revision)),"markdown":.string("Original"),"blocks":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.object(["text":.string("Original")])])]),"nativeDocument":.array([]),"academicMetadata":.object(["version":.int(1)]),"schemaVersion":.int(2)])
    }
    private func input(_ revision:Int,text:String="Móvil") -> JSONValue {
        .object(["pageId":.string("page"),"expectedRevision":.int(Int64(revision)),"title":.string("Título móvil"),"markdown":.string(text),"blocks":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.object(["text":.string(text)])])]),"nativeDocument":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.array([.object(["type":.string("text"),"text":.string(text),"styles":.object([:])])])])]),"academicMetadata":.object(["version":.int(1)])])
    }
    private func setup() throws -> (PrivateBridgeCache,URL,KeychainStore,String) {
        let id=UUID().uuidString,directory=FileManager.default.temporaryDirectory.appendingPathComponent(id),keychain=KeychainStore(service:"nodus.tests.pages.\(id)")
        return (try PrivateBridgeCache(pairingId:id,directory:directory,keychain:keychain,readLimitBytes:1),directory,keychain,id)
    }
    private func open(_ cache:PrivateBridgeCache) async throws -> CompanionPageDocuments {
        try await .init(cache:cache,vaultId:"vault",data:cache.data(vaultId:"vault",domain:.writing,recordId:CompanionPageDocuments.storageKey))
    }
    @Test("Full native draft survives reopening independently of disposable downloads")
    func durability() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store=try await open(cache);try await store.seed(pageId:"page",document:document())
        let saved=try await store.save(pageId:"page",input:input(3)),owned=try #require(saved.objectValue?["document"])
        let reopened=try await open(cache),copy=try #require(await reopened.document(pageId:"page"))
        #expect(copy==owned);#expect(copy.objectValue?["page"]?.objectValue?["title"] == .string("Título móvil"));#expect(copy.objectValue?["nativeDocument"] == input(3).objectValue?["nativeDocument"])
        #expect(try await cache.data(vaultId:"other",domain:.writing,recordId:CompanionPageDocuments.storageKey)==nil)
        #expect(try await cache.data(vaultId:"vault",domain:.corpus,recordId:CompanionPageDocuments.storageKey)==nil)
    }
    @Test("A newly authored offline page opens, keeps its structured edits and retains an empty creation baseline")
    func localCreation() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store = try await open(cache)
        let page = Row(["id": .string("page"), "title": .string("Mi página"), "origin": .string("standalone"), "state": .string("active"), "revision": .int(1),
            "locked": .int(0), "created_at": .string("2026-10-11T10:00:00Z"), "updated_at": .string("2026-10-11T10:00:00Z")])
        let created = try await store.createLocal(page: page)
        #expect(created.objectValue?["revision"] == .int(-1)); #expect(created.objectValue?["blocks"] == .array([]))
        #expect(created.objectValue?["mobileSyncState"] == .string("pending"))
        let reopened = try await open(cache)
        #expect(await reopened.document(pageId: "page") == created)
        _ = try await reopened.save(pageId: "page", input: input(-1))
        let changed = try await open(cache), draft = try #require(await changed.document(pageId: "page"))
        #expect(draft.objectValue?["nativeDocument"] == input(-1).objectValue?["nativeDocument"])
        let probe = PageProbe(document: document(2, title: "Título móvil"))
        try await changed.synchronize { request in try await probe.send(request, lose: false) }
        #expect(await probe.requests.first?.input.objectValue?["expectedRevision"] == .int(1))
        #expect(await probe.requests.first?.input.objectValue?["expectedPageRevision"] == .int(1))
    }
    @Test("Local page creation cannot replace an existing Mac baseline")
    func existingPageProtection() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store = try await open(cache); try await store.seed(pageId: "page", document: document())
        let page = Row(["id": .string("page"), "title": .string("New"), "origin": .string("standalone"), "state": .string("active"), "revision": .int(1),
            "created_at": .string("stamp"), "updated_at": .string("stamp")])
        await #expect(throws: DesktopBridgeError.self) { try await store.createLocal(page: page) }
        #expect(await store.hasDraft(pageId: "page") == false)
    }
    @Test("Applied authored documents survive reopening after disposable read copies are unavailable")
    func committedOwnership() async throws {
        let id = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("page-owned-\(id)")
        let keychain = KeychainStore(service: "nodus.tests.page.owned.\(id)")
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: directory, keychain: keychain, readLimitBytes: 0)
        let store = try await open(cache)
        try await store.seed(pageId: "page", document: document())
        #expect(await store.authoredSource(pageId: "page") == nil, "Consulting a Mac document does not turn it into a permanent download")
        _ = try await store.save(pageId: "page", input: input(3))
        var saved = document(4, title: "Título móvil").objectValue!
        saved["markdown"] = .string("Móvil"); saved["nativeDocument"] = input(3).objectValue?["nativeDocument"]
        let confirmed = JSONValue.object(saved), probe = PageProbe(document: confirmed)
        try await store.synchronize { request in try await probe.send(request, lose: false) }
        let reopened = try await open(cache), source = try #require(await reopened.authoredSource(pageId: "page"))
        #expect(await reopened.hasDraft(pageId: "page") == false)
        #expect(try CompanionPageDocuments.document(source, vaultId: "vault", pageId: "page") == confirmed)
        #expect(try await cache.data(vaultId: "vault", domain: .corpus, recordId: CompanionDocumentOutbox.operationKey("getMobilePageDocument", [.string("page")])) == nil)
        #expect(await reopened.authoredPageRows().first?.string("title") == "Título móvil")
        #expect(try await cache.data(vaultId: "other", domain: .writing, recordId: CompanionPageDocuments.storageKey) == nil)
        let old: JSONValue = .object(["version": .int(1), "vaultId": .string("vault"), "document": document(3)])
        try await reopened.refreshAuthoredSource(pageId: "page", source: old)
        #expect(await reopened.authoredSource(pageId: "page") == source)
        let newer: JSONValue = .object(["version": .int(1), "vaultId": .string("vault"), "document": document(5, title: "Actualizado en Nodus")])
        try await reopened.refreshAuthoredSource(pageId: "page", source: newer)
        #expect(await reopened.authoredSource(pageId: "page") == newer)
    }
    @Test("Existing draft storage migrates without inventing a confirmed authored document")
    func legacyDraftStorage() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store = try await open(cache); try await store.seed(pageId: "page", document: document())
        _ = try await store.save(pageId: "page", input: input(3))
        let bytes = try #require(try await cache.data(vaultId: "vault", domain: .writing, recordId: CompanionPageDocuments.storageKey))
        let state = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes), legacy = try #require(state.objectValue?["records"])
        let migrated = try CompanionPageDocuments(cache: cache, vaultId: "vault", data: JSONEncoder.nodus.encode(legacy))
        let expected = await store.document(pageId: "page")
        #expect(await migrated.document(pageId: "page") == expected)
        #expect(await migrated.authoredSource(pageId: "page") == nil)
    }
    @Test("Lost reply freezes the request and later edits cannot be retired by its acknowledgement")
    func lostReply() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store=try await open(cache);try await store.seed(pageId:"page",document:document());_ = try await store.save(pageId:"page",input:input(3))
        let probe=PageProbe(document:document(4,title:"Título móvil"))
        await #expect(throws:URLError.self){try await store.synchronize{request in try await probe.send(request,lose:true)}}
        let reopened=try await open(cache),copy=try #require(await reopened.document(pageId:"page")),revision=try #require(copy.objectValue?["revision"]?.intValue)
        _ = try await reopened.save(pageId:"page",input:input(revision,text:"Segunda edición"))
        try await reopened.synchronize{request in try await probe.send(request,lose:false)}
        let sent=await probe.requests
        #expect(sent.count==3);#expect(sent[0].id==sent[1].id);#expect(sent[0].input==sent[1].input);#expect(sent[2].id != sent[0].id)
        #expect(sent[0].input.objectValue?["markdown"]==nil);#expect(sent[0].input.objectValue?["expectedPageRevision"] == .int(3));#expect(sent[2].input.objectValue?["expectedRevision"] == .int(4))
        #expect(await reopened.document(pageId:"page")==nil)
    }
    @Test("Conflicts retain both versions and require an explicit resolution")
    func conflict() async throws {
        let (cache,directory,keychain,id)=try setup();defer{try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let store=try await open(cache);try await store.seed(pageId:"page",document:document());_ = try await store.save(pageId:"page",input:input(3))
        let remote=document(9,title:"Mac")
        await #expect(throws:APIError.self){try await store.synchronize{_ in throw APIError(status:409,code:"page_revision_conflict",details:["remote":remote])}}
        let reopened=try await open(cache),copy=try #require(await reopened.document(pageId:"page"))
        #expect(copy.objectValue?["mobileSyncState"] == .string("conflict"));#expect(copy.objectValue?["mobileConflictRemote"]==remote)
        let resolved=try await reopened.resolve(pageId:"page",keepMobile:true)
        #expect(resolved.objectValue?["mobileSyncState"] == .string("pending"));#expect(resolved.objectValue?["markdown"] == .string("Móvil"))
        let probe=PageProbe(document:document(10,title:"Título móvil"));try await reopened.synchronize{request in try await probe.send(request,lose:false)}
        #expect(await probe.requests.first?.input.objectValue?["expectedRevision"] == .int(9))
    }
    @Test("Action-created pages retain structured edits offline and wait for their exact creation receipt")
    func actionPageDependency() async throws {
        let (cache,directory,keychain,id)=try setup(); defer {try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id))}
        let actionId = UUID().uuidString.lowercased(), rowId = "drow-exact", pageId = "row:drow-exact"
        let originalBlocks: [JSONValue] = [
            .object(["id":.string("table"),"type":.string("table"),"content":.object(["rows":.array([.array([.string("Original cell")])]),"columnWidths":.array([.int(180)])])]),
            .object(["id":.string("child"),"parentBlockId":.string("table"),"type":.string("paragraph"),"content":.object(["text":.string("Nested source"),"reference":.object(["id":.string("actual-reference")])])])]
        let checkpoint = try CompanionDatabaseActionCheckpoint(.object(["version":.int(1),"vaultId":.string("vault"),"id":.string(actionId),
            "request":.object(["rowId":.string("source-row"),"columnId":.string("button"),"kind":.string("button"),"revision":.string(String(repeating:"a",count:64))]),"model":.null,
            "createdAt":.string("2026-10-15T10:00:00Z"),"state":.string("failed"),
            "source":.object(["plan":.object(["operations":.array([.object(["type":.string("create_page"),"rowId":.string(rowId),"databaseId":.string("destination"),"blocks":.array(originalBlocks)]),.object(["type":.string("webhook"),"url":.string("https://never-called.invalid")])])])]),
            "buttonResult":.object(["clickedAt":.string("2026-10-15T10:00:00Z"),"completedSteps":.int(1),"pendingWebhook":.int(1),"webhooks":.object([:])])]))
        let store = try await open(cache)
        #expect(try await store.prepareDatabaseActionPage(checkpoint:checkpoint,rowId:rowId) == pageId)
        let first = try #require(await store.document(pageId:pageId))
        let firstContents = first.objectValue?["blocks"]?.arrayValue?.map { $0.objectValue?["content"] }
        let originalContents = originalBlocks.map { $0.objectValue?["content"] }
        #expect(firstContents == originalContents)
        let native: JSONValue = .array([.object(["id":.string("table"),"type":.string("table"),"content":.object(["type":.string("tableContent"),"rows":.array([.object(["cells":.array([.array([.object(["type":.string("text"),"text":.string("Edited cell"),"styles":.object(["bold":.bool(true)])])])])])])])])])
        var editedBlocks = originalBlocks
        var table = editedBlocks[0].objectValue!, content = table["content"]!.objectValue!
        content["rows"] = .array([.array([.string("Edited cell")])]);table["content"] = .object(content);editedBlocks[0] = .object(table)
        let edit: JSONValue = .object(["pageId":.string(pageId),"expectedRevision":.int(-1),"title":.string("Edited offline"),"blocks":.array(editedBlocks),"nativeDocument":native,"markdown":.string("Editor projection"),"reason":.string("Explicit edit")])
        _ = try await store.save(pageId:pageId,input:edit)
        let reopened = try await open(cache)
        #expect(await reopened.document(pageId:pageId)?.objectValue?["nativeDocument"] == native)
        try await reopened.synchronize { _ in Issue.record("No page save may precede the owning creation receipt");throw URLError(.notConnectedToInternet) }
        var canonical = first.objectValue!
        canonical["revision"] = .int(4);canonical["blocks"] = .array(originalBlocks)
        var metadata = canonical["page"]!.objectValue!;metadata["revision"] = .int(7);canonical["page"] = .object(metadata)
        let receipt = DesktopJobLedger.Request(id:actionId,method:"saveMobileDatabaseButtonResult",args:[],createdAt:Date(),jobId:"actual-job",state:"available",issue:nil,result:.object(["createdPages":.array([.object(canonical)])]))
        try await cache.store(JSONEncoder.nodus.encode([actionId:receipt]),vaultId:"vault",domain:.researchGeneration,recordId:"job-ledger-v1")
        let committedBase = canonical, expectedBlocks = editedBlocks
        try await reopened.synchronize { request in
            #expect(request.input.objectValue?["expectedRevision"] == .int(4))
            #expect(request.input.objectValue?["expectedPageRevision"] == .int(7))
            #expect(request.input.objectValue?["blocks"] == .array(expectedBlocks))
            #expect(request.input.objectValue?["nativeDocument"] == native)
            var committed = committedBase;committed["revision"] = .int(5);committed["blocks"] = .array(expectedBlocks);committed["nativeDocument"] = native
            return .object(["id":.string(request.id),"document":.object(committed)])
        }
        let final = try await open(cache)
        #expect(await final.authoredSource(pageId:pageId)?.objectValue?["document"]?.objectValue?["nativeDocument"] == native)
        #expect(await final.hasDraft(pageId:pageId) == false)
    }

}
private actor PageProbe {
    let document:JSONValue
    var requests:[CompanionPageDocuments.Request]=[]
    init(document:JSONValue){self.document=document}
    func send(_ request:CompanionPageDocuments.Request,lose:Bool)throws->JSONValue {
        requests.append(request);if lose{throw URLError(.networkConnectionLost)}
        return .object(["id":.string(request.id),"document":document,"assets":.array([]),"dependencies":.array([])])
    }

}
