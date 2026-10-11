import Foundation
import Testing
@testable import NodusKit

@Suite("Complete companion page documents")
struct CompanionPageDocumentsTests {
    private func document(_ revision:Int=3,title:String="Original") -> JSONValue {
        .object(["page":.object(["id":.string("page"),"title":.string(title),"revision":.int(revision),"locked":.bool(false)]),"revision":.int(revision),"markdown":.string("Original"),"blocks":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.object(["text":.string("Original")])])]),"nativeDocument":.array([]),"academicMetadata":.object(["version":.int(1)]),"schemaVersion":.int(2)])
    }
    private func input(_ revision:Int,text:String="Móvil") -> JSONValue {
        .object(["pageId":.string("page"),"expectedRevision":.int(revision),"title":.string("Título móvil"),"markdown":.string(text),"blocks":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.object(["text":.string(text)])])]),"nativeDocument":.array([.object(["id":.string("block"),"type":.string("paragraph"),"content":.array([.object(["type":.string("text"),"text":.string(text),"styles":.object([:])])])])]),"academicMetadata":.object(["version":.int(1)])])
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
