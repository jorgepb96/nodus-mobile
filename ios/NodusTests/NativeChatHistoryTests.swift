import Foundation
import Testing
import NodusAI
import NodusKit
@testable import Nodus

@Suite("Native companion conversation recovery")
@MainActor
struct NativeChatHistoryTests {
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
}
