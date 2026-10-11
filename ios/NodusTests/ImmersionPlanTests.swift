import Foundation
import NodusKit
import Testing
@testable import Nodus

@Suite("Native immersion source fidelity")
struct ImmersionPlanTests {
    @Test("native study stations preserve full quotes, commentary and actual citation identity")
    func completeCitations() throws {
        let literal = String(repeating: "Evidencia literal íntegra. ", count: 900)
        let commentary = String(repeating: "Lectura de la fuente. ", count: 300)
        let plan: JSONValue = .object(["title": .string("Fotografía"), "topic": .string("Fotografía"), "minutes": .int(60),
            "stations": .array([.object(["id": .string("station"), "title": .string("Primera estación"),
                "citations": .array([.object(["passageId": .string("passage%2F37"), "workId": .string("work"),
                    "workTitle": .string("Obra de prueba"), "authors": .array([.string("Autora, A.")]),
                    "text": .string(literal), "commentary": .string(commentary), "whyItMatters": .string("Aporta contexto verificable.")])]), "quiz": .array([])])]),
            "exam": .object(["questions": .array([])])])
        let native = try #require(ImmersionPlan(Row(["plan": plan])))
        let citation = try #require(native.stations.first?.citations.first)
        #expect(native.source == plan); #expect(citation.text == literal); #expect(citation.commentary == commentary)
        #expect(citation.whyItMatters == "Aporta contexto verificable.")
        let reference = try #require(citation.targetURL.flatMap(CorpusReference.init))
        #expect(reference.recordId == "passage%2F37"); #expect(reference.destination == .passage)
    }
}
