import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Autonomous report source scope")
struct ResearchMaterialScopeTests {
    @Test("a resumed checkpoint preserves the prior material scope and its already-paid sections")
    func checkpointScope() throws {
        let request = DeepResearchRequest(objective: "Fotografía", model: .init(provider: .openai, model: "fixture"))
        let checkpoint = DeepResearchCheckpoint(request: request, titles: ["Fuente", "Comparación"], wordTarget: 100,
            sections: [.init(title: "Fuente", prose: "Prosa ya generada", citations: [], rejectedCitations: [])],
            citationsChecked: 0, citationsRejected: 0, startedAt: Date(timeIntervalSince1970: 1000))
        let saved = checkpoint.withMaterialScopes(["device_downloads"])
        let reopened = try JSONDecoder.nodus.decode(DeepResearchCheckpoint.self, from: JSONEncoder.nodus.encode(saved))
        #expect(reopened.materialScopes == ["device_downloads"]); #expect(reopened.nextSectionIndex == 1)
        #expect(reopened.sections == checkpoint.sections); #expect(reopened.startedAt == checkpoint.startedAt)
        var legacy = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(checkpoint)).objectValue!
        legacy.removeValue(forKey: "materialScopes")
        #expect(try JSONDecoder.nodus.decode(DeepResearchCheckpoint.self, from: JSONEncoder.nodus.encode(JSONValue.object(legacy))).materialScopes == nil)
    }

    @Test("passage prompts retain literal evidence beyond the citation's short display label")
    func fullLiteralEvidence() throws {
        let text = "Fotografía · " + String(repeating: "Evidencia literal íntegra. ", count: 30) + "ÚLTIMA FRASE"
        let value: JSONValue = .object(["sections": .array([.object(["kind": .string("passages"), "items": .array([
            .object(["passage_id": .string("p"), "nodus_id": .string("w"), "text": .string(text), "page_label": .string("37")])])])]),
            "stats": .object(["chars": .int(1000), "budget": .int(120_000), "truncated": .bool(false), "matched": .int(1)]), "citationScheme": .object([:])])
        let context = try JSONDecoder.nodus.decode(ContextPackage.self, from: JSONEncoder.nodus.encode(value))
        let entry = try #require(CitationCatalog.from(context).entries.first)
        #expect(entry.label.count <= 120); #expect(entry.detail == text)
        #expect(entry.workId == "w"); #expect(entry.locator == "37")
    }

    @Test("device and mixed scope survives persisted reports and exports without discarding support or audit")
    func durableScope() throws {
        let report = DeepResearchReport(objective: "Fotografía", sections: [.init(title: "Fuente", prose: "Prosa guardada", citations: [], rejectedCitations: [])],
            references: [], words: 2, pages: 1, citationsChecked: 0, citationsRejected: 0, stoppedReason: nil,
            audit: .init(citationsChecked: 0, citationsRejected: 0, citedSourceCount: 0, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(report.materialNotice == nil)
        let selected = report.withMaterialScopes(["device_downloads"])
        #expect(selected.audit == report.audit)
        let decoded = try JSONDecoder.nodus.decode(DeepResearchReport.self, from: JSONEncoder.nodus.encode(selected))
        #expect(decoded.materialScopes == ["device_downloads"]); #expect(decoded.markdown.contains("no representa el vault completo"))
        #expect(decoded.audit == report.audit); #expect(decoded.supportMatrix == report.supportMatrix); #expect(decoded.sections == report.sections)
        let mixed = selected.withMaterialScopes(["device_downloads", "linked_corpus"])
        #expect(mixed.materialNotice?.contains("combina") == true)
        var legacy = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(report)).objectValue!
        legacy.removeValue(forKey: "materialScopes")
        #expect(try JSONDecoder.nodus.decode(DeepResearchReport.self, from: JSONEncoder.nodus.encode(JSONValue.object(legacy))).materialNotice == nil)
    }
}
