import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Native autonomous Study companion")
@MainActor
struct CompanionStudyChatTests {
    @Test("Full question and study-exam originals reject a mismatched source identity")
    func originalIdentity() async throws {
        let question: JSONValue = .object(["id":.string("question-1"),"prompt":.string("¿Qué regula el intercambio?"),"explanation":.string("El gradiente."),"answer":.object(["text":.string("El gradiente")]),"options":.array([])])
        let source: JSONValue = .object(["kind":.string("question"),"sourceId":.string("question-1"),"data":question])
        try await CompanionChatContext.validateStudyOriginal(source)
        let exam: JSONValue = .object(["kind":.string("exam"),"sourceId":.string("exam-1"),"data":.object(["id":.string("exam-1"),"kind":.string("exam"),"title":.string("Examen de membrana"),"description":.string(""),"items":.array([.object(["questionId":.string("question-1"),"points":.int(2),"question":question])])])])
        try await CompanionChatContext.validateStudyOriginal(exam)
        var wrong = source.objectValue!;wrong["sourceId"] = .string("another-question")
        await #expect(throws:(any Error).self) { try await CompanionChatContext.validateStudyOriginal(.object(wrong)) }
    }
    private func citation() -> JSONValue {
        .object(["id":.string("S1"),"sourceKey":.string("material:source"),"indexId":.string("fragment"),"kind":.string("material"),"sourceId":.string("source"),"title":.string("Membrana 🌊"),"subtitle":.string("Biología"),"quote":.string("El gradiente permite intercambio."),"location":.object(["materialId":.string("source"),"pageNumber":.int(3)]),"scope":.object(["courseId":.null,"subjectId":.null,"folderId":.null,"topicId":.null])])
    }
    @Test("An actual Desktop study conversation retains controls and locatable evidence")
    func desktopCopy() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:UUID().uuidString,root:root,backup:nil),id = UUID().uuidString
        var options = CompanionStudyChatOptions();options.selection.scope = "manual";options.selection.sourceKeys = ["material:source"];options.task = "compare";options.level = "advanced";options.tone = "academic";options.language = "fr"
        var data = try options.value.objectValue!
        data["id"] = .string(id);data["title"] = .string("Estudio");data["archived"] = .bool(false)
        data["messages"] = .array([.object(["id":.string(UUID().uuidString),"role":.string("assistant"),"content":.string("Intercambio [S1](nodus://study/evidence/S1)"),"citations":.array([citation()])])])
        let document = CompanionChatDocument(version:1,kind:.study,id:id,revision:String(repeating:"a",count:64),data:.object(data),companion:nil)
        let imported = try store.importDesktop(document)
        #expect(imported.study == options)
        #expect(imported.messages.first?.studyCitations == [citation()])
        #expect(ChatHistoryStore(spaceId:"unused",root:root,backup:nil).conversations.isEmpty)
        #expect(imported.messages.first?.desktopRecord?.objectValue?["citations"] == .array([citation()]))
    }
    @Test("Authored evidence and chosen controls survive restart, frozen sync and the real ACK shape")
    func durableEvidence() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),space = UUID().uuidString
        defer { try? FileManager.default.removeItem(at:root) }
        let store = ChatHistoryStore(spaceId:space,root:root,backup:nil);try store.bind(kind:.study)
        var options = CompanionStudyChatOptions();options.selection.scope = "manual";options.selection.sourceKeys = ["material:source"];options.task = "explain"
        let user = ChatHistoryStore.Message(role:.user,text:"Qué cambia?",citations:[])
        let proof: JSONValue = .object(["S1":.object(["entry":.object(["indexId":.string("fragment")]),"signature":.string(String(repeating:"a",count:64)),"maxChars":.int(3600)])])
        let reply = ChatHistoryStore.Message(role:.assistant,text:"Intercambio [S1](nodus://study/evidence/S1)",citations:[],delivery:.completed,studyCitations:[citation()],studyEvidence:proof)
        let conversation = ChatHistoryStore.Conversation(id:UUID().uuidString,title:"Estudio",messages:[user,reply],createdAt:Date(),updatedAt:Date(),isArchived:false,study:options)
        try store.save(conversation)
        let reopened = ChatHistoryStore(spaceId:space,root:root,backup:nil)
        #expect(reopened.conversations.first?.study == options)
        #expect(reopened.conversations.first?.messages.last?.studyEvidence == proof)
        await reopened.synchronize { kind,request in
            #expect(kind == .study)
            let draft = try #require(request.objectValue?["draft"]?.objectValue)
            #expect(draft["study"] == (try options.value))
            #expect(draft["studyEvidence"]?.objectValue?[reply.id.uuidString] == proof)
            #expect(draft["messages"]?.arrayValue?.last?.objectValue?["citations"] == .array([citation()]))
            var data = try options.value.objectValue!;data["id"] = .string(conversation.id);data["title"] = .string("Estudio");data["archived"] = .bool(false);data["messages"] = draft["messages"]
            let snapshot = CompanionChatDocument(version:1,kind:.study,id:conversation.id,revision:String(repeating:"b",count:64),data:.object(data),companion:request.objectValue?["companion"])
            return .object(["id":request.objectValue!["id"]!,"snapshot":try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(snapshot))])
        }
        #expect(reopened.conversations.first?.desktop?.state == .saved)
        #expect(reopened.conversations.first?.messages.last?.studyCitations == [citation()])
    }
    @Test("Native citation verification actually executes the bundled Desktop validator")
    func sharedCitationValidator() async throws {
        _ = try #require(Bundle.main.url(forResource:"companion-chat",withExtension:"js",subdirectory:"SharedDesktop"))
        let answer = try await CompanionChatContext.validateStudyAnswer("Gradiente [S1]. Inventado [S999].",citations:[citation()])
        #expect(answer.citations == [citation()]);#expect(!answer.answer.contains("S999"));#expect(answer.answer.contains("nodus://study/evidence/S1"))
    }
}
