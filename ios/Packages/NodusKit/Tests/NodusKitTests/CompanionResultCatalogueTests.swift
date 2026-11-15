import Foundation
import Testing
@testable import NodusKit

@Suite("Device-authored results in their owning section")
struct CompanionResultCatalogueTests {
    private func request(_ method: String, _ checkpoint: JSONValue?, state: String = "pending") -> DesktopJobLedger.Request {
        var result = DesktopJobLedger.Request(id: UUID().uuidString, method: method, args: [], createdAt: Date(), jobId: nil, state: state, issue: nil)
        result.checkpoint = checkpoint
        return result
    }
    @Test("translations stay with the source section before and after acknowledgement")
    func translations() {
        for state in ["pending", "accepted", "running", "saved", "available", "failed", "interrupted", "cancelled"] {
            for (kind, surface) in [("deep_research", "deepResearch"), ("immersion", "immersion"), ("study_document", "workspace"), ("study_transcript", "workspace"), ("study_assistant", "workspace")] {
                let value = request("saveContentTranslationFromMobile", .object(["request": .object(["entityKind": .string(kind), "sourceTitle": .string("Chosen source")]), "markdown": .string("Complete translation")]), state: state)
                #expect(CompanionResultCatalogue.contains(value, in: surface))
                for other in ["dictionary", "deepResearch", "workspace", "immersion", "chat", "argument", "graph"] where other != surface {
                    #expect(!CompanionResultCatalogue.contains(value, in: other))
                }
                #expect(CompanionResultCatalogue.title(value) == "Chosen source")
            }
        }
        #expect(!CompanionResultCatalogue.contains(request("saveContentTranslationFromMobile", .object(["request": .object(["entityKind": .string("unknown")]), "markdown": .string("Body")])), in: "workspace"))
        #expect(!CompanionResultCatalogue.contains(request("saveContentTranslationFromMobile", .object(["request": .object(["entityKind": .string("deep_research")]), "markdown": .string("")])), in: "deepResearch"))
    }
    @Test("only complete publication types are offered as locally readable results")
    func completeResults() {
        let dictionary = request("saveDictionaryGeneratedVersion", .object(["context": .object(["entry": .object(["term": .string("Exact concept")])]), "definition": .object(["contentMarkdown": .string("Definition")])]))
        #expect(CompanionResultCatalogue.contains(dictionary, in: "dictionary"))
        #expect(CompanionResultCatalogue.title(dictionary) == "Exact concept")
        #expect(!CompanionResultCatalogue.contains(dictionary, in: "workspace"))
        let writing = request("saveStudyImprovementFromMobile", .object(["preview": .object(["text": .string("Protected preview")])]))
        #expect(CompanionResultCatalogue.contains(writing, in: "workspace"))
        #expect(!CompanionResultCatalogue.contains(request("saveStudyImprovementFromMobile", .object(["raw": .string("Incomplete provider text")])), in: "workspace"))
        let immersion = request("saveImmersionGeneratedSession", .object(["plan": .object(["title": .string("Complete plan")])]))
        #expect(CompanionResultCatalogue.contains(immersion, in: "immersion"))
        #expect(CompanionResultCatalogue.title(immersion) == "Complete plan")
        #expect(!CompanionResultCatalogue.contains(request("researchChatStream", .object(["markdown": .string("Message")])), in: "chat"))
        #expect(!CompanionResultCatalogue.contains(request("saveDictionaryGeneratedVersion", nil), in: "dictionary"))
    }
}
