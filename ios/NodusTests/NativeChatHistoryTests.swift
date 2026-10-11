import Foundation
import Testing
import NodusAI
import NodusKit
@testable import Nodus

@Suite("Native companion conversation recovery")
@MainActor
struct NativeChatHistoryTests {
    @Test("Per-turn authorship times survive persistence, synchronization and legacy imports")
    func authorshipTimes() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString,id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let first = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        try first.bind(kind:.research)
        let questionAt = Date(timeIntervalSince1970:1_767_344_400.125),answerAt = questionAt.addingTimeInterval(135.25)
        let messages: [ChatHistoryStore.Message] = [.init(role:.user,text:"Question",citations:[],createdAt:questionAt),.init(role:.assistant,text:"Answer",citations:[],createdAt:answerAt)]
        try first.save(.init(id:id,title:"Question",messages:messages,createdAt:questionAt,updatedAt:answerAt,isArchived:false))
        let reopened = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        #expect(reopened.conversations.first?.messages.map(\.createdAt) == [questionAt,answerAt])
        var sent: JSONValue?
        await reopened.synchronize { _,request in sent = request;throw URLError(.networkConnectionLost) }
        let raw = try #require(sent?.objectValue?["draft"]?.objectValue?["messages"]?.arrayValue)
        #expect(raw[0].objectValue?["createdAt"] == .string("2026-01-02T09:00:00.125Z"))
        #expect(raw[1].objectValue?["createdAt"] == .string("2026-01-02T09:02:15.375Z"))
        let legacyId = UUID().uuidString
        let legacy = try reopened.importDesktop(document(id:legacyId,messages:[.object(["id":.string(UUID().uuidString),"role":.string("user"),"content":.string("Earlier turn")])]))
        #expect(legacy.messages.first?.createdAt == nil)
    }
    @Test("Follow-ups retain chronological roles, current sources and complete bounded turns")
    func context() {
        let history:[ChatMessage] = [.init(role:.system,content:"Not a user-controlled system instruction"),.init(role:.user,content:"Primera pregunta 🌊"),.init(role:.assistant,content:"Respuesta anterior"),.init(role:.user,content:"Segunda pregunta"),.init(role:.assistant,content:"Otra respuesta")]
        let full = NativeChatPrompt.make(history:history,system:"Sistema vigente",question:"Y después?",citations:"Fuentes vigentes")
        #expect(full.messages.map(\.role) == [.system,.user,.assistant,.user,.assistant,.user])
        #expect(full.messages[1].content == "Primera pregunta 🌊")
        #expect(full.messages.last?.content == "Y después?\n\nFuentes vigentes")
        #expect(full.omittedTurns == 0)
        let recent = NativeChatPrompt.make(history:history,system:"Sistema",question:"Nueva",citations:"Fuentes",maxHistoryBytes:"Segunda pregunta".utf8.count + "Otra respuesta".utf8.count)
        #expect(recent.messages.map(\.content) == ["Sistema","Segunda pregunta","Otra respuesta","Nueva\n\nFuentes"])
        #expect(recent.omittedTurns == 2)
        let oversize = NativeChatPrompt.make(history:[.init(role:.user,content:"Pregunta"),.init(role:.assistant,content:String(repeating:"🌊",count:100))],system:"Sistema",question:"Nueva",citations:"Fuentes",maxHistoryBytes:20)
        #expect(oversize.messages.count == 2);#expect(oversize.omittedTurns == 2)
    }
    @Test("Accepted questions and partial replies reopen with their original message identities")
    func durability() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString,id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let first = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        let messages:[ChatHistoryStore.Message] = [.init(role:.user,text:"Pregunta",citations:[]),.init(role:.assistant,text:"Texto recibido 🌊",citations:[],delivery:.streaming)]
        let conversation = ChatHistoryStore.Conversation(id:id,title:"Pregunta",messages:messages,createdAt:Date(),updatedAt:Date(),isArchived:false)
        try first.save(conversation)
        let reopened = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        #expect(reopened.conversations.first?.messages == messages)
        #expect(reopened.conversations.first?.messages.last?.delivery == .streaming)
        try reopened.setArchived(true,for:id)
        #expect(ChatHistoryStore(spaceId:space,root:root,backup:nil).archived.count == 1)
        #expect(ChatHistoryStore(spaceId:UUID().uuidString,root:root,backup:nil).conversations.isEmpty)
        let corrupt = ChatHistoryStore.directory(spaceId:space,root:root).appendingPathComponent("broken.json")
        try Data("{broken".utf8).write(to:corrupt)
        reopened.reload();#expect(reopened.issue != nil);#expect(reopened.conversations.count == 1)
        #expect(FileManager.default.fileExists(atPath:corrupt.path))
    }
    @Test("A failed write is surfaced instead of pretending the exchange was saved")
    func writeFailure() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("A file cannot contain a conversations directory".utf8).write(to:root)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:UUID().uuidString,root:root,backup:nil)
        let conversation = ChatHistoryStore.Conversation(id:UUID().uuidString,title:"Trabajo propio",messages:[],createdAt:Date(),updatedAt:Date(),isArchived:false)
        #expect(throws:(any Error).self) { try store.save(conversation) }
        #expect(store.conversations.isEmpty);#expect(store.issue != nil)
    }

    private func document(id: String,kind: CompanionChatKind = .research,messages: [JSONValue],revision: String = String(repeating:"a",count:64),companion: JSONValue = .null) throws -> CompanionChatDocument {
        try JSONDecoder.nodus.decode(CompanionChatDocument.self,from:JSONEncoder.nodus.encode(JSONValue.object(["version":.int(1),"kind":.string(kind.rawValue),"id":.string(id),"revision":.string(revision),"data":.object(["id":.string(id),"title":.string("Historial del Mac"),"messages":.array(messages),"archived":.bool(false),"created_at":.string("2026-10-11T08:00:00Z"),"updated_at":.string("2026-10-11T08:00:00Z")]),"companion":companion])))
    }
    private func receipt(_ request: JSONValue,revision: String = String(repeating:"a",count:64)) throws -> JSONValue {
        let fields = request.objectValue!,draft = fields["draft"]!.objectValue!
        return .object(["id":fields["id"]!,"snapshot":.object(["version":.int(1),"kind":.string("research"),"id":fields["conversationId"]!,"revision":.string(revision),"data":.object(["id":fields["conversationId"]!,"title":draft["title"]!,"messages":draft["messages"]!,"archived":draft["archived"]!]),"companion":fields["companion"] ?? .null])])
    }
    @Test("A lost acknowledgement reopens the frozen edit and does not duplicate the chat")
    func lostAcknowledgement() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString,id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        try store.bind(kind:.research)
        try store.save(.init(id:id,title:"Trabajo móvil",messages:[.init(role:.user,text:"Pregunta",citations:[]),.init(role:.assistant,text:"Respuesta",citations:[],delivery:.completed)],createdAt:Date(),updatedAt:Date(),isArchived:false))
        var first: JSONValue?
        await store.synchronize { _,request in first = request;throw URLError(.networkConnectionLost) }
        #expect(store.conversations.first?.desktop?.state == .pending)
        let reopened = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        var replay: JSONValue?
        await reopened.synchronize { _,request in replay = request;return try receipt(request) }
        #expect(first == replay);#expect(reopened.conversations.first?.desktop?.state == .saved)
        #expect(reopened.conversations.first?.id == id)
        try reopened.setArchived(true,for:id)
        await reopened.synchronize { _,request in
            #expect(request.objectValue?["expectedRevision"] == .string(String(repeating:"a",count:64)))
            #expect(request.objectValue?["draft"]?.objectValue?["archived"] == .bool(true))
            return try receipt(request,revision:String(repeating:"b",count:64))
        }
        try reopened.delete(id);#expect(reopened.active.isEmpty);#expect(reopened.archived.isEmpty)
        await reopened.synchronize { _,request in
            #expect(request.objectValue?["action"] == .string("delete"))
            #expect(request.objectValue?["expectedRevision"] == .string(String(repeating:"b",count:64)))
            return .object(["id":request.objectValue!["id"]!,"deleted":.bool(true)])
        }
        #expect(ChatHistoryStore(spaceId:space,root:root,backup:nil).conversations.isEmpty)
    }
    @Test("A newer edit received during the network send survives the old acknowledgement")
    func coalescedEdit() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString,id = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.research)
        try store.save(.init(id:id,title:"Primero",messages:[.init(role:.user,text:"Pregunta",citations:[])],createdAt:Date(),updatedAt:Date(),isArchived:false))
        await store.synchronize { _,request in
            var edited = store.conversations[0];edited.messages.append(.init(role:.assistant,text:"Respuesta nueva",citations:[],delivery:.completed));try store.save(edited)
            return try receipt(request)
        }
        #expect(store.conversations.first?.desktop?.state == .pending)
        #expect(store.conversations.first?.messages.last?.text == "Respuesta nueva")
        await store.synchronize { _,request in
            #expect(request.objectValue?["draft"]?.objectValue?["messages"]?.arrayValue?.count == 2)
            #expect(request.objectValue?["expectedRevision"] == .string(String(repeating:"a",count:64)))
            return try receipt(request,revision:String(repeating:"b",count:64))
        }
        #expect(store.conversations.first?.desktop?.state == .saved)
    }
    @Test("Selected rich chats are temporary, while edits and explicit conflict recovery are retained")
    func richAndConflict() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString,id = UUID().uuidString,messageId = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.research)
        let rich: JSONValue = .object(["id":.string(messageId),"role":.string("assistant"),"content":.string("Respuesta del Mac"),"skills":.array([.object(["id":.string("fixture"),"name":.string("Habilidad")])]),"attachments":.array([.object(["id":.string("attachment")])]),"selectionKey":.string("selected-scope")])
        let source = try document(id:id,messages:[rich])
        let selected = try store.importDesktop(source);#expect(selected.downloadedUntil != nil)
        var edited = selected;edited.messages.append(.init(role:.user,text:"Seguimiento",citations:[]));try store.save(edited)
        #expect(store.conversations.first?.downloadedUntil == nil)
        let remote = try document(id:id,messages:[.object(["id":.string(messageId),"role":.string("assistant"),"content":.string("Edición del Mac")])],revision:String(repeating:"b",count:64))
        await store.synchronize { _,request in
            #expect(request.objectValue?["draft"]?.objectValue?["messages"]?.arrayValue?.first == rich)
            throw APIError(status:409,code:"chat_revision_conflict",message:"Conflict",details:["remote":try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(remote))])
        }
        #expect(store.conversations.first?.desktop?.state == .conflict)
        try store.resolveConflict(id:id,keepMobile:false)
        #expect(store.conversations.first(where:{$0.id == id})?.messages.first?.text == "Edición del Mac")
        let recovered = try #require(store.conversations.first(where:{$0.isLocalRecovery == true}))
        #expect(recovered.messages.last?.text == "Seguimiento");#expect(recovered.desktop == nil)
        try store.bind(kind:.research);#expect(store.conversations.first(where:{$0.id == recovered.id})?.desktop == nil)
    }
    @Test("Removing a download keeps the Mac conversation and revocation keeps authored drafts")
    func downloadsAndRevocation() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.research)
        let id = UUID().uuidString
        try store.importDesktop(document(id:id,messages:[]));try store.removeDownloaded(id)
        #expect(store.conversations.isEmpty)
        try store.importDesktop(document(id:UUID().uuidString,messages:[]))
        let own = UUID().uuidString
        try store.save(.init(id:own,title:"Pregunta propia",messages:[.init(role:.user,text:"Conservar",citations:[])],createdAt:Date(),updatedAt:Date(),isArchived:false))
        try store.revokeLink()
        #expect(store.conversations.count == 1);#expect(store.conversations.first?.id == own)
        #expect(store.conversations.first?.desktop?.state == .blocked)
    }
}
