import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Native live chat durable questions") @MainActor
struct NativeLiveChatTests {
    @Test("Every chat family freezes a question, keeps partial text and imports the actual rich Mac answer")
    func recoverAllKinds() async throws {
        for kind in CompanionChatKind.allCases {
            let root=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space=UUID().uuidString,id=UUID().uuidString,answer=UUID()
            defer { try? FileManager.default.removeItem(at:root) }
            let store=ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:kind)
            let question=ChatHistoryStore.Message(role:.user,text:"Consulta 🌊",citations:[],createdAt:Date(timeIntervalSince1970:1000))
            var proposed=ChatHistoryStore.Conversation(id:id,title:"Trabajo móvil",messages:[question],createdAt:Date(),updatedAt:Date(),isArchived:false)
            if kind == .study { proposed.study=CompanionStudyChatOptions() }
            if kind == .world { proposed.world=CompanionWorldChatOptions() }
            if kind == .database { proposed.databaseIds=["database-a"] }
            let generation:JSONValue = .object(["model":.object(["provider":.string("codex"),"model":.string("Mac subscription")]),"thinkingEffort":.string("high")])
            let request=try store.beginLive(proposed,pairingId:"paired-Mac",generation:generation,answerId:answer)
            #expect(request.edit.objectValue?["draft"]?.objectValue?["messages"]?.arrayValue?.count == 1)
            #expect(store.active.first?.messages.last?.id == answer);#expect(store.active.first?.downloadedUntil == nil)
            #expect(throws:(any Error).self) { try store.save(proposed) }
            #expect(throws:(any Error).self) { try store.delete(id) }
            var accidentalSends=0
            await store.synchronize { _,_ in accidentalSends += 1;throw URLError(.notConnectedToInternet) }
            #expect(accidentalSends == 0)
            let events=try [event(1,"mobile:chat:delta",request.requestId,.string("Texto ")),event(2,"mobile:chat:delta",request.requestId,.string("🌊"))]
            try store.applyLiveEvents(id:id,requestId:request.requestId,events:events)
            try store.applyLiveEvents(id:id,requestId:request.requestId,events:events)
            #expect(store.active.first?.messages.last?.text == "Texto 🌊")
            let reopened=ChatHistoryStore(spaceId:space,root:root,backup:nil);try reopened.bind(kind:kind)
            #expect(reopened.active.first?.pendingLive?.request == request);#expect(reopened.active.first?.pendingLive?.sequence == 2)
            #expect(reopened.active.first?.messages.last?.delivery == .streaming)
            try reopened.applyLiveEvents(id:id,requestId:request.requestId,events:[event(3,"mobile:chat:replace",request.requestId,.string("Resultado final $x^2$"))])
            let document=try snapshot(request,answer:"Resultado final $x^2$")
            let envelope:JSONValue = .object(["version":.int(1),"requestId":.string(request.requestId),"kind":.string(kind.rawValue),"document":try json(document),"interrupted":.bool(false)])
            try reopened.finishLive(envelope,request:request)
            #expect(reopened.active.first?.pendingLive == nil);#expect(reopened.active.first?.desktop?.state == .saved)
            #expect(reopened.active.first?.messages.last?.desktopRecord?.objectValue?["skills"]?.arrayValue?.count == 1)
            #expect(reopened.active.first?.messages.last?.delivery == .completed);#expect(reopened.active.first?.downloadedUntil == nil)
        }
    }
    @Test("Explicit pre-submit cancellation keeps the authored question and removes only its empty placeholder")
    func cancelUnsubmitted() throws {
        let root=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space=UUID().uuidString,id=UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.research)
        let proposed=ChatHistoryStore.Conversation(id:id,title:"Pregunta propia",messages:[.init(role:.user,text:"Conservar esta pregunta",citations:[])],createdAt:Date(),updatedAt:Date(),isArchived:false)
        let request=try store.beginLive(proposed,pairingId:"Mac",generation:.object([:]),answerId:UUID())
        try store.cancelUnsubmittedLive(id:id,request:request)
        #expect(store.active.first?.pendingLive == nil);#expect(store.active.first?.messages.count == 1)
        #expect(store.active.first?.desktop?.state == .pending);#expect(store.active.first?.downloadedUntil == nil)
    }
    @Test("A live CAS conflict preserves the partial and exposes the exact remote history")
    func conflict() throws {
        let root=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space=UUID().uuidString,id=UUID().uuidString,answer=UUID()
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.research)
        let proposed=ChatHistoryStore.Conversation(id:id,title:"Pregunta",messages:[.init(role:.user,text:"Consulta",citations:[])],createdAt:Date(),updatedAt:Date(),isArchived:false)
        let request=try store.beginLive(proposed,pairingId:"Mac",generation:.object([:]),answerId:answer)
        try store.applyLiveEvents(id:id,requestId:request.requestId,events:[event(1,"mobile:chat:delta",request.requestId,.string("Texto local recibido"))])
        let remote=try snapshot(request,answer:"Edición de Desktop")
        try store.finishInterruptedLive(id:id,request:request,remote:remote,state:"failed",issue:"chat_revision_conflict")
        #expect(store.active.first?.messages.last?.text == "Texto local recibido")
        #expect(store.active.first?.desktop?.state == .conflict);#expect(store.active.first?.desktop?.remote == remote)
        #expect(store.active.first?.pendingLive == nil)
        try store.resolveConflict(id:id,keepMobile:false)
        #expect(store.active.first(where:{$0.id == id})?.messages.last?.text == "Edición de Desktop")
        #expect(store.active.contains(where:{$0.isLocalRecovery == true && $0.messages.last?.text == "Texto local recibido"}))
    }
    private func event(_ sequence:Int,_ channel:String,_ id:String,_ value:JSONValue) throws -> DesktopBridgeJob.Event {
        try JSONDecoder.nodus.decode(DesktopBridgeJob.Event.self,from:JSONEncoder.nodus.encode(JSONValue.object(["sequence":.int(Int64(sequence)),"channel":.string(channel),"args":.array([.string(id),value])])))
    }
    private func json<T:Encodable>(_ value:T) throws -> JSONValue { try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(value)) }
    private func snapshot(_ request:CompanionLiveChatRequest,answer:String) throws -> CompanionChatDocument {
        let draft=request.edit.objectValue!["draft"]!.objectValue!
        var data:[String:JSONValue]=["id":.string(request.conversationId),"title":draft["title"]!,"archived":.bool(false),"createdAt":.string("2026-10-11T09:30:00Z"),"updatedAt":.string("2026-10-11T09:30:01Z")]
        var messages=draft["messages"]!.arrayValue!
        messages.append(.object(["id":.string(request.answerId),"role":.string("assistant"),"content":.string(answer),"createdAt":.string("2026-10-11T09:30:01Z"),"skills":.array([.object(["id":.string("actual-Mac-skill"),"name":.string("Habilidad")])])]))
        data["messages"] = .array(messages)
        if request.kind == .study { data.merge(draft["study"]!.objectValue!,uniquingKeysWith:{$1}) }
        if request.kind == .world { data.merge(draft["world"]!.objectValue!,uniquingKeysWith:{$1}) }
        if request.kind == .database { data["databaseIds"]=draft["databaseIds"] }
        return CompanionChatDocument(version:1,kind:request.kind,id:request.conversationId,revision:String(repeating:"a",count:64),data:.object(data),companion:nil)
    }
}
