import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Native autonomous world companion")
@MainActor
struct CompanionWorldChatTests {
    @Test("An actual world history copy retains manual focus and follow-up settings")
    func desktopContext() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:UUID().uuidString,root:root,backup:nil)
        var options = CompanionWorldChatOptions();options.selection.scope = "manual";options.selection.entryKeys = ["character:kaelen"];options.selection.keepFocus = true
        options.focus = [.init(kind:"character",id:"kaelen",title:"Kaelen 🌊")]
        let id = UUID().uuidString
        var data = try options.value.objectValue!;data["id"] = .string(id);data["title"] = .string("Mundo");data["archived"] = .bool(false);data["messages"] = .array([])
        let document = CompanionChatDocument(version:1,kind:.world,id:id,revision:String(repeating:"a",count:64),data:.object(data),companion:nil)
        let imported = try store.importDesktop(document)
        #expect(imported.world == options);#expect(imported.world?.focusKeys == ["character:kaelen"])
    }
    @Test("Calculated facts persist with the answer and choices synchronize without providers")
    func durableFacts() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.world)
        var options = CompanionWorldChatOptions();options.selection.keepFocus = true;options.focus = [.init(kind:"character",id:"kaelen",title:"Kaelen")]
        let facts: JSONValue = .object(["worldDay":.int(15),"computed":.object(["memberships":.array([.object(["personName":.string("Kaelen"),"groupName":.string("Cuervos"),"fromWorldDay":.int(10),"toWorldDay":.int(20)])])])])
        let message = ChatHistoryStore.Message(role:.assistant,text:"Pertenecía a los Cuervos.",citations:[],delivery:.completed,worldFacts:facts)
        let conversation = ChatHistoryStore.Conversation(id:UUID().uuidString,title:"Mundo",messages:[message],createdAt:Date(),updatedAt:Date(),isArchived:false,world:options)
        try store.save(conversation)
        let reopened = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        #expect(reopened.conversations.first?.messages.first?.worldFacts == facts)
        await reopened.synchronize { kind,request in
            #expect(kind == .world);#expect(request.objectValue?["draft"]?.objectValue?["world"] == (try options.value))
            throw URLError(.networkConnectionLost)
        }
        #expect(reopened.conversations.first?.desktop?.state == .pending)
        #expect(reopened.conversations.first?.desktop?.sending != nil)
        #expect(ChatHistoryStore(spaceId:space,root:root,backup:nil).conversations.first?.messages.first?.worldFacts == facts)
    }
    @Test("The actual shared citation validator rejects a real but unsupplied world ID")
    func citations() async throws {
        _ = try #require(Bundle.main.url(forResource:"companion-chat",withExtension:"js",subdirectory:"SharedDesktop"))
        let answer = try await CompanionChatContext.validateWorldAnswer("Está aquí [Kaelen](nodus://world/character/kaelen). Inventado [Otro](nodus://world/character/other).",citable:[.init(kind:"character",id:"kaelen",title:"Kaelen")])
        #expect(answer.contains("nodus://world/character/kaelen"));#expect(!answer.contains("nodus://world/character/other"))
    }
}
